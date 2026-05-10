# Haskan2 Shader Pipeline Analysis Report

**Date:** 2026-05-10  
**Scope:** Full trace from glTF loading → pixel output, with focus on coordinate systems, PBR correctness, type precision, and pipeline design.  
**Analyzed Files:** 28 `.hs` modules across `src/`, `3rdparty/fir/`, `3rdparty/gltf-loader/`

---

## Executive Summary

| Category | Issues Found | Severity |
|----------|-------------|----------|
| Coordinate systems | 3 (1 critical, 2 medium) | High |
| PBR/BRDF formulas | 2 (1 fixed recently, 1 remaining) | Medium |
| Type conversions / precision | 5 | Medium |
| Pipeline design | 4 | Low–Medium |
| **Total** | **14** | — |

The pipeline is functionally correct for uniform-scale scenes but has a **critical normal-transform bug** under non-uniform scale, a **Y-flip coordinate inconsistency** papered over by clockwise front-face winding, and **aggressive 16-bit depth** that will z-fight.

---

## 1. Pipeline Trace: glTF → Pixel

### 1.1 Asset Loading (CPU)

**Files:** `3rdparty/gltf-loader/src/Text/GLTF/Loader/*`, `src/Graphics/Haskan/Scene/GLTF.hs`

1. **Binary decode** (`BufferAccessor.hs:164`, `Decoders.hs:30-42`): glTF accessors decoded as little-endian `V3 Float` positions/normals, `V2 Float` UVs, `Word32` indices.
2. **Schema adaptation** (`Adapter.hs:129-250`): JSON schema types → engine `Gltf` types. Quaternion kept as `(x,y,z,w)` tuple.
3. **Mesh construction** (`GLTF.hs:371-409`):
   - Missing normals default to `V3 0 0 1`; missing UVs to `V2 0 0`; missing tangents to `V4 1 0 0 1`.
   - Tangents computed via Mikkelsen-style algorithm (`Utils/TangentSpace.hs:18-106`) if ≥3 indices.
   - Gram-Schmidt orthogonalization + handedness computed on CPU.
   - **All fields converted via `realToFrac` → `CFloat`** (`GLTF.hs:576-583`).
4. **Node transform** (`GLTF.hs:568-569`): glTF `(x,y,z,w)` quaternion swapped to Linear's `(w,x,y,z)`.
5. **ECS assignment** (`GLTF.hs:424-558`): PBR scalars (`metallicFactor`, `roughnessFactor`, `occlusionStrength`) + 5 texture indices stored per entity.

### 1.2 Scene Graph & Culling (CPU)

**Files:** `src/Graphics/Haskan/Render/RenderSystem.hs`, `src/Graphics/Haskan/Engine.hs`

1. **Transform hierarchy** (`RenderSystem.hs:78`): `childLocal !*! parentWorld` (column-vector convention).
2. **Model matrix** (`Transform.hs:24-35`): `M = T * R * S` (scale first, then rotate+translate).
3. **View matrix** (`Camera.hs:93-96`): `linear` `lookAt` → OpenGL-style right-handed Y-up view.
4. **Projection matrix** (`Engine.hs:1355-1358`): `Linear.Projection.perspective` → OpenGL-style perspective with Z in `[-1, 1]`.
5. **Transpose on upload** (`Engine.hs:591-592`): CPU row-major → GPU column-major via explicit `transpose`.
6. **SSBO upload** (`Engine.hs:621-640`): `ComputeEntityData` (std430, 144 bytes/entity) uploaded each frame.
7. **Compute culling** (`Shaders/Compute/Cull.hs:45-115`): Frustum-AABB test + distance-based LOD → `VkDrawIndexedIndirectCommand`.

### 1.3 G-Buffer Geometry Pass (GPU Vertex)

**File:** `src/Graphics/Haskan/Vulkan/Shaders/Deferred/GBuffer.hs:56-83`

**Vertex layout** (stride 60 bytes):

