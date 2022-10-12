{ pkgs ? import <nixpkgs> {}, unstable ? import <unstable> {}, compiler ? "ghc942" }:
with pkgs;
let
  inherit (pkgs);
  myghc = haskell.packages.${compiler}.ghcWithPackages (ps: with ps; [
#          cabal-install
        ]);
  libs = [ SDL2 glfw3 glm zlib pcre vulkan-loader vulkan-validation-layers vulkan-tools vulkan-tools-lunarg shaderc ];
in
pkgs.stdenv.mkDerivation {
  name = "Haskan";
  buildInputs = [ pkgconfig myghc ] ++ libs;
  shellHook = ''
    eval $(egrep ^export ${ghc}/bin/ghc)
    LD_LIBRARY_PATH="$LD_LIBRARY_PATH:${lib.makeLibraryPath libs}"
    echo "Haskan nix dev environment"
  '';
}
