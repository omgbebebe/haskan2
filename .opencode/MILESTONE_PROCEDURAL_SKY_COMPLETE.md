# Milestone: Procedural Sky — Complete Cubemap Replacement (GPU Compute)

## Objective

Replace the photo-based environment cubemap (`data/textures/cubemaps/<envDir>/`) with a **fully procedural environment** when `--procedural-sky` is provided. The cubemap must not be loaded from disk in procedural mode. All pipeline stages that previously consumed the photo cubemap must instead consume a **procedurally generated cubemap and 2D Sky LUT**.

## Background

The current `--procedural-sky` flag (commit `88d9d84`) generates a 200×200 RGBA16F Sky LUT on the CPU and uploads it to the GPU, but **still loads the photo cubemap** from `data/textures/cubemaps/<envDir>/`. The `LightingProcedural` shader uses the Sky LUT for background pixels but continues to sample `env_map` and `irradiance_map` (the photo cubemaps) for geometry IBL. This means:

1. The `--env-dir` option is not actually ignored when `--procedural-sky` is passed.
2. Photo files are read from disk despite the user asking for procedural sky.
3. Day-night cycling is impossible because the photo cubemap encodes a fixed sun position and fixed lighting.

## Design Principles

- **Mutual exclusivity**: `--procedural-sky` and `--env-dir` are mutually exclusive. When `--procedural-sky` is set, the engine must not touch `data/textures/cubemaps/`.
- **Single source of truth**: The `SkyParams` record (sun direction, Rayleigh/Mie coefficients, turbidity) drives both the Sky LUT and the cubemap generation.
- **All consumers switch**: Background, clouds, and geometry IBL must all sample the procedural environment.
- **GPU-side generation**: Use FIR compute shaders to generate Sky LUT and cubemaps on the GPU, not the CPU. This makes dynamic regeneration feasible for day-night cycles.

---

## Architecture

```
Startup (when --procedural-sky):
│
├─> CPU: Create empty storage images (sky_lut, env_map, irradiance_map)
│       ├─> sky_lut: 200×200 RGBA16F storage image
│       ├─> env_map: 512×512×6 RGBA8 storage image (cube)
│       ├─> irradiance_map: 64×64×6 RGBA8 storage image (cube)
│       └─> brdf_lut: unchanged (existing)
│
├─> GPU (compute dispatch):
│       ├─> Sky LUT compute: LocalSize 8 8 1, 25×25 workgroups
│       │   Each invocation: compute UV from gl_GlobalInvocationID,
│       │   decode to (cosGamma, cosTheta), evaluateSky(), imageWrite
│       ├─> Radiance cubemap compute: LocalSize 8 8 1, 64×64×6 workgroups
│       │   Each invocation: compute face+texel direction, evaluateSky(), imageWrite
│       └─> Irradiance cubemap compute: LocalSize 8 8 1, 8×8×6 workgroups
│           Each invocation: hemisphere Monte Carlo integration,
│           evaluateSky() per sample, average, imageWrite
│
├─> GPU (barrier + transition):
│       Storage images transitioned to SHADER_READ_ONLY_OPTIMAL
│       for sampling by graphics pipelines
│
└─> Runtime: All shaders sample procedural environment
        ├─> Lighting pass background ──> sky_lut (2D sample)
        ├─> Lighting pass geometry IBL ──> env_map / irradiance_map (cube sample)
        └─> Cloud pass ambient in-scattering ──> sky_lut (2D sample)

Dynamic update (during day-night cycle):
│
├─> State loop: monitor gameTimeOfDay TVar
├─> When sunDir changes by > threshold (2°):
│   Set TVar Bool skyNeedsRegeneration
├─> Render loop: check flag before frame
├─> If set: dispatch compute shaders (same as startup)
│   with updated sunDir uniform buffer
├─> Pipeline barrier ensures storage writes complete
│   before graphics shaders sample
└─> Clear flag
```

---

