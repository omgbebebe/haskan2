# Haskan2 EEVEE Parity — Rendering Pipeline Milestones

**Status**: Not started (blocked by `MILESTONE_FIR_PIPELINE_FIXES.md` for Phases 3+)
**Estimate**: ~50-80 weeks total across all phases
**Reference**: EEVEE Next is ~174K LOC across ~600 files. This plan targets visual parity with ~18K LOC FIR.

---

## Overview

Five phases, each delivering independently visible rendering improvements. Each phase assumes completion of prior phases and the FIR fixes milestone.

```
Phase 1 (Done):  PBR deferred, IBL, clouds, culling
Phase 2:         Shadows + lights + AO + TAA
Phase 3:         SSR + SSS + probes + volumes
Phase 4:         DoF + motion blur + transparency
Phase 5:         Clustered lighting + advanced (requires FIR atomics)
```

---

## Current Baseline (M10 Complete)

| Feature | Status | Shader | LOC |
|---------|--------|--------|-----|
| PBR Deferred (Cook-Torrance) | Done | `GBuffer.hs` + `Lighting.hs` | 1161 |
| Normal Mapping | Done | `GBuffer.hs` | 284 |
| IBL Split-Sum + BRDF LUT | Done | `Lighting.hs` + compute prefilters | ~400 |
| 4 Directional Lights | Done | `Lighting.hs` | ~200 |
| Volumetric Clouds | Done | `Clouds.hs` | 540 |
| Bindless Textures | Done | `Render/Bindless.hs` | ~150 |
| GPU Frustum Culling | Done | `Cull` compute | 156 |
| Skybox (HDRI + Hosek-Wilkie) | Done | `Lighting.hs` | ~300 |
| Day/Night Cycle | Done | `DayNight.hs` | ~200 |
| Dear ImGui Debug | Done | `UI/Backend.hs` | ~400 |

**Total FIR shader code**: ~3,300 lines

---

## Phase 2: Foundation — Shadows, Lights, AO, TAA

**Priority**: High
**Estimate**: 8-12 weeks
**Dependencies**: None (current FIR is sufficient)
**EEVEE features covered**: Cascaded shadows, point/spot lights, GTAO, temporal anti-aliasing

### 2.1: Point and Spot Light Support

**Estimate**: 2-3 weeks

#### Description

Extend the lighting system from 4 directional lights to N point/spot/directional lights via a lights SSBO. The `LightData` struct (48 bytes) already exists in the entity system.

#### Tasks

1. **Extend `LightData` struct** in lighting shader
   - Current: position, intensity, color, type, direction, range
   - Add: `innerConeAngle`, `outerConeAngle` (spot), `falloffExponent`
   - Add: `lightType` enum (Directional=0, Point=1, Spot=2, AreaRect=3, AreaDisc=4)

2. **Attenuation model**
   - Point: inverse-square with range cutoff
   - Spot: cone attenuation * inverse-square
   - Directional: no attenuation (current behavior)
   ```haskell
   attenuation = case lightType of
     0 -> 1.0                                        -- directional
     1 -> saturate(1.0 - (dist/range)^4) / (dist^2)  -- point (UE4 falloff)
     2 -> coneFalloff * pointFalloff                   -- spot
   ```

3. **Dynamic light count**
   - Current: 4 lights hardcoded/unrolled
   - Target: `while` loop over SSBO, bounded by `maxLights` push constant or spec constant
   - FIR constraint: `while` loop works, but SSBO indexing inside loops may be fragile
   - Fallback: unroll to 8 or 16 lights if loop proves unstable

4. **Light SSBO population**
   - Parse lights from glTF (already partially supported)
   - Add point lights (position, color, intensity, range) to ECS
   - Upload to SSBO per frame

5. **Stochastic light sampling** (optional, advanced)
   - For >16 lights, sample subset per pixel using blue noise
   - Temporal accumulation over frames

#### Deliverables

| Item | File |
|------|------|
| Extended `LightData` struct | `Vulkan/Shaders/Deferred/Lighting.hs` |
| Point/spot attenuation functions | Same |
| Dynamic light loop or 8-16 light unroll | Same |
| glTF point/spot light parsing | `Scene/GLTF.hs` |
| Light SSBO update per frame | `Engine/Render.hs` |
| ImGui light list panel | `UI/Backend.hs` |

