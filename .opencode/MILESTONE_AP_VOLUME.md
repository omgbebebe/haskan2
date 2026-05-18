# 3D Aerial Perspective Volume

**Status**: Not started
**Priority**: P1 — depends on FIR Choose fix (MILESTONE_FIR_CHOOSE_FIX.md)
**Estimate**: 3-4 weeks
**Precedent**: Unreal Engine 4/5 volumetric fog, Frostbite AP volume

---

## Overview

Replace the separate cloud pass + god ray radial blur with a camera-aligned 3D Aerial Perspective volume. A compute shader fills a low-res 3D texture with raymarched scattering data per frame. The lighting pass samples this volume for atmospheric effects on all geometry — god rays appear naturally everywhere without a dedicated post-process pass.

### What This Replaces

| Current | After |
|---------|-------|
| Cloud pass (half-res fragment, raymarch per pixel) | AP volume compute (64³, raymarch per voxel) |
| God ray pass (32-sample radial blur) | **Deleted** — sampling AP volume covers this |
| Lighting samples `cloud_result` + `god_ray` | Lighting samples `ap_volume` (3D texture) |

### Why

- God rays on geometry (currently sky-only) come for free
- Atmospheric fog/haze on terrain and meshes via the same volume
- Lower per-pixel cost in lighting pass (one 3D texture sample vs two 2D samples + blending)
- Foundation for volumetric fog, height fog, and participating media

---

## Phase 0: Cloud Push Constants → UBO (3 days)

### Problem

Cloud push constants are 216 bytes. AP volume adds camera frustum params, grid dimensions, etc. — will exceed any reasonable push constant budget. Must migrate to UBO first.

### Implementation

**New file**: `src/Graphics/Haskan/Vulkan/Shaders/Deferred/CloudUniforms.hs`

```haskell
data CloudUniforms = CloudUniforms
  { cuCameraPos    :: !(V3 Float)
  , cuFrustumRay0  :: !(V3 Float)
  , cuFrustumRay1  :: !(V3 Float)
  , cuFrustumRay2  :: !(V3 Float)
  , cuSkyTint      :: !(V3 Float)
  , cuIblIntensity :: !Float
  , cuSunDir       :: !(V3 Float)
  , cuSunColor     :: !(V3 Float)
  , cuCloudHeight  :: !Float
  , cuTime         :: !Float
  , cuBlend        :: !Float
  , cuPrevVP       :: !(M44 Float)
  }
```

Packing: std140-aligned (each `V3 Float` takes 16 bytes with padding). Total ≈ 256 bytes in a UBO.

**Files to modify**:
- `Clouds.hs` — replace push constant reads with `UniformBuffer` binding
- `DeferredResources.hs` — add `drCloudUniformBuffer`, `drCloudUniformMemory`
- `Deferred.hs` — `uploadUniformBuffer` instead of push constant packing
- `DescriptorSetLayout.hs` — new UBO binding in cloud descriptor set
- `PassRecording.hs` — `vkCmdBindDescriptorSets` for UBO, remove `vkCmdPushConstants` for cloud pass

**Keep push constants for**: small per-pass data (render mode flags, debug toggles). Under 128 bytes.

### Deliverables

| Item | File |
|------|------|
| `CloudUniforms` data type | `Shaders/Deferred/CloudUniforms.hs` |
| UBO creation + upload | `DeferredResources.hs`, `Deferred.hs` |
| Cloud shader reads UBO | `Shaders/Deferred/Clouds.hs` |
| Remove cloud push constants | `PassRecording.hs`, `Deferred.hs` |

---

## Phase 1: AP Volume Infrastructure (5 days)

### 1A: Vulkan resources

**File**: `src/Graphics/Haskan/Vulkan/DeferredResources.hs`

Add to `DeferredResources`:

```haskell
, drAPVolumeImage      :: !Vulkan.VkImage
, drAPVolumeImageView  :: !Vulkan.VkImageView
, drAPVolumeExtent     :: !(Word32, Word32, Word32)  -- e.g. (64, 32, 64)
```

