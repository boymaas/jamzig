{
  description = "JamZig - ⚡️🛠️ A Zig-fueled implementation for the JAM protocol";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    zls.url = "github:zigtools/zls?ref=master";
    zig2nix.url = "github:Cloudef/zig2nix";

    rust.url = "github:oxalica/rust-overlay";
    rust.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, zig2nix, zls, rust, ... }: let
    flake-utils = zig2nix.inputs.flake-utils;
  in (flake-utils.lib.eachDefaultSystem (system: let

      pkgs = import nixpkgs {
            inherit system;
            overlays = [ rust.overlays.default ];
      };

      zls-pkg = zls.packages.${system}.default;

      # Zig flake helper
      # Check the flake.nix in zig2nix project for more options:
      # <https://github.com/Cloudef/zig2nix/blob/master/flake.nix>
      env = zig2nix.outputs.zig-env.${system} {
        zig =  zig2nix.outputs.packages.${system}.zig-0_14_0;


      };
    in with builtins; with env.pkgs.lib; rec {
      # Produces clean binaries meant to be ship'd outside of nix
      # nix build .#foreign
      packages.foreign = env.package {
        src = cleanSource ./.;

        # Packages required for compiling
        nativeBuildInputs =  [
            # Cross compilation tools: Brackets are important here
            (pkgs.rust-bin.beta.latest.default.override {
              targets = [ 
                "x86_64-unknown-linux-gnu"
                "x86_64-unknown-linux-musl"
                "aarch64-unknown-linux-gnu"
                "aarch64-unknown-linux-musl"
                "aarch64-apple-darwin"
                "x86_64-apple-darwin"
                "powerpc64-unknown-linux-gnu"
              ];
              extensions = ["rust-analyzer" "rust-src"];
            })
            pkgs.qemu
          ];

        # Packages required for linking
        buildInputs =  [];

        # Smaller binaries and avoids shipping glibc.
        zigPreferMusl = true;
      };

      # nix build .
      packages.default = packages.foreign.override (attrs: {
        # src = cleanSource ./.;

        # Prefer nix friendly settings.
        zigPreferMusl = false;

        nativeBuildInputs = attrs.nativeBuildInputs ++ [];

          buildInputs = attrs.buildInputs ++ [];

        # Executables required for runtime
        # These packages will be added to the PATH
        zigWrapperBins =  [];

        # Libraries required for runtime
        # These packages will be added to the LD_LIBRARY_PATH
        zigWrapperLibs = attrs.buildInputs or [];
      });

      # For bundling with nix bundle for running outside of nix
      # example: https://github.com/ralismark/nix-appimage
      apps.bundle = {
        type = "app";
        program = "${packages.foreign}/bin/default";
      };

      # nix run .
      apps.default = env.app [] "zig build run \"$@\"";

      # nix run .#build
      apps.build = env.app [] "zig build \"$@\"";

      # nix run .#test
      apps.test = env.app [] "zig build test \"$@\"";

      # nix run .#test-ffi
      apps.test-ffi = env.app [] "zig build test-ffi \"$@\"";

      # nix run .#docs
      apps.docs = env.app [] "zig build docs \"$@\"";

      # nix run .#deps
      apps.deps = env.showExternalDeps;

      # nix run .#zon2nix
      apps.zon2nix = env.app [env.zon2nix] "zon2nix \"$@\"";

      # nix develop
      devShells.default = env.mkShell {
        # Packages required for compiling, linking and running
        # Libraries added here will be automatically added to the LD_LIBRARY_PATH and PKG_CONFIG_PATH
        nativeBuildInputs = []
          ++ packages.default.nativeBuildInputs
          ++ packages.default.buildInputs
          ++ packages.default.zigWrapperBins
          ++ packages.default.zigWrapperLibs
          ++ [
              zls-pkg # Zig language server
            ];
            

        # # https://github.com/ziglang/zig/issues/18998
        shellHook = ''
          unset ZIG_LOCAL_CACHE_DIR
          unset ZIG_GLOBAL_CACHE_DIR
        '';
      };
    }));
}