| Location | Attribute | Type | Format |
|----------|-----------|------|--------|
| 0 | position | `V3 Float` | `R32G32B32_SFLOAT` |
| 1 | UV | `V2 Float` | `R32G32_SFLOAT` |
| 2 | normal | `V3 Float` | `R32G32B32_SFLOAT` |
| 3 | tangent | `V4 Float` | `R32G32B32A32_SFLOAT` |
| 4 | color | `V3 Float` | `R32G32B32_SFLOAT` |

**Vertex shader transforms:**
- `mvp = projection * view * model`
- `worldPos = model * vec4(pos, 1)`
- `worldNorm = model * vec4(normal, 0)`  ← **BUG: no normal matrix**
- `worldTangent = model * tangent`       ← **BUG: no normal matrix**

### 1.4 G-Buffer Geometry Pass (GPU Fragment)

**File:** `src/Graphics/Haskan/Vulkan/Shaders/Deferred/GBuffer.hs:110-196`

1. **Albedo**: sample bindless texture array at `materialIndex`.
2. **Metallic/Roughness**: sample MR texture (blue=metallic, green=roughness) or use scalar factors.
3. **TBN construction**: normalize N and T, `B = cross(N, T) * handedness`. No re-orthogonalization in shader.
4. **Normal mapping**: decode `[0,1] → [-1,1]`, transform to world space via TBN.
5. **Occlusion**: `1.0 - strength * (1.0 - aoRaw)` if texture present, else `1.0`.
6. **Emissive**: sample texture or `0`.

**MRT outputs** (4 attachments + depth):

| Location | Output | Format | Channels |
|----------|--------|--------|----------|
| 0 | position | `RGBA16_SFLOAT` | XYZ = world pos, W = metallic |
| 1 | normal | `RGBA8_UNORM` | XYZ = encoded normal, W = roughness |
| 2 | albedo | `RGBA8_UNORM` | RGB = albedo, W = AO |
| 3 | emissive | `RGBA8_UNORM` | RGB = emissive, W = 1.0 |
| D | depth | `D16_UNORM` | depth |

### 1.5 Deferred Lighting Pass (GPU)

**File:** `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Lighting.hs:22-327`

**Vertex shader:** Fullscreen triangle from `gl_VertexIndex`, UVs with V-flip for Vulkan top-left origin.

**Fragment shader pipeline:**
1. **Decode g-buffer** (`lines 105-118`):
   - Position: `Vec4 posX posY posZ metallic` (sampled as 32-bit float despite 16-bit storage via `Texture2D'`)
   - Normal: decode `* 2 - 1`, renormalize
2. **View vector**: `V = normalize(cameraPos - worldPos)`
3. **Direct light** (`lines 157-202`): single directional light at `(1,1,1)/√3`
4. **IBL** (`lines 204-243`):
   - Diffuse: `irradiance_map * albedo * (1-metallic) * AO * 0.3`
   - Specular: `env_map LOD(roughness*9) * (F0*scale + bias) * 0.3`
5. **Tone mapping**: Reinhard `color / (color + 1)`
6. **Gamma correction**: `sqrt(color)` (~gamma 2.0)

### 1.6 Final Output

**File:** `src/Graphics/Haskan/Vulkan/GraphicsPipeline.hs:238-427`

- Lighting pass renders to swapchain image via `managedFullscreenPipeline`.
- No blending; single color attachment.
- Depth test **disabled** for fullscreen triangle (lighting pass reads depth from g-buffer, does not write it).

---

## 2. Coordinate Systems: Analysis

### 2.1 Space Definitions

| Space | Y | Z | Handedness | Source |
|-------|---|---|------------|--------|
| glTF | Up | — | Right | Asset spec |
| World | Up | — | Right | Matches glTF |
| View | Up | Into screen | Right | `linear` `lookAt` (OpenGL) |
| Clip | Up | Into screen | — | `linear` `perspective` (OpenGL) |
| NDC (Vulkan) | **Down** | Into screen | — | Vulkan spec |
| Screen | Down | — | — | `y=0` at top |

### 2.2 Critical Issue: Y-Up Projection in Y-Down NDC

**Location:** `Engine.hs:1355-1358` (`makeProjectionMatrix`)

`Linear.Projection.perspective` produces OpenGL-style clip space (Y-up, Z in `[-1,1]`). Vulkan NDC requires Y-down. There is **no Y-flip** in projection, viewport, or shader.

