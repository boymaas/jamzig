{
  description = "JamZig";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Overlays
    zig.url = "github:mitchellh/zig-overlay";
    rust.url = "github:oxalica/rust-overlay";

    # Adding ZLS
    zls.url = "github:zigtools/zls";

    flake-compat.url = "https://flakehub.com/f/edolstra/flake-compat/1.tar.gz";
  };

  outputs = { self, nixpkgs, flake-utils, zls, ... } @ inputs: let
    overlays = [
      # Other overlays
      (final: prev: {
        zigpkgs = inputs.zig.packages.${prev.system};
        rustpkgs = inputs.rust.packages.${prev.system};
      })
    ];

    # Our supported systems are the same supported systems as the Zig binaries
    systems = builtins.attrNames inputs.zig.packages;
  in
    flake-utils.lib.eachSystem systems (
      system: let
        pkgs = import nixpkgs { inherit overlays system; };
      in rec {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            rustpkgs.rust-beta
            rustpkgs.rust-beta

            zigpkgs.master
            zls.packages.${system}.zls # Adding ZLS from the master branch
          ];

          packages = with pkgs; [
            rust-analyzer
          ];

          # shellHook = "exec zsh";
        };

        # For compatibility with older versions of the `nix` binary
        devShell = self.devShells.${system}.default;

        # For shell.nix compatibility
        packages.default = self.devShells.${system}.default;
      }
    );
}
