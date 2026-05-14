# Haskan2 — Critical Project Context (Survives Compaction)

## Core Principle
**NO WORKAROUNDS. EVER.** If a dependency is missing a feature, we implement it properly. If a tool is broken, we fix it. Never accept hacks, shortcuts, or "good enough" solutions. Every technical debt item must be tracked and resolved.

## Build & Run
- **Build**: `nix develop --command cabal build all`
- **Run**: `nix develop --command cabal run exe:haskan2 -- -t 5 MODEL`
- **Debug socket**: `nix develop --command cabal run exe:haskan2 -- -t 60 --debug-socket /tmp/haskan2.sock MODEL`
- **Debug client**: `python3 scripts/debug_client.py key f10 true`
- **UV check**: `--uv-check-cube`, `--uv-check-sphere`, `--uv-check-plane`
- **Lights**: `--lights N` (1-8, default 3)
- **Day/Night**: `--day-night --time HOURS --time-speed FACTOR`
- **spirv-opt**: Available at `/nix/store/...-spirv-tools-1.4.341.0/bin/spirv-opt` — run `-O` on generated `.spv` for 30-50% size reduction (Phase 0 target)

## Architecture
- **GHC 9.14.1** via `haskell.compiler.ghc9141` from nixpkgs-unstable
- **Cabal-only** for Haskell deps; system libs (Vulkan, SDL2) from nixpkgs
- **FIR fork**: `git@github.com:omgbebebe/haskan2-fir.git` (origin), upstream `gitlab.com/sheaf/fir.git`
- **Effects**: `effectful` over mtl; no IORef globals
- **Logging**: production-ready with multiple backends, per-backend levels/formatters
- **CLI**: `optparse-applicative` — `haskan2 MODEL [-t SECONDS] [-T TITLE] [--debug-socket PATH] [--log-file PATH] [--uv-check-*]`
- **Window manager**: xmonad does NOT intercept F-keys (confirmed from `~/.xmonad/xmonad.hs`)

## Current Status
- **M9 COMPLETE**: PBR deferred rendering, normal mapping, AO, emissive, IBL split-sum with BRDF LUT
- **M10 COMPLETE**: Phase 1 (multi-light) DONE, Phase 2 (skybox) DONE, Phase 3 (day/night) DONE, Phase 4 (volumetric clouds) DONE
- **Milestone plan**: `docs/M10-PLAN.md`
- **FIR optimization roadmap**: `3rdparty/fir/.opencode/roadmap/optimization/README.md`

## Key Design Decisions
1. **glTF UV convention**: Matches Vulkan (0,0 = top-left), NOT OpenGL. `flipV` was removed.
2. **Skybox**: Rendered inside lighting shader (not separate pass) using per-vertex frustum rays + `env_map` sampling
3. **Screen-space overlays**: Axis arrows + ground plane drawn in lighting shader fragment stage, not geometry mesh
4. **linear's lookAt**: Creates **right-handed** view space: +X = world +X (right), +Y = world +Y (up), +Z = backward
5. **Y-down handling**: Negative viewport height (`VkViewport.height = -h; y = h`) — Vulkan 1.1+ core. No Y-flip in projection matrix. Preserves CCW winding for backface culling.
6. **Backface culling**: `VK_CULL_MODE_BACK_BIT` with `VK_FRONT_FACE_COUNTER_CLOCKWISE` (standard)
7. **Normal matrix**: Added to `EntityData` SSBO; computed per entity via `transpose . inv33`
8. **Mesh merging**: All scene meshes concatenated into single buffers with per-entity `firstIndex`/`vertexOffset`
9. **FIR `if-then-else` ambiguity**: Convert `gl_VertexIndex` to `Code Float` via `fromIntegral` first
10. **BlockArguments**: Required for `liftIO $ do` nested blocks
11. **Push constant**: 96 bytes — camera pos (12) + debugMode (4) + axisOverlay (4) + groundPlane (4) + sunAzimuth (4) + lightCount (4) + ray0 (16) + ray1 (16) + ray2 (16) + skyTint (12) + iblIntensity (4)
12. **Vertex stride**: 60 bytes (pos 12 + uv 8 + norm 12 + tangent 16 + col 12)
13. **G-buffer shader**: Normal encoding `* 0.5 + 0.5`; lighting shader decodes via `* 2 - 1`
14. **TBN**: `bitangent = cross(normal, tangent) * handedness`; normal map sampled via bindless array
15. **PBR packed into g-buffer alpha**: position.a=metallic, normal.a=roughness, albedo.a=ao
16. **Background detection**: `hasGeometry = abs posX + abs posY + abs posZ > 0.001`
17. **Present mode**: `IMMEDIATE_KHR`
18. **Shader texture format**: `Rgba8 UNorm`; view `VK_FORMAT_R8G8B8A8_UNORM`
19. **JuicyPixels**: Loads row 0 at top; Vulkan stores row 0 at top. No V-flip needed in texture upload.
20. **Vertex format**: `v3_s32float >*< v2_s32float >*< v3_s32float >*< v4_s32float >*< v3_s32float` matches g-buffer shader inputs at locations 0-4 exactly
21. **NO WORKAROUNDS**: Project #1 principle. Missing dependencies implemented properly (e.g., FIR math extensions). Never accept hacks.
22. **IBL intensity range**: 0.0-1.0 (was 0.05-0.3, imperceptible on bright HDR cubemaps)

