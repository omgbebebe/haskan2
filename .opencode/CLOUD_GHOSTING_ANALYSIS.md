# Deep Analysis: Cloud Ghosting, Horizon Banding & Zenith Noise

> Date: 2026-05-18 (updated after first fix round failed)
> Status: **True root cause found** — swapchain history/VP frame mismatch
> Reference: [leoawen/volumetric_cloud_atmosphere_scattering](https://github.com/leoawen/volumetric_cloud_atmosphere_scattering)

---

## Executive Summary

**Previous analysis was wrong.** Applied fixes (god ray mask, `fract()` removal, horizon epsilon increase) had no visible effect. Deep re-investigation reveals the actual root cause.

The ghosting is caused by a **temporal reprojection frame mismatch**: the `prevViewProj` matrix is always 1 frame old, but the cloud history texture is `maxFramesInFlight` (= 2) frames old. The shader reprojects current-frame positions into a screen space that doesn't match the history buffer's actual viewport, producing a displaced ghost of the previous clouds.

| # | Bug | True Root Cause | Location |
|---|-----|-----------------|----------|
| 1 | Cloud ghosting on rotation | **prevViewProj is 1-frame-old, history is N-frames-old** | `Render.hs:410-411` |
| 2 | Vertical bands at horizon | Same — wrong reprojection creates systematic column errors | Same |
| 3 | Zenith pixelated noise | Wrong reprojection → `validReproj` fails → no temporal blend → raw dither visible | Same + `Clouds.hs:578` |

All three symptoms stem from a single bug.

---

## Root Cause: Swapchain History/VP Frame Mismatch

### The Timeline

`maxFramesInFlight = 2` (`Vulkan/Render.hs:46`). Cloud resources are per-swapchain-image:

```
PassRecording.hs:174-175:
  cloudImage = drCloudImages !! fromIntegral imageIdx
  cloudHistoryImage = drCloudHistoryImages !! fromIntegral imageIdx
```

Timeline with 2 frames in flight:

```
Frame A (swapchain 0, T=0):
  - reads historyImage[0] (contains cloud from T=-2)
  - renders cloud to cloudImage[0]
  - copies cloudImage[0] → historyImage[0]
  - prevViewProj written = VP(T=0)

Frame B (swapchain 1, T=1):
  - reads historyImage[1] (contains cloud from T=-1)
  - renders cloud to cloudImage[1]
  - copies cloudImage[1] → historyImage[1]
  - prevViewProj written = VP(T=1)

Frame A (swapchain 0, T=2):
  - reads historyImage[0] (contains cloud from T=0, rendered with VP(T=0))
  - prevViewProj read = VP(T=1)   ← WRONG! Should be VP(T=0)
  - Error = 1 frame of camera movement
```

### The Code

**Render.hs:409-411** — single TVar, overwritten every frame:
```haskell
cloudPrevViewProj = view !*! projection          -- current frame's VP
prevViewProj <- STM.readTVarIO rePrevViewProj    -- reads LAST FRAME's VP
liftIO $ STM.atomically $ STM.writeTVar rePrevViewProj cloudPrevViewProj
```

Same issue with `prevTime` (Render.hs:433-434):
```haskell
prevTimeVal <- liftIO $ STM.readTVarIO rePrevTime       -- 1 frame old
liftIO $ STM.atomically $ STM.writeTVar rePrevTime elapsedSeconds
```

The wind delta `dt = max 0.0 (time - prevTime)` (Clouds.hs:548) is also wrong — it represents 1 frame of wind but should represent N frames.

### Why This Causes Ghosting

The temporal blend (Clouds.hs:592-599):
```haskell
baseBlend = 0.3 * 0.92 * distFade + 0.2 * 0.92 * (1.0 - distFade)
-- effective blend ≈ 0.18–0.28
reprojBlend = rayHitCloud * baseBlend * validReproj * brightFade * ghostSuppress
accR = reprojBlend * histR + (1.0 - reprojBlend) * cloudSkyR
```

With `dpdBlendFactor = 0.92` (PassRecording.hs:243), the effective blend is 18–28%. This means **28% of the wrongly-reprojected history** is mixed into the current frame. When the camera moves, the 1-frame VP error causes the history sample to be displaced from where the clouds actually were, creating a visible ghost.

### Why It Causes Zenith Noise

At zenith, the camera looks straight up. The 1-frame VP error produces reprojected UVs that are systematically wrong for this viewing angle. The `validReproj` check (Clouds.hs:578):
```haskell
validReproj = step 0.0 prevU * step prevU 1.0 * step 0.0 prevV * step prevV 1.0 * step 0.0 prevClipW
```

With wrong UVs, `validReproj` often fails → `reprojBlend = 0` → no temporal blending. Without temporal smoothing, the blue noise dither (Clouds.hs:335-337) is the only per-pixel variation, producing visible pixelated noise that shifts with time-of-day.

### Why It Causes Horizon Bands

At the horizon, camera rotation creates systematic vertical displacement in the wrongly-reprojected UVs. The `validReproj` check passes for some screen columns but fails for others, creating vertical bands where temporal blend switches on/off. The half-resolution history texture (960×540) amplifies this by making the transition between valid/invalid more abrupt.

---

## Matrix Arithmetic Verification (Correct)

The matrix computation itself is correct. Tracing through:

1. `view = transpose(V_cam)`, `projection = transpose(P_cam)` — transposed from `lookAt`/`perspective` row-major convention
2. `cloudPrevViewProj = view !*! projection = transpose(P_cam * V_cam)` — via identity `A^T * B^T = (B*A)^T`
3. UBO packing decomposes into columns of `(P*V)`, stored as sequential V4s
4. Shader manual multiply reconstructs `(P*V) * worldPos` correctly

The matrix is correct. The **age** of the matrix is wrong — it's from frame T-1 but should be from frame T-N.

---

## Fix

### Primary Fix: Per-Swapchain-Image VP Storage

**File**: `Engine/Render.hs`

Replace the single TVar with a per-frame-index buffer:

```haskell
-- Initialization (where rePrevViewProj is created):
-- BEFORE:
prevViewProjTVar <- STM.newTVarIO (identity :: M44 Foreign.C.CFloat)

-- AFTER:
prevViewProjTVars <- replicateM Render.maxFramesInFlight
                      (STM.newTVarIO (identity :: M44 Foreign.C.CFloat))
```

```haskell
-- Render loop (where prevViewProj is read/written):
-- BEFORE:
prevViewProj <- liftIO $ STM.readTVarIO rePrevViewProj
liftIO $ STM.atomically $ STM.writeTVar rePrevViewProj cloudPrevViewProj

-- AFTER:
let frameIdx = fromIntegral frameNumber `mod` Render.maxFramesInFlight
prevViewProj <- liftIO $ STM.readTVarIO (rePrevViewProjRing !! frameIdx)
liftIO $ STM.atomically $ STM.writeTVar (rePrevViewProjRing !! frameIdx) cloudPrevViewProj
```

Same fix for `prevTime`:

```haskell
-- BEFORE:
prevTimeVal <- liftIO $ STM.readTVarIO rePrevTime
liftIO $ STM.atomically $ STM.writeTVar rePrevTime elapsedSeconds

-- AFTER:
let frameIdx = fromIntegral frameNumber `mod` Render.maxFramesInFlight
prevTimeVal <- liftIO $ STM.readTVarIO (rePrevTimeRing !! frameIdx)
liftIO $ STM.atomically $ STM.writeTVar (rePrevTimeRing !! frameIdx) elapsedSeconds
```

**Why this works**: Frame index N reads VP from when swapchain image N was last used (N frames ago), matching the actual age of historyImage[N].

### Secondary Fix: Reduce Blend Factor

The current `dpdBlendFactor = 0.92` gives effective blend ≈ 28%. After fixing the VP mismatch, reduce to 0.3 (matching the reference):

```haskell
-- PassRecording.hs:243:
dpdBlendFactor = 0.3,  -- was 0.92
```

---

## Previous Fixes (Applied But Insufficient)

These were applied but did not resolve the ghosting because they addressed secondary issues:

1. **God ray mask** (`LightingProcedural.hs:675`): `godRayMask = if hasGeometry then 0.0 else 1.0` — correctly masks god rays from geometry, but the cloud sky itself still ghosts from temporal blend error.

2. **`fract()` removal** (`Clouds.hs:432-434`): Correct change — sampler REPEAT handles tiling. But doesn't fix the temporal blend ghosting.

3. **Horizon epsilon increase** (`Clouds.hs:312`): `dirY_safe = max 0.05` — reduces tangent-ray singularity but doesn't fix temporal reprojection error.

These fixes should remain — they're individually correct — but they don't address the primary ghosting cause.

---

## FIR Investigation Results

### ImageTexel Sampling: Confirmed Working

`ImageTexel` with `Texture2D` + `NilOps` → `OpImageSampleImplicitLod` with LINEAR filtering:

- `Texture2D` = `Properties FloatingPointCoordinates ... Sampled ...` (`FIR/Syntax/Synonyms.hs:263-267`)
- `FloatingPointCoordinates` → sampling branch (`CodeGen/Images.hs:154`)
- `NilOps` → `ImplicitLOD` → `OpImageSampleImplicitLod` (`CodeGen/Images.hs:329`)
- Combined image sampler with `VK_FILTER_LINEAR` (`DescriptorSet.hs:221-226`)

**Not a sampling mode issue.** The earlier MEMORIES.md hypothesis about `OpImageFetch`/nearest-neighbor was wrong.

### `if-then-else` on Code Types: Working for Scalars

The god ray mask uses `if hasGeometry then 0.0 else 1.0` which resolves to:

- `Choose (Code Bool) '(Code Float, Code Float, Code Float)` — OVERLAPPABLE instance
- `Chooser Code Float Code Float PureChoice` — scalar select
- Generates `OpSelect` in SPIR-V — branchless, correct

The MEMORIES.md note about "broken if-then-else" applies to **vector types** (V3, V4) where `canUseSelection` may fail. Scalar `if` works correctly.

### FIR `LOD` Operand: Working

`use @(ImageTexel "cloud_noise") (LOD noiseLod NilOps)` generates `OpImageSampleExplicitLod` with the LOD as an image operand. This is correct SPIR-V.

---

## Validation Criteria

After the per-frame-index VP fix:

- [ ] No gray ghost overlay during camera rotation (sky or geometry)
- [ ] No vertical banding at the horizon
- [ ] Cloud structures visible at zenith with temporal smoothing
- [ ] No pixelated noise at zenith
- [ ] Smooth temporal convergence (no flickering)
- [ ] Ghost suppression (alpha-diff) triggers less frequently
- [ ] God rays masked to sky-only (keep existing fix)