## Why GPU Compute Instead of CPU

The engine already has FIR compute shader infrastructure (`Cull.hs`, `ComputePipeline.hs`). The previous plan proposed CPU-side generation (~85ms startup, dominated by irradiance Monte Carlo). GPU compute is the correct approach because:

1. **Performance**: Sky LUT = 625 invocations × ~50 ops = sub-millisecond. Irradiance = 64×64×6 × 256 samples = ~6M ops, but parallelized across ~3K invocations = ~0.5ms on GPU. Total < 2ms.

2. **Dynamic updates**: Sub-millisecond cost means regeneration every frame is feasible. Even conservative approach (regenerate on 2° sun change) is trivial.

3. **No CPU-GPU synchronization bottleneck**: Compute writes directly to GPU memory. No staging buffers, no host-device copies.

4. **Existing pattern**: The cull shader (`Cull.hs:47`) uses `EntryPoint '[LocalSize 64 1 1] Compute`, `StorageBuffer`, and dispatch. Storage image writes (`imageWrite`) are supported in FIR.

---

## Detailed Work Items

### Phase 1: FIR Compute Shaders for Procedural Generation

**New file**: `src/Graphics/Haskan/Vulkan/Shaders/Compute/SkyLUTGen.hs`

**Shader**: Sky LUT generation compute shader
```haskell
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Graphics.Haskan.Vulkan.Shaders.Compute.SkyLUTGen where

import FIR
import Graphics.Haskan.Vulkan.Shaders.Sky.Procedural (evaluateSky, SkyParams)
import Math.Linear

type SkyGenData =
  Struct
    '[ "sunDirX" ':-> Float,
       "sunDirY" ':-> Float,
       "sunDirZ" ':-> Float,
       "sunIntensity" ':-> Float,
       "rayleighR" ':-> Float,
       "rayleighG" ':-> Float,
       "rayleighB" ':-> Float,
       "mieCoeff" ':-> Float,
       "mieG" ':-> Float,
       "turbidity" ':-> Float
     ]

type Defs =
  '[ "skyLutImage" ':-> StorageImage '[DescriptorSet 0, Binding 0] (RGBA16 F),
     "skyGenData" ':-> Uniform '[DescriptorSet 0, Binding 1] SkyGenData,
     "main" ':-> EntryPoint '[LocalSize 8 8 1] Compute
   ]

program :: Module Defs
program = Module $ entryPoint @"main" @Compute do
  ~(Vec3 gidX gidY _) <- get @"gl_GlobalInvocationID"
  
  -- Read uniform
  sunDirX <- use @(Name "skyGenData" :.: Name "sunDirX")
  sunDirY <- use @(Name "skyGenData" :.: Name "sunDirY")
  sunDirZ <- use @(Name "skyGenData" :.: Name "sunDirZ")
  -- ... read remaining params
  
  -- Decode invocation ID to UV
  let u = gidX / 199.0
      v = gidY / 199.0
      cosGamma = u * 2.0 - 1.0
      cosTheta = v * v
      sinTheta = sqrt (max 0.0 (1.0 - cosTheta * cosTheta))
      viewDir = normalize (Vec3 sinTheta cosTheta 0.0)
      sunDir = normalize (Vec3 sunDirX sunDirY sunDirZ)
  
  -- Evaluate sky (inline the atmospheric model)
  let cosGammaDot = dot viewDir sunDir
      -- ... full evaluateSky logic inline ...
      radiance = Vec3 r g b
      result = Vec4 r g b 1.0
  
  -- Write to storage image
  imageWrite @"skyLutImage" (Vec2 gidX gidY) result
```

**Notes**:
- The `evaluateSky` function from `Procedural.hs` must be inlined into FIR DSL (or reimplemented in FIR terms). FIR shaders cannot call Haskell functions.
- Alternative: keep `evaluateSky` as a pure Haskell function used only for CPU fallback, and duplicate the math in FIR for the compute shader.
- `imageWrite` writes to `StorageImage` which is a `writeonly image2D` in SPIR-V.