#### Tests

- Scene with 3 point lights, colored, verify multi-shadow behavior
- Spot light with cone visible on ground plane
- Verify existing 4 directional lights still work

---

### 2.2: Cascaded Shadow Maps

**Estimate**: 3-4 weeks

#### Description

Shadow mapping for the primary directional light using cascaded shadow maps (CSM). 3-4 cascades split by distance, PCF filtering.

EEVEE uses virtual shadow maps (VSM) with page allocation — that's 12+ shaders with atomics. CSM is the practical alternative: 90% visual quality, 3-4 shaders, no atomics needed.

#### Tasks

1. **Shadow map render pass**
   - 3-4 depth-only render passes (one per cascade)
   - Each cascade: orthogonal projection fitting a slice of the view frustum
   - Depth format: `D32_SFLOAT` or `D16_UNORM`
   - Resolution: 2048×2048 per cascade (configurable)
   - Render targets: texture array (3-4 layers) or separate images

2. **Cascade split computation**
   - Practical split scheme: logarithmic + linear blend
   ```haskell
   splitLambda = 0.75
   cascadeSplit i = near * (far/near)^(i/numCascades) -- logarithmic
                  + near + (far - near) * (i/numCascodes) -- linear
   cascadeSplit i = mix logSplit linearSplit splitLambda
   ```
   - Compute on CPU per frame, upload via push constant or UBO

3. **Shadow projection matrices**
   - For each cascade: compute tight bounding box around frustum slice
   - Stabilize: snap to texel grid to reduce shadow shimmer
   - Upload as array of `V 4 (M 4 4 Float)` (4 cascades × 64 bytes = 256 bytes — needs UBO, exceeds push constant)

4. **PCF shadow sampling**
   - Sample shadow map with `N×N` PCF kernel (3×3 default, 5×5 for soft)
   - Depth comparison: `fragmentDepth > shadowDepth + bias`
   - Average results for soft shadow
   - Poisson disk sampling for efficiency

5. **Cascade selection in lighting shader**
   - Determine which cascade the fragment falls in based on view-space depth
   - Sample the correct shadow map layer
   - Blend between cascades at seams to avoid hard transitions

6. **Shadow acne mitigation**
   - Slope-based depth bias (`dtan(slope)`)
   - Normal offset bias
   - Configurable bias parameters

#### FIR Shaders

```haskell
-- New: Shadow map vertex shader
shadowVertex :: Shader ...
  -- Transform vertex to each cascade's light space
  -- Output: gl_Position for depth-only render

-- Modified: Lighting.hs
-- Add shadow sampling function
shadowSample :: Code (V 3 Float)    -- world position
             -> Code Float          -- view-space depth
             -> Code Float          -- shadow factor [0..1]
```

#### Deliverables

| Item | File |
|------|------|
| Shadow map render pass (3-4 cascades) | `Render/Deferred.hs` |
| Shadow depth texture array | `Vulkan/DeferredResources.hs` |
| Shadow vertex shader | `Vulkan/Shaders/Shadow/Depth.hs` (new) |
| Shadow sampling in lighting | `Vulkan/Shaders/Deferred/Lighting.hs` |
| Cascade split computation | `Render/Shadow.hs` (new) |
| Shadow UBO (matrices + splits) | `Render/Deferred.hs` |
| PCF sampling (3×3, 5×5) | In shader |
| ImGui shadow debug panel | `UI/Backend.hs` |

#### Tests

- Single directional light with shadows on ground plane
- 3 cascade splits visible with debug coloring
- No shadow acne on sloped surfaces
- Shadow shimmer test: slow camera rotation

---

### 2.3: Ground Truth Ambient Occlusion (GTAO)

**Estimate**: 1-2 weeks

#### Description

Screen-space ambient occlusion using the GTAO algorithm (Jimenez et al., SIGGRAPH 2016). Single compute dispatch, ~200-400 lines GLSL equivalent.

#### Tasks

