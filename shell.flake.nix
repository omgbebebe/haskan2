{ pkgs, compiler ? "ghc9141" }:

with pkgs;

let
  ghc = haskell.compiler.${compiler};

  nativeLibs = [
    SDL2
    vulkan-loader
    vulkan-validation-layers
    vulkan-tools
    vulkan-tools-lunarg
    shaderc
    zlib
  ];
in
mkShell {
  name = "haskan-dev";
  buildInputs = [
    ghc
    cabal-install
    haskell-language-server
    pkg-config
    socat
  ] ++ nativeLibs;
  shellHook = ''
    export LD_LIBRARY_PATH="${lib.makeLibraryPath nativeLibs}:$LD_LIBRARY_PATH"
    echo "Haskan dev shell — GHC $(ghc --numeric-version)"
  '';
}