**Consequence:** The rendered image is upside-down relative to standard Vulkan convention.

**Compensation:** `VK_FRONT_FACE_CLOCKWISE` (`GraphicsPipeline.hs:115,319`) reverses winding order so that triangles still culled correctly despite the implicit Y-flip. This is a **symptom patch**, not a fix.

**Fix options:**
1. Use FIR's `Math.Linear.perspective` (`3rdparty/fir/src/Math/Linear.hs:799-816`) which defines a Vulkan-native matrix with Z in `[0,1]` and Y-down. It exists but is **unused**.
2. Or add a Y-flip scale matrix `scale(1, -1, 1)` after projection, and revert `frontFace` to `COUNTER_CLOCKWISE`.

### 2.3 Critical Issue: No Normal Matrix

**Location:** `GBuffer.hs:71-73`

```haskell
worldNorm  = model !*^ Vec4 nx ny nz 0
worldTangent = model !*^ tangent
```

Normals and tangents are transformed by the raw `model` matrix. For **non-uniform scale**, this is mathematically incorrect. The correct transform is `inverse(transpose(upper-left 3x3 of model))`.

**Impact:** Any mesh with non-uniform scaling (e.g., flattened spheres, stretched cubes) will have incorrect normals, breaking lighting and normal mapping.

**Fix:** Compute normal matrix on CPU per entity (or per frame if animated) and upload as an additional SSBO field, or compute `inverse(transpose(model))` in the vertex shader (expensive).

### 2.4 Tangent Space Consistency

**CPU** (`Utils/TangentSpace.hs`):
- Gram-Schmidt orthogonalizes tangent against normal.
- Computes handedness via `dot(bitanSum, cross(normal, tangent))`.

**GPU** (`GBuffer.hs:132-154`):
- Normalizes N and T independently.
- Derives B via `cross(N, T) * handedness`.
- **No Gram-Schmidt in shader** — assumes CPU orthogonality is preserved after model transform.

**Assessment:** This is fine **if** the model matrix is orthogonal (uniform scale + rotation). Under non-uniform scale, both the missing normal matrix and the TBN orthogonality assumption break.

### 2.5 glTF UV Convention

**Status:** Fixed 2025-05-10. `flipV` was removed. glTF UV `(0,0)` = top-left matches Vulkan. Procedural meshes (`unitCube`, `uvSphere`) also use Vulkan convention.

---

## 3. PBR / BRDF / Environment Mapping Audit

### 3.1 Direct-Light BRDF (Deferred Lighting)

**File:** `Lighting.hs:157-202`

| Term | Formula | Status |
|------|---------|--------|
| F0 | `lerp(0.04, albedo, metallic)` | Correct |
| Fresnel (Schlick) | `F0 + (1-F0)*(1-V·H)^5` | Correct |
| GGX NDF | `α² / (π * ((N·H)²*(α²-1)+1)²)` where `α = roughness²` | Correct |
| Geometry (Schlick-Smith) | `k = (α+1)²/8`, `G1 = N·L/(N·L*(1-k)+k)`, `G = G1L*G1V` | Correct |
| Specular | `D*F*G / (4*N·L*N·V + 0.001)` | Correct (epsilon prevents div-by-zero) |
| Diffuse | `albedo * (1-metallic) / π` | Correct (Lambert) |

**Note:** Single hardcoded directional light at `(1,1,1)/√3`. No point lights, spot lights, or light culling.

### 3.2 Environment IBL (Split-Sum)

**File:** `Lighting.hs:204-243`

| Component | Implementation | Status |
|-----------|---------------|--------|
| Diffuse IBL | `irradiance_map * albedo * (1-metallic) * AO * 0.3` | Correct |
| Specular IBL | `prefiltered_env_map * (F0*scale + bias) * 0.3` | Correct |
| BRDF LUT | Sampled at `(N·V, roughness)` | Correct |
| Fresnel for IBL | Uses `N·V` instead of `V·H` | **Correct** — IBL has no half-vector |

**Hardcoded `envIntensity = 0.3`** (`Lighting.hs:232`). No exposure or HDR tone-mapper beyond simple Reinhard.