1. **GTAO compute shader**
   - Input: depth buffer (Hi-Z), normals, view/projection matrices
   - Output: AO texture (R8 or RG8)
   - Algorithm:
     - For each pixel, reconstruct world position from depth
     - Sample 4-8 directions in screen space
     - For each direction, find horizon angles via depth marching
     - Integrate occlusion using cosine-weighted hemisphere
   - Temporal accumulation: blend with previous frame's AO

2. **Hi-Z / depth mip chain**
   - Compute shader to build depth mip chain (already needed for SSR)
   - 6-8 mip levels, min-depth for each level
   - Single compute dispatch per level

3. **Integration into lighting**
   - Multiply GTAO result into ambient/diffuse lighting term
   - Current: AO from texture (per-vertex/per-material)
   - New: AO = max(textureAO, screenSpaceAO)
   - Or: AO = textureAO * screenSpaceAO (multiplicative)

4. **Parameters** (via push constant or UBO)
   - `aoRadius`: world-space sampling radius (0.5-5.0)
   - `aoBias`: bias to avoid self-occlusion (0.001-0.01)
   - `aoSamples`: direction samples (4-8)
   - `aoPower`: contrast exponent (1.0-3.0)

#### FIR Shader

```haskell
-- New: GTAO compute shader
gtaoCompute :: Shader '[LocalSize 8 8 1] Compute ...
  -- Read depth + normals
  -- Compute AO per pixel
  -- Write AO texture
```

#### Deliverables

| Item | File |
|------|------|
| GTAO compute shader | `Vulkan/Shaders/Deferred/GTAO.hs` (new) |
| Hi-Z depth mip chain shader | `Vulkan/Shaders/Compute/HiZ.hs` (new) |
| Hi-Z mip chain generation | `Render/Deferred.hs` |
| AO pass in deferred pipeline | `Render/Deferred.hs` |
| AO integration in lighting | `Vulkan/Shaders/Deferred/Lighting.hs` |
| ImGui AO debug panel | `UI/Backend.hs` |

#### Tests

- Scene with pillars, verify darkening in corners
- AO radius slider visual verification
- Performance: verify compute dispatch <0.5ms

---

### 2.4: Temporal Anti-Aliasing (TAA)

**Estimate**: 2-3 weeks

#### Description

TAA accumulation with velocity-based history reprojection. Sub-pixel jittered camera projection, neighborhood clamping for ghosting reduction.

#### Tasks

1. **Sub-pixel camera jitter**
   - Halton sequence (2,3) for sub-pixel offsets
   - Apply jitter to projection matrix: `proj[2][0] += offsetX/w`, `proj[2][1] += offsetY/h`
   - 8 or 16 samples, cycling each frame

2. **Velocity buffer**
   - G-buffer pass: output screen-space velocity `(currentPos - prevPos) / currentPos.w`
   - Requires previous frame projection × view matrix
   - Store as `RG16F` (2-component screen-space velocity)

3. **History reprojection**
   - Compute shader or fragment shader
   - Read current frame color + depth + velocity
   - Reproject previous frame color using velocity
   - Neighborhood clamping: variance clipping (3×3 or 5×5)
   - Blend: `result = lerp(reprojected, current, 0.05-0.1)`

4. **Film accumulation pass**
   - Persistent texture (not cleared between frames)
   - History reset on camera cut/jump (detect large velocity)
   - Tonemap space: clip in YCoCg space for better results

5. **Integration with existing pipeline**
   - TAA pass runs after lighting, before tone mapping
   - Output: supersampled color buffer
   - Tone mapping applied after TAA

#### Deliverables

| Item | File |
|------|------|
| Velocity buffer output | `Vulkan/Shaders/Deferred/GBuffer.hs` |
| TAA accumulation shader | `Vulkan/Shaders/Deferred/TAA.hs` (new) |
| History texture management | `Vulkan/DeferredResources.hs` |
| Halton jitter sequence | `Camera.hs` or `Render/Deferred.hs` |
| TAA pass in pipeline | `Render/Deferred.hs` |
| ImGui TAA panel | `UI/Backend.hs` |

#### Tests

- Scene with checkerboard floor, verify no flickering
- Moving camera, verify no ghosting artifacts
- Camera cut triggers history reset

---

## Phase 3: Visual Quality — SSR, SSS, Probes, Volumes

