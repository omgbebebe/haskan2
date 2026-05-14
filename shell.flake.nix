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
  nativeBuildInputs = with pkgs; [
    poppler-utils
    gdb
    tree
  ];
  buildInputs = [
    ghc
    cabal-install
    haskell-language-server
    pkg-config
    socat
    mermaid-cli
    imagemagick
    feh
    (python3.withPackages (p: with p; [
      sympy
      requests
      numpy
      scipy
      pillow
      openexr
    ]))
    ktx-tools
    openexr imagemagick # to work with exr (HDRi)
    # Linting/formatting tools (built with ghc98 since ghc914 versions are broken)
    haskell.packages.ghc98.hlint
    haskell.packages.ghc98.apply-refact
  ] ++ nativeLibs;
  shellHook = ''
    export LD_LIBRARY_PATH="${lib.makeLibraryPath nativeLibs}:$LD_LIBRARY_PATH"
    export VK_LAYER_PATH="${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d"
    echo "Haskan dev shell — GHC $(ghc --numeric-version)"
  '';
}
