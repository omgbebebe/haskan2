# Procedural Sky Bug Report v2: Black Skydome, Banded Sun

**Date**: 2026-05-16 (after initial fixes applied)
**Symptoms**: No blue skydome (black void), sun has circular color bands, no ground/horizon color, clouds visible

---

## Root Cause #1: Scattering Coefficients Are 100× Too Small

The scattering model produces values in the range `0.0001–0.003` for a typical sky pixel. After ACES tonemapping, these become `~0.0002` — indistinguishable from black.

**Numerical trace** for `viewDir = (0,1,0)` (straight up), default params (`sunDir ≈ (0, 0.287, -0.958)`):

```
cosGamma = 0.287
cosThetaView = 1.0
rayleighPhase = 3/(16π) * (1 + 0.287²) = 0.0648
rayleighExp = exp(-0.05) = 0.951

rayleighScatterR = 0.0058 * 0.0648 * 0.951 = 0.000357
rayleighScatterG = 0.0135 * 0.0648 * 0.951 = 0.000831
rayleighScatterB = 0.0331 * 0.0648 * 0.951 = 0.00204

mieScatter = 0.021 * 0.0276 * 0.905 = 0.000523

total = (0.000880, 0.001354, 0.00256)
scaled = (0.00106, 0.00122, 0.00138)    -- after colorTemp * turbidity
ACES(0.001) ≈ 0.0002                     -- BLACK
```

**Why**: The Rayleigh coefficients `(0.0058, 0.0135, 0.0331)` are physically correct values (in 1/m at sea level for RGB wavelengths), but the model doesn't integrate over the atmospheric path length. A proper single-scatter model multiplies by the optical path integral:

```
τ(h, θ) = ∫₀ᴴ β(λ) · exp(-h/H) ds
```

For a ray at zenith angle θ through atmosphere of height H ≈ 80km with scale height H_R ≈ 8.5km, the vertical optical depth is `β * H_R ≈ 0.0331 * 8500 = 281` for blue — that's why the sky IS blue. But the current code uses `β * exp(-0.05/cosTheta)` which gives `β * ~1.0 = β`, missing the entire `H_R` scaling.

**Fix**: Multiply the extinction optical depth by a physical scale and increase the scattering to produce visible sky. Simplest fix that produces a reasonable sky:

```haskell
-- Replace the extinction-based scattering with a direct model
-- that produces visible values

-- Remove the exp() extinction terms entirely. Use a simplified
-- Rayleigh-only model that actually produces visible colors:

rayleighPhase = (3.0 / (16.0 * pi)) * (1.0 + cosGammaClamped * cosGammaClamped)

-- Optical depth scales the scattering to visible range.
-- Typical vertical optical depth at sea level for blue ≈ 0.3
-- Use this as a direct multiplier instead of exp(-tiny/...)
skyR = rayleighR * rayleighPhase * 3.0   -- ×3 to bring into [0, ~0.3] range
skyG = rayleighG * rayleighPhase * 3.0
skyB = rayleighB * rayleighPhase * 3.0
```

Or, more physically grounded, use the Preetham analytic approximation for Rayleigh+Mie scattering. The key insight: the current coefficients need a scale factor of ~100–1000× to produce visible sky colors.

---

## Root Cause #2: Sun Disc Creates Color Bands (RGBA8 Quantization)

**File**: `RadianceGen.hs:86`
```haskell
sunDisc = if cosGammaClamped > 0.9995 then sunIntensity else 0.0
```

`sunIntensity = 50.0`. When `cosGamma > 0.9995` (within the sun disc angular radius), the output jumps from `~0.001` to `50.0`. After ACES: `ACES(50) = 50*(126+0.03)/(50*(121.5+0.59)+0.14) = 6302/6109 ≈ 1.03`, clamped to 1.0.

But the pixels *just outside* the sun disc (cosGamma = 0.9994) have value `~0.001` → ACES ≈ 0.0002. And pixels at the disc edge transition from `0.0002` to `1.0` in a single pixel step.

**The banding comes from RGBA8 quantization**. The cubemap is `RGBA8 UNorm` — only 256 levels per channel. The transition from dark sky (~1/256 = 0.004) to bright sun (1.0) happens over ~2 pixels at 512×512 resolution for the sun disc. Each quantization step creates a visible ring.

Worse, the sun disc is a hard binary threshold. The human eye perceives the sun as a smooth gradient (Mie forward scattering halo). The model should have a soft falloff:

```haskell
-- Soft sun disc with limb darkening
sunCosSize = 0.9995  -- ~0.53° half-angle (real sun is 0.27°, use larger for visibility)
sunDisc = if cosGammaClamped > sunCosSize
  then sunIntensity * smoothstep sunCosSize 1.0 cosGammaClamped
  else 0.0
```

But even with smoothstep, RGBA8 will quantize the halo into bands.