**Priority**: Medium-High
**Estimate**: 12-16 weeks
**Dependencies**: Phase 2 (Hi-Z from GTAO, velocity buffer from TAA)
**EEVEE features covered**: Screen-space reflections, subsurface scattering, reflection probes, irradiance grids, fog/volumetrics

### 3.1: Screen-Space Reflections (SSR)

**Estimate**: 4-6 weeks

#### Description

HiZ-based screen-space raymarching for specular reflections. 3-pass pipeline: ray generation → trace → denoise.

#### Tasks

1. **Ray generation pass** (compute)
   - For each pixel with roughness < threshold, generate reflection ray
   - Ray = reflect(viewDir, normal) + jitter
   - Output: ray direction + origin buffer

2. **HiZ raymarching pass** (compute)
   - March ray through Hi-Z depth pyramid (built in Phase 2.3)
   - Start at coarse mip, refine to fine mip on hit
   - 32-64 steps max
   - Output: hit coordinates + confidence

3. **Spatial + temporal denoise** (2 compute passes)
   - Spatial: bilateral filter guided by normal/depth/roughness
   - Temporal: history reprojection using velocity buffer (from Phase 2.4)
   - Output: denoised reflections

4. **Integration in lighting**
   - Blend SSR with probe-based reflections based on roughness
   - Rough surfaces: probe only
   - Smooth surfaces: SSR with probe fallback for disocclusions

#### FIR Shaders

| Shader | Est. LOC |
|--------|----------|
| `SSR/GenerateRays.hs` | 80-120 |
| `SSR/TraceHiZ.hs` | 200-300 |
| `SSR/DenoiseSpatial.hs` | 100-150 |
| `SSR/DenoiseTemporal.hs` | 100-150 |

#### Deliverables

- 4 FIR compute shaders
- SSR render passes integrated into deferred pipeline
- Roughness-based blending with probes
- ImGui SSR debug (show rays, hit mask, denoised output)

---

### 3.2: Subsurface Scattering (SSS)

**Estimate**: 2-3 weeks

#### Description

Screen-space Christensen-Burley SSS convolution. 16 samples per pixel, per-channel scattering radius.

#### Tasks

1. **SSS setup pass** (compute)
   - Extract pixels with SSS closure from G-buffer
   - Pack radiance + object ID into compact texture
   - Tile classification for indirect dispatch

2. **SSS convolution pass** (compute)
   - 16 Burley-profile samples per pixel
   - Per-channel scattering (R/G/B separate radii)
   - Object ID boundary clamping (prevent leaking)

3. **Material integration**
   - Add `subsurfaceRadius` and `subsurfaceColor` to material system
   - G-buffer: flag pixels with SSS in header or material index
   - Replace diffuse lighting for SSS pixels with SSS output

#### FIR Shaders

| Shader | Est. LOC |
|--------|----------|
| `SSS/Setup.hs` | 60-80 |
| `SSS/Convolve.hs` | 120-180 |

#### Deliverables

- 2 FIR compute shaders
- SSS render pass in deferred pipeline
- Material system extended with SSS parameters
- Visual test: wax candle or skin material

---

### 3.3: Reflection Probes and Irradiance Grids

**Estimate**: 3-4 weeks

#### Description

Reflection cubemap atlas for specular reflections, SH L1 irradiance grid for diffuse ambient. Replaces single HDRI skybox with localized environment sampling.

#### Tasks

1. **Reflection cubemap atlas**
   - Pre-bake cubemap at probe positions (6-face render or HDRI capture)
   - Octahedral mapping into shared atlas texture
   - Mip-chain convolution for roughness (similar to existing radiance prefilter)
   - Runtime: sample nearest probe based on world position

2. **Irradiance grid**
   - 3D texture with SH L1 coefficients (4 × RGB = 12 values per cell)
   - Pre-baked: render hemisphere integral at grid points
   - Runtime: trilinear sampling, rotate SH by inverse object transform

3. **Probe blending**
   - Sample 2-4 nearest probes weighted by distance
   - Parallax correction for box probes

4. **Probe management**
   - Probe positions stored in scene data
   - ImGui panel for probe placement
   - Probe baking: offline or on-demand

#### FIR Shaders