## Camera Defaults
- **Distance**: 20.0 (default), min 0.1, max 20.0
- **Animation**: Slerp interpolation, 0.1s duration by default
- **Elevation bounds**: `(-pi/2 + 0.01, pi/2 - 0.01)` if unspecified
- **setAngles**: Uses `orientationFromAzEl` which constructs quaternion from azimuth + elevation with local-right pitch axis
- **Rotation handler**: Computes local right axis from current forward; clamps elevation after applying delta
- **Per-frame animation**: `Camera.animate` called from `stateUpdateLoop` with `dtSeconds`

## Session History

### 2025-05-12: M10.1 Multi-Light + M10.3 Day/Night
**M10.1 Complete**: 
- `LightData` SSBO with 256-light capacity (`src/Graphics/Haskan/Engine/Types.hs`)
- Lighting shader unrolled for 4 directional lights with full PBR per light (`Lighting.hs`)
- `--lights N` CLI option (1-8 predefined lights)
- `scripts/benchmark_lights.sh` for frame time comparison
- Push constant expanded from 80→96 bytes (added `skyTintR/G/B` + `iblIntensity`)

**M10.3 Complete**:
- `DayNight.hs` module with sun trajectory, intensity, color, sky tint, IBL modulation
- `GameState` extended with `gameTimeOfDay`, `gameTimeSpeed`, `gameDayNightEnabled` TVars
- `--day-night --time HOURS --time-speed FACTOR` CLI options
- Time speed unit: game-hours per real-second (divide by 3600)
- State update loop advances time and updates first light (the sun) each frame
- Render thread reads time, computes `SunState`, passes `skyTint` and `iblIntensity` to shader
- Bug fixed: time-speed was in wrong units (seconds instead of hours), causing flicker
- IBL range increased from 0.05-0.3 to 0.0-1.0 for visible effect

**Known M10.3 Limitation**: IBL cubemap is static. Objects reflect unchanged environment; only intensity scales. Dynamic cubemap rotation/blending requires FIR math extensions (see FIR Plan below).

### 2026-05-12: FIR Math + M10.3 IBL Rotation + M10.4 Clouds (Attempt)
**FIR Math Extensions DONE**:
- Added 5 missing functions to FIR: `clamp`, `mix` (lerp), `step`, `smoothstep`, `fract`
- All wired to GLSL.std.450 extended instructions via `GLSLMath` typeclass
- Files: `SPIRV/Operation.hs`, `SPIRV/PrimOp.hs`, `FIR/Prim/Op.hs`, `Math/Algebra/Class.hs`, `FIR/Syntax/AST.hs`, `FIR/Syntax/Program.hs`
- Already had: `sin`, `cos`, `atan2`, `pow`, `floor`, `exp`, `signum` (plan was outdated)
- FIR submodule commit: `0d8e55a`

**M10.3 IBL Rotation DONE**:
- Added `ssAzimuth` to `SunState` (continuous 24h, full 360°)
- Passed `sunAzimuth` via push constant (replaced `pad0`, still 96 bytes)
- Fragment shader rotates cubemap sampling directions around Y using FIR `sin`/`cos`
- Applied to: skybox background, diffuse IBL (irradiance_map), specular IBL (env_map LOD)
- Main repo commit: `c605193`
- Note: Current HDRI (env1 sunset) has baked sun at horizon. Rotating it makes sun orbit like lighthouse. User wants to find better HDRI or render own cubemap set.

**M10.4 Clouds — BLOCKED by SPIR-V Bloat**:
- Implemented procedural clouds in lighting shader (hash noise + bilinear interpolation)
- Build succeeded, but SPIR-V is 10.9MB with 542,910 IDs (normal shader: 5-50KB)
- FIR inlines everything without CSE/DCE. 4 unrolled PBR lights already produce ~10MB baseline.
- Adding any math pushes it over driver limit. Pipeline creation fails silently → black screen.
- Attempted simplification (inline everything, no helper functions) — still 10.9MB.
- **CONCLUSION**: M10.4 blocked until FIR optimization. Cannot add non-trivial math to lighting shader.

