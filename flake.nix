{
  description = "JamZig - ⚡️🛠️ A Zig-fueled implementation for the JAM protocol";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    zls.url = "github:zigtools/zls/7485feeeda45d1ad09422ae83af73307ab9e6c9e"; # v0.14.0
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


      zig-pkg = zig2nix.outputs.packages.${system}.zig-0_14_0;

      zls-pkg = zls.packages.${system}.zls.overrideAttrs (old: {
                  nativeBuildInputs = [ zig-pkg ];
      });


      # Define the rust toolchain once so it can be reused
      rustToolchain = pkgs.rust-bin.beta.latest.default.override {
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
      };

      # Zig flake helper
      # Check the flake.nix in zig2nix project for more options:
      # <https://github.com/Cloudef/zig2nix/blob/master/flake.nix>
      env = zig2nix.outputs.zig-env.${system} {
        zig =  zig-pkg;
      };
    in with builtins; with env.pkgs.lib; rec {
      # Produces clean binaries meant to be ship'd outside of nix
      # nix build .#foreign
      packages.foreign = env.package {
        src = cleanSource ./.;

        # Packages required for compiling
        nativeBuildInputs = with env.pkgs; [
            # Cross compilation tools: Brackets are important here
            rustToolchain
            pkgs.qemu
          ];

        # Packages required for linking
        buildInputs = with env.pkgs.ForTarget target;  [];

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

      # Common dependencies for all app environments
      commonDeps = [
        rustToolchain
        pkgs.qemu
      ];

      # For bundling with nix bundle for running outside of nix
      # example: https://github.com/ralismark/nix-appimage
      apps.bundle = {
        type = "app";
        program = "${packages.foreign}/bin/default";
      };

      # nix run .
      apps.default = env.app commonDeps "zig build run \"$@\"";

      # nix run .#build
      apps.build = env.app commonDeps "zig build \"$@\"";

      # nix run .#test
      apps.test = env.app commonDeps "zig build test -fqemu \"$@\"";

      # nix run .#docs
      apps.docs = env.app commonDeps "zig build docs \"$@\"";

      # nix run .#deps
      apps.deps = env.showExternalDeps;

      # nix run .#zig2nix
      apps.zig2nix = env.app [env.zig2nix] "zig2nix \"$@\"";

      # nix develop
      devShells.default = env.mkShell {
        # Packages required for compiling, linking and running
        # Libraries added here will be automatically added to the LD_LIBRARY_PATH and PKG_CONFIG_PATH
        nativeBuildInputs = [ 
            zls-pkg 
            rustToolchain
            pkgs.qemu
          ];
            

        # Zig2Nix leaks these variables, for now just unset them
        shellHook = ''
          # unset ZIG_LOCAL_CACHE_DIR
          # unset ZIG_GLOBAL_CACHE_DIR
        '';
      };
    }));
}