| Shader | Est. LOC |
|--------|----------|
| `Probes/CubemapConvolve.hs` | 80-100 |
| `Probes/IrradianceIntegrate.hs` | 60-80 |
| Modify `Lighting.hs` for probe sampling | +100-150 |

#### Deliverables

- Cubemap atlas generation (builds on existing radiance prefilter)
- Irradiance grid generation
- Probe sampling in lighting shader
- Scene data for probe positions
- ImGui probe editor

---

### 3.4: Fog and Volumetric Lighting

**Estimate**: 3-4 weeks

#### Description

Froxed-based volumetric fog with light scattering. Not full volumetric materials (no phase function per object) — just homogeneous/heterogeneous fog with shadow integration.

#### Tasks

1. **Froxed grid allocation**
   - 3D texture: `(screenW/8) × (screenH/8) × 64` depth slices
   - Exponential depth distribution

2. **Fog scattering pass** (compute)
   - Evaluate fog density per froxel (constant or height-based)
   - In-scatter from directional light (with shadow from Phase 2.2)
   - Out-scatter (extinction)
   - Single-scatter approximation

3. **Fog integration pass** (compute)
   - March along view rays through froxel grid
   - Accumulate scattered light × transmittance
   - Output: froxel radiance + transmittance

4. **Fog resolve** (fragment or compute)
   - Composite fog onto scene color
   - Depth-based blending per pixel

5. **Parameters**
   - Fog density, color, height falloff
   - Light scattering intensity
   - Mie scattering (optional: simple phase function)

#### FIR Shaders

| Shader | Est. LOC |
|--------|----------|
| `Fog/Scatter.hs` | 120-180 |
| `Fog/Integrate.hs` | 80-120 |
| `Fog/Resolve.hs` | 40-60 |

#### Deliverables

- 3 FIR shaders (2 compute + 1 fragment/compute)
- Froxel grid textures
- Fog passes in deferred pipeline
- Height-based and constant fog modes
- ImGui fog controls

---

## Phase 4: Polish — DoF, Motion Blur, Transparency

**Priority**: Medium
**Estimate**: 8-12 weeks
**Dependencies**: Phase 2 (TAA, velocity buffer)
**EEVEE features covered**: Depth of field, motion blur, forward transparent pass

### 4.1: Depth of Field (Bokeh)

**Estimate**: 6-8 weeks

#### Description

Post-processing bokeh DoF following "Life of a Bokeh" (SIGGRAPH 2018). 14+ compute dispatches. This is the most shader-heavy single feature.

#### Tasks

1. **Circle of Confusion (CoC) computation**
   - From camera focal length, aperture, focus distance
   - Per-pixel CoC stored in half-res texture

2. **Bokeh LUT generation** (compute)
   - Precompute bokeh shape (polygonal blades, rotation)
   - 1 dispatch at startup

3. **Half-res downsample** (compute)
   - Separate near/far field
   - Preserve highlights for bright bokeh

4. **Tile analysis** (compute)
   - Min/max CoC per tile for gather optimization
   - Tile dilation (looped)

5. **Gather pass** (compute, 2 dispatches: foreground + background)
   - Sample bokeh shape from LUT
   - Weighted accumulation

6. **Scatter pass** (indirect draw)
   - Render bokeh sprites for bright out-of-focus points
   - Requires indirect draw from compute output

7. **Final resolve** (compute)
   - Composite near/far fields at full resolution
   - Fill disocclusion holes

8. **Camera parameters**
   - `focalLength`, `aperture`, `focusDistance`
   - `bladeCount`, `bladeRotation` (bokeh shape)
   - Store in camera data / UBO

#### FIR Shaders

| Shader | Est. LOC |
|--------|----------|
| `DoF/BokehLUT.hs` | 40-60 |
| `DoF/Setup.hs` | 60-80 |
| `DoF/Downsample.hs` | 40-60 |
| `DoF/TilesFlatten.hs` | 40-60 |
| `DoF/TilesDilate.hs` | 40-60 |
| `DoF/Gather.hs` | 150-200 |
| `DoF/Filter.hs` | 60-80 |
| `DoF/Resolve.hs` | 80-100 |

**Total**: ~600-800 lines FIR

#### Deliverables

- 8 FIR compute shaders
- DoF render passes in pipeline
- Camera DoF parameters in scene data
- Visual test: focused sphere with blurry background
- ImGui DoF controls