Create the 3D image:

```haskell
-- RGBA16F, 64×32×64 ≈ 1 MB
apImage <- Texture.createStorageImage3D rm pdev device 64 32 64 1
  Vulkan.VK_FORMAT_R16G16B16A16_SFLOAT graphicsQueue cmdBuf
```

**File**: `src/Graphics/Haskan/Vulkan/DescriptorSetLayout.hs`

New layout for AP volume compute:
- Binding 0: `StorageImage` (3D, RGBA16F) — write target
- Binding 1: `CombinedImageSampler` (3D, RGBA8) — cloud noise
- Binding 2: `UniformBuffer` — AP uniform data

**File**: `src/Graphics/Haskan/Vulkan/DescriptorSet.hs`

Update descriptor writes to bind the AP volume image.

### 1B: AP uniform data

**New file**: `src/Graphics/Haskan/Vulkan/Shaders/Compute/APVolumeUniforms.hs`

```haskell
data APVolumeUniforms = APVolumeUniforms
  { apuCameraPos     :: !(V3 Float)      -- 16 bytes (padded)
  , apuInvViewProj   :: !(M44 Float)     -- 64 bytes
  , apuSunDir        :: !(V3 Float)      -- 16 bytes
  , apuSunColor      :: !(V3 Float)      -- 16 bytes
  , apuCloudBase     :: !Float           -- 4 bytes
  , apuCloudTop      :: !Float           -- 4 bytes
  , apuTime          :: !Float           -- 4 bytes
  , apuNear          :: !Float           -- 4 bytes
  , apuFar           :: !Float           -- 4 bytes
  , apuVolumeDepth   :: !Float           -- 4 bytes (total depth of volume)
  }
```

Packed std140. Total ≈ 148 bytes. Fits comfortably in UBO.

### 1C: Render graph integration

**File**: `src/Graphics/Haskan/Render/Deferred.hs`

Insert AP volume compute dispatch into render graph:

```
Current order:
  G-Buffer → Clouds → God Rays → Lighting → ImGui

New order:
  G-Buffer → AP Volume (compute) → Lighting → ImGui
```

The cloud fragment pass and god ray pass are **removed**. Replaced by a single compute dispatch.

**File**: `src/Graphics/Haskan/Engine/Render/Internal/PassRecording.hs`

Add AP volume compute recording:

```haskell
-- 1. Transition AP volume image: UNDEFINED → GENERAL (storage)
-- 2. vkCmdBindPipeline COMPUTE
-- 3. vkCmdBindDescriptorSets COMPUTE
-- 4. vkCmdDispatch 64 32 64
-- 5. Barrier: COMPUTPUTE_WRITE → FRAGMENT_READ
```

### Deliverables

| Item | File |
|------|------|
| 3D AP volume image + view | `DeferredResources.hs` |
| AP volume descriptor layout | `DescriptorSetLayout.hs` |
| AP volume descriptor set + bindings | `DescriptorSet.hs` |
| AP uniform data type | `Shaders/Compute/APVolumeUniforms.hs` |
| Compute dispatch in render graph | `Deferred.hs`, `PassRecording.hs` |
| Remove god ray pass | `DeferredResources.hs`, `Deferred.hs`, `PassRecording.hs` |

---

## Phase 2: AP Volume Compute Shader (7 days)

### 2A: FIR compute shader definition

**New file**: `src/Graphics/Haskan/Vulkan/Shaders/Compute/APVolume.hs`

```haskell
type APVolumeDefs =
  '[ "apImage"     ':-> StorageImage '[DescriptorSet 0, Binding 0]
                          (Properties IntegralCoordinates Float ThreeD
                            (Just NotDepthImage) NonArrayed SingleSampled
                            Storage (Just (RGBA16 F)))
   , "cloudNoise"  ':-> Texture3D '[Binding 1, DescriptorSet 0] (RGBA8 UNorm)
   , "apUniforms"  ':-> UniformBuffer APVolumeUniforms
   , "main"        ':-> EntryPoint '[LocalSize 4 4 4] Compute
   ]
```

