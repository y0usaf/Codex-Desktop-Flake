{
  description = "Codex Desktop for Linux - Nix flake for OpenAI Codex on Linux";

  inputs = {
    # Pinned to nixos-unstable via flake.lock. Run `nix flake update` carefully —
    # bumping the lock may require testing if electron_40 or other attrs change.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }:
    flake-utils.lib.eachSystem ["x86_64-linux" "aarch64-linux"] (
      system: {
        packages.default = nixpkgs.legacyPackages."${system}".callPackage ./package.nix {};
        apps.default = {
          type = "app";
          program = "${self.packages."${system}".default}/bin/codex-desktop";
        };
      }
    );
}