---

### 4.2: Post-Process Motion Blur

**Estimate**: 1-2 weeks

#### Description

Feature-aware post-FX motion blur (Guertin et al.). 3 compute dispatches. Relatively simple — reuses velocity buffer from TAA.

#### Tasks

1. **Tile flatten** (compute)
   - Max velocity per tile from velocity buffer

2. **Tile dilate** (compute)
   - Expand tiles to cover fast-moving neighbors

3. **Convolve** (compute)
   - Feature-aware gather along motion vector
   - Weight by depth similarity and normal similarity

#### FIR Shaders

| Shader | Est. LOC |
|--------|----------|
| `MotionBlur/TilesFlatten.hs` | 40-50 |
| `MotionBlur/TilesDilate.hs` | 30-40 |
| `MotionBlur/Convolve.hs` | 100-150 |

#### Deliverables

- 3 FIR compute shaders
- Motion blur passes in pipeline
- Motion blur amount parameter
- Visual test: fast-rotating object

---

### 4.3: Forward Transparent Pass

**Estimate**: 2 weeks

#### Description

Forward rendering pass for transparent/alpha-blended objects that can't use deferred rendering.

#### Tasks

1. **Depth prepass separation**
   - Opaque objects: deferred (current)
   - Transparent objects: forward, rendered after deferred lighting

2. **Forward fragment shader**
   - Full PBR lighting computation in single pass
   - Reuse same light SSBO and shadow maps from deferred
   - Alpha blending: `SRC_ALPHA * ONE_MINUS_SRC_ALPHA`

3. **Sort transparent objects**
   - CPU-side depth sort by distance to camera
   - Or: order-independent transparency via depth peeling (advanced, skip for now)

4. **Material classification**
   - Materials with `alphaMode: BLEND` or alpha < 1.0 → forward pass
   - Add `isTransparent` flag to entity data

#### FIR Shaders

| Shader | Est. LOC |
|--------|----------|
| `Forward/Vertex.hs` | ~60 |
| `Forward/Fragment.hs` | ~300-400 (full PBR in one pass) |

#### Deliverables

- 2 FIR shaders (vertex + fragment)
- Forward render pass after deferred lighting
- Transparent material detection
- Visual test: glass window with deferred scene behind it

---

## Phase 5: Advanced — Clustered Lighting + Optimizations

**Priority**: Low-Medium (significant performance improvement)
**Estimate**: 8-12 weeks
**Dependencies**: `MILESTONE_FIR_PIPELINE_FIXES.md` Fix 1 (Atomics), Phase 2
**EEVEE features covered**: Clustered light culling, per-tile optimization

### 5.1: Clustered Light Culling

**Estimate**: 4-6 weeks
**Requires**: FIR atomics (atomic add for light assignment)

#### Description

Partition view frustum into 3D clusters (16×16×24 typical). Assign lights to clusters via atomic counters. Each fragment samples only lights in its cluster — O(lights_per_cluster) instead of O(total_lights).

#### Tasks

1. **Cluster bounds computation** (compute)
   - 16×16×24 = 6144 clusters
   - Each cluster: AABB in view space
   - Constant per frame (depends on camera)

2. **Light assignment** (compute)
   - For each light, determine overlapping clusters
   - `atomicAdd(clusterLightCount[c])` for assignment
   - Write light index to `clusterLightGrid[c][i]`
   - **Requires FIR atomics**

3. **Cluster lookup in lighting** (fragment or compute)
   - Determine cluster from gl_FragCoord + depth
   - Iterate only assigned lights
   - Removes the need for hardcoded max lights

#### FIR Shaders

| Shader | Est. LOC |
|--------|----------|
| `Cluster/BuildBounds.hs` | 80-120 |
| `Cluster/AssignLights.hs` | 100-150 |
| Modify `Lighting.hs` for cluster lookup | +80-120 |

#### Deliverables

- 2 FIR compute shaders
- Cluster light grid SSBOs
- Modified lighting shader for cluster lookup
- Performance benchmark: 100+ lights at 60fps

---

### 5.2: GPU-Driven Rendering