### 3.3 BRDF LUT Generation

**File:** `src/Graphics/Haskan/Vulkan/BRDF.hs`

| Term | Formula | Status |
|------|---------|--------|
| GGX sampling | `cosθ = sqrt((1-r2)/(1+(a²-1)*r2))` | Correct |
| Visibility | `vis = G*V·H/(N·H*N·V)` | Correct |
| Scale/Bias | `scale = vis*(1-fc)`, `bias = vis*fc` | Correct |

**Known bug fixed 2025-05-10:** Code previously multiplied by extra `1/pdf`, double-counting PDF. `vis` term already equals `BRDF*N·L/PDF` in importance sampling. Fix removed the extra weight.

**Remaining concern:** BRDF LUT stored as `RGBA8_UNORM` — 8-bit quantization of scale/bias. This is standard (LearnOpenGL, Filament) and usually sufficient.

### 3.4 G-Buffer PBR Write

**File:** `GBuffer.hs:126-130`

```haskell
let useMrTexture = mrIdx /= 0
mrColor <- use @(BindlessTexel "tex") mrIdx NilOps uv
let metallicFinal = if useMrTexture then view @(Index 2) mrColor else metallic
    roughnessFinal = if useMrTexture then view @(Index 1) mrColor else roughness
```

- **Blue channel = metallic, green = roughness**. This matches glTF 2.0 spec.
- Scalar factors act as defaults when no texture is bound.

---

## 4. Type Conversions & Precision

### 4.1 G-Buffer Formats

| Attachment | Vulkan Format | Sampled Type | Issue |
|------------|--------------|--------------|-------|
| Position | `R16G16B16A16_SFLOAT` | `RGBA32 F` (via `Texture2D'`) | **Correct** — `Texture2D'` decouples sampled type from image format to satisfy VUID-SampledType-04471 |
| Normal | `R8G8B8A8_UNORM` | `RGBA8 UNorm` | Match |
| Albedo | `R8G8B8A8_UNORM` | `RGBA8 UNorm` | Match |
| Emissive | `R8G8B8A8_UNORM` | `RGBA8 UNorm` | Match |
| Depth | `D16_UNORM` | — | **Aggressive — see §4.4** |

### 4.2 Vertex Attributes

All attributes use `R32_*_SFLOAT` (32-bit float). This is **correct but wasteful**:

| Attribute | Current | Could be | Savings/vertex |
|-----------|---------|----------|----------------|
| Normal | `R32G32B32_SFLOAT` (12B) | `R8G8B8A8_SNORM` (4B) | 8B |
| Color | `R32G32B32_SFLOAT` (12B) | `R8G8B8A8_UNORM` (4B) | 8B |
| Tangent | `R32G32B32A32_SFLOAT` (16B) | `R8G8B8A8_SNORM` + `R8` (4B) | 12B |

**Current stride:** 60 bytes. **Potential stride:** ~32 bytes (47% reduction).

### 4.3 Precision Loss Paths

| Data Path | Source | Storage | Loss? |
|-----------|--------|---------|-------|
| Position (vertex → G-buffer) | `Float32` | `Float16` | **Yes** — 16-bit world position. Adequate for typical scenes, banding at large coordinates. |
| Normal (vertex → G-buffer) | `Float32` | `UNorm8` | **Yes** — ~0.4° angular quantization error. Renormalized on read, which fixes length but not direction quantization. |
| Roughness (G-buffer) | `Float32`/`UNorm8` tex | `UNorm8` (normal.a) | **Yes** — 8-bit roughness = 256 discrete steps. Visible stepping on smooth materials. |
| Metallic (G-buffer) | `Float32`/`UNorm8` tex | `Float16` (pos.a) | No — 16-bit is plenty for metallic. |
| Depth | `Float32` clip | `D16_UNORM` | **Yes** — significant z-fighting risk. See §4.4. |

### 4.4 Critical: D16_UNORM Depth Buffer

**Location:** `DeferredResources.hs:76`, `GraphicsPipeline.hs` (depth stencil state)

`VK_FORMAT_D16_UNORM` provides only 16 bits of depth precision. With a near plane of `0.1` and far of `10000`, the precision distribution is:

