{ pkgs, compiler ? "ghc98" }:

with pkgs;

let
  ghc = haskell.packages.${compiler}.ghcWithPackages (ps: with ps; [
    cabal-install
    haskell-language-server
    vector-sized
    text-short
    typelits-witnesses
    finite-typelits
    generic-monoid
    ghc-typelits-knownnat
    ghc-typelits-natnormalise
    half
    tree-view
    variant
    atomic-file-ops
  ]);

  nativeLibs = [
    SDL2
    vulkan-loader
    vulkan-validation-layers
    vulkan-tools
    vulkan-tools-lunarg
    shaderc
  ];
in
mkShell {
  name = "haskan-dev";
  buildInputs = [ pkg-config ghc ] ++ nativeLibs;
  shellHook = ''
    export LD_LIBRARY_PATH="${lib.makeLibraryPath nativeLibs}:$LD_LIBRARY_PATH"
    echo "Haskan dev shell — GHC $(ghc --numeric-version)"
  '';
}