**Fix for bands**: Either (a) use `RGBA16F` for the cubemap (65536 levels, no visible banding), or (b) tonemap BEFORE writing to the cubemap so the sun disc is already in [0,1] with smooth falloff. Option (b) is already being done (ACES is applied), but the hard binary threshold prevents smooth gradients.

---

## Root Cause #3: No Ground Color

The scattering model evaluates the same formula for all directions — up, down, and sideways. With `cosThetaView = abs(dirY)`:

- Looking up (`dirY = 1.0`): `cosThetaView = 1.0`, `exp(-0.05/1.001) = 0.951` → near-maximum scattering
- Looking at horizon (`dirY = 0.0`): `cosThetaView = 0.0`, `exp(-0.05/0.001) = exp(-50) ≈ 0` → ZERO scattering
- Looking down (`dirY = -1.0`): `cosThetaView = 1.0`, `exp(-0.05/1.001) = 0.951` → same as looking up

The `abs()` fix made looking-down produce the same result as looking-up, which is physically wrong — ground should show reflected sky light, not direct scattering. But even with `abs()`, the values are still ~0.001 (too dark to see) because of Root Cause #1.

The horizon (`dirY ≈ 0`) is the worst case: `exp(-0.05/0.001) = exp(-50) ≈ 0`. **The epsilon 0.001 is too small**. The horizon should be the BRIGHTEST part of the sky (longest optical path, most scattering). The `+ 0.001` clamp prevents division by zero but creates a sharp brightness cliff at the horizon.

---

## Issue #4: Double Tonemapping

The radiance cubemap stores ACES-tonemapped values in RGBA8. The lighting shader then applies Reinhard tonemapping to these values:

```haskell
-- Clouds.hs:446 — composites sky from env_map (already tonemapped)
cloudSkyR = skyR * finalTransmittance + finalAccR

-- LightingProcedural.hs:650 — applies Reinhard AGAIN
cloudMapR = cloudSkyR / (cloudSkyR + 1.0)
-- Then gamma:
cloudGamR = sqrt cloudMapR
```

So the pipeline is: `raw HDR → ACES → RGBA8 → Reinhard → gamma`. Two tonemapping operators stacked. This compresses the dynamic range twice, making everything darker and flatter.

**Fix**: Either (a) store HDR values in the cubemap (RGBA16F, no ACES) and let the lighting shader handle all tonemapping, or (b) remove the Reinhard+gamma in the lighting shader for background pixels since the cubemap is already tonemapped and gamma-encoded.

---

## Recommended Fix Order

### Step 1: Fix scattering scale (eliminates black sky)

In all three compute shaders, increase the scattering output by replacing the extinction model:

```haskell
-- Instead of: rayleighExp = exp (-0.05 / (cosThetaView + 0.001))
-- Use a model that produces visible sky colors:

-- Rayleigh scattering intensity (physical approximation for clear sky)
-- The optical depth at zenith for Rayleigh is ~0.1-0.3 per channel
-- Scattering ∝ β * τ / cos(θ) for single scatter
let rayleighOD = 0.3  -- approximate zenith optical depth for blue channel
    mieOD = 0.1
    -- Transmittance through atmosphere
    rayleighTrans = exp (-rayleighOD / (cosThetaView + 0.01))
    mieTrans = exp (-mieOD / (cosThetaView + 0.01))
    -- In-scattered light (what we see)
    rayleighScatterR = rayleighR * rayleighPhase * (1.0 - rayleighTrans) * 20.0
    rayleighScatterG = rayleighG * rayleighPhase * (1.0 - rayleighTrans) * 20.0
    rayleighScatterB = rayleighB * rayleighPhase * (1.0 - rayleighTrans) * 20.0
    mieScatter = mieCoeff * miePhase * (1.0 - mieTrans) * 20.0
```

The `(1 - transmittance)` gives the in-scattered fraction, and `×20` brings values into the `~0.1–5.0` range that ACES maps to visible colors.

### Step 2: Fix sun disc hard edge (eliminates bands)

```haskell
sunDisc = if cosGammaClamped > 0.9999
  then sunIntensity * (cosGammaClamped - 0.9999) / 0.0006  -- soft falloff
  else 0.0
```

Or use `smoothstep`:
```haskell
sunDisc = sunIntensity * smoothstep 0.9995 1.0 cosGammaClamped
```

This creates a smooth gradient instead of a binary step, reducing banding even in RGBA8.

### Step 3: Fix horizon epsilon

Replace `+ 0.001` with `+ 0.05` (or use `max 0.05 cosThetaView`) to prevent the extinction from going to zero at the horizon. The horizon should be the brightest part of the sky.

### Step 4: Remove double tonemapping

For background pixels in LightingProcedural.hs, skip Reinhard+gamma since the cubemap is already tonemapped:
```haskell
-- Background: cubemap is already ACES-tonemapped and gamma-encoded
finalx = if hasGeometry then gamx else cloudSkyR  -- direct, no extra tonemap
```

Or better: switch cubemap to RGBA16F, remove ACES from the compute shaders, and let the lighting shader handle all tonemapping uniformly.
