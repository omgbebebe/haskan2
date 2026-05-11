# Haskan2 — Critical Project Context (Survives Compaction)

## Build & Run
- **Build**: `nix develop --command cabal build all`
- **Run**: `nix develop --command cabal run exe:haskan2 -- -t 5 MODEL`
- **Debug socket**: `nix develop --command cabal run exe:haskan2 -- -t 60 --debug-socket /tmp/haskan2.sock MODEL`
- **Debug client**: `python3 scripts/debug_client.py key f10 true`
- **UV check**: `--uv-check-cube`, `--uv-check-sphere`, `--uv-check-plane`

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
- **M10 IN PROGRESS**: Phase 1 (multi-light), Phase 2 (skybox) complete, Phase 3 (day/night), Phase 4 (volumetric clouds)
- **Milestone plan**: `docs/M10-PLAN.md`

## Key Design Decisions
1. **glTF UV convention**: Matches Vulkan (0,0 = top-left), NOT OpenGL. `flipV` was removed.
2. **Skybox**: Rendered inside lighting shader (not separate pass) using per-vertex frustum rays + `env_map` sampling
3. **Screen-space overlays**: Axis arrows + ground plane drawn in lighting shader fragment stage, not geometry mesh
4. **linear's lookAt**: Creates **right-handed** view space: +X = world +X (right), +Y = world +Y (up), +Z = backward
5. **Y-flip projection**: `makeProjectionMatrix` post-multiplies by `scale(1, -1, 1)`; reverted to `COUNTER_CLOCKWISE`
6. **Depth precision**: `D16_UNORM` → `D32_SFLOAT`
7. **Normal matrix**: Added to `EntityData` SSBO; computed per entity via `transpose . inv33`
8. **Mesh merging**: All scene meshes concatenated into single buffers with per-entity `firstIndex`/`vertexOffset`
9. **FIR `if-then-else` ambiguity**: Convert `gl_VertexIndex` to `Code Float` via `fromIntegral` first
10. **BlockArguments**: Required for `liftIO $ do` nested blocks
11. **Push constant**: 80 bytes — camera pos (12) + debugMode (4) + axisOverlay (4) + groundPlane (4) + pad0 (4) + ray0 (16) + ray1 (16) + ray2 (16)
12. **Vertex stride**: 60 bytes (pos 12 + uv 8 + norm 12 + tangent 16 + col 12)
13. **G-buffer shader**: Normal encoding `* 0.5 + 0.5`; lighting shader decodes via `* 2 - 1`
14. **TBN**: `bitangent = cross(normal, tangent) * handedness`; normal map sampled via bindless array
15. **PBR packed into g-buffer alpha**: position.a=metallic, normal.a=roughness, albedo.a=ao
16. **Background detection**: `hasGeometry = abs posX + abs posY + abs posZ > 0.001`
17. **Present mode**: `IMMEDIATE_KHR`
18. **Shader texture format**: `Rgba8 UNorm`; view `VK_FORMAT_R8G8B8A8_UNORM`
19. **JuicyPixels**: Loads row 0 at top; Vulkan stores row 0 at top. No V-flip needed in texture upload.
20. **Vertex format**: `v3_s32float >*< v2_s32float >*< v3_s32float >*< v4_s32float >*< v3_s32float` matches g-buffer shader inputs at locations 0-4 exactly

## Camera Defaults
- **Distance**: 20.0 (default), min 0.1, max 20.0
- **Animation**: Slerp interpolation, 0.1s duration by default
- **Elevation bounds**: `(-pi/2 + 0.01, pi/2 - 0.01)` if unspecified
- **setAngles**: Uses `orientationFromAzEl` which constructs quaternion from azimuth + elevation with local-right pitch axis
- **Rotation handler**: Computes local right axis from current forward; clamps elevation after applying delta
- **Per-frame animation**: `Camera.animate` called from `stateUpdateLoop` with `dtSeconds`

## Open Issues
1. **UV texturing of procedural cube/sphere**: `unitCube` and `uvSphere` UV orientation still incorrect. Vision model confirms upside-down text on all faces. Deferred to future session.
2. **FIR shader missing `sin`/`floor`**: Needed for 1-unit grid cells effect. Marked in M10-PLAN.md technical decisions.
3. **IBL dynamic sky**: Deferred to future milestone; currently using precomputed offline cubemaps (Variant A)
4. **Shadows for sun**: Blocked until CSM implemented; shadowless day/night acceptable for M10

## Critical Files
- `src/Graphics/Haskan/Engine.hs` — main loop, ECS, deferred graph, `computeSkyboxRays`, UV check mode, axis/ground plane state, debug mode handling
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Lighting.hs` — lighting shader with skybox sampling, axis overlay, ground plane, debug modes 1-12
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/GBuffer.hs` — g-buffer vertex/fragment shaders; normal mapping with TBN
- `src/Graphics/Haskan/Camera.hs` — `OrbitalCamera`, `InterpolationMethod`, `animateOrbital`, quaternion math
- `src/Graphics/Haskan/Mesh.hs` — `unitCube`, `uvSphere`, `uvPlane`, `groundPlaneMesh`
- `src/Graphics/Haskan/Vertex.hs` — `Vertex` type with Storable instance
- `src/Graphics/Haskan/Render/Deferred.hs` — deferred graph builder; push constant upload 80 bytes
- `src/Graphics/Haskan/Vulkan/DeferredResources.hs` — lighting push constant range 80 bytes, pipeline layouts
- `src/Graphics/Haskan/Input.hs` — key bindings including `G` and `Shift+G` for overlays
- `src/Graphics/Haskan/Debug/Interface.hs` — debug socket key mappings
- `src/Graphics/Haskan/Debug/Screenshot.hs` — screenshot capture with zero-size guards
- `src/Graphics/Haskan/Vulkan/Buffer.hs` — `vkMapMemory` guards for empty data
- `src/Graphics/Haskan/Vulkan/Texture.hs` — `readImageFromFile` using JuicyPixels (top-down row order)
- `docs/M10-PLAN.md` — milestone plan

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

## UV Mapping Fixes (2025-05-10)

### Bugs Fixed
1. **UV sphere mirrored text**: `u` coordinate was not flipped; fixed to `u = 1.0 - lonIdx/lonCount`
2. **Cube UVs upside-down**: All cube face UVs used `v=0` at bottom-left (OpenGL convention); flipped to `v=1` at top-left (Vulkan convention)
3. **Cube face winding**: Front/right faces had reversed winding causing backface culling issues; fixed triangle order
4. **Cube tangents**: Back/right face tangents pointed in wrong U direction after UV flip; corrected to match flipped UVs

### Files Changed
- `src/Graphics/Haskan/Mesh.hs` — `unitCube` and `uvSphere` UV/tangent fixes

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
- `.opencode/ORBITAL_CAMERA_AUDIT.tex` — audit report (3 issues found, 2 fixed, 1 spec-only)