### 2B: Raymarch per voxel

Each compute invocation (x, y, z) maps to a world-space position in the camera frustum:

```haskell
main = shader do
  -- Get voxel coordinate
  gid <- get @"gl_GlobalInvocationID"
  let vx = x gid  -- [0, 64)
      vy = y gid  -- [0, 32)
      vz = z gid  -- [0, 64)

  -- Map to clip-space
  let ndcX = (fromIntegral vx + 0.5) / 64.0 * 2.0 - 1.0
      ndcY = (fromIntegral vy + 0.5) / 32.0 * 2.0 - 1.0
      depthSlice = fromIntegral vz / 64.0

  -- Unproject to world position using invViewProj
  worldPos <- unproject ndcX ndcY depthSlice invViewProj

  -- Ray direction from camera to worldPos
  let rayDir = normalise (worldPos - cameraPos)

  -- Cloud density at this voxel (sample noise)
  density <- sampleCloudDensity worldPos time cloudNoise

  -- Light march toward sun (reuse existing light march logic from Clouds.hs)
  lightEnergy <- lightMarch worldPos sunDir cloudBase cloudTop time cloudNoise

  -- Atmospheric scattering (Rayleigh + Mie approximation)
  scattering <- atmosphericScattering rayDir sunDir depthSlice

  -- Combine
  let result = Vec4 (scatterR + cloudR) (scatterG + cloudG)
                    (scatterB + cloudB) (density)

  imageWrite @"apImage" (Vec3 vx vy vz) result
```

### 2C: Density sampling (extract from Clouds.hs)

Extract the cloud density function from `Clouds.hs` into a shared module:

**New file**: `src/Graphics/Haskan/Vulkan/Shaders/Shared/CloudDensity.hs`

Contains:
- `sampleDensity` — noise sampling + height mask + domain warping
- `lightMarch` — Beer-Lambert + powder effect toward sun
- `henyeyGreenstein` — phase function

Shared between AP volume compute and any future cloud-related passes.

### 2D: Depth distribution

The z-slices of the volume need non-linear depth distribution to concentrate detail near camera:

```haskell
-- Exponential depth distribution
sliceDepth = near * pow(far / near, fromIntegral vz / 64.0)
```

Parameters tuneable via AP uniform push constants or UBO.

### Deliverables

| Item | File |
|------|------|
| AP volume compute shader | `Shaders/Compute/APVolume.hs` |
| Shared cloud density module | `Shaders/Shared/CloudDensity.hs` |
| Extracted density/light march | Refactored from `Clouds.hs` |
| Depth distribution function | `APVolume.hs` |

---

## Phase 3: Lighting Pass Integration (3 days)

### 3A: Sample AP volume in lighting shader

**File**: `src/Graphics/Haskan/Vulkan/Shaders/Deferred/LightingProcedural.hs`

Add 3D texture binding:

```haskell
, "ap_volume" ':-> Texture3D '[Binding 10, DescriptorSet 0] (RGBA16 F)
```

Sample at world position:

```haskell
-- Reconstruct world position from g-buffer (already available)
worldPos <- get @"in_world_pos"

-- Convert world position to AP volume UVW
let apUvw = worldPosToAPVolumeUVW worldPos invViewProj near far
~(Vec4 scatterR scatterG scatterB fogDensity) <- use @(ImageTexel "ap_volume") NilOps apUvw

-- Apply fog/atmosphere to lit surface color
let fogColor = Vec3 scatterR scatterG scatterB
    finalColor = lerp litSurfaceColor fogColor fogDensity
```

### 3B: World-to-AP-volume coordinate mapping

The UVW mapping reverses the voxel→world mapping from the compute shader:

