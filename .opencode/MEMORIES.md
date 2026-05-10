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