- `Δz` at 1m: ~0.06 mm
- `Δz` at 10m: ~6 mm  
- `Δz` at 100m: ~0.6 m
- `Δz` at 1000m: ~60 m

**Fix:** Use `VK_FORMAT_D32_SFLOAT` or `VK_FORMAT_D24_UNORM_S8_UINT`.

### 4.5 Type Conversions in Shader Code

**Explicit casts:**
- `Lighting.hs:33`: `fromIntegral vertIdx :: Code Float` (vertex index → float for branch)
- `Bindless.hs:80`: `fromIntegral matIdx :: Code Float` (layer index for array texture)

**Implicit conversions:**
- G-buffer texture samples (`RGBA8 UNorm`) implicitly convert to `Float` when extracted.
- Normal decode `* 2 - 1` is explicit remap; no precision change in the operation itself.

**No hazardous casts found** (e.g., `float` → `int` truncation, `double` → `float` narrowing in shader).

---

## 5. Pipeline Design, Bottlenecks & Improvements

### 5.1 Strengths

| Aspect | Assessment |
|--------|------------|
| Deferred shading | Clean 4-target G-buffer, fullscreen triangle lighting pass. Standard and correct. |
| Bindless textures | Single `BindlessTexture2D` array for all materials. No descriptor set rebinding per draw. |
| GPU culling | Compute shader frustum cull + LOD via `VkDrawIndexedIndirectCommand`. Modern approach. |
| SSBO-driven rendering | Per-instance data from SSBO indexed by `gl_InstanceIndex`. Minimal CPU overhead. |
| `Texture2D'` patch | Correctly handles sampled-type vs image-format decoupling for 16-bit position. |

### 5.2 Bottlenecks & Design Issues

#### 5.2.1 Single directional light only
**Location:** `Lighting.hs:120-123`

```haskell
ldx = 1.0 / sqrt 3.0
ldy = 1.0 / sqrt 3.0
ldz = 1.0 / sqrt 3.0
```

No light list, no point/spot lights, no shadow mapping. The deferred architecture is ready for multiple lights but the shader is hardcoded to one.

**Improvement:** Add a light SSBO (position, color, intensity, type) and loop in the lighting shader. Start with a small fixed array (e.g., 64 lights) + tile/cluster deferred later.

#### 5.2.2 No shadow mapping
No shadow maps for the directional light. Scenes look flat without contact shadows.

**Improvement:** Add cascaded shadow maps (CSM) for the directional light. The deferred pipeline already separates geometry and lighting, so shadow sampling fits naturally in the lighting pass.

#### 5.2.3 CPU-side BRDF LUT generation
**Location:** `Engine.hs:968`

`BRDF.generateBRDFLUT 256 256` runs on CPU at startup. For 256×256×128 samples this is negligible (~8 ms), but it is single-threaded and blocks load.

**Improvement:** Precompute offline and load from disk, or generate on GPU via compute shader.

#### 5.2.4 No runtime environment prefiltering
**Location:** `Engine.hs:946-971`

Radiance cubemap is expected to be pre-filtered offline (mip chain = roughness levels). No runtime compute prefiltering.

**Assessment:** Acceptable for static environments. For dynamic skies or time-of-day, add a compute shader that convolutes the radiance cubemap into filtered mip levels.

#### 5.2.5 Reinhard + sqrt gamma is primitive
**Location:** `Lighting.hs:250-258`

```haskell
mapx = colx / (colx + 1)
gamx = sqrt mapx
```

Reinhard crushes highlights; `sqrt` is a crude gamma approximation. No exposure control, no bloom, no auto-exposure.

**Improvement:** ACES filmic tone mapping + proper sRGB OETF (`pow(color, 1/2.2)` or piecewise sRGB curve). Add a `tonemap(exposure, color)` function with configurable exposure.

#### 5.2.6 G-buffer bandwidth
4 MRT attachments × 4 bytes/pixel (except position at 8 bytes) = ~24 bytes/pixel. At 1920×1080 this is ~50 MB/frame written. For a single directional light, this is overkill — forward+ or clustered forward might be more efficient.

