{ pkgs, compiler ? "ghc9141" }:

with pkgs;

let
  ghc = haskell.compiler.${compiler};

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
    jolt-physics
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
    export LD_LIBRARY_PATH="${lib.makeLibraryPath nativeLibs}:${toString ./3rdparty/jolt-wrapper}:$LD_LIBRARY_PATH"
    export VK_LAYER_PATH="${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d"
    export JOLT_INCLUDE_DIR="${jolt-physics}/include"
    export JOLT_LIB_DIR="${jolt-physics}/lib"
    echo "Haskan dev shell — GHC $(ghc --numeric-version)"
  '';
}
