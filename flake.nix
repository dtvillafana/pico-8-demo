{
  description = "PICO-8 development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.pico8-ls = {
    url = "github:japhib/pico8-ls";
    flake = false;
  };

  outputs =
    {
      self,
      nixpkgs,
      pico8-ls,
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      pico8-ls-package = pkgs.buildNpmPackage {
        pname = "pico8-ls";
        version = "0.7.0";
        src = "${pico8-ls}/server";
        npmDepsHash = "sha256-sauXR/uK5BtAA2rMLFamH4kNHjeSUGRHBhPBuxUS0Is=";
        npmBuildScript = "compile";
        nativeBuildInputs = [ pkgs.makeWrapper ];
        dontNpmInstall = true;
        # Upstream's server tsconfig includes tests without Mocha type definitions.
        postPatch = ''
          ${pkgs.nodejs}/bin/node -e '
            const fs = require("fs");
            const config = JSON.parse(fs.readFileSync("tsconfig.json", "utf8"));
            config.exclude = ["src/**/test/**"];
            fs.writeFileSync("tsconfig.json", JSON.stringify(config));
          '
        '';
        installPhase = ''
          runHook preInstall
          mkdir -p "$out/lib/pico8-ls" "$out/bin"
          cp -r out node_modules "$out/lib/pico8-ls/"
          makeWrapper ${pkgs.nodejs}/bin/node "$out/bin/pico8-ls" \
            --add-flags "$out/lib/pico8-ls/out/server.js --stdio"
          runHook postInstall
        '';
      };
      native-bridge = pkgs.stdenv.mkDerivation {
        pname = "pico8-native-bridge";
        version = "0.1.0";
        src = ./native;
        buildInputs = [ pkgs.openssl ];
        dontConfigure = true;
        buildPhase = ''
          runHook preBuild
          $CC -std=c11 -O2 -Wall -Wextra -Werror -fPIC -shared \
            bridge.c -o libpico8-dev.so -lcrypto -Wl,-z,noexecstack
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          install -Dm755 libpico8-dev.so "$out/lib/libpico8-dev.so"
          runHook postInstall
        '';
      };
      pico8 = pkgs.buildFHSEnv {
        name = "pico8";
        targetPkgs = pkgs: [
          pkgs.SDL2
          pkgs.libGL
          pkgs.alsa-lib
          pkgs.pulseaudio
          pkgs.wget
        ];
        runScript = pkgs.writeShellScript "pico8-launch" ''
          project_root="''${PICO8_PROJECT_ROOT:-$PWD}"
          runtime_dir="''${PICO8_RUNTIME_DIR:-$project_root}"
          export PICO8_PROJECT_ROOT="$project_root"

          if [[ ! -x "$runtime_dir/pico8_dyn" || ! -f "$runtime_dir/pico8.dat" ]]; then
            echo "Place the licensed Linux PICO-8 files in $runtime_dir (pico8_dyn and pico8.dat)." >&2
            echo "Ensure pico8_dyn is executable, or set PICO8_RUNTIME_DIR to your installation." >&2
            exit 1
          fi

          if [[ "''${PICO8_HOT_RELOAD:-0}" == 1 ]]; then
            export PICO8_NATIVE_BRIDGE=1
            export LD_PRELOAD="${native-bridge}/lib/libpico8-dev.so''${LD_PRELOAD:+:$LD_PRELOAD}"
          fi

          exec "$runtime_dir/pico8_dyn" -windowed 1 \
            -root_path "''${PICO8_CART_ROOT:-$project_root/carts}" "$@"
        '';
      };
      hot-reload = pkgs.writeShellScriptBin "pico8-hot-reload" ''
        export PICO8_HOT_RELOAD=1
        if [[ $# == 0 ]]; then
          set -- -run "''${PICO8_PROJECT_ROOT:-$PWD}/carts/main.p8"
        fi
        exec ${pico8}/bin/pico8 "$@"
      '';
    in
    {
      packages.${system} = {
        default = pico8;
        pico8-ls = pico8-ls-package;
        inherit native-bridge hot-reload;
      };
      devShells.${system} = {
        default = pkgs.mkShell {
          packages = [
            pico8
            pico8-ls-package
            hot-reload
            pkgs.ripgrep
            pkgs.python3
            pkgs.ruff
            pkgs.clang-tools
          ];
          shellHook = ''
            export PICO8_PROJECT_ROOT="''${PICO8_PROJECT_ROOT:-$PWD}"
          '';
        };
      };
      formatter.${system} = pkgs.nixfmt-tree;
    };
}