**New file**: `src/Graphics/Haskan/Vulkan/Shaders/Compute/CubemapGen.hs`

**Shader**: Radiance and irradiance cubemap generation
```haskell
-- Two variants or two entry points in one module:
-- 1. radianceGen: one invocation per texel per face, direct evaluateSky
-- 2. irradianceGen: one invocation per texel per face, hemisphere integration

type CubemapGenData =
  Struct
    '[ -- same sky params as SkyGenData
       "faceSize" ':-> Word32,  -- 512 for radiance, 64 for irradiance
       "faceIndex" ':-> Word32  -- 0-5 for cube face
     ]

type Defs =
  '[ "cubemapImage" ':-> StorageImage '[DescriptorSet 0, Binding 0] (RGBA8 UNorm),
     "genData" ':-> Uniform '[DescriptorSet 0, Binding 1] CubemapGenData,
     "main" ':-> EntryPoint '[LocalSize 8 8 1] Compute
   ]
```

For irradiance, each invocation does a hemisphere integration loop:
```haskell
-- Pseudocode in FIR DSL
let normal = getCubeFaceDirection faceIndex texelCoord
    samples = 256
    accumulator = Vec3 0 0 0
loop i from 0 to samples-1:
    sampleDir = hemisphereSample(normal, i, samples)  -- Hammersley
    radiance = evaluateSky sampleDir sunDir
    accumulator = accumulator + radiance * dot(sampleDir, normal)
result = accumulator / samples
imageWrite "cubemapImage" (computeImageCoord faceIndex texelCoord) (Vec4 result 1)
```

**FIR limitations to check**:
- Does FIR support `for` loops? The cull shader uses `if` but no loops.
- Does FIR support `imageWrite` for cube images? Need to check if `StorageImage` can be cube-typed.
- Does FIR support array indexing for quasi-random sequence tables?

If loops are not supported in FIR, the irradiance convolution must be done with fewer samples in unrolled code (impractical at 256 samples). Alternative: generate irradiance on CPU with the existing `generateSkyLUT`-style code, but only once at startup. The radiance cubemap (direct evaluateSky, no integration) is trivial in FIR.

**Decision**: If FIR lacks loop support for irradiance:
- Sky LUT: GPU compute (trivial, no loops)
- Radiance cubemap: GPU compute (trivial, no loops)
- Irradiance cubemap: CPU-side at startup only (~6ms with 64 samples, acceptable). OR use a simplified approximation (e.g., average of face corners, or direct radiance cubemap blurred with box filter via `vkCmdBlitImage`).

### Phase 2: Compute Pipeline Infrastructure

**Modules**: 
- `src/Graphics/Haskan/Vulkan/DescriptorSetLayout.hs` — add compute descriptor set layouts for sky LUT gen and cubemap gen
- `src/Graphics/Haskan/Vulkan/DescriptorPool.hs` — add compute descriptor pools
- `src/Graphics/Haskan/Vulkan/ComputePipeline.hs` — already exists, reuse

**New layouts**:
```haskell
managedSkyLUTComputeDescriptorSetLayout :: VkDevice -> m VkDescriptorSetLayout
-- Bindings: 0 = StorageImage (sky_lut), 1 = Uniform (skyGenData)

managedCubemapComputeDescriptorSetLayout :: VkDevice -> m VkDescriptorSetLayout
-- Bindings: 0 = StorageImage (cubemap), 1 = Uniform (cubemapGenData)
```

**New descriptor pools**:
```haskell
managedSkyLUTComputeDescriptorPool :: VkDevice -> m VkDescriptorPool
managedCubemapComputeDescriptorPool :: VkDevice -> m VkDescriptorPool
```

**Compute pipelines**:
- One pipeline per compute shader (SkyLUTGen, RadianceGen, IrradianceGen)
- Pipeline layout with single descriptor set layout