**Estimate**: 4-6 weeks
**Requires**: Indirect draw (already demonstrated in `Cull` shader)

#### Description

Full GPU-driven pipeline: culling, LOD selection, draw call generation entirely on GPU. CPU submits a single indirect draw call.

#### Tasks

1. **Extend GPU cull shader**
   - Current: frustum culling only
   - Add: occlusion culling via Hi-Z query
   - Add: LOD selection based on screen-space error
   - Add: meshlet culling (future: mesh shaders)

2. **Indirect draw buffer**
   - Current: `VkDrawIndexedIndirectCommand` buffer
   - Extend with per-instance entity data
   - GPU writes draw count via `atomicAdd`

3. **Multi-draw indirect**
   - Submit single `vkCmdDrawIndexedIndirectCount` (or multiple `vkCmdDrawIndexedIndirect`)
   - No CPU-side visibility determination

4. **GPU scene representation**
   - All entity data on GPU (SSBO, already done)
   - All transforms on GPU (currently CPU → SSBO upload)
   - Animation on GPU (compute shader for bone transforms)

#### Deliverables

- Extended GPU cull shader with occlusion + LOD
- Full indirect draw pipeline
- GPU-only transform hierarchy
- Performance benchmark: 10k objects at 60fps

---

## Feature Parity Matrix

| EEVEE Feature | Phase | Status | FIR LOC (est.) |
|---|---|---|---|
| PBR Deferred | — | Done | 1161 |
| Normal Mapping | — | Done | 284 |
| IBL | — | Done | ~400 |
| 4 Directional Lights | — | Done | ~200 |
| Volumetric Clouds | — | Done | 540 |
| GPU Culling | — | Done | 156 |
| Bindless Textures | — | Done | ~150 |
| Point/Spot Lights | 2.1 | Pending | ~300 |
| Cascaded Shadow Maps | 2.2 | Pending | ~500 |
| GTAO | 2.3 | Pending | ~300 |
| TAA | 2.4 | Pending | ~250 |
| SSR | 3.1 | Pending | ~700 |
| SSS | 3.2 | Pending | ~300 |
| Reflection Probes | 3.3 | Pending | ~300 |
| Irradiance Grids | 3.3 | Pending | ~200 |
| Volumetric Fog | 3.4 | Pending | ~300 |
| Depth of Field | 4.1 | Pending | ~700 |
| Motion Blur | 4.2 | Pending | ~250 |
| Forward Transparency | 4.3 | Pending | ~500 |
| Clustered Lighting | 5.1 | Pending | ~400 |
| GPU-Driven Rendering | 5.2 | Pending | ~400 |
| **Total** | | | **~7,000** |

**Existing**: ~3,300 lines FIR
**New**: ~5,100 lines FIR (shaders only, not counting Haskell host code)
**Total at parity**: ~8,400 lines FIR + ~3,000-5,000 lines Haskell host code

---

## Deliberately Excluded Features

| EEVEE Feature | Why Excluded |
|---|---|
| Virtual Shadow Maps | Requires atomics + 12 shaders. CSM is 90% as good. |
| Polymorphic 3-closure G-buffer | Single PBR closure sufficient for game engine. |
| BSL (C++ shader language) | Blender-specific, no SPIR-V equivalent needed. |
| Full shader node compiler | Fixed PBR model + texture baking is sufficient. |
| Surfel GI baking | Pre-baked probes are simpler. Runtime GI is future work. |
| Planar reflections | Requires full deferred re-render. Low ROI. |
| Cryptomatte | Production compositing, not runtime. |
| Volume materials | Requires OpenVDB-level data. Froxel fog is enough. |
| Grease Pencil | 2D animation domain. |
| Compositor | Post-production, not runtime. |

---

## Timeline Summary

| Phase | Duration | Cumulative | Key Deliverable |
|---|---|---|---|
| Phase 2 | 8-12 weeks | 8-12 wks | Shadows + multi-light + AO + TAA |
| Phase 3 | 12-16 weeks | 20-28 wks | SSR + SSS + probes + fog |
| Phase 4 | 8-12 weeks | 28-40 wks | DoF + motion blur + transparency |
| Phase 5 | 8-12 weeks | 36-52 wks | Clustered lighting + GPU-driven |
| **Total** | **36-52 weeks** | | |