**FIR Optimization Roadmap Found**:
- Location: `3rdparty/fir/.opencode/roadmap/optimization/README.md`
- Phase 0 (1 hour): `spirv-opt` integration → 30-50% size reduction
- Phase 1.1 (1-2 weeks): `storeAtTypeThroughAccessChain` loop instead of unrolling
- Phase 1.3 (1-2 weeks): vectorization whitelist (SelectionF/IfF, LetF, BindF) → biggest win for Haskan2
- Phase 2 (1-2 months): CSE, DCE, peephole, inlining
- Phase 0 is the immediate blocker for M10.4. Phase 1.3 is the enabler for non-trivial fragment shader math.

**Commits**:
- `0d8e55a` — FIR: add GLSL math functions
- `c605193` — M10.3: dynamic IBL cubemap rotation
- `40306cd` — M10.4: procedural volumetric clouds (reverted due to SPIR-V bloat)
- `26065eb` — Update MEMORIES.md

### 2026-05-12 (later session): FIR Optimization + M10.4 Completion
**FIR Phase 0 DONE**:
- Added `Optimize` compiler flag to FIR
- `compileTo` runs `spirv-opt -O` on generated `.spv` when flag is present
- Graceful degradation when `spirv-opt` not available
- All Haskan2 shader compilations updated to use `[SPIRV (Version 1 5), Optimize]`
- FIR submodule commit: `e211a8a`
- **Impact**: 10.9MB → 18.3KB raw lighting shader (596× reduction)

**FIR Phase 1.3 DONE**:
- Added `SanitiseVectorisation` instance for `SelectionF`/`IfF`
- Vector conditionals emit single `OpSelect` instead of N independent codegen passes
- FIR submodule commit: `e8fbb82`
- **Impact**: Zero on current shader (all conditionals are scalar), forward-compatible for vector `fmap`/`\u003c*\u003e`

**Phase 1.1/1.2 CANCELLED**:
- Both require emitting raw SPIR-V loop CFG in monadic `CGMonad ()` code
- Too complex, high bug risk in critical `assign` path
- `spirv-opt` already eliminates unrolled stores via DCE/scalar-replacement
- Haskan2 doesn't hit these paths (no large local arrays)
- Full rationale in `.opencode/FIR_OPTIMIZATION_REPORT.md`

**M10.4 Volumetric Clouds DONE**:
- Restored cloud code from commit `40306cd`
- Hash-based value noise, 3-octave fBm, spherical UV mapping
- Animated drift via `sunAzimuth`, height mask, smoothstep density
- Sun-based shading (bright at noon, darker at sunrise/set)
- Blended over skybox before tinting, background pixels only
- **With spirv-opt**: 21.8KB optimized SPIR-V (1073 instructions)
- Main repo commit: `b9998b3`

**FIR Future Work Phase B-D DONE**:
- Vector comparisons (`lessThanV`, `greaterThanV`, `equalV`, `notEqualV`, `lessThanEqualV`, `greaterThanEqualV`) returning `V n Bool`
- Scalar `fma` and vector `fmaV` (fused multiply-add)
- `packUnorm4x8` / `unpackUnorm4x8` (GLSL ext-inst pack/unpack)
- `findILsb`, `findSMsb`, `findUMsb` (bit find operations)
- Interpolation ops (`interpolateAtCentroid`, `interpolateAtSample`, `interpolateAtOffset`) — **REMOVED**: require pointer operand, FIR `Code` represents values not pointers. Deferred until codegen supports input variable references.
- FIR submodule commit: `3322e26`
- Main repo commit: `9f1f0c6`

**Cloud noise generator optimized** (`2faa37e`):
- Replaced O(27×N³) brute-force Worley with O(N³ log cells) scipy cKDTree
- 128³: 8s → 4.7s, 512³: ~5.3 min (was hours)
- 512³ textures available: 512MB per file, much finer detail
- Default remains 128³ for git/repo size

**Commits**:
- `3322e26` — FIR: vector comparisons, FMA, pack/unpack, bit find
- `9f1f0c6` — Update FIR submodule
- `bdcf6c6` — Integrate fma into lighting/cloud shaders (30 Fma instructions)
- `eb6602d` — Pipeline documentation in shader modules
- `a5e20e0` — Fix cloud noise script docs to match shader
- `2faa37e` — Optimize cloud noise generator with scipy cKDTree

## Open Issues
1. **FIR SPIR-V Bloat — FIXED**: FIR generates 10.9MB raw SPIR-V (542k IDs) for the lighting fragment shader. **Phase 0 (spirv-opt) reduces this to ~22KB** (with clouds) / ~18KB (without). Driver pipeline creation now succeeds. M10.4 clouds unblocked.
   - **Phase 0 DONE**: `spirv-opt -O` integrated into FIR `compileTo` via `Optimize` flag
   - **Phase 1.3 DONE**: Vectorized `SelectionF`/`IfF` in applicative context (single `OpSelect`)
   - **Phase 1.1/1.2 CANCELLED**: Loop-based stores/concatenation. Too complex for monadic `CGMonad`; spirv-opt already handles via DCE/scalar-replacement. See `.opencode/FIR_OPTIMIZATION_REPORT.md`.
   - **Roadmap**: `3rdparty/fir/.opencode/roadmap/optimization/README.md`