### Phase 3: Storage Image Creation and Upload

**Module**: `src/Graphics/Haskan/Vulkan/Texture.hs` or new module

1. **Create `sky_lut` as storage image**: 
   - `VK_IMAGE_TYPE_2D`, `VK_FORMAT_R16G16B16A16_SFLOAT`
   - `VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_SAMPLED_BIT`
   - `VK_IMAGE_LAYOUT_GENERAL` for compute writes, transition to `SHADER_READ_ONLY_OPTIMAL` after dispatch

2. **Create `env_map` (radiance) as storage image**:
   - `VK_IMAGE_TYPE_2D`, 6 array layers, `VK_FORMAT_R8G8B8A8_UNORM`
   - `VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT` (for mip generation)
   - Same for `irradiance_map`

3. **Mipmap generation for radiance**:
   - After compute writes the base level (512×512), use `vkCmdBlitImage` to generate mip chain.
   - Alternative: multiple compute dispatches, one per mip level (more control but more code).

### Phase 4: Compute Dispatch Wiring

**Module**: `src/Graphics/Haskan/Engine/Render.hs` or `src/Graphics/Haskan/Engine/Render/Internal/FramePrepare.hs`

**Dispatch function**:
```haskell
dispatchSkyGeneration ::
  VkCommandBuffer ->
  VkPipeline ->
  VkPipelineLayout ->
  VkDescriptorSet ->
  IO ()
dispatchSkyGeneration cmdBuf pipeline layout descriptorSet = do
  vkCmdBindPipeline cmdBuf VK_PIPELINE_BIND_POINT_COMPUTE pipeline
  vkCmdBindDescriptorSets cmdBuf VK_PIPELINE_BIND_POINT_COMPUTE layout 0 [descriptorSet] []
  vkCmdDispatch cmdBuf 25 25 1  -- 200/8 = 25
```

**Placement in render loop**:
```haskell
renderFrameLoop ... = do
  -- Check if sky needs regeneration
  needsRegen <- liftIO $ STM.readTVarIO tvSkyNeedsRegeneration
  when needsRegen $ do
    -- Transition images to GENERAL for compute writes
    -- Dispatch Sky LUT compute
    -- Dispatch radiance cubemap compute  
    -- Dispatch irradiance cubemap compute
    -- Pipeline barrier: compute writes -> shader reads
    -- Transition images to SHADER_READ_ONLY_OPTIMAL
    liftIO $ STM.atomically $ STM.writeTVar tvSkyNeedsRegeneration False
  
  -- Continue with normal frame rendering
  ...
```

**Pipeline barrier requirements**:
- After compute dispatches: memory barrier from `SHADER_WRITE` (compute) to `SHADER_READ` (fragment)
- Image layout transition from `GENERAL` to `SHADER_READ_ONLY_OPTIMAL`
- Must happen **before** the lighting/cloud render passes that sample these images

### Phase 5: Uniform Buffer for Sky Parameters

**Module**: `src/Graphics/Haskan/Engine/Types.hs` (or new UBO struct)

Create a uniform buffer that holds `SkyParams`:
```haskell
data SkyGenUniforms = SkyGenUniforms
  { sgSunDir :: !(V3 Float),
    sgSunIntensity :: !Float,
    sgRayleigh :: !(V3 Float),
    sgMieCoeff :: !Float,
    sgMieG :: !Float,
    sgTurbidity :: !Float
  }
  deriving (Show, Generic)
```

This UBO is updated each time the sky needs regeneration (sun direction changes). The compute shader reads it via `Uniform` binding.

**Placement**: The UBO can be a small Vulkan buffer (~48 bytes) created once and updated with `vkCmdUpdateBuffer` or mapped memory before each compute dispatch.

### Phase 6: Trigger Mechanism for Dynamic Updates

**State loop** (`Engine/Update.hs`):
- Watch `gameTimeOfDay` TVar
- Compute sun direction from time (already done in `computeSunState`)
- Compare with previous sun direction
- If angle > 2°, set `tvSkyNeedsRegeneration = True`

