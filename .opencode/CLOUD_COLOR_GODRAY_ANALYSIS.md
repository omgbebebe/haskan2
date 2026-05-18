# Deep Analysis: God Ray Feasibility & Dawn/Dusk Color Math

> Date: 2026-05-19
> Status: Math audit complete — root causes identified, fixes designed

---

## 1. God Rays: Feasible With Current Architecture?

### Short Answer: Yes, but requires a dedicated render pass. The inline-in-lighting-pass approach is fundamentally wrong.

### Current State

God rays are **disabled** (`godRayR = godRayG = godRayB = 0.0` in `LightingProcedural.hs:352-354`).

The previous 3-sample inline approach:
```haskell
sampleX1 = clamp (uvX + toSunX * 0.25) 0.0 1.0
sampleX2 = clamp (uvX + toSunX * 0.5)  0.0 1.0
sampleX3 = clamp (uvX + toSunX * 0.75) 0.0 1.0
```
was not a god ray at all — it was a 3-point occlusion probe. This cannot produce crepuscular rays.

### Why Inline God Rays Cannot Work

**Architectural mismatch:** God rays are a **post-processing effect** on an occlusion mask, not a per-pixel lighting computation. They require:

1. **Occlusion mask**: Binary-ish texture showing where clouds block the sun (derivable from `cloud_result.w` = cloudOpacity)
2. **Radial blur**: 60–80 samples radiating from screen-space sun position with exponential decay
3. **Separate compositing**: `finalSky += godRays * sunColor * (1.0 - geometryMask)`

The lighting pass samples `cloud_result` at the **current pixel UV**. God rays need to sample the occlusion mask at **multiple UVs along a radial line from the sun**. These are orthogonal access patterns. Doing radial sampling inside the lighting pass would:
- Explode register pressure (60+ texture samples per pixel)
- Break the G-buffer → lighting → compositing data flow
- Make the already-complex lighting shader unmaintainable

### Proper Implementation (Feasible)

With current architecture, add a **god ray blur pass** between cloud and lighting passes:

```
Cloud Pass (half-res) → History Copy
    ↓
God Ray Pass (half-res):
  Input: cloud_result (occlusion from alpha)
  Output: god_ray_texture
  Shader: radial blur with 60 samples, decay=0.96
  Push constants: sunScreenX, sunScreenY, intensity
    ↓
Lighting Pass:
  Sample cloud_result for sky color
  Sample god_ray_texture for crepuscular contribution
  Composite: sky += god_ray * sunColor * (1 - geometryMask)
```

**Resources needed:**
- One additional `RGBA16F` half-res image
- One compute or fragment shader for radial blur
- One pipeline + render pass
- ~2 hours to implement if following existing patterns

**Reference**: leoawen implementation uses exactly this architecture: occlusion mask → radial blur → additive composite.

### Recommendation

**Defer god rays** until after the atmosphere color fix (Section 2). The architecture supports them, but they're a visual enhancement, not a bug fix. The current disabled state is correct — enabling the 3-sample probe would reintroduce ghosting.

---

## 2. Why Dawns/Dusks Are Blueish Instead of Red/Orange

### Short Answer: The analytic sky model in `Clouds.hs` applies a **global warm tint** at sunset that suppresses blue everywhere uniformly. Physically, only the area **near the sun** should be warm; the rest of the sky should be deep blue. The color temperature model is directionally invariant and uses wrong coefficient ratios.

### The Math

#### 2.1 Current Model (Clouds.hs:262-305)

```haskell
rayleighScatterR = 0.0058 * rayleighPhase * (1.0 - rayleighTrans) * 100.0
rayleighScatterG = 0.0135 * rayleighPhase * (1.0 - rayleighTrans) * 100.0
rayleighScatterB = 0.0331 * rayleighPhase * (1.0 - rayleighTrans) * 100.0

sunElev = sunDirY
warmth = clamp ((clamp sunElev (-0.1) 1.0) / 0.3) 0.0 1.0
colorTempR = 1.0
colorTempG = 0.45 + 0.55 * warmth
colorTempB = 0.2 + 0.8 * warmth

totalR = (rayleighScatterR + mieScatter + sunDisc) * colorTempR
totalG = (rayleighScatterG + mieScatter + sunDisc) * colorTempG
totalB = (rayleighScatterB + mieScatter + sunDisc) * colorTempB
```

#### 2.2 The Problem: Global Multiplicative Tint