2. **UV texturing of procedural cube/sphere**: `unitCube` and `uvSphere` UV orientation still incorrect. Vision model confirms upside-down text on all faces. Deferred to future session.
3. **IBL dynamic sky**: Deferred until FIR math functions available. **NOW UNBLOCKED** — `sin`/`cos` available. **BUT** HDRI rotation looks weird with current env1 (sunset with sun at horizon). Need better HDRI or procedural sky.
4. **Shadows for sun**: Blocked until CSM implemented; shadowless day/night acceptable for M10.
5. **Day/night IBL cubemap rotation**: **FIXED** — `sunAzimuth` passed via push constant. Fragment shader rotates sampling directions around Y. Cubemap rotates with sun. **Limitation**: Current env1 HDRI has sun baked at horizon; rotating makes it orbit like lighthouse. Need better HDRI or separate cubemap sets for dawn/noon/dusk/night.
6. **M10.4 Volumetric Clouds**: **DONE** — Procedural clouds in lighting shader. Hash noise, value noise, 3-octave fBm, spherical UV, height mask, smoothstep density, sun-based shading. Optimized SPIR-V: ~22KB. Background pixels only.
   - **Bug fix**: Original code had `smoothstep 0.85 0.65` (reversed edges = undefined behavior in SPIR-V), causing clouds to appear at top/bottom instead of horizon band. Fixed to `smoothstep 0.5 0.52 * (1.0 - smoothstep 0.7 0.9)`.
   - **Tuning**: Normalized fBm to [0,1], widened density threshold to `smoothstep 0.35 0.65` for softer edges.
   - **Debug modes**: 13.0=cloud density (Shift+F1), 14.0=height mask (Shift+F2), 15.0=raw noise (Shift+F3).

## Critical Files
- `src/Graphics/Haskan/Engine.hs` — main loop, ECS, deferred graph, `computeSkyboxRays`, UV check mode, axis/ground plane state, debug mode handling
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Lighting.hs` — lighting shader with skybox sampling, axis overlay, ground plane, debug modes 1-15, procedural clouds
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/GBuffer.hs` — g-buffer vertex/fragment shaders; normal mapping with TBN
- `src/Graphics/Haskan/Camera.hs` — `OrbitalCamera`, `InterpolationMethod`, `animateOrbital`, quaternion math
- `src/Graphics/Haskan/Mesh.hs` — `unitCube`, `uvSphere`, `uvPlane`, `groundPlaneMesh`
- `src/Graphics/Haskan/Vertex.hs` — `Vertex` type with Storable instance
- `src/Graphics/Haskan/Render/Deferred.hs` — deferred graph builder; push constant upload 96 bytes
- `src/Graphics/Haskan/Vulkan/DeferredResources.hs` — lighting push constant range 96 bytes, pipeline layouts
- `src/Graphics/Haskan/Input.hs` — key bindings including debug modes F1-F9, Shift+F1/F2/F3 (cloud debug), Ctrl/Shift+F12, G/Shift+G for overlays
- `src/Graphics/Haskan/Debug/Interface.hs` — debug socket key mappings
- `src/Graphics/Haskan/Debug/Screenshot.hs` — screenshot capture with zero-size guards
- `src/Graphics/Haskan/Vulkan/Buffer.hs` — `vkMapMemory` guards for empty data
- `src/Graphics/Haskan/Vulkan/Texture.hs` — `readImageFromFile` using JuicyPixels (top-down row order)
- `docs/M10-PLAN.md` — milestone plan
- `docs/` — project documentation directory
- `.opencode/FIR_MATH_PLAN.md` — FIR math extension implementation plan
- `src/Graphics/Haskan/DayNight.hs` — sun trajectory, sky color, IBL intensity computation
- `src/Graphics/Haskan/Vulkan/Shaders/LightData.hs` — FIR LightData struct for SSBO
- `src/Graphics/Haskan/Engine/Types.hs` — GameState with lights, timeOfDay, dayNight fields
- `scripts/benchmark_lights.sh` — multi-light benchmark harness
- `3rdparty/fir/.opencode/roadmap/optimization/README.md` — FIR optimization roadmap (Phase 0-2)
- `3rdparty/fir/src/FIR.hs` — `compileTo` function (Phase 0 target)
- `3rdparty/fir/src/CodeGen/Applicative.hs` — vectorization whitelist (Phase 1.3 target)
- `3rdparty/fir/src/CodeGen/Optics.hs` — `storeAtTypeThroughAccessChain` (Phase 1.1 target)
- `3rdparty/fir/src/CodeGen/Binary.hs` — instruction emission (Phase 2 target)

