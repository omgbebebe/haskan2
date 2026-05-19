# glTF Loader & Rendering Pipeline — Deep Audit Report

**Date**: 2026-05-19
**Auditor**: Rune
**Scope**: Full glTF loading → ECS → GPU upload → deferred rendering pipeline

---

## Table of Contents

1. [Duck.gltf Holes + Black Head — Root Cause Analysis](#1-duckgltf-issues)
2. [Multi-Mesh / Multi-Texture Pipeline Correctness](#2-multi-mesh-pipeline)
3. [PBR Implementation Completeness](#3-pbr-completeness)
4. [Emission](#4-emission)
5. [Transparency, Translucency, Reflection, Refraction](#5-advanced-features)
6. [Full Issue Register](#6-issue-register)

---

## 1. Duck.gltf Holes + Black Head — Root Cause Analysis <a name="1-duckgltf-issues"></a>

### 1A. Mesh Holes (Missing Triangles)

**Root cause: Multi-primitive mesh merged with single material.**

The Duck model has **one mesh with one primitive**. However, the root cause is the interaction between mesh merging and the GPU cull/compute indirect draw system.

**Critical finding — `Scene.hs:65-71` — Near plane = 1.0:**

```haskell
makeProjectionMatrix width height =
  Linear.Projection.perspective (pi / 3) (realToFrac width / realToFrac height) 1.0 50000.0
```

The Duck model sits near origin. Camera default distance is 20.0 with the model roughly [-2,2] in Y. The near plane at **1.0** clips geometry that passes between camera and near plane. When the camera orbits close, the duck's head/body vertices that project behind the near plane are clipped, creating **apparent holes**.

**Evidence:**
- Camera distance range: 0.1 to 20.0 (MEMORIES.md line 56)
- Near plane: 1.0 — vertices within 1.0 world unit of camera are clipped
- When camera is at distance 20 looking at origin, this is fine
- When camera moves closer (distance ~5-10), parts of the duck near the camera clip
- The duck head appearing when camera gets closer but being black confirms the geometry is there but clipped at certain angles

**Severity**: P1 — Works at default distance, breaks at close range. Near plane should be 0.1.

### 1B. Black Head Texture (No Lighting)

**Root cause: G-buffer normal encoding overflow / normal matrix corruption.**

When geometry does appear (camera close enough that head vertices survive clipping), it renders **black** (unlit). This indicates one of:

1. **Normal matrix degenerate**: `RenderSystem.hs:62-79` — `computeWorldMatrices` computes world matrix as `toMatrix t !*! go parent`. This is correct for hierarchical transforms, but `inv33` in `FramePrepare.hs:50-61` can produce degenerate normals for non-uniform scaling or near-singular upper-left 3x3.

2. **G-buffer precision loss**: Normal stored in **RGBA8 UNorm** (`DeferredResources.hs:149`). Encoding `* 0.5 + 0.5` into 8-bit gives only **256 quantization levels**. For grazing-angle normals (head seen from side), this loses directionality → lighting computes near-zero contribution.

3. **`hasGeometry` detection**: `LightingProcedural.hs:341` — `abs posX + abs posY + abs posZ > 0.001`. Position stored in **RGBA16F** with metallic in alpha. If position components happen to be near zero (duck centered near origin), this threshold can misclassify geometry as background, showing sky instead.

**Most likely cause for black head**: The duck's default material in glTF-Sample-Assets has `metallicFactor: 0.0, roughnessFactor: 1.0`. If the MR texture is not loaded correctly (or `metallicRoughnessIndex` is 0 in the bindless array), the shader falls back to scalar factors. With `roughness=1.0`, the GGX distribution is maximally spread → specular energy is tiny. Combined with Lambert diffuse `albedo/pi`, the result is very dim → **looks black** after Reinhard tonemapping + gamma.

**Specific smoking gun**: `GBuffer.hs:217` — `metallicFinal = if useMrTexture then view @(Index 2) mrColor else metallic`. The `useMrTexture = mrIdx /= 0` check means if the bindless index resolves to 0 (default/unassigned), the texture is ignored and scalar factors used. The Duck.glTF material has a metallic-roughness texture, but if the bindless texture array doesn't map it correctly, the shader falls back to `metallic=0.0, roughness=1.0` which gives very dim output.

---

## 2. Multi-Mesh / Multi-Texture Pipeline Correctness <a name="2-multi-mesh-pipeline"></a>

### 2A. Architecture Flow

```
glTF file → gltf-loader → Scene.GLTF → ECS World
                                        ↓
                              RenderSystem.extractDrawList
                                        ↓
                              Buffer.mergeMeshes → single vertex+index buffer
                                        ↓
                              FramePrepare.buildComputeEntityData → SSBO
                                        ↓
                              Compute Cull shader → DrawIndexedIndirectCommand buffer
                                        ↓
                              vkCmdDrawIndexedIndirect → GBuffer shader reads per-entity SSBO
```

### 2B. Multi-Mesh: **WORKS** with caveats

- `Buffer.mergeMeshes:240-282` correctly concatenates all mesh vertices/indices with offset tracking
- `Cull.hs:122-126` correctly writes `firstIndex`, `vertexOffset`, `indexCount` per entity
- `GBuffer.hs:154` reads entity transform/material via `gl_InstanceIndex` (matches `firstInstance` from cull)
- **Single draw call** `vkCmdDrawIndexedIndirect` with `dpdEntityCount` commands

**Issues:**
1. **One mesh per entity**: `processNode` (`GLTF.hs:504-574`) assigns one `MeshHandle` per node. If a glTF mesh has multiple primitives with different materials, `loadMesh` merges them into one mesh with one material. **Multi-material meshes lose per-primitive material differentiation.**

2. **No multi-primitive entity support**: The ECS has one `MeshHandle` per entity. The merged primitives share the first primitive's material. Duck has one primitive, so this isn't the Duck issue, but any multi-material glTF model will render incorrectly.

### 2C. Multi-Texture: **WORKS** via bindless

- `Texture.hs` creates textures and uploads to GPU
- `Engine/Render.hs` builds `texIndexMap :: IntMap Word32` mapping `TextureHandle` → bindless array index
- `RenderSystem.hs:113-120` resolves each entity's material/MR/normal/occlusion/emissive textures to bindless indices
- `FramePrepare.hs:67-77` packs indices into `ComputeEntityData`
- `GBuffer.hs` shader reads `materialIndex`, `metallicRoughnessIndex`, etc. from SSBO and samples bindless textures

**Issues:**
1. **Bindless index 0 = "no texture"**: `GBuffer.hs:215,245,265,274` — `if idx /= 0` gates texture sampling. Index 0 is the first texture in the array. If the first texture happens to be an entity's albedo, it's treated as "no texture" → **first texture in the array is invisible**.

2. **All textures are RGBA8 UNorm**: Normal maps, MR maps, emissive maps all uploaded as RGBA8 UNorm. No sRGB conversion for albedo. This means albedo textures are sampled in linear space instead of sRGB → **albedo appears too bright** for sRGB-encoded textures (which is most glTF assets).

3. **Texture deduplication missing**: If two materials share the same image, it's decoded and uploaded twice with different bindless indices. Wastes GPU memory.

---

## 3. PBR Implementation Completeness <a name="3-pbr-completeness"></a>

### 3A. What's Implemented

| Component | Status | Location |
|-----------|--------|----------|
| Cook-Torrance Specular BRDF | ✅ Complete | `LightingProcedural.hs:397-592` |
| GGX Normal Distribution | ✅ Complete | `LightingProcedural.hs:423-426` |
| Smith GGX Geometry (Schlick-GGX) | ✅ Complete | `LightingProcedural.hs:427-430` |
| Schlick Fresnel Approximation | ✅ Complete | `LightingProcedural.hs:420-422` |
| Lambert Diffuse | ✅ Complete | `LightingProcedural.hs:435-437` |
| Dielectric F0 = 0.04 | ✅ Complete | `LightingProcedural.hs:393-395` |
| Metalness-modulated F0 | ✅ Complete | `LightingProcedural.hs:393-395` |
| IBL Diffuse (Irradiance Map) | ✅ Complete | `LightingProcedural.hs:613,625-627` |
| IBL Specular (Prefiltered + BRDF LUT) | ✅ Complete | `LightingProcedural.hs:617-619,631-633` |
| Split-Sum Approximation | ✅ Complete | `LightingProcedural.hs:610-633` |
| Normal Mapping (TBN) | ✅ Complete | `GBuffer.hs:220-258` |
| Ambient Occlusion | ✅ Complete | `GBuffer.hs:261-268` |
| Emissive | ✅ Complete | `GBuffer.hs:270-278`, `LightingProcedural.hs:636` |
| Reinhard Tonemapping | ✅ Complete | `LightingProcedural.hs:641-643` |
| Gamma Correction (sqrt) | ✅ Complete | `LightingProcedural.hs:646-648` |
| Bindless Material Textures | ✅ Complete | `GBuffer.hs:206-278` |
| Metallic-Roughness Map | ✅ Complete | `GBuffer.hs:215-218` (G=roughness, B=metallic) |

### 3B. What's Missing / Incomplete

| Component | Status | Impact |
|-----------|--------|--------|
| **sRGB albedo sampling** | ❌ Missing | All albedo sampled as linear → too bright for sRGB textures |
| **Light count variable** | ❌ Broken | `lightCount` push constant exists but shader always evaluates 4 lights |
| **Point/spot lights** | ❌ Missing | `LightData` struct has `type` field but shader only handles directional |
| **Shadow mapping** | ❌ Missing | No shadow maps, no cascaded shadow maps |
| **SSAO** | ❌ Missing | Only baked AO from texture |
| **Emissive strength factor** | ❌ Missing | No `emissiveStrength` scalar multiplier |
| **glTF `alphaMode`/`alphaCutoff`** | ❌ Missing | No alpha test or alpha blend |
| **Double-sided rendering** | ❌ Missing | Backface culling always on |
| **Texture transform (KHR_texture_transform)** | ❌ Missing | No UV offset/scale |
| **Anisotropic filtering** | ❌ Missing | No sampler anisotropy |

### 3C. PBR Math Issues

1. **Geometry function uses `(alpha+1)^2/8`** (`LightingProcedural.hs:427`): This is the **Smith-IGX** approximation for the IBL geometry function, NOT the correct Smith-GGX for direct lighting. For direct lighting, `k = alpha^2 / 2` (Schlick-GGX remapping) is standard. Using the IBL variant makes specular too bright at low roughness.

2. **No energy conservation enforcement**: The specular BRDF can reflect more energy than it receives, especially at low roughness with the wrong geometry function. This causes blown-out highlights.

3. **Gamma approximation `sqrt()`**: Using `sqrt()` for gamma 2.0 instead of proper `pow(1/2.2)`. This under-corrects in shadows and over-corrects in highlights compared to real sRGB output.

---

## 4. Emission <a name="4-emission"></a>

**Status: Implemented but incomplete.**

- **Emissive texture**: ✅ Loaded from glTF (`GLTF.hs:322-338,565-570`), sampled in G-buffer (`GBuffer.hs:270-278`), written to emissive attachment, composited in lighting (`LightingProcedural.hs:636`)
- **glTF `emissiveFactor`**: ❌ Not loaded. The `pbrMetallicRoughness` struct has `baseColorFactor` but the glTF material's `emissiveFactor` (V3 Float, default [0,0,0]) is never read from the glTF material or stored in the entity data.
- **`EntityData` struct**: Has `emissiveIndex` (Word32) but no `emissiveFactor` (V3 Float). Need to add this field.
- **Emissive bloom**: ❌ Not implemented. Emissive values are just additively blended, which is correct for the base pass but doesn't produce the bloom/glow effect.

**Required for Duck**: The Duck model has no emissive, so this is not the issue.

---

## 5. Transparency, Translucency, Reflection, Refraction <a name="5-advanced-features"></a>

### 5A. Transparency — ❌ Not Implemented

- No alpha blend pass exists in the render graph
- No `alphaMode` property loaded from glTF materials (OPAQUE/MASK/BLEND)
- G-buffer has no alpha channel for transmission
- Deferred rendering fundamentally cannot do per-pixel alpha blending (would need forward pass or OIT)
- The milestone plan notes: "Deferred can't do transparency; keep forward path for glass/etc."

### 5B. Translucency / Subsurface Scattering — ❌ Not Implemented

- No SSS approximation
- No thickness map
- No wrap lighting

### 5C. Reflection — Partial

- **Specular IBL**: ✅ Environment map reflection via prefiltered cubemap + BRDF LUT
- **Screen-space reflections (SSR)**: ❌ Not implemented
- **Planar reflections**: ❌ Not implemented
- **KHR_materials_clearcoat**: ❌ Not implemented
- **KHR_materials_sheen**: ❌ Not implemented

### 5D. Refraction — ❌ Not Implemented

- No IOR (index of refraction) handling
- No transmission texture
- No `KHR_materials_transmission` support
- No `KHR_materials_volume` (for thick glass)
- No `KHR_materials_ior`

---

## 6. Full Issue Register <a name="6-issue-register"></a>

### P0 — Critical (Causes Visible Artifacts)

| # | Issue | File:Line | Description |
|---|-------|-----------|-------------|
| 1 | **Near plane clips close geometry** | `Scene.hs:70` | Near plane = 1.0. Camera can get as close as 0.1. Vertices between 0.1 and 1.0 from camera are clipped → holes in mesh. **Fix: near plane 0.1** |
| 2 | **Bindless index 0 = invisible** | `GBuffer.hs:215,245,265,274` | `if idx /= 0` treats index 0 as "no texture". First texture in bindless array is never sampled. **Fix: use `idx == 0xFFFFFFFF` or separate "has texture" flag** |
| 3 | **sRGB albedo not decoded** | `Texture.hs` + `GBuffer.hs:206` | All textures uploaded as RGBA8 UNorm. sRGB-encoded albedo sampled in linear space → too bright. **Fix: use `VK_FORMAT_R8G8B8A8_SRGB` for albedo** |

### P1 — High (Incorrect Rendering)

| # | Issue | File:Line | Description |
|---|-------|-----------|-------------|
| 4 | **Wrong geometry function for direct lighting** | `LightingProcedural.hs:427` | Uses IBL geometry remap `(α+1)²/8` instead of direct lighting remap `α²/2`. Makes specular too bright at low roughness. |
| 5 | **Multi-primitive single material** | `GLTF.hs:370-379,508-513` | `loadMesh` merges all primitives into one mesh. `processNode` assigns first primitive's material. Multi-material glTF models render wrong. |
| 6 | **Light count always 4** | `LightingProcedural.hs:397-592` | `lightCount` push constant read at line 375 but never used — all 4 lights always evaluated regardless of count. |
| 7 | **`emissiveFactor` not loaded** | `GLTF.hs` + `EntityData.hs` | glTF `Material.emissiveFactor` (V3 Float) never read or stored. No `emissiveFactor` in EntityData. |
| 8 | **`emissiveStrength` not loaded** | `GLTF.hs` | KHR_materials_emissive_strength extension not supported. No scalar multiplier for emissive. |

### P2 — Medium (Missing Features)

| # | Issue | File:Line | Description |
|---|-------|-----------|-------------|
| 9 | **No transparency/alpha blend** | Pipeline | No alpha test, no alpha blend pass. `alphaMode`/`alphaCutoff` not loaded. |
| 10 | **No shadow mapping** | Pipeline | No shadow maps for any light type. Direct lighting has no shadows. |
| 11 | **No point/spot lights** | `LightingProcedural.hs` | `LightData.type` field exists but shader only handles directional lights. No attenuation, no cone falloff. |
| 12 | **No SSR / planar reflections** | Pipeline | Only cubemap IBL reflections. No screen-space reflections. |
| 13 | **No refraction / transmission** | Pipeline | No IOR, no transmission texture, no volume. KHR extensions not supported. |
| 14 | **No subsurface scattering** | Pipeline | No SSS approximation, no thickness map, no wrap lighting. |
| 15 | **No texture transforms** | `GLTF.hs` | KHR_texture_transform (UV offset/scale/rotation) not loaded. |
| 16 | **No double-sided** | Pipeline | Backface culling always on. `material.doubleSided` not loaded. |
| 17 | **No anisotropic filtering** | Sampler creation | No `VK_SAMPLER_ANISOTROPY_ENABLE` on texture samplers. |
| 18 | **No animation/skinning** | `GLTF.hs` | glTF animations parsed by codec but never applied. No joint matrices, no morph targets. |
| 19 | **Mesh data kept in RAM** | `Resources.hs:88-89` | `mrVertices :: ![Vertex]` and `mrIndices :: ![Word32]` kept forever after GPU upload. Memory leak for large scenes. |

### P3 — Low (Code Quality / Future)

| # | Issue | File:Line | Description |
|---|-------|-----------|-------------|
| 20 | **Gamma sqrt() approximation** | `LightingProcedural.hs:646-648` | `sqrt()` ≈ gamma 2.0, should be `pow(1/2.2)` for proper sRGB. |
| 21 | **Lighting.hs duplicated** | `Lighting.hs` vs `LightingProcedural.hs` | 879/890 lines near-identical. Should unify with specialization constant or preprocessor. |
| 22 | **`DeferredPassData` 107 fields** | `Deferred.hs:36-111` | Monolithic record. Should decompose into per-pass sub-records. |
| 23 | **`error` for loading failures** | `GLTF.hs:148,221` | Crashes instead of graceful error. |
| 24 | **PBR math scalar-expanded** | `LightingProcedural.hs:397-592` | All vector math decomposed to scalars due to FIR limitations. ~5x code bloat vs GLSL. |
| 25 | **No texture deduplication** | `GLTF.hs` | Shared images decoded + uploaded multiple times. |

---

## 7. Summary Assessment

### What Works Well
- Full deferred pipeline (G-buffer → cloud → god ray → lighting → ImGui)
- Bindless texture array for per-entity materials
- GPU-driven rendering via compute cull + indirect draw
- PBR Cook-Torrance with IBL split-sum
- Normal mapping with TBN
- Emissive texture support
- Multi-light (4 directional, though always 4)
- glTF scene graph traversal with TRS transforms

### What Needs Immediate Fix (for Duck model)
1. **Near plane**: Change from 1.0 to 0.1 in `Scene.hs:70`
2. **Bindless index 0**: Reserve index 0 as "no texture" sentinel, start real textures at index 1
3. **sRGB albedo**: Use SRGB format for albedo textures

### What Needs Work (for general glTF correctness)
4. Multi-primitive → multi-entity (one entity per primitive with its own material)
5. Variable light count in shader
6. Direct lighting geometry function fix
7. `emissiveFactor` + `emissiveStrength` loading

### What's Major Feature Work
8. Transparency (requires forward pass or OIT)
9. Shadow mapping
10. Point/spot lights
11. Refraction/transmission
12. Animation/skinning
13. SSR