**Render loop**:
- At start of each frame, check `tvSkyNeedsRegeneration`
- If true, execute compute dispatches (Phase 4)
- Clear flag

**Why 2° threshold**: Sun moves 360° per 24 hours = 15° per hour = 0.25° per minute. At 1× time speed, a 2° threshold triggers regeneration every ~8 minutes of game time, or ~8 seconds of real time at 60 FPS. This is visually smooth without excessive dispatch overhead.

### Phase 7: Cloud Shader — Sky LUT Sampling

**Module**: `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs`

Same as original milestone Phase 4:
1. Add `sky_lut :: Texture2D '[Binding Y, DescriptorSet 0] (RGBA16 F)` to `CloudFragmentDefs`
2. Replace `env_map` ambient lookup with `sky_lut` lookup
3. Update `CloudDescriptorSetLayout` to include `sky_lut`
4. Update `updateCloudDescriptorSets` to write `sky_lut` view

The cloud shader now samples the **dynamically regenerated** `sky_lut`, so cloud ambient updates with the sun.

### Phase 8: Lighting Shader — Procedural IBL

**Module**: `src/Graphics/Haskan/Vulkan/Shaders/Deferred/LightingProcedural.hs`

Unchanged from current implementation. The shader already:
- Samples `sky_lut` for background (binding 9)
- Samples `env_map`/`irradiance_map` for geometry IBL (bindings 4-5)

The only change is that `env_map` and `irradiance_map` now contain **procedurally generated** content instead of photo data.

### Phase 9: Setup.hs — Conditional Loading and Initial Generation

**Module**: `src/Graphics/Haskan/Engine/Render/Internal/Setup.hs`

When `proceduralSkyEnabled`:
1. Skip photo cubemap loading entirely
2. Create empty storage images for `sky_lut`, `env_map`, `irradiance_map`
3. Create compute pipelines, descriptor sets, uniform buffers
4. Write initial `SkyParams` (from `defaultSkyParams` or from `initialTimeOfDay`) to uniform buffer
5. Dispatch compute shaders for initial generation
6. Wait for completion (pipeline barrier)
7. Transition images to `SHADER_READ_ONLY_OPTIMAL`
8. Return `IBLTextures` with the generated views

### Phase 10: Build and Test

1. `cabal build exe:haskan2`
2. `cabal run exe:haskan2 -- --compile-shaders`
3. Test startup: `cabal run exe:haskan2 -- --procedural-sky --cloud-test`
4. Verify no photo loading in logs
5. Test day-night cycle: enable `--day-night`, observe sky color changes over time
6. Test without flag: `cabal run exe:haskan2 -- --cloud-test --env-dir env1` — loads photo cubemap
7. Verify no validation errors from compute dispatch

---

## Decision Record: GPU Compute vs CPU Generation

**Decision**: Use GPU compute shaders for Sky LUT and cubemap generation. Reject CPU-side generation.

**Rationale**:

1. **Performance**: CPU generation of irradiance cubemap alone costs ~63ms (Monte Carlo at 64×64×6 with 256 samples). GPU compute parallelizes this to ~0.5ms. Sky LUT is <0.1ms on GPU vs ~1ms on CPU.

2. **Dynamic updates**: The entire motivation for procedural sky is day-night cycling. CPU generation at 63ms per sun movement is unacceptable (would hitch the frame). GPU compute at <2ms total is imperceptible.

3. **Existing infrastructure**: The engine already has:
   - FIR compute shaders (`Cull.hs` with `EntryPoint '[LocalSize 64 1 1] Compute`)
   - Compute pipeline creation (`ComputePipeline.hs`)
   - Compute dispatch in render loop (cull shader dispatch in `Render.hs`)
   - Storage image writes (`StorageImage` type, `imageWrite` operation)
   
   Adding sky generation compute shaders follows the exact same pattern.