```haskell
worldPosToAPVolumeUVW :: Code (V 3 Float) -> Code (M 4 4 Float) -> Code Float -> Code Float -> Code (V 3 Float)
worldPosToAPVolumeUVW worldPos invVP near far = do
  clipPos <- invVP !* worldPos  -- actually viewProj, not invVP
  let ndcX = clipPos^.x / clipPos^.w
      ndcY = clipPos^.y / clipPos^.w
      linearDepth = length (worldPos - cameraPos)
      u = ndcX * 0.5 + 0.5
      v = ndcY * 0.5 + 0.5
      w = log(linearDepth / near) / log(far / near)  -- exponential distribution
  Vec3 u v w
```

This requires the view-projection matrix in the lighting push constant or UBO.

### 3C: Cloud compositing for sky pixels

For sky-only pixels (no geometry), sample the AP volume at the sky direction and composite directly:

```haskell
if hasGeometry
  then applyFog litSurfaceColor apVolumeSample
  else apVolumeSample  -- sky gets full atmospheric scattering
```

### 3D: Remove old cloud/god ray bindings

From `LightingProcedural.hs`:
- Remove `cloud_result` binding (binding 7 or wherever)
- Remove `god_ray` binding (binding 9)
- Remove cloud compositing code
- Remove god ray compositing code

From `DeferredResources.hs`:
- Remove `drCloudImages`, `drCloudImageViews`, `drCloudHistoryImages`, etc.
- Remove `drGodRayImages`, etc.
- Remove cloud and god ray render passes, pipelines, framebuffers

### Deliverables

| Item | File |
|------|------|
| AP volume 3D texture binding | `LightingProcedural.hs` |
| World-to-UVW mapping | `LightingProcedural.hs` |
| Fog compositing on geometry | `LightingProcedural.hs` |
| Sky compositing from AP volume | `LightingProcedural.hs` |
| Old cloud/god ray bindings removed | `LightingProcedural.hs`, `DeferredResources.hs` |

---

## Phase 4: Temporal Accumulation (3 days)

### 4A: Temporal reprojection for AP volume

Re-project previous frame's AP volume to reduce noise:

**File**: `Shaders/Compute/APVolume.hs`

Add history texture binding:
```haskell
, "ap_history" ':-> Texture3D '[Binding 3, DescriptorSet 0] (RGBA16 F)
```

In compute shader:
```haskell
-- Re-project current voxel to previous frame's UVW
prevWorldPos <- unproject ndcX ndcY depthSlice prevInvViewProj
prevUvw <- worldPosToAPVolumeUVW prevWorldPos prevInvViewProj near far
~(Vec4 hr hg hb ha) <- use @(ImageTexel "ap_history") NilOps prevUvw

-- Blend
let blendFactor = 0.1  -- exponential moving average
    result = lerp historySample currentSample blendFactor
```

### 4B: History copy

After AP compute dispatch, copy current volume to history:

```
vkCmdCopyImage apVolume → apVolumeHistory (with appropriate 3D copy regions)
```

Or use `vkCmdBlitImage` if history is lower resolution.

### Deliverables

| Item | File |
|------|------|
| History texture + binding | `APVolume.hs`, `DeferredResources.hs` |
| Temporal reprojection in compute | `APVolume.hs` |
| History copy barrier | `PassRecording.hs` |

---

## Phase 5: Bilateral Upsample (2 days)

### 5A: Full-res AP volume sampling with depth-aware upsample

The AP volume is 64×32×64 (low-res). Naive trilinear sampling creates halo artifacts on geometry edges. Use bilateral upsample:

```haskell
-- In lighting shader
let volumeSample = sampleAPVolume bilinear worldPos

-- Reject samples where depth discontinuity is too large
let depthDiff = abs (geometryDepth - volumeDepth)
    weight = exp (-depthDiff * depthDiff / sigma)
    finalFog = volumeSample * weight
```

This requires the AP volume to store linear depth in one channel (e.g., alpha or a separate R32 texture).

### Deliverables

| Item | File |
|------|------|
| Bilateral upsample in lighting | `LightingProcedural.hs` |
| Depth-aware weight calculation | `LightingProcedural.hs` |

---

## Phase 6: Cleanup & Testing (2 days)

### 6A: Remove dead code

