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
    mermaid-cli
    imagemagick
    feh
    (python3.withPackages (p :[ p.requests ]))
  ] ++ nativeLibs;
  shellHook = ''
    export LD_LIBRARY_PATH="${lib.makeLibraryPath nativeLibs}:$LD_LIBRARY_PATH"
    export VK_LAYER_PATH="${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d"
    echo "Haskan dev shell — GHC $(ghc --numeric-version)"
  '';
}