4. **Memory bandwidth**: GPU compute writes directly to VRAM. CPU generation requires:
   - Allocate CPU buffers (~50MB for cubemaps)
   - Fill buffers on CPU
   - Copy via staging buffer to GPU
   - This is slower and more complex than a single compute dispatch.

**Consequences**:
- Need to write FIR compute shaders (new skill, but patterned after existing cull shader)
- Need to manage storage image layout transitions (GENERAL for compute, SHADER_READ_ONLY for graphics)
- Need pipeline barriers between compute writes and graphics reads
- Day-night cycle with procedural sky is now **fully dynamic** — sky updates smoothly as sun moves

---

## FIR Limitations and Mitigations

### Limitation 1: FIR Loop Support

**Question**: Does FIR support `for` loops in compute shaders?

**Investigation needed**: Check if FIR has a `loop` or `while` construct. The cull shader uses `if` but no loops. If loops are missing:

**Mitigation for irradiance**: 
- Option A: Unroll a small number of samples (e.g., 16) manually. Quality may be acceptable at 64×64.
- Option B: Use CPU for irradiance only (6ms with 64 samples, still acceptable since it's rare — only when sun changes).
- Option C: Generate irradiance by blurring the radiance cubemap with `vkCmdBlitImage` (approximate but fast).

**Mitigation for Sky LUT and radiance**: No loops needed. Direct evaluation per invocation. No issue.

### Limitation 2: FIR Cube Storage Images

**Question**: Does FIR `StorageImage` support cube array layers?

**Investigation needed**: Check FIR source for `StorageImage` type constructors. If cube storage images are not supported:

**Mitigation**: Generate cubemap faces as separate 2D storage images, then copy/alias them into a cube image after compute. Or use a single 2D array image (6 layers) and treat it as cubemap via manual direction mapping in the sampling shader.

**Likely resolution**: SPIR-V supports `OpTypeImage` with `Dim=Cube` and `Sampled=2` (storage image). FIR likely supports this via `StorageImage` with appropriate dimension type parameter.

### Limitation 3: FIR Math Functions

**Question**: Does FIR support `sqrt`, `sin`, `cos`, `dot`, `normalize`, `exp`?

**Investigation needed**: Check FIR's `Math.Linear` module for available intrinsics.

**Expected**: Yes — these are basic GLSL operations that FIR must support for any useful shader.

---

## Files to Create/Modify

### New Files
| File | Purpose |
|------|---------|
| `src/Graphics/Haskan/Vulkan/Shaders/Compute/SkyLUTGen.hs` | FIR compute shader for Sky LUT generation |
| `src/Graphics/Haskan/Vulkan/Shaders/Compute/CubemapGen.hs` | FIR compute shader for radiance/irradiance cubemap generation |

### Modified Files
| File | Changes |
|------|---------|
| `src/Graphics/Haskan/Vulkan/Shaders/Sky/Procedural.hs` | Keep `evaluateSky` for reference; may inline into FIR shaders |
| `src/Graphics/Haskan/Vulkan/Texture.hs` | Add `createStorageImage`, `createStorageImageCube` |
| `src/Graphics/Haskan/Vulkan/DescriptorSetLayout.hs` | Add compute descriptor set layouts for sky LUT and cubemap gen |
| `src/Graphics/Haskan/Vulkan/DescriptorPool.hs` | Add compute descriptor pools |
| `src/Graphics/Haskan/Vulkan/DescriptorSet.hs` | Add `updateSkyLUTComputeDescriptorSets`, `updateCubemapComputeDescriptorSets` |
| `src/Graphics/Haskan/Engine/Render/Internal/Setup.hs` | Create storage images, set up compute pipelines, dispatch initial generation |
| `src/Graphics/Haskan/Engine/Render.hs` | Add compute dispatch before frame when `tvSkyNeedsRegeneration` is set |
| `src/Graphics/Haskan/Engine/Update.hs` | Add sun direction monitoring and `tvSkyNeedsRegeneration` trigger |
| `src/Graphics/Haskan/Engine/Types.hs` | Add `tvSkyNeedsRegeneration :: TVar Bool` to `GameState` |
| `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` | Add `sky_lut` binding, replace `env_map` ambient |
| `app/Main.hs` | Add mutual-exclusivity warning for `--procedural-sky` + `--env-dir` |

### No Changes Needed
| File | Reason |
|------|--------|
| `src/Graphics/Haskan/Vulkan/Shaders/Deferred/LightingProcedural.hs` | Already samples `sky_lut` and `env_map`/`irradiance_map`. CPU just needs to populate procedural content. |
| `src/Graphics/Haskan/Engine.hs` | Already passes `proceduralSkyEnabled`. |
| `src/Graphics/Haskan.hs` | Already accepts `proceduralSky` parameter. |

---

## Acceptance Criteria

- [ ] `cabal run exe:haskan2 -- --procedural-sky --cloud-test` starts without reading any file from `data/textures/cubemaps/`
- [ ] `--procedural-sky` and `--env-dir` are mutually exclusive
- [ ] Sky LUT is generated by GPU compute shader (<1ms)
- [ ] Radiance cubemap is generated by GPU compute shader (<1ms)
- [ ] Irradiance cubemap is generated (GPU preferred, CPU fallback acceptable)
- [ ] Background sky is procedural (not photo)
- [ ] Clouds sample `sky_lut` for ambient light
- [ ] Geometry has diffuse IBL from procedural irradiance cubemap
- [ ] Geometry has specular reflections from procedural radiance cubemap
- [ ] Day-night cycle updates sky colors dynamically (sun movement triggers compute dispatch)
- [ ] Without `--procedural-sky`, photo cubemaps load correctly
- [ ] All shaders compile to SPIR-V without errors
- [ ] No new validation errors
- [ ] Build passes: `cabal build exe:haskan2`

---

## Performance Budget

| Task | GPU Cost | Notes |
|------|----------|-------|
| Sky LUT compute | ~0.1ms | 625 invocations, trivial ALU |
| Radiance cubemap compute | ~0.5ms | 512²×6 = 1.5M texels, direct eval |
| Irradiance cubemap compute | ~0.5-2ms | 64²×6 × 256 samples, hemisphere integration |
| Pipeline barriers + layout transitions | ~0.1ms | Memory barriers |
| **Total per regeneration** | **~1-3ms** | Imperceptible at 60 FPS |
| Regeneration frequency | Every 2° sun change | ~8 seconds real-time at 1× speed |

---

## Follow-up Work (Post-Milestone)

1. **HDR Procedural Cubemap**: Store radiance/irradiance in RGBA16F instead of RGBA8. Requires HDR IBL pipeline in lighting pass.
2. **Atmospheric Model Upgrade**: Replace simplified Rayleigh+Mie with Hosek-Wilkie or Preetham model. Compute shader needs more ALU but still well within budget.
3. **Volumetric Clouds**: Use Sky LUT for ambient in-scattering in a full volumetric cloud renderer (beyond the current ray-marched clouds).
4. **Multi-scattering**: Add multi-scattering approximation to `evaluateSky` for more realistic twilight colors.

---

## Technical Review: Previous CPU-Generation Plan Issues (Resolved)

### Issue 1: 85ms Startup Cost
**Status**: Resolved. GPU compute reduces startup to ~1-3ms.

### Issue 2: Static Sky (No Day-Night)
**Status**: Resolved. Dynamic regeneration via compute dispatch on sun change.

### Issue 3: CPU-GPU Transfer Bottleneck
**Status**: Resolved. Compute writes directly to VRAM.

### Issue 4: Irradiance Monte Carlo Cost
**Status**: Mitigated. GPU parallelizes 6M samples across 3K invocations. If FIR lacks loops, use CPU fallback (rare trigger) or blit approximation.
