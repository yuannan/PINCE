{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default";
  };

  outputs = { self, nixpkgs, systems, ... }:
    let
      forEachSystem = nixpkgs.lib.genAttrs (import systems);
    in
    {
      packages = forEachSystem (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          python = pkgs.python311;
          pythonEnv = python.withPackages (ps: with ps; [
            pyqt6
            pycairo
            pygobject3
            capstone
            keyboard
            keystone-engine
            pygdbmi
            pexpect
          ]);
          
          # Fetch libscanmem separately
          libscanmem-src = pkgs.fetchFromGitHub {
            owner = "brkzlr";
            repo = "libscanmem-PINCE";
            rev = "e69461446cf9a541ed4c2a4a7b1bc6621503d218";
            sha256 = "sha256-s0HCgd7VM9uKXLfZl5h5Xv7GNoQkqg78nWcGIpXX8DA=";
          };
          
          # Fetch libptrscan files
          libptrscanSource = pkgs.fetchurl {
            url = "https://github.com/kekeimiku/PointerSearcher-X/archive/refs/tags/v0.7.4-dylib.tar.gz";
            sha256 = "sha256-LKRAJx6PFfV9vCq9n08Oye8zkgXUQvGQ1jQOGnXiByI=";
          };
          
          libptrscanBinary = pkgs.fetchurl {
            url = "https://github.com/kekeimiku/PointerSearcher-X/releases/download/v0.7.4-dylib/libptrscan_pince-x86_64-unknown-linux-gnu.tar.gz";
            sha256 = "sha256-woo19XWAoQ/YJrmCBhgQNopCedOJig7xp4a9+Ljz+/M=";
          };
        in
        {
          default = self.packages.${system}.PINCE;
          
          PINCE = pkgs.stdenv.mkDerivation rec {
            pname = "PINCE";
            version = "unstable-2024";

            src = ./.;

            nativeBuildInputs = with pkgs; [
              cmake
              pkg-config
              qt6.qttools
              qt6.wrapQtAppsHook
              makeWrapper
              gobject-introspection
            ];

            buildInputs = with pkgs; [
              pythonEnv
              gdb
              libtool
              cairo
              gobject-introspection
              qt6.qtbase
              qt6.qtwayland
              gtk3
              glib
              libGL
              libGLU
              libxkbcommon
              xorg.libX11
              xorg.libxcb
              xorg.libXcursor
              xorg.libXi
              xorg.libXrandr
              wayland
              dbus
              stdenv.cc.cc.lib
            ];

            # Don't run cmake automatically
            dontConfigure = true;

            postUnpack = ''
              # Copy libscanmem source into the build
              echo "Copying libscanmem source..."
              cp -r ${libscanmem-src} $sourceRoot/libscanmem-PINCE
              chmod -R u+w $sourceRoot/libscanmem-PINCE
              
              echo "Contents after copying:"
              ls -la $sourceRoot/
            '';

            buildPhase = ''
              runHook preBuild
              
              # Build libscanmem
              echo "Building libscanmem..."
              
              mkdir -p libpince/libscanmem
              cd libscanmem-PINCE
              cmake -DCMAKE_BUILD_TYPE=Release .
              make -j$NIX_BUILD_CORES
              cp libscanmem.so ../libpince/libscanmem/
              cp wrappers/scanmem.py ../libpince/libscanmem/
              cd ..
              
              # Extract libptrscan
              echo "Installing libptrscan..."
              mkdir -p libpince/libptrscan
              
              # Extract source (for license compliance)
              tar xf ${libptrscanSource} -C libpince/libptrscan
              
              # Extract binary
              tar xf ${libptrscanBinary} -C libpince/libptrscan --strip-components 1
              
              # Compile translations
              echo "Compiling translations..."
              if [ -d "i18n/ts" ]; then
                ${pkgs.qt6.qttools}/bin/lrelease i18n/ts/*
                mkdir -p i18n/qm
                mv i18n/ts/*.qm i18n/qm/ 2>/dev/null || true
              fi
              
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              
              # Create installation directory
              mkdir -p $out/share/pince
              
              # Copy all PINCE files
              cp -r * $out/share/pince/
              
              # Create bin directory
              mkdir -p $out/bin
              
              # Create wrapper script with makeWrapper
              makeWrapper ${pythonEnv}/bin/python $out/bin/pince \
                --run "cd $out/share/pince" \
                --prefix LD_LIBRARY_PATH : "${pkgs.lib.makeLibraryPath [
                  pkgs.stdenv.cc.cc.lib
                  pkgs.glib
                  pkgs.cairo
                  pkgs.gtk3
                  pkgs.libGL
                  pkgs.libGLU
                  pkgs.libxkbcommon
                  pkgs.dbus.lib
                  pkgs.xorg.libX11
                  pkgs.xorg.libxcb
                  pkgs.xorg.libXcursor
                  pkgs.xorg.libXi
                  pkgs.xorg.libXrandr
                  pkgs.wayland
                ]}" \
                --prefix GI_TYPELIB_PATH : "${pkgs.lib.makeSearchPath "lib/girepository-1.0" [
                  pkgs.gtk3
                  pkgs.glib
                  pkgs.gobject-introspection
                  pkgs.cairo
                ]}" \
                --set PYTHONPATH "$out/share/pince" \
                --set PYTHONDONTWRITEBYTECODE "1" \
                --add-flags "$out/share/pince/PINCE.py" \
                --prefix PATH : "${pkgs.lib.makeBinPath [ pkgs.sudo pkgs.gdb ]}"
              
              runHook postInstall
            '';

            # Tell wrapQtAppsHook to wrap our binary
            dontWrapQtApps = false;
            
            preFixup = ''
              wrapQtApp $out/bin/pince
            '';

            meta = with pkgs.lib; {
              description = "A reverse engineering tool for games (Linux alternative to Cheat Engine)";
              homepage = "https://github.com/korcankaraokcu/PINCE";
              license = licenses.gpl3Plus;
              platforms = platforms.linux;
              mainProgram = "pince";
            };
          };
        });

      # Development shell
      devShells = forEachSystem (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            inputsFrom = [ self.packages.${system}.PINCE ];
            shellHook = ''
              echo "PINCE development environment"
              echo "Run 'nix build' to build the package"
              echo "Run 'nix run' to run PINCE"
            '';
          };
        });
    };
}
