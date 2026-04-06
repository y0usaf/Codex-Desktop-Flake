{
  description = "Codex Desktop for Linux - Nix flake for OpenAI Codex on Linux";

  inputs = {
    # Pinned to nixos-unstable via flake.lock. Run `nix flake update` carefully —
    # bumping the lock may require testing if electron_40 or other attrs change.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    forAllSystems = nixpkgs.lib.genAttrs ["x86_64-linux" "aarch64-linux"];
  in {
    packages = forAllSystems (system: {
      default = nixpkgs.legacyPackages.${system}.callPackage ./package.nix {};
    });
    apps = forAllSystems (system: {
      default = {
        type = "app";
        program = "${self.packages.${system}.default}/bin/codex-desktop";
      };
    });
  };
}
