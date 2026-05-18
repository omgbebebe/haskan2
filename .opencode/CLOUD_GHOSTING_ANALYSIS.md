# Deep Analysis: Cloud Rendering — Ghosting Fix, God Rays, Dawn/Dusk Color

> Date: 2026-05-19 (updated after fixes verified working)
> Status: **Ghosting fixed.** Two open issues: god ray quality, dawn/dusk blue tint.

---

## Fix History

### Fix 1: God Ray Ghost (Applied, Verified)
**Problem**: 3-sample radial probe in lighting pass added warm-tinted cloud opacity copy centered on sun screen position. Created ghost that moved with sun.

**Fix**: Replaced with dedicated god ray render pass (`GodRays.hs`, 32-sample radial blur).

**Current state**: `GodRays.hs` has a working 32-sample radial blur pass. Architecture is:
1. Cloud pass → `cloud_result` (RGBA16F: RGB=color, A=opacity)
2. God ray pass → reads `cloud_result`, radial blur → `god_ray` texture
3. Lighting pass → adds `god_ray` to sky pixels

### Fix 2: Temporal VP Mismatch (Applied, Verified)
**Problem**: `prevViewProj`/`prevTime` TVars indexed by `frameIdx = frameNumber mod maxFramesInFlight` (cycles 0,1), but cloud history images indexed by `imageIdx` (swapchain index, cycles 0..N-1). With 3 swapchain images, indices diverged.

**Fix**: 
- `rePrevViewProj`/`rePrevTime` now allocated with `numSwapchainImages` entries
- Read/write moved into `buildRecordAction` which receives `imageIdx`
- `RecordContext` carries `rcPrevViewProjTVars`/`rcPrevTimeTVars`/`rcCurrentCloudViewProj`

**Files changed**: `Render.hs`, `PassRecording.hs`

### Fix 3: Blend Factor (Applied, Verified)
`dpdBlendFactor` reduced from 0.92 → 0.3 (`PassRecording.hs:253`)

### Fix 4: Noise UV `fract()` removal (Applied, Verified)
Correct — sampler REPEAT handles tiling.

### Fix 5: Horizon epsilon (Applied, Verified)
`dirY_safe = max 0.05 dirY` — reduces tangent-ray singularity.

---

## Open Issue 1: God Ray Quality

### Current Implementation (`GodRays.hs`)

The 32-sample radial blur works but has a conceptual flaw in how it accumulates light:

```haskell
-- Lines 109-119: per sample
~(Vec4 cloudR cloudG cloudB cloudA) <- use @(ImageTexel "cloud_result") NilOps (Vec2 su sv)
let occ = cloudA
    contribR = cloudR * occ * sd * weight
```

This **accumulates cloud color × opacity** along the radial. It produces a smeared copy of cloud color centered on the sun, not proper crepuscular rays.

### What Proper God Rays Need

Crepuscular rays are bright streaks of light visible through cloud gaps, with dark shadows behind clouds. The math:

1. Start with sun brightness at the sun's screen position
2. March from each pixel toward the sun
3. At each step, measure **occlusion** (cloud opacity)
4. Light transmission: `T = exp(-Σ opacity_i)` along the path
5. Bright ray where `T` is high (gap), dark shadow where `T` is low (behind cloud)
6. Apply Mie forward scattering (phase function peaked toward sun)

### Fix for GodRays.hs

```haskell
-- Correct accumulation: measure occlusion, not cloud color
-- Start from pixel, march toward sun
-- Each sample reduces light by cloud opacity

_ <- def @"transmittance" @RW @Float 1.0
_ <- def @"accLight" @RW @Float 0.0

loop do
  -- ...sample cloud opacity at su,sv...
  let stepOcclusion = cloudA * density  -- how much light is blocked
  t <- get @"transmittance"
  let newT = t * exp(-stepOcclusion)
      -- In-scatter: light that reaches this point and scatters toward camera
      scatter = t * (1.0 - exp(-stepOcclusion)) * sd * weight
  put @"transmittance" newT
  modify @"accLight" (+ scatter)
  -- ...advance sampleU/V...
```

This gives Beer-Lambert attenuation with in-scattering — proper volumetric light.

### Answer: Can we do good god rays with current architecture?

**Yes.** The current architecture is correct:
- `cloud_result` texture already has cloud opacity in alpha
- Separate god ray pass at half resolution is the right approach
- Only the accumulation math needs correction
- Push constants for sun screen position already available

The fix is ~15 lines in `GodRays.hs`. The pipeline architecture doesn't need to change.

---

## Open Issue 2: Dawn/Dusk Only Blue, No Red/Orange Tint

### Root Cause: `skyTint` Calculation in `DayNight.hs`

The `skyTint` computed on CPU is applied as a **multiplicative tint** in the lighting pass:

```haskell
-- LightingProcedural.hs:658-660
tintedSkyR = cloudGamR * skyTintR
tintedSkyG = cloudGamG * skyTintG
tintedSkyB = cloudGamB * skyTintB
```

The problem is in `DayNight.hs:106-116`:

```haskell
skyLerp = clamp 0.0 1.0 (sin sunAngle)        -- 0 at horizon, 1 at noon
sunsetLerp = 1.0 - abs (dayProgress - 0.5) * 2.0  -- 1 at sunrise/set, 0 at noon
tempTint = lerpV3 sunsetLerp dayTint sunsetTint    -- warm at sunrise/set
skyTint = lerpV3 skyLerp nightTint tempTint         -- ← BUG HERE
```

**The bug**: `skyLerp = sin(sunAngle) ≈ 0` at sunrise/sunset. The final blend:
```
skyTint = lerpV3 0 nightTint tempTint = nightTint = V3 0.1 0.1 0.2  (dark blue!)
```

The warm `sunsetTint` is computed correctly in `tempTint`, but `skyLerp` forces the result to `nightTint` at the exact moments when sunset tint should appear.

### Numerical Trace

| Time | sunAngle | skyLerp | sunsetLerp | tempTint | **skyTint** | Expected |
|------|----------|---------|------------|----------|-------------|----------|
| 6:00 (sunrise) | 0 | 0.00 | 1.0 | (1, 0.7, 0.4) | **(0.1, 0.1, 0.2)** blue | warm orange |
| 6:30 | 0.13 | 0.13 | 0.08 | (1, 0.98, 0.95) | **(0.22, 0.22, 0.30)** blue | warm |
| 8:00 | 0.52 | 0.50 | 0.33 | (1, 0.90, 0.80) | **(0.55, 0.50, 0.50)** neutral | warm fading |
| 12:00 | 1.57 | 1.00 | 0.0 | (1, 1, 1) | **(1, 1, 1)** white | white ✓ |

The sky is **blue at dawn/dusk** because the night→day transition skips the sunset phase entirely.

### Fix: 3-Phase Sky Tint Blend

Replace the 2-step blend with a proper 3-phase transition:

```haskell
-- Phase 1: night → sunset (sun near/below horizon)
horizonPhase = clamp 0.0 1.0 ((sin sunAngle + 0.15) / 0.3)
-- Phase 2: sunset → day (sun well above horizon)  
dayPhase = clamp 0.0 1.0 ((sin sunAngle - 0.15) / 0.5)

baseTint = lerpV3 horizonPhase nightTint sunsetTint
skyTint = lerpV3 dayPhase baseTint dayTint
```

This gives:

| Time | horizonPhase | dayPhase | baseTint | **skyTint** |
|------|-------------|----------|----------|-------------|
| Night | 0.0 | 0.0 | nightTint | **nightTint** (dark blue) |
| Sunrise | 0.5 | 0.0 | 50/50 night/sunset | **sunsetTint-ish** (warm) |
| +30min | 1.0 | 0.0 | sunsetTint | **sunsetTint** (warm orange) |
| +2h | 1.0 | 0.5 | sunsetTint | **blend toward white** |
| Noon | 1.0 | 1.0 | sunsetTint | **dayTint** (white) |

### GPU Side: Cloud Shader Already Has Warm Tones

The cloud shader (`Clouds.hs:261-313`) computes its own analytic sky with directional color temperature:

```haskell
horizonFactor = 1.0 - clamp ((sunElev + 0.1) / 0.4) 0.0 1.0
sunProximity = max 0.0 (dir ^.^ sunDir)
warmth = sunProximity * horizonFactor
colorTempG = mix 1.0 0.55 warmth    -- reduce green
colorTempB = mix 1.0 0.25 warmth    -- reduce blue more
```

This correctly produces warm tones near the sun at low elevation. But these warm tones are then **killed** by the blue `skyTint` multiplier in the lighting pass.

Fixing `DayNight.hs` will let the cloud shader's warm tones through to the screen.

### The cloud shader's analytic sky also has a minor issue

The Rayleigh scattering coefficients (lines 277-279):
```haskell
rayleighScatterR = 0.0058 * rayleighPhase * (1.0 - rayleighTrans) * 100.0
rayleighScatterG = 0.0135 * rayleighPhase * (1.0 - rayleighTrans) * 100.0
rayleighScatterB = 0.0331 * rayleighPhase * (1.0 - rayleighTrans) * 100.0
```

These are Rayleigh scattering coefficients (λ⁻⁴ dependence). Blue (0.0331) >> Red (0.0058). This makes the base sky very blue. The `colorTemp` correction at lines 303-305 helps at sunset, but the blue base is overwhelming. The coefficients could be rebalanced for more visible warm tones at low sun angles, but this is a tuning issue, not a bug. The `DayNight.hs` fix is the primary solution.

---

## File Reference

| File | Lines | What |
|------|-------|------|
| `DayNight.hs:106-116` | skyTint calculation (BUG: 2-phase blend skips sunset) |
| `DayNight.hs:38-52` | defaultDayNightConfig (colors are correct, math is wrong) |
| `LightingProcedural.hs:658-660` | tintedSkyR = cloudGamR * skyTintR (multiplies blue tint over warm sky) |
| `GodRays.hs:109-119` | god ray accumulation (accumulates cloud color, should use Beer-Lambert) |
| `GodRays.hs:82-84` | direction is pixel→sun (correct for radial blur) |
| `Clouds.hs:261-313` | analytic sky with directional color temperature (correct) |
| `Render.hs:912-913` | prevViewProj/prevTime allocation (now per-swapchain-image) |
| `PassRecording.hs:170-174` | prevViewProj/prevTime read/write by imageIdx (fixed) |