## Test Assets
- `data/hdri/env_test/` — colored test cubemap: +X=red, -X=blue, +Y=green, -Y=yellow, +Z=gray, -Z=brown
- `data/debug/models/uvCube.gltf` — Blender test cube (texture atlas UVs)
- `data/textures/uv_checker.png` — UV checker texture (arrows point up)
- Debug screenshots: `data/debug/screenshots/`

## Environment
- **OS**: NixOS, platform linux
- **GPU**: NVIDIA GeForce RTX 4090
- **Vulkan**: 1.4.312
- **Descriptor indexing**: nonUniform=True, updateAfterBind=True, partiallyBound=True, runtimeArray=True

## Previous Context Below
- `src/Graphics/Haskan/Vulkan/DeferredResources.hs` — attachment count 3→4
- `src/Graphics/Haskan/Vulkan/Device.hs` — `fragmentStoresAndAtomics` feature
- `src/Graphics/Haskan/Scene/ECS.hs` — PBR component stores
- `src/Graphics/Haskan/Render/RenderSystem.hs` — PBR fields in DrawCall
- `src/Graphics/Haskan/Engine.hs` — SSBO upload with PBR data
- `src/Graphics/Haskan/Scene/GLTF.hs` — PBR texture loading and assignment
- `3rdparty/gltf-loader/src/Text/GLTF/Loader/Gltf.hs` — MR/normal/occlusion texture fields
- `3rdparty/gltf-loader/src/Text/GLTF/Loader/Internal/Adapter.hs` — adapter for new PBR fields

## glTF V-Flip Fix (2025-05-10)

### Bug
The glTF loader was incorrectly applying `flipV (V2 u v) = V2 u (1 - v)` to all UV coordinates. This was based on the assumption that glTF uses OpenGL convention (V=0 bottom-left), but the glTF 2.0 spec states UV (0,0) is top-left — matching Vulkan's convention.

### Fix
Removed `flipV` from `primitiveToVertices` in `src/Graphics/Haskan/Scene/GLTF.hs`. glTF UVs are now passed through unchanged.

### Verification
- Blender-generated `uvCube.gltf` (with proper UVs) renders correctly
- Vision model audit: no upside-down text, no mirroring, standard cube unwrap
- Procedural `unitCube` and `uvSphere` regression tested — no issues

### File Changed
- `src/Graphics/Haskan/Scene/GLTF.hs` — removed `flipV` function and its usages

## BRDF LUT Fix (2025-05-10)

### Bug
BRDF LUT integration in `Graphics.Haskan.Vulkan.BRDF` was double-counting the PDF weight. The `vis` term (`G*VdotH/(NdotH*NdotV)`) already equals `BRDF*NdotL/PDF` in importance-sampled Monte Carlo, but the code was additionally multiplying by `1/pdf`.

### Fix
Removed the incorrect `weight = 1/pdf` multiplication. The Monte Carlo accumulation now directly uses:
- `scale' = vis * (1 - fc)`
- `bias' = vis * fc`

This matches the standard LearnOpenGL split-sum BRDF LUT derivation.

### Result
Specular IBL intensity is now physically correct — no more over-bright reflections or "environment islands" on non-metallic surfaces.

### File Changed
- `src/Graphics/Haskan/Vulkan/BRDF.hs` — removed `weight` multiplication from `integrateBRDF`

## UV Mapping Fixes (2025-05-11)

### Y-Down Handling (Proper Implementation)
- **No Y-flip in projection**: Standard `Linear.Projection.perspective` matrix
- **Negative viewport height**: `VkViewport.height = -h; y = h` (Vulkan 1.1+ core)
- **Backface culling**: `VK_CULL_MODE_BACK_BIT` with `VK_FRONT_FACE_COUNTER_CLOCKWISE`
- **Result**: CCW world-space meshes remain CCW in clip space, fully compatible with glTF

### Previous Mistake
Y-flip matrix in projection (`scale(1, -1, 1)`) reversed winding in clip space. Attempted workaround (`CLOCKWISE` frontFace) broke glTF compatibility. Reverted and replaced with negative viewport height.

### Cube Fixes Applied
1. **Side face V coordinates**: Swapped V on all 4 side faces. Y+ vertices get V=1, Y- vertices get V=0.
2. **Top/Bottom face V coordinates**: Swapped V. Top face Y+ gets V=1, Bottom face Y- gets V=0.
3. **Left face winding**: Changed from `12,13,14, 12,14,15` to `12,15,14, 12,14,13` (was CW in world space, now CCW).

