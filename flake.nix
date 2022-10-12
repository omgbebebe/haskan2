{
  description = "Haskan Game Engine";

  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.unstable.url = "github:nixos/nixpkgs-channels/nixos-unstable";

  outputs = { self, nixpkgs, unstable, flake-utils }:
    flake-utils.lib.eachDefaultSystem
      (system:
        let pkgs = nixpkgs.legacyPackages.${system}; in
        {
          devShell = import ./shell.nix { inherit pkgs; };
        }
      );
}