Plus 6 weeks for FIR pipeline fixes = **42-58 weeks total** from now.

---

## Key Files Reference

| Current File | Phase 2 Modifications |
|---|---|
| `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Lighting.hs` | Point/spot lights, shadow sampling, GTAO integration, probe sampling |
| `src/Graphics/Haskan/Vulkan/Shaders/Deferred/GBuffer.hs` | Velocity output, SSS flag |
| `src/Graphics/Haskan/Render/Deferred.hs` | All new render passes (shadow, AO, TAA, SSR, etc.) |
| `src/Graphics/Haskan/Vulkan/DeferredResources.hs` | Shadow textures, AO texture, Hi-Z, history buffers |
| `src/Graphics/Haskan/Engine/Render.hs` | Per-frame SSBO updates, pass orchestration |
| `src/Graphics/Haskan/Engine/Render/Internal/PassRecording.hs` | Command buffer recording for new passes |
| `src/Graphics/Haskan/Vulkan/DescriptorSetLayout.hs` | New descriptor layouts per pass |
| `src/Graphics/Haskan/Camera.hs` | TAA jitter, DoF params |
| `src/Graphics/Haskan/Scene/ECS.hs` | Light entities, material extensions |
| `src/Graphics/Haskan/UI/Backend.hs` | Debug panels for each feature |

| New File | Phase |
|---|---|
| `Vulkan/Shaders/Shadow/Depth.hs` | 2.2 |
| `Vulkan/Shaders/Deferred/GTAO.hs` | 2.3 |
| `Vulkan/Shaders/Compute/HiZ.hs` | 2.3 |
| `Vulkan/Shaders/Deferred/TAA.hs` | 2.4 |
| `Vulkan/Shaders/SSR/GenerateRays.hs` | 3.1 |
| `Vulkan/Shaders/SSR/TraceHiZ.hs` | 3.1 |
| `Vulkan/Shaders/SSR/DenoiseSpatial.hs` | 3.1 |
| `Vulkan/Shaders/SSR/DenoiseTemporal.hs` | 3.1 |
| `Vulkan/Shaders/SSS/Setup.hs` | 3.2 |
| `Vulkan/Shaders/SSS/Convolve.hs` | 3.2 |
| `Vulkan/Shaders/Probes/CubemapConvolve.hs` | 3.3 |
| `Vulkan/Shaders/Probes/IrradianceIntegrate.hs` | 3.3 |
| `Vulkan/Shaders/Fog/Scatter.hs` | 3.4 |
| `Vulkan/Shaders/Fog/Integrate.hs` | 3.4 |
| `Vulkan/Shaders/Fog/Resolve.hs` | 3.4 |
| `Vulkan/Shaders/DoF/BokehLUT.hs` | 4.1 |
| `Vulkan/Shaders/DoF/Setup.hs` | 4.1 |
| `Vulkan/Shaders/DoF/Downsample.hs` | 4.1 |
| `Vulkan/Shaders/DoF/Gather.hs` | 4.1 |
| `Vulkan/Shaders/DoF/Resolve.hs` | 4.1 |
| `Vulkan/Shaders/MotionBlur/Convolve.hs` | 4.2 |
| `Vulkan/Shaders/Forward/Fragment.hs` | 4.3 |
| `Vulkan/Shaders/Cluster/BuildBounds.hs` | 5.1 |
| `Vulkan/Shaders/Cluster/AssignLights.hs` | 5.1 |
| `Render/Shadow.hs` | 2.2 |
| `Vulkan/ShaderSpecialization.hs` | FIR Fix 3 |

---

## Success Criteria

1. **Phase 2**: Scene with 8 colored point lights casting shadows, GTAO darkening corners, no flickering with TAA
2. **Phase 3**: Chrome sphere showing SSR reflections, skin-like material with SSS, localized reflections from probes
3. **Phase 4**: Camera focusing on near object with blurred background, fast-moving object with motion blur, glass window transparent
4. **Phase 5**: 100+ lights scene at 60fps with clustered culling, 10k objects GPU-culled and rendered
5. **Overall**: Visual quality comparable to EEVEE Next viewport for typical Blender scenes (PBR materials, indoor/outdoor, moderate complexity)
