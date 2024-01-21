{
  description = "Haskan Game Engine";

  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.unstable.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs, unstable, flake-utils }:
    flake-utils.lib.eachDefaultSystem
      (system:
#        let pkgs = unstable.legacyPackages.${system};
         let mkPkgs = pkgs: extraOverlays: import pkgs {
               inherit system;
               config.allowUnfree = true; # forgive me Stallman senpai
             };
             pkgs = mkPkgs unstable [];
        in
        {
          devShell = import ./shell.flake.nix { inherit pkgs; };
        }
      );
}
