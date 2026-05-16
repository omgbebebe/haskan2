# Procedural Sky Bug Report: Dark Skydome, No Ground, No Horizon

**Date**: 2026-05-16
**Symptom**: Clouds visible but skydome is dark. No ground color below horizon. No visible horizon transition.
**Reference**: `.opencode/procedural_sky_milestone.tex`

---

## Root Cause: Below-Horizon Sky is Always Black

**File**: `src/Graphics/Haskan/Vulkan/Shaders/Compute/RadianceGen.hs:69`

```haskell
cosThetaView = max 0.0 (view @(Index 1) viewDir)
```

This clamps `cosThetaView` to `[0, 1]` — meaning any direction with a negative Y component (below the horizon) gets `cosThetaView = 0`.

Then the extinction term:

```haskell
rayleighExp = exp (-0.05 / (cosThetaView + 0.001))  -- line 72
```

When `cosThetaView = 0`: `exp(-0.05 / 0.001) = exp(-50) ≈ 1.9e-22 ≈ 0`.

**Result**: The entire sky at and below the horizon evaluates to near-zero. The scattering contribution is effectively black for ~50% of the skydome (all downward-facing cubemap texels and near-horizon texels).

**The same bug exists in all three compute shaders:**
- `RadianceGen.hs:69` — cubemap for env_map (used by cloud pass for sky background)
- `SkyLUTGen.hs` — 2D LUT (but this is dead code in the output path, see Finding #2)
- `IrradianceGen.hs` — diffuse IBL cubemap (also black below horizon)

**Fix**: Replace the hard clamp with a proper extinction model that handles negative view angles. At minimum:
```haskell
cosThetaView = view @(Index 1) viewDir  -- remove max 0.0
```
This allows `cosThetaView` to go negative (looking down), which makes `exp(-0.05 / (negative + 0.001))` approach infinity (no extinction, full scattering), which is physically wrong but at least not black. A proper fix requires an atmospheric path integral that accounts for looking through more atmosphere at oblique angles, regardless of direction.

Better fix — use absolute value for the optical depth:
```haskell
cosThetaView = abs (view @(Index 1) viewDir)
```
This treats upward and downward rays symmetrically. Not physically correct but gives a reasonable ground color.

---

## Finding #2: Sky LUT is Dead Code in the Output Path

**File**: `src/Graphics/Haskan/Vulkan/Shaders/Deferred/LightingProcedural.hs:343-346`

The sky LUT is sampled:
```haskell
let skyCosGamma = dirX * sunDirX + dirY * sunDirY + dirZ * sunDirZ
    skyU = (skyCosGamma + 1.0) * 0.5
    skyV = sqrt (max 0.0 dirY)
~(Vec4 skyR skyG skyB _) <- use @(ImageTexel "sky_lut") NilOps (Vec2 skyU skyV)
```

But `skyR/skyG/skyB` are **never used** for final output. The background path (lines 648-661):
```haskell
cloudMapR = cloudSkyR / (cloudSkyR + 1.0)     -- from cloud_result
cloudGamR = sqrt cloudMapR
tintedSkyR = cloudGamR * skyTintR
finalx = if hasGeometry then gamx else tintedSkyR  -- uses cloud_result, NOT sky_lut
```

The actual background pixel path is:
1. Cloud pass samples `env_map` (procedural radiance cubemap) → gets sky color
2. Cloud pass composites cloud accumulation over env_map color → `cloud_result`
3. Lighting pass uses `cloud_result` for all background pixels
4. Lighting pass applies Reinhard tonemap + sky tint

**The sky_lut sample exists but the result is thrown away.** The entire background comes from the cloud pass's `env_map` cubemap sample. Since the cloud pass covers the full screen, this works — but only if `env_map` has correct sky colors (which it doesn't, due to Finding #1).

---

## Finding #3: No Dynamic Sky Regeneration

**File**: `src/Graphics/Haskan/Engine/Render.hs:305-309`

```haskell
needsSkyRegen <- STM.readTVarIO reTvNeedsSkyRegen
when needsSkyRegen $ do
  -- TODO: dynamic compute dispatch would go here
  STM.atomically $ STM.writeTVar reTvNeedsSkyRegen False
```

The sky is generated once at startup via `dispatchProceduralSkyGeneration` (Setup.hs:244). The `needsSkyRegen` flag is checked every frame but the handler is a no-op. Day/night cycle changes the push constant `sunAzimuth` (which rotates the cubemap sampling direction) but does NOT regenerate the cubemap. The sky stays fixed at the initial sun position.

This is by design (documented in `MILESTONE_PROCEDURAL_SKY_COMPLETE.md` Decision Record), but it means the day/night cycle doesn't work with procedural sky.

---

## Finding #4: Cubemap Face Direction Mapping — Verify Against Vulkan Spec

**File**: `RadianceGen.hs:58-61`

```haskell
dirX = if faceIdx == 0 then 1.0 else (if faceIdx == 1 then (-1.0) else
        (if faceIdx == 4 then u else (if faceIdx == 5 then (-u) else u)))
dirY = if faceIdx == 2 then 1.0 else (if faceIdx == 3 then (-1.0) else (-v))
dirZ = if faceIdx == 4 then 1.0 else (if faceIdx == 5 then (-1.0) else
        (if faceIdx == 0 then (-u) else (if faceIdx == 1 then u else v)))
```

Vulkan cubemap layer mapping (from VK_KHR_maintenance1 / Vulkan 1.1):
| Layer | Face | Major Axis | s direction | t direction |
|-------|------|-----------|-------------|-------------|
| 0 | +X | +x | -z → +z | -y → +y |
| 1 | -X | -x | +z → -z | -y → +y |
| 2 | +Y | +y | +x → -x | +z → -z |
| 3 | -Y | -y | +x → -x | -z → +z |
| 4 | +Z | +z | +x → -x | -y → +y |
| 5 | -Z | -z | -x → +x | -y → +y |

For a cubemap texel at coordinates (s, t) where s = u*2-1 and t = v*2-1 (in [-1,1]):

Standard direction reconstruction:
```
face 0 (+X): dir = (+1, -t, s)  = (+1, 1-2v, 2u-1)
face 1 (-X): dir = (-1, -t, -s) = (-1, 1-2v, 1-2u)
face 2 (+Y): dir = (s, +1, -t)  = (2u-1, +1, 2v-1)    -- NOT matching code
face 3 (-Y): dir = (s, -1, t)   = (2u-1, -1, 1-2v)     -- NOT matching code
face 4 (+Z): dir = (-s, -t, +1) = (1-2u, 1-2v, +1)     -- NOT matching code
face 5 (-Z): dir = (s, -t, -1)  = (2u-1, 1-2v, -1)     -- NOT matching code
```

But the code uses raw `u, v` in [0, 1] without remapping to [-1, 1]:
```
face 0 (+X): dir = (+1, -v, u)     -- should be (+1, 1-2v, 2u-1)
face 1 (-X): dir = (-1, -v, u)     -- should be (-1, 1-2v, 1-2u)  -- Z SIGN WRONG
face 2 (+Y): dir = (u, +1, v)      -- should be (2u-1, +1, 2v-1)
face 3 (-Y): dir = (u, -1, v)      -- should be (2u-1, -1, 1-2v)
face 4 (+Z): dir = (u, -v, +1)     -- should be (1-2u, 1-2v, +1)
face 5 (-Z): dir = (-u, -v, -1)    -- should be (2u-1, 1-2v, -1)
```

**ISSUE 1**: The code uses `u ∈ [0,1]` and `v ∈ [0,1]` directly instead of `s = 2u-1, t = 2v-1 ∈ [-1,1]`. This means cubemap texels don't cover the full hemisphere — they only cover the positive octant. Direction vectors are biased toward the corner (+1, 0, +1) instead of the face center.

**ISSUE 2**: Face 1 (-X) has wrong Z direction. Code: `dirZ = if faceIdx == 1 then u`. Should be `1-2u` (positive to negative Z as u goes 0→1).

**ISSUE 3**: Face 4 (+Z) has `dirX = u` but should be `1-2u` (negative to positive X).

**Impact**: The cubemap has incorrect direction coverage. Some directions are never sampled, others are double-sampled. After `normalize`, the directions are valid unit vectors but don't uniformly cover the sphere. The sky will look wrong — bright spots where they shouldn't be, dark spots where there should be color.

---

## Finding #5: UBO/SkyGenUniforms Padding — OK

**File**: `src/Graphics/Haskan/Engine/Types.hs:280-319`

```haskell
data SkyGenUniforms = SkyGenUniforms
  { sgSunDirX :: !Float,      -- offset 0
    sgSunDirY :: !Float,      -- offset 4
    sgSunDirZ :: !Float,      -- offset 8
    sgSunIntensity :: !Float, -- offset 12
    sgRayleighR :: !Float,    -- offset 16
    sgRayleighG :: !Float,    -- offset 20
    sgRayleighB :: !Float,    -- offset 24
    sgMieCoeff :: !Float,     -- offset 28
    sgMieG :: !Float,         -- offset 32
    sgTurbidity :: !Float     -- offset 36
  }
```

All fields are `Float` (4-byte alignment). 10 floats = 40 bytes. std140/std430: scalar alignment = 4. Packed tightly, no padding needed. **This is correct.**

The FIR struct `SkyGenData` in the compute shaders has the same 10 scalar `Float` fields in the same order. **Match confirmed.**

**BUT**: The UBO is created with size 256 bytes (`Setup.hs` cloud frame data, line 314: `let cloudFrameDataSize = 256`). The `SkyGenUniforms` is only 40 bytes. If the buffer is only 40 bytes but declared as 256, the extra bytes are wasted but harmless. If the buffer is only 40 bytes and the GPU expects 256, there could be issues. Let me check...

Actually the SkyGenUniforms buffer is separate from the cloud frame data buffer. The compute shader UBO is created in `dispatchProceduralSkyGeneration`. Need to verify its size.

---

## Finding #6: Light SSBO Not Bound in Descriptor Sets

**File**: `src/Graphics/Haskan/Vulkan/DeferredResources.hs:308,310`

Both procedural and non-procedural paths pass `Nothing` for `mLightBuffer`:
```haskell
DescriptorSet.updateLightingProceduralDescriptorSets device ds sampler allViews Nothing (Just cloudView)
DescriptorSet.updateLightingDescriptorSets device ds sampler baseViews Nothing (Just cloudView)
```

The lighting shaders expect `lights` at binding 7 (StorageBuffer). With `Nothing`, no SSBO is bound. Vulkan spec: reading from an unbound descriptor produces undefined values (typically zero). This means **all direct PBR lighting is broken** — geometry appears lit only by IBL.

This is a pre-existing bug, not introduced by procedural sky. But it should be fixed.

---

## Finding #7: No Mipmaps on Procedural Radiance Cubemap

**File**: `src/Graphics/Haskan/Engine/Render/Internal/Setup.hs:210`

```haskell
radianceHandle <- Texture.createStorageImageCube rm physicalDevice device 512 VK_FORMAT_R8G8B8A8_UNORM ...
```

`createStorageImageCube` creates `mipLevels=1`. The lighting shader samples with LOD for specular IBL:
```haskell
-- LightingProcedural.hs:617
~(Vec4 envR envG envB _) <- use @(ImageTexel "env_map") (LOD lod NilOps) (rotateY ...)
```

But the sampler is created with `maxLod=0` (Setup.hs:202: `createSamplerWithLod device 0`), so LOD is clamped to 0. **This is consistent** — no mipmaps, no LOD sampling, all roughness levels get the same reflection. Not ideal but not broken.

---

## Summary of Fixes (Priority Order)

### P0 — Fix Below-Horizon Black Sky (Root Cause of Reported Bug)

In all three compute shaders (`RadianceGen.hs`, `SkyLUTGen.hs`, `IrradianceGen.hs`), replace:
```haskell
cosThetaView = max 0.0 (view @(Index 1) viewDir)
```
with:
```haskell
cosThetaView = abs (view @(Index 1) viewDir)
```

This gives symmetric up/down scattering. Not physically accurate (ground should show reflected/forward-scattered light differently) but eliminates the black hemisphere.

### P1 — Fix Cubemap Face Direction Mapping

In `RadianceGen.hs` and `IrradianceGen.hs`, remap UV to [-1,1]:
```haskell
s = u * 2.0 - 1.0
t = v * 2.0 - 1.0
```
Then use proper Vulkan cubemap direction formulas per face index.

### P2 — Fix or Remove Dead Sky LUT Sampling in Lighting Shader

Either wire `skyR/skyG/skyB` into the background output (for when cloud_result is absent/transparent), or remove the dead code to avoid GPU waste.

### P3 — Bind Light SSBO in Descriptor Sets

Pass the light SSBO buffer to `updateLightingProceduralDescriptorSets` and `updateLightingDescriptorSets` instead of `Nothing`.