At sunset (`sunElev ≈ 0`, `warmth = 0`):
- `colorTemp = (1.0, 0.45, 0.2)` — strong warm filter

This multiplies the **entire sky** by (1.0, 0.45, 0.2). But the scattering itself has:
- `rayleighScatterB > rayleighScatterG > rayleighScatterR` (correct for Rayleigh)

For a ray **away from the sun** at sunset (`cosGamma ≈ 0`):
- `rayleighPhase ≈ 0.06`
- `rayleighScatterR ≈ 0.035`, `G ≈ 0.081`, `B ≈ 0.198`
- After colorTemp: `R' = 0.035*1.0 = 0.035`, `G' = 0.081*0.45 = 0.036`, `B' = 0.198*0.2 = 0.040`

Result: **R ≈ G ≈ B ≈ 0.037** — gray, not deep blue.

Physically, the sky away from the sun at sunset should be **deep blue** (Rayleigh scattering of residual sunlight). The colorTemp suppresses blue so aggressively that the natural Rayleigh color dominance is neutralized.

For a ray **toward the sun** at sunset (`cosGamma ≈ 1`):
- `sunDisc = 50.0` dominates
- `colorTempR = 1.0`, so sun disc stays bright
- `colorTempG = 0.45`, `colorTempB = 0.2` — sun disc becomes orange

Result: Sun disc IS orange, but the surrounding sky is gray, not the gradual warm→blue gradient of a real sunset.

#### 2.3 Secondary Problem: Rayleigh Coefficients

The standard Rayleigh scattering coefficients for Earth's atmosphere (at sea level) are approximately:
- `βR ≈ (5.8, 13.5, 33.1) × 10⁻⁶ m⁻¹`

Current code uses:
- `(0.0058, 0.0135, 0.0331)` — these are 1000× too large!

Then multiplies by 100: effective coefficients = `(0.58, 1.35, 3.31)`.

The optical depth `rayleighOD = 0.3` combined with these huge coefficients means the atmosphere is optically thick even at zenith (`cosThetaView = 1.0`):
- `rayleighTrans = exp(-0.3 / 1.05) ≈ 0.75` at zenith

