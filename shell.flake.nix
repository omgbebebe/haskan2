{ pkgs, compiler ? "ghc9141" }:

with pkgs;

let
  ghc = haskell.compiler.${compiler};
  myHaskellPackages = pkgs.haskell.packages.${compiler}.override {
    overrides = hself: hsuper: {
#      ghc-trace-events = pkgs.haskell.lib.doJailbreak hsuper.ghc-trace-events;
#      hie-compat = pkgs.haskell.lib.doJailbreak hsuper.hie-compat;
#      dec = pkgs.haskell.lib.doJailbreak hsuper.dec;
#      singleton-bool = pkgs.haskell.lib.doJailbreak hsuper.singleton-bool;
#      Cabal-syntax = pkgs.haskell.lib.doJailbreak hsuper.Cabal-syntax;
#      haskell-language-server = pkgs.haskell.lib.doJailbreak hsuper.haskell-language-server;
#      cabal-install = pkgs.haskell.lib.doJailbreak hsuper.cabal-install;
    };
  };

  jolt-physics = stdenv.mkDerivation rec {
    pname = "jolt-physics";
    version = "5.5.0";

    src = fetchFromGitHub {
      owner = "jrouwe";
      repo = "JoltPhysics";
      rev = "v${version}";
      sha256 = "0dzqi4mxrzg5cyf5k8rdlb078939ib849n7gs6014d3ljymf839r";
    };

    nativeBuildInputs = [ cmake ninja ];

    cmakeFlags = [
      "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"
      "-DCMAKE_BUILD_TYPE=Release"
      "-DJPH_BUILD_SHARED_LIBRARY=OFF"
      "-DJPH_BUILD_STATIC_LIBRARY=ON"
      "-DJPH_BUILD_SAMPLES=OFF"
      "-DJPH_BUILD_TEST_FRAMEWORK=OFF"
      "-DJPH_BUILD_UNIT_TESTS=OFF"
      "-DJPH_BUILD_PERFORMANCE_TEST=OFF"
      "-DJPH_DISABLE_LTO=ON"
    ];

    # Build in a separate directory to avoid name conflicts with source dirs
    configurePhase = ''
      runHook preConfigure
      mkdir -p build
      cd build
      cmake -GNinja -S ../Build -B . $cmakeFlags
      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild
      ninjaBuildPhase
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib $out/include
      cp -r $src/Jolt $out/include/
      find . -name "libJolt*.a" -exec cp {} $out/lib/ \;
      runHook postInstall
    '';
  };

  nativeLibs = [
    SDL2
    vulkan-loader
    vulkan-validation-layers
    vulkan-tools
    vulkan-tools-lunarg
    shaderc
    zlib
  ];

#  haskellPackages = pkgs.haskell.packages.ghc914.override {
#    overrides = hself: hsuper: {
#      # This "jailbreaks" the package, stripping its strict upper bounds
#      ghc-trace-events = pkgs.haskell.lib.doJailbreak hsuper.ghc-trace-events;
#      hie-compat = pkgs.haskell.lib.doJailbreak hsuper.hie-compat;
#      dec = pkgs.haskell.lib.doJailbreak hsuper.dec;
#      singleton-bool = pkgs.haskell.lib.doJailbreak hsuper.singleton-bool;
#      Cabal-syntax = pkgs.haskell.lib.doJailbreak hsuper.Cabal-syntax;
#    };
#  };
in
mkShell {
  name = "haskan-dev";
  nativeBuildInputs = with pkgs; [
    poppler-utils
    gdb
    tree
    haskell-language-server
    haskellPackages.hoogle
#    ghc
    cabal-install
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
#    haskell.packages.ghc98.hlint
#    haskell.packages.ghc98.apply-refact
#    myHaskellPackages.haskell-language-server
#    haskell.packages.ghc914.haskell-language-server
    myHaskellPackages.ghc
#    myHaskellPackages.cabal-install
    vscodium
  ];
  buildInputs = [
    jolt-physics
  ] ++ nativeLibs;
  shellHook = ''
    export LD_LIBRARY_PATH="${lib.makeLibraryPath nativeLibs}:${toString ./3rdparty/jolt-wrapper}:$LD_LIBRARY_PATH"
    export VK_LAYER_PATH="${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d"
    export JOLT_INCLUDE_DIR="${jolt-physics}/include"
    export JOLT_LIB_DIR="${jolt-physics}/lib"
    echo "Haskan dev shell — GHC $(ghc --numeric-version)"
  '';
}