- `GodRays.hs` — delete entirely
- Cloud fragment pass code in `Clouds.hs` — keep density functions, remove render pass shader
- Cloud framebuffers, render passes, pipelines — remove from `DeferredResources.hs`
- God ray resources — remove from `DeferredResources.hs`

### 6B: Visual regression testing

- `--cloud-test` mode must produce similar cloud appearance
- `--procedural-sky` with AP volume must show atmospheric scattering on terrain
- God rays visible on geometry (not just sky) — the main quality improvement
- No ghosting (verify temporal accumulation)

### 6C: Performance benchmarking

| Metric | Target |
|--------|--------|
| AP volume compute (64³) | < 1ms on RTX 4090 |
| Lighting pass (AP sample) | < 0.1ms added |
| Total frame time vs current | Equal or better |
| VRAM increase | ~2MB (64×32×64 × 8 bytes × 2 for history) |

---

## Execution Order

```
Week 1: Phase 0 (UBO migration)
  0A → 0B → build verification

Week 1-2: Phase 1 (Infrastructure)
  1A → 1B → 1C → builds, no visual change yet

Week 2-3: Phase 2 (Compute shader)
  2C (extract shared) → 2A (defs) → 2B (raymarch) → 2D (depth)
  FIR Choose fix MUST be done first for clean conditionals

Week 3: Phase 3 (Lighting integration)
  3A → 3B → 3C → 3D → first visual result

Week 3-4: Phase 4 (Temporal)
  4A → 4B → ghosting test

Week 4: Phase 5 (Upsample) + Phase 6 (Cleanup)
  5A → 6A → 6B → 6C
```

---

## Dependencies

| Dependency | Why | Status |
|-----------|-----|--------|
| FIR Choose fix | Clean conditionals in compute shader | `MILESTONE_FIR_CHOOSE_FIX.md` |
| UBO in FIR | Phase 0 requires `UniformBuffer` binding in shaders | Already working in FIR examples |
| 3D storage image | AP volume write target | Already working (`CloudNoiseGen.hs`) |
| Compute pipeline | Per-frame dispatch | Already working (cull shader) |
| `imageWrite` in FIR | Compute writes 3D texture | Already working |

---

## Risk Assessment

| Risk | Mitigation |
|------|-----------|
| FIR type inference limits in complex compute shader | Same `step()` workarounds if Choose fix not done; or break into simpler functions |
| Push constant overflow without UBO migration | Phase 0 must complete first |
| Ghosting from temporal reprojection | Per-swapchain-image history (lesson from cloud ghosting fix) |
| AP volume resolution too low | Tunable: 64³ → 128³ at 8× VRAM cost |
| Depth distribution artifacts | Exponential distribution tuneable via uniforms |

---

## Key Files

| File | Role |
|------|------|
| `src/.../Shaders/Compute/APVolume.hs` | **New** — AP volume compute shader |
| `src/.../Shaders/Shared/CloudDensity.hs` | **New** — extracted shared density/light functions |
| `src/.../Shaders/Deferred/CloudUniforms.hs` | **New** — UBO data type |
| `src/.../Shaders/Deferred/LightingProcedural.hs` | Major changes — AP volume sampling, fog composite |
| `src/.../Vulkan/DeferredResources.hs` | Add AP volume images, remove cloud/god ray |
| `src/.../Render/Deferred.hs` | Render graph restructure |
| `src/.../Engine/Render/Internal/PassRecording.hs` | Compute dispatch recording |
| `src/.../Shaders/Deferred/GodRays.hs` | **Delete** |
| `3rdparty/fir/src/FIR/Syntax/IfThenElse.hs` | Prerequisite: Choose fix |

---

## Success Criteria

1. AP volume compute dispatch runs every frame, fills 64×32×64 RGBA16F texture
2. Lighting pass samples AP volume — atmospheric fog on terrain and meshes
3. God rays visible on geometry (not just sky) without dedicated post-process
4. God ray render pass deleted from render graph
5. No ghosting with temporal accumulation
6. Cloud appearance visually similar to current implementation
7. Total frame time ≤ current frame time
8. `spirv-val` passes on AP volume compute shader
