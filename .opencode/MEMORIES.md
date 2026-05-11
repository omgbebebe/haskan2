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