### Sphere Fixes Applied
1. **U coordinate**: `u = lonIdx/lonCount` (removed `1.0 -` inversion)
2. **Tangent**: `(-sin φ, 0, cos φ)` (negated to match corrected U)
3. **Winding**: Kept original CCW ordering

### Files Changed
- `src/Graphics/Haskan/Mesh.hs` — `unitCube` and `uvSphere` UV/tangent/winding fixes
- `src/Graphics/Haskan/Vulkan/GraphicsPipeline.hs` — culling disabled, CCW restored
- `.opencode/UV_CHECK_MESH_AUDIT.tex` — detailed mathematical analysis

## FIR Patch — Texture2D' (2025-05-10)

### Problem
G-buffer position uses `R16G16B16A16_SFLOAT` format but FIR `Texture2D` forces the SPIR-V sampled type to match the image format (`half`/`Float16`). Vulkan requires sampled type to be 32-bit float for `< 64-bit` formats (VUID-SampledType-04471).

### Solution
Patched FIR with `Texture2D'` synonym allowing independent sampled type and image format:
```haskell
type Texture2D' decs sampledFmt imageFmt = ...
```

Lighting shader now uses:
```haskell
"gbuf_position" ':-> Texture2D' '[Binding 0, DescriptorSet 0] (RGBA32 F) (RGBA16 F)
```

### Files Changed
- `3rdparty/fir/src/FIR/Syntax/Synonyms.hs` — added `Texture2D'` synonym and export
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Lighting.hs` — uses `Texture2D'` for position

## Skybox Ray Math Fix (2025-05-11)

### Bug 1: worldRot extracted columns instead of rows
`computeSkyboxRays` received `transpose(V)` (not `V`) from `Camera.unViewMatrix`. Extracting columns of this transposed matrix gave `R` (world→view) instead of `R^T` (view→world). For non-axis-aligned cameras this produced a severe diagonal tilt.

### Bug 2: Incorrect X-axis negation
`viewDir = V3 (-x/fx) ...` was based on the false assumption that linear's `lookAt` produces left-handed view space. Mathematical analysis confirmed `lookAt` is right-handed: +X = world +X (right), +Y = world +Y (up), +Z = backward, -Z = forward. The `-x` negation inverted the horizontal axis.

### Fix
1. `worldRot` now extracts rows (not columns) from the transposed view matrix:
   ```haskell
   V4 (V4 v00 v01 v02 _) (V4 v10 v11 v12 _) (V4 v20 v21 v22 _) _ = view
   worldRot = V3 (V3 v00 v01 v02) (V3 v10 v11 v12) (V3 v20 v21 v22)
   ```
2. Removed incorrect negation: `viewDir = V3 (x/fx) (y/fy) (-1)`

### Verification
- Colored test cubemap for skybox orientation verification:
  | Face | Axis | Color |
  |------|------|-------|
  | +X | Right | Red (255, 0, 0) |
  | -X | Left | Blue (0, 0, 255) |
  | +Y | Up | Green (0, 255, 0) |
  | -Y | Down | Yellow (255, 255, 0) |
  | +Z | Backward | Light Gray (192, 192, 192) |
  | -Z | Forward | Brown (128, 64, 0) |
- `data/hdri/env_test/` — 6 solid-color PNGs (512x512 each)
- Axis arrows at origin with matching 1x1 colored textures confirm alignment
- No diagonal tilt; skybox perfectly straight with world axes

### Files Changed
- `src/Graphics/Haskan/Engine.hs` — `computeSkyboxRays` function
- `.opencode/SKYBOX_MATH_AUDIT.tex` — mathematical analysis and verification

## Axis Arrows Debug Visualization (2025-05-11)

### Addition
Added `axisArrow` and `axisArrows` mesh generators to `Mesh.hs` for world-axis visualization at origin. Each arrow is a thin colored box with:
- `axisArrow axisDir color` — creates arrow along any axis direction
- `axisArrows` — combines X/Y/Z arrows at origin

### Implementation
Since g-buffer fragment shader samples albedo textures (not vertex colors), 1x1 colored textures are created per arrow:
- X arrow: red texture `(255, 0, 0, 255)`
- Y arrow: green texture `(0, 255, 0, 255)`
- Z arrow: blue texture `(0, 0, 255, 255)`

### Files Changed
- `src/Graphics/Haskan/Mesh.hs` — `axisArrow`, `axisArrows` functions
- `src/Graphics/Haskan/Engine.hs` — creates colored textures and adds arrows to scene

## Orbital Camera Fix — Pitch Axis, Animation, Elevation Clamping (2025-05-11)

### Bug 1: Pitch rotates around world-X instead of local right axis
The `Rotate` handler in `orbitalModify` applied pitch as `axisAngle (V3 1 0 0) pitch` — always world-X. After any yaw rotation, this produced a mix of tilt and roll ("diagonal inclination"). At 90° yaw, pitch became pure roll.