**Improvement:** Evaluate clustered forward shading. Eliminates G-buffer bandwidth and allows MSAA. Keep deferred for many lights.

#### 5.2.7 All materials use same shader
No shader permutation for:
- Alpha tested / blended materials
- Unlit / emissive-only materials
- Subsurface scattering
- Clear coat

**Improvement:** Add a material flags field to `EntityData` and branch in the G-buffer fragment shader, or use shader specialization constants.

### 5.3 Synchronization & Resource Management

- **G-buffer layout transition** (`DeferredResources.hs:107-116`): Initial `UNDEFINED → SHADER_READ_ONLY_OPTIMAL` transition is done on a one-time command buffer. Correct.
- **No barriers between g-buffer and lighting?** The task agents did not locate explicit image memory barriers. The render pass subpass dependencies likely handle this, but this should be verified in `RenderPass.hs`.

---

## 6. Issue Summary Table

| # | Issue | Location | Severity | Fix Effort |
|---|-------|----------|----------|------------|
| 1 | **No normal matrix** — raw `model` transforms normals; breaks non-uniform scale | `GBuffer.hs:71-73` | **Critical** | Medium (add SSBO field or compute in VS) |
| 2 | **OpenGL projection in Vulkan** — Y-up clip space, image upside-down; compensated by CW winding | `Engine.hs:1355-1358`, `GraphicsPipeline.hs:115` | **High** | Low (use FIR `perspective` or Y-flip) |
| 3 | **D16_UNORM depth** — severe z-fighting at distance | `DeferredResources.hs:76` | **High** | Trivial (change format to D32_SFLOAT) |
| 4 | Roughness stored in 8-bit UNORM — visible stepping on smooth materials | `GBuffer.hs:194` | Medium | Low (store roughness in 16-bit channel) |
| 5 | Position stored in 16-bit float — potential banding at large coordinates | `DeferredResources.hs:74` | Medium | Low (use RGBA32F if bandwidth allows) |
| 6 | No point/spot lights — deferred pipeline underutilized | `Lighting.hs:120-123` | Medium | Medium (add light SSBO) |
| 7 | Primitive tone mapping (Reinhard + sqrt) — crushed highlights | `Lighting.hs:250-258` | Low | Low (ACES + sRGB) |
| 8 | Vertex attribute over-precision — 32-bit normals/colors wasteful | `Vertex.hs:50-57` | Low | Low (switch to 8-bit SNORM/UNORM) |
| 9 | TBN not re-orthogonalized in shader — assumes orthonormal input | `GBuffer.hs:132-154` | Low | Low (add Gram-Schmidt in VS or FS) |
| 10 | No shadow mapping | — | Medium | High (add CSM) |
| 11 | No runtime env prefiltering | `Engine.hs:946-971` | Low | Medium (compute shader) |
| 12 | G-buffer bandwidth high for simple scenes | `DeferredResources.hs:74-99` | Low | High (evaluate clustered forward) |
| 13 | `envIntensity` hardcoded | `Lighting.hs:232` | Low | Trivial (make push constant / uniform) |
| 14 | BRDF LUT generated on CPU at startup | `Engine.hs:968` | Low | Low (precompute to disk) |

---

## 7. Recommended Priority Order

1. **Fix normal matrix** (§6 #1) — incorrect lighting on any scaled mesh is a rendering bug.
2. **Fix projection Y-flip** (§6 #2) — use Vulkan-native matrix, revert winding to CCW.
3. **Upgrade depth format** (§6 #3) — `D32_SFLOAT` to eliminate z-fighting.
4. **Increase roughness precision** (§6 #4) — store roughness in 16-bit (e.g., move to position.a or use RG16).
5. **Add light SSBO** (§6 #6) — unlock deferred shading's main benefit.
6. **Improve tone mapping** (§6 #7) — ACES filmic for better visuals.
7. **Optimize vertex formats** (§6 #8) — 47% vertex bandwidth reduction.
8. **Add shadow mapping** (§6 #10) — major visual improvement.

---

*Report generated from analysis of haskan2 deferred rendering pipeline. All line numbers refer to repository state as of 2026-05-10.*
