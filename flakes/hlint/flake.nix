{
  description = "HLint + apply-refact for haskan2";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
  let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" ];
  in {
    packages = forAllSystems (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        hs = pkgs.haskell.packages.ghc98;
      in {
        default = pkgs.symlinkJoin {
          name = "hlint-with-refactor";
          paths = [ hs.hlint hs.apply-refact ];
        };
        hlint = hs.hlint;
        apply-refact = hs.apply-refact;
      }
    );
  };
}