### Fix
Pitch now computes the local right axis from the camera's current forward direction:
```haskell
currentForward = orbitalCameraForward cam
right = normalize (currentForward `cross` V3 0 1 0)
pitchQ = axisAngle right pitch
```

### Bug 2: Elevation bounds never enforced
`elevationBounds` field existed but was never checked. Camera could pass through poles (φ = 0 or π), causing `lookAt` to degenerate.

### Fix
After computing the target orientation from yaw/pitch deltas, extract elevation from the resulting forward vector and clamp:
```haskell
rawForward = normalize (rotate rawTarget (V3 0 0 (-1)))
rawEl = asin (rawForward ^. _y)
clampedEl = max elMin (min elMax rawEl)
```

### Feature: Animated camera rotation
New `InterpolationMethod` enum: `Instantaneous | Linear | Slerp`. Camera orientation animates from current to target over `animationSpeed` seconds (default 0.1s). `Camera.animate` is called each frame from `stateUpdateLoop` with `dtSeconds`.

### Files Changed
- `src/Graphics/Haskan/Camera.hs` — `orbitalModify`, `animateOrbital`, `orientationFromAzEl`, `nlerpQuaternion`, `InterpolationMethod`
- `src/Graphics/Haskan/Engine.hs` — `Camera.animate` called per frame in `stateUpdateLoop`
- `.opencode/orbital_camera.tex` — camera spec document
---

## Critical Bug: FIR Push Constant Layout Mismatch (std430 vs CPU packing)

**Discovered**: 2026-05-13 during cloud height debugging — cloud height changes had no visual effect despite TVar updates and shader reads.

**Root cause**: CPU-side push constant packing in `Render/Deferred.hs` added a `0` padding float after every `V 3 Float`, treating vec3 as vec4 (16 bytes). But FIR's `std430` layout for `V 3 Float` has size=12, alignment=16. No tail padding after vec3.

**CPU layout (WRONG)** — every vec3 followed by explicit `0`:
```haskell
-- WRONG: padding after ray2 and sunDir
camPosData = [ camX, camY, camZ, debugMode          -- offset 0
             , axis, ground, sunAz, lightCount      -- offset 16
             , r0x, r0y, r0z, 0                     -- offset 32 (vec3+pad=16)
             , r1x, r1y, r1z, 0                     -- offset 48
             , r2x, r2y, r2z, 0                     -- offset 64 (WRONG: no pad needed)
             , tintR, tintG, tintB, iblInt          -- offset 80 (shifted by 4!)
             , sunDirX, sunDirY, sunDirZ, 0         -- offset 96 (pad needed for 16-align)
             , cloudHeight                          -- offset 112 (WRONG: should be 108)
             ]
```

**FIR layout (CORRECT)** — `V 3 Float` = 12 bytes, alignment=16:
```
offset 0:   cameraX/Y/Z, debugMode              (16 bytes)
offset 16:  axis, groundPlane, sunAzimuth, lightCount (16 bytes)
offset 32:  ray0 (V3 Float)                      (12 bytes)
offset 44:  ray1 (V3 Float)                      (12 bytes)
offset 56:  ray2 (V3 Float)                      (12 bytes)
offset 68:  skyTintR                            (4 bytes, aligned to 4)
offset 72:  skyTintG                            (4 bytes)
offset 76:  skyTintB                            (4 bytes)
offset 80:  iblIntensity                        (4 bytes)
offset 84:  [padding]                           (4 bytes to align sunDir to 16)
offset 88:  sunDir (V3 Float)                    (12 bytes)
offset 100: cloudHeight                         (4 bytes)
```

**Fields that were broken**:
- `skyTintR/G/B` and `iblIntensity` — shifted by 4 bytes, reading wrong values
- `cloudHeight` — always read `0.0` (the padding float after sunDir)

**Fix**: Remove explicit `0` padding after `ray0`, `ray1`, `ray2`. Only add padding when needed for 16-byte alignment of the next vec3 field:
```haskell
-- CORRECT: no padding after ray2
camPosData = [ camX, camY, camZ, realToFrac dpdDebugMode
             , realToFrac dpdAxisOverlay, realToFrac dpdGroundPlane
             , realToFrac dpdSunAzimuth, realToFrac dpdLightCount
             , realToFrac r0x, realToFrac r0y, realToFrac r0z     -- ray0: 12 bytes
             , realToFrac r1x, realToFrac r1y, realToFrac r1z     -- ray1: 12 bytes
             , realToFrac r2x, realToFrac r2y, realToFrac r2z     -- ray2: 12 bytes
             , realToFrac tintR, realToFrac tintG, realToFrac tintB, realToFrac dpdIBLIntensity  -- 16 bytes
             , realToFrac sunDirX, realToFrac sunDirY, realToFrac sunDirZ, 0  -- sunDir + pad to 16-align
             , realToFrac dpdCloudHeight                          -- 4 bytes
             ]
-- Total: 29 floats = 116 bytes
```