This is plausible (Earth's atmosphere has ~0.3 optical depth in blue at zenith), but the scaling is confusing and the colorTemp hack compensates for it incorrectly.

#### 2.4 Tertiary Problem: No Directional Color Variation

Real sunset sky color varies with **view angle relative to sun**:
- **Toward sun**: Long path through atmosphere → red/orange (Mie + attenuated direct)
- **90° from sun**: Medium path → yellow/green
- **Away from sun**: Short path → deep blue (Rayleigh)

Current model uses `colorTemp` based ONLY on `sunDirY` (sun elevation). It does not vary with `cosGamma` (view-sun angle). The entire sky gets the same tint.

### The Fix

Replace the global colorTemp with a **directional scattering model**:

```haskell
-- Phase-dependent color temperature
-- Near sun: warm (long path through atmosphere)
-- Away from sun: cool (Rayleigh scattering dominates)
sunViewAngle = cosGammaClamped  -- 1.0 = looking at sun, -1.0 = opposite

-- Warmth peaks near sun, falls off with angle
angularWarmth = (1.0 + sunViewAngle) * 0.5  -- [0,1] from away to toward sun
-- Elevation warmth: stronger at sunset
elevationWarmth = 1.0 - warmth  -- 1.0 at horizon, 0.0 at zenith

-- Combined: warmest when looking at sun at sunset
totalWarmth = angularWarmth * elevationWarmth

-- Color temperature varies by direction
colorTempR = 1.0
colorTempG = mix 1.0 0.55 totalWarmth  -- 1.0 at noon/away, 0.55 at sunset/sunward
colorTempB = mix 1.0 0.35 totalWarmth  -- 1.0 at noon/away, 0.35 at sunset/sunward
```

**Additional fix**: Remove the `turbidityScale = 1.2` uniform multiplier. It's unnecessary brightness boost that washes out color variation.

**Result**: 
- At sunset looking at sun: strong warmth → orange/red sun disc and surrounding glow
- At sunset looking away: `totalWarmth ≈ 0`, `colorTemp ≈ (1,1,1)` → pure Rayleigh scattering → deep blue
- At noon: `elevationWarmth ≈ 0`, `colorTemp ≈ (1,1,1)` → natural blue sky

### 2.5 Hosek-Wilkie vs. Analytic Sky

The `env_map` cubemap is generated with Hosek-Wilkie coefficients (`computeHWCoeffs 2.0 0.3 sunElevation`). This model IS directionally aware and DOES produce correct sunset colors. However:

1. The cloud pass does NOT use `env_map` for sky background — it uses the analytic model
2. The lighting pass uses `cloud_result` (containing the analytic sky) for sky pixels
3. The `env_map` is only sampled for ambient light on clouds and IBL on geometry

**Better fix**: Sample the `env_map` cubemap for sky background instead of computing analytic sky inline.

```haskell
-- In Clouds.hs, replace analytic sky with cubemap sample:
~(Vec4 envR envG envB _) <- use @(ImageTexel "env_map") NilOps dir
let skyR = envR * sunIntensity * 0.01  -- scale HW output to match HDR range
    skyG = envG * sunIntensity * 0.01
    skyB = envB * sunIntensity * 0.01
```

This would:
- Use the already-computed physically-based Hosek-Wilkie model
- Automatically get correct directional color variation
- Eliminate the broken analytic model entirely
- Reduce shader complexity

**Caveat**: The `env_map` is `RGBA16F` and contains HDR values. Need to verify scaling matches the cloud pass's HDR range. The HW model outputs radiance; the cloud pass works in arbitrary HDR units. A scale factor of ~0.01–0.05 would likely align them.

---

## 3. Summary Table

| Issue | Root Cause | Location | Fix Complexity |
|-------|-----------|----------|---------------|
| God rays missing | Disabled; inline approach architecturally wrong | `LightingProcedural.hs:352` | Medium (new render pass) |
| Sunset sky gray/blueish | Global colorTemp suppresses blue uniformly | `Clouds.hs:291-299` | Low (directional colorTemp) |
| Sunset lacks red glow | No directional warmth variation | `Clouds.hs:291-299` | Low (angularWarmth factor) |
| Analytic sky redundant | HW cubemap already computed but unused | `Clouds.hs:262-305` | Low (sample env_map instead) |

---

## 4. Recommended Fix Order

1. **Quick win**: Replace analytic sky with `env_map` cubemap sample in `Clouds.hs`
   - Delete lines 262–305 (analytic sky)
   - Add single `env_map` sample using `dir`
   - Scale by `sunIntensity * 0.01` to match HDR range
   - Expected: immediate correct sunset colors

2. **If env_map sampling has issues**: Fix directional colorTemp in `Clouds.hs`
   - Add `angularWarmth = (1.0 + cosGamma) * 0.5`
   - Modify `colorTempG/B` to mix between noon and sunset values based on `angularWarmth * elevationWarmth`
   - Remove `turbidityScale`

3. **God rays**: Implement as separate render pass
   - New shader: radial blur on cloud opacity mask
   - New half-res image for god ray output
   - Composite in lighting pass: `sky += godRay * sunColor`
   - Only visible when sun is above horizon and clouds present

---

## Files Involved

| File | Role | Lines |
|------|------|-------|
| `Clouds.hs` | Analytic sky model, color temperature | 262–305 |
| `LightingProcedural.hs` | God ray compositing (disabled) | 352–354, 656–658 |
| `RadianceGen.hs` | Hosek-Wilkie sky generation (correct model) | 111–147 |
| `DayNight.hs` | Sun state, sky tint for lighting pass | 38–52 |
| `FramePrepare.hs` | `computeSkyParams` — passes tint to shaders | 97–108 |

---

## Reference Math

### Rayleigh Scattering (Standard)
- `βR(λ) ∝ λ⁻⁴` — shorter wavelengths scatter more
- At 680nm (red): ~5.8×10⁻⁶ m⁻¹
- At 550nm (green): ~13.5×10⁻⁶ m⁻¹
- At 440nm (blue): ~33.1×10⁻⁶ m⁻¹

### Sunset Physics
- Sun near horizon → light path through atmosphere ~38× longer than at zenith
- Blue scattered out of direct path → red/orange direct light
- Scattered blue light visible AWAY from sun → deep blue sky opposite sunset
- Mie scattering (aerosols) → bright glow around sun disc

### Hosek-Wilkie Model
- Turbidity 2.0 = clear sky, minimal aerosols
- Coefficients precomputed for RGB channels
- Naturally produces correct directional color variation
- See `RadianceGen.hs:111-147` for implementation