**Rule**: FIR `V 3 Float` in std430 = 12 bytes, alignment=16. Do NOT add tail padding. Only pad to reach 16-byte alignment for the NEXT field if it's also a vec3.

**Files**: `src/Graphics/Haskan/Render/Deferred.hs` (push constant packing)

### 2026-05-13: Cloud Shader Modularization + Quarter-Res + Temporal Accumulation
**Cloud Shader Modularization (Phase 0)**:
- Extracted cloud ray-marching from `Lighting.hs` into new `Clouds.hs` shader module
- Created separate cloud render pass (RGBA16F intermediate, full-res)
- Added cloud descriptor set layout/pool/updates
- Lighting pass now samples `cloud_result` texture instead of computing inline
- Added `CloudPushConstant` (116 bytes) with camera, rays, sky tint, sun dir, cloud height, time
- Fixed `Half`/`Float` mismatches when sampling `RGBA16F` — used FIR `convert` primitive
- Fixed per-frame cloud_result descriptor binding (was always using cloudImageViews !! 0)

**Quarter-Resolution Rendering (Phase 8)**:
- Cloud pass renders at half width/height of surface extent
- Created `cloudExtent` in `DeferredResources` — all cloud images/views/framebuffers/pipeline use it
- Lighting pass bilinearly upsamples low-res `cloud_result`
- No shader changes needed (fullscreen triangle UVs are resolution-independent)

**Temporal Accumulation (Phase 9)**:
- Added `cloud_history` texture binding (binding 2) to cloud descriptor set
- Added `blendFactor` to `CloudPushConstant` (120 bytes total)
- Created cloud history images/views (one per swapchain image)
- Cloud shader blends current frame with history: `result = hist*0.92 + current*0.08`
- After cloud pass, `vkCmdCopyImage` copies current cloud image to history
- Added layout transition cases for `SHADER_READ_ONLY_OPTIMAL <-> TRANSFER_SRC/DST_OPTIMAL`
- Added `cmdCopyImage` helper to `CommandBuffer.hs`

**Warning Cleanup**:
- Replaced partial functions (`head`/`tail`) with safe alternatives across 7 files
- Fixed missing `vTangent` field in `Model.hs` Vertex construction
- Fixed `BS.hGetLine` deprecation → `BSC.hGetLine` in `Debug/Server.hs`
- Suppressed `partial-type-signatures` in all FIR shader modules
- Build and tests pass with no warnings in our code

**Formatting**:
- Applied `ormolu` to entire `src/` directory
- `hlint --cross` reported no hints

**Files Changed**:
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` — new cloud ray-marching shader module
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Lighting.hs` — samples `cloud_result`, removed inline cloud code
- `src/Graphics/Haskan/Render/Deferred.hs` — cloud pass integration, push constant packing
- `src/Graphics/Haskan/Vulkan/DeferredResources.hs` — `cloudExtent`, cloud images/views/framebuffers/pipeline
- `src/Graphics/Haskan/Vulkan/CommandBuffer.hs` — `cmdCopyImage` helper
- `src/Graphics/Haskan/Vulkan/Pipeline.hs` — cloud pipeline creation
- `src/Graphics/Haskan/Model.hs` — fixed `vTangent` field
- `src/Graphics/Haskan/Debug/Server.hs` — `BSC.hGetLine`
- Multiple files — partial function replacements, `{-# OPTIONS_GHC -fno-warn-partial-type-signatures #-}`

### 2026-05-14: Cloud Shader Production Milestone — Phase 6 Complete
**Adaptive Step Count**:
- Step count now varies based on `abs(dirY)`:
  - `|dirY| < 0.1`: 16 steps (grazing angles, stretched traversal)
  - `|dirY| < 0.6`: 24 steps (medium angles)
  - `|dirY| >= 0.6`: 32 steps (near-vertical, best quality)
- `stepSize = totalRayLength / stepCountF` where `stepCountF = fromIntegral stepCount`
- Dynamic loop bound: `when (s >= stepCount) do break @1`

**Near-Horizon Skip**:
- When `abs(dirY) < 0.05`, raymarching loop is skipped entirely
- Accumulators remain at initial values (transmittance=1.0, accRGB=0.0)
- Result is pure skybox color, avoiding expensive loop for negligible contribution

**Interleaved Gradient Noise Dithering**:
- Replaced `sin(hash)` dither with Jimenez's interleaved gradient noise:
  `fract(52.9829189 * fract(uvX * 0.06711056 + uvY * 0.00583715))`
- Better temporal stability than hash-based dither without requiring texture lookup

**Files Changed**:
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` — adaptive step count, horizon skip, IGN dither
