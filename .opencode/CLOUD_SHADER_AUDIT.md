# Cloud Shader Audit Report

Date: 2026-05-14
References:
- [Frostnova (CIS5650)](https://github.com/YueZhang1027/CIS5650-Final-Project-Frostnova) — Nubis-based VDB clouds (C++, Vulkan)
- [Sakmary CTU Thesis 2022](https://dcgi.fel.cvut.cz/wp-content/wpallimport-dist/theses/pdf/theses-2022-sakmamat-thesis.pdf) — Hillaire atmosphere + Schneider procedural clouds (C++, Vulkan)

## Technique Comparison

| Aspect | Haskan2 | Frostnova | Sakmary Thesis |
|--------|---------|-----------|---------------|
| **Atmosphere** | Static HDRI cubemap + rotation | Physical sky (Preetham) | Hillaire 2020 LUT-based (Transmittance + Multiscattering + SkyView + AerialPerspective) |
| **Cloud density source** | 3D Worley noise RGBA (128³) | VDB voxel grids + 3D noise | Two 3D Worley textures (256³ base + 128³ detail), 4-channel each |
| **Cloud geometry** | Flat layer at `cloudHeight` with thickness 800 | Atmosphere shell (sphere intersect) | Sphere-intersected atmosphere shell (planet surface + cloud bottom/top) |
| **Primary ray march** | 6 uniform steps, unrolled | Adaptive (SDF-guided + sqrt(distance)) | Linear with `iter+0.3` offset for better exponential integration |
| **Light march** | 1 sample toward sun | 6-sample cone + VDB light grid | Small secondary ray march toward sun |
| **Phase function** | Dual-lobe HG (0.6, -0.3) | Dual-lobe HG + silver lining | Double HG (Mie, equation 2.28) |
| **Transmittance** | Beer-Lambert `exp(-d*5)` + secondary `0.7*exp(-d*0.1)` | Beer-Lambert + powder `max(primary, secondary)` | Beer-Lambert + Powder effect `P = 1 - exp(-2τ)`, combined with atmosphere transmittance LUT |
| **Density** | `R*A - erosion(G,B)*0.8 - threshold` × height × 4.0 | Profile from VDB × erosion from noise | Base texture (high-res Worley) - detail texture weighted by inverse base |
| **Temporal** | Blend with history buffer (push constant `blendFactor`) | Temporal upscaling (near/far split) | N/A |
| **Aerial perspective** | None | None | Pre-computed 3D LUT applied as post-pass |
| **Output** | RGBA16F intermediate → lighting pass composites | Compute → tone.frag | HDR backbuffer with cloud alpha → aerial perspective → tonemap |
| **Tonemapping** | Reinhard + gamma sqrt | Uncharted 2 + god rays + vignette | Adaptive luminance + Reinhard/ACES/Lottes/Uchimura |

### Key Difference: Sakmary Uses a Fundamentally Different Atmosphere Pipeline

Sakmary's thesis combines **Hillaire 2020** (precomputed atmospheric scattering LUTs) with **Schneider 2015** (procedural noise clouds). This is a **more physically grounded** approach than both Haskan2 and Frostnova:

1. **Atmosphere is ray-marched from scratch** using Transmittance, Multiscattering, SkyView, and Aerial Perspective LUTs — not a static cubemap.
2. **Cloud lighting includes atmosphere transmittance toward the sun** — sampled from the Transmittance LUT. This gives physically correct coloring (red clouds at sunset, etc.).
3. **Aerial perspective is applied on top of everything** including clouds, giving distance-based atmospheric haze.
4. **Powder effect** `P = 1 - exp(-2τ)` is explicitly modeled for cloud internal scattering — both Haskan2 and Frostnova use simplified approximations of this.

### Key Difference: Frostnova Uses VDB Modeling Data

Frostnova's unique contribution is using OpenVDB voxel grids (Nubis3 style) for cloud shape:
- NVDF textures store dimensional profile, detail type, density scale, and SDF
- Light voxel grid (256×256×32) pre-computes sun-density for O(1) light lookup
- Near/far temporal upscaling split at 500m threshold

This produces more realistic, art-directable cloud shapes than procedural noise alone.

### Key Difference: Haskan2 Is Simplified Procedural

Haskan2's approach is the simplest of the three:
- No atmosphere LUTs (uses static HDRI cubemap)
- No VDB modeling (procedural noise only)
- No sphere intersection (flat cloud layer)
- No powder effect
- No aerial perspective
- Single-sample light march

The cloud rendering equation is the same core algorithm (ray march + Beer-Lambert + HG phase), but with fewer samples and no physical atmosphere coupling.

## 1. CRITICAL: Push Constant Layout Mismatch

### The Bug

The cloud pass and lighting pass share a push constant packing in `Render/Deferred.hs`, but their FIR structs are **completely different**.

**CloudPushConstant** (`Clouds.hs:28-44`) — 15 fields, 23 scalars:
```
cameraX, cameraY, cameraZ, sunAzimuth    (4 Float)
ray0 (V3 Float)
ray1 (V3 Float)
ray2 (V3 Float)
skyTintR, skyTintG, skyTintB, iblIntensity (4 Float)
sunDir (V3 Float)
cloudHeight, time, blendFactor            (3 Float)
```

**CameraPushConstant** (`Lighting.hs:64-84`) — 18 fields, 26 scalars:
```
cameraX, cameraY, cameraZ, debugMode     (4 Float)
axisOverlay, groundPlane, sunAzimuth, lightCount (4 Float)
ray0, ray1, ray2                          (3× V3 Float)
skyTintR, skyTintG, skyTintB, iblIntensity (4 Float)
sunDir (V3 Float)
cloudHeight, time                         (2 Float)
```

**CPU sends the lighting layout to BOTH passes** (Deferred.hs:178-211 for clouds, 252-283 for lighting).

### What the cloud shader actually reads

| FIR field | Byte offset | CPU sends | What shader gets |
|-----------|-------------|-----------|------------------|
| cameraX/Y/Z | 0,4,8 | camX,Y,Z | ✓ correct |
| sunAzimuth | 12 | debugMode | **WRONG** (always ~0) |
| ray0 | 16-47 | axisOverlay, groundPlane, sunAzimuth, lightCount | **GARBAGE** |
| ray1 | 48-59 | r0x,r0y,r0z + pad | **WRONG** |
| ray2 | 64-75 | r1x,r1y,r1z + pad | **WRONG** |
| skyTintR/G/B | 76-87 | r2x,r2y,r2z | **GARBAGE** |
| iblIntensity | 88 | tintR | **WRONG** |
| sunDir | 96-107 | pad + tintG,tintB,iblInt | **GARBAGE** |
| cloudHeight | 108 | pad | **0.0** |
| time | 112 | sunDirX | **WRONG** |
| blendFactor | 116 | sunDirY | **WRONG** |

### Symptoms explained

- **Black screen**: Ray directions are garbage (axisOverlay/groundPlane values), noise coordinates go to invalid locations, density reads return 0 or negligible values → no cloud visible.
- **Blue flicker**: When camera angle changes, the garbage ray directions happen to align with a valid cubemap sample, producing a flash of blue sky color.
- **Partial clouds at certain times**: When debugMode happens to be non-zero and the garbage values partially align with valid noise texture coordinates.

### Recommended fix

**Option A (Recommended): Align CloudPushConstant with CameraPushConstant**

Add `debugMode`, `axisOverlay`, `groundPlane`, `lightCount` to `CloudPushConstant`:
```haskell
type CloudPushConstant =
  Struct
    '[ "cameraX" ':-> Float,
       "cameraY" ':-> Float,
       "cameraZ" ':-> Float,
       "debugMode" ':-> Float,        -- ADD
       "axisOverlay" ':-> Float,      -- ADD
       "groundPlane" ':-> Float,      -- ADD
       "sunAzimuth" ':-> Float,
       "lightCount" ':-> Float,       -- ADD
       "ray0" ':-> V 3 Float,
       "ray1" ':-> V 3 Float,
       "ray2" ':-> V 3 Float,
       "skyTintR" ':-> Float,
       "skyTintG" ':-> Float,
       "skyTintB" ':-> Float,
       "iblIntensity" ':-> Float,
       "sunDir" ':-> V 3 Float,
       "cloudHeight" ':-> Float,
       "time" ':-> Float,
       "blendFactor" ':-> Float
    ]
```

Then use the SAME packing for both passes. Benefits:
- One packing to maintain
- Cloud shader can reuse debug modes
- Less error-prone

The pipeline size stays 120 bytes. CPU packing stays as-is.

**Option B: Separate packing per pass**

Keep CloudPushConstant as-is (23 scalars, ~104 bytes). Write a new CPU packing for the cloud pass:
```haskell
-- std430: V3 align 16, size 12
cloudData =
  [ camX, camY, camZ, sunAzimuth                    -- 16 bytes
  , r0x, r0y, r0z, 0                                 -- 16 bytes (V3 + pad)
  , r1x, r1y, r1z, 0                                 -- 16 bytes (V3 + pad)
  , r2x, r2y, r2z, tintR                             -- 16 bytes (V3 + scalar)
  , tintG, tintB, iblInt, 0                           -- 16 bytes (3 scalars + pad)
  , sunDirX, sunDirY, sunDirZ, cloudHeight            -- 16 bytes (V3 + scalar)
  , time, blendFactor                                 -- 8 bytes
  ] :: [CFloat]  -- Total: 104 bytes
```

Update `cloudPushConstantRange` size to 104 bytes.

---

## 2. FIR std430 Layout Rules (verified from MEMORIES + working lighting pass)

FIR uses standard std430 rules for push constant structs:
- `Float`: alignment 4, size 4
- `V3 Float`: alignment 16, size 12
- Between consecutive `V3 Float` members: 4 bytes padding to reach 16-alignment
- Before a `V3 Float` after scalars: pad to next 16-byte boundary
- After last `V3 Float` before scalars: NO padding (scalars are 4-aligned)

This was confirmed by the working lighting pass (26 scalars in struct → 29 floats in CPU with 3 padding zeros).

---

## 3. Cloud Shader Math vs Frostnova Reference

### 3.1 Henyey-Greenstein Phase Function ✓

```haskell
-- Our implementation (Clouds.hs:240-244)
hgPhase g = (1.0 - g²) / (4π * (1.0 + g² - 2g·cosθ)^1.5)
phase = 0.7 * hgPhase(0.6) + 0.3 * hgPhase(-0.3)
```

Frostnova uses dual-lobed with silver lining effect:
```glsl
phase = max(HG(cos, g1), silverIntensity * HG(cos, g2))
// where g2 = 0.99 - silverSpread, silverIntensity=1.27, silverSpread=1.32
```

Our dual-lobe with g=0.6 (forward) and g=-0.3 (backward) is a reasonable simplification. The forward lobe creates silver lining, the backward lobe adds ambient scattering. **Coefficients are correct.**

### 3.2 Beer-Lambert Transmittance ⚠️

```haskell
-- Our implementation (Clouds.hs:264-267)
lightT d = max (exp(-d * 5.0)) (0.7 * exp(-d * 0.1))
```

Frostnova:
```glsl
primary   = exp(-density_to_sun)
secondary = exp(-density_to_sun * 0.25) * 0.7
result    = max(primary, secondary)
```

**Issue**: Our `exp(-d * 5.0)` is very aggressive. With density scaled by 4.0 (line 250), effective coefficient is ~20x raw density. This will make clouds very dark except at edges.

**Recommendation**: Reduce to `exp(-d * 1.5)` for primary, keep secondary at `exp(-d * 0.25) * 0.7`. This matches Frostnova more closely:
```haskell
lightT d = max (exp(-d * 1.5)) (0.7 * exp(-d * 0.25))
```

### 3.3 Density Computation ✓

```haskell
d = max 0 (R*A - (G*0.5 + B*0.25)*0.8 - 0.25) * heightF * 4.0
```

Noise channels: R=Perlin-Worley (macro shape), A=high-freq detail. G/B=medium/high erosion.
- `R*A` = base shape modulated by detail
- Subtraction of erosion terms is correct
- Threshold of 0.25 creates sparse coverage
- Scale of 4.0 increases contrast
- Height fade (smoothstep 0.0→0.15 bottom, 0.85→1.0 top) is correct for stratus/cumulus band

**Matches Frostnova approach**. Coefficients are reasonable.

### 3.4 Light March — Simplified ⚠️

**Our implementation**: Single sample toward sun per march step.
```haskell
ls = fract(s + sunDir * stepSize * noiseScale)  -- one sample toward sun
```

**Frostnova**: 6-sample cone march toward sun with Beer-Powder modification.

**Impact**: Missing self-shadowing depth. Clouds will look flat/uniform in lighting.
**Recommendation**: For a first pass, the single sample is acceptable. To improve, add 2-3 samples along sun direction at different depths.

### 3.5 Transmittance Accumulation ✓

```haskell
t_{i} = t_{i-1} * exp(-d_i * stepSize)    -- Beer-Lambert per step
a_{i} = a_{i-1} + s_i * t_{i-1}           -- front-to-back compositing
```

Standard front-to-back alpha compositing. **Correct.**

### 3.6 Early Termination ✓

```haskell
active = step 0.01 t_prev  -- skip if transmittance < 1%
d_eff = d * active
```

Correct early-out when cloud is fully opaque.

---

## 4. stepSize Unbounded for Near-Horizontal Rays ⚠️

```haskell
totalRayLength = cloudThickness / max 0.01 dirY  -- line 117
stepSize = totalRayLength / 6.0                   -- line 118
```

For `dirY = 0.01` (near-horizon): `totalRayLength = 80000`, `stepSize = 13333`. Noise coordinates become huge even after `fract`, producing poor-quality sampling.

The `cloudsMask = step 0.01 dirY` clips to upward rays, but the transition zone (0.01 < dirY < 0.1) has terrible quality.

**Recommendation**: Clamp `totalRayLength`:
```haskell
totalRayLength = min 10000.0 (cloudThickness / max 0.01 dirY)
```

---

## 5. Vulkan Padding Analysis

### Lighting pass (116 bytes) ✓ CORRECT

```
Float indices:  [0..28] = 29 floats
Byte layout:
  0-15:   camX/Y/Z, debugMode
  16-31:  axisOverlay, groundPlane, sunAzimuth, lightCount
  32-43:  ray0 (V3)
  44-47:  PAD
  48-59:  ray1 (V3)
  60-63:  PAD
  64-75:  ray2 (V3)
  76-79:  skyTintR
  80-83:  skyTintG
  84-87:  skyTintB
  88-91:  iblIntensity
  92-95:  PAD (align sunDir to 96)
  96-107: sunDir (V3)
  108-111: cloudHeight
  112-115: time
Total: 116 bytes ✓ matches pipeline declaration
```

### Cloud pass (120 bytes) ✗ WRONG STRUCT

The CPU sends 30 floats in the lighting layout but the cloud shader expects 23 scalars in a different field order. See Section 1.

---

## 6. Recommendations (Priority Order)

1. **Fix push constant mismatch** — This is the black screen bug. Option A recommended.
2. **Clamp stepSize** — Add `min 10000.0` to `totalRayLength`.
3. **Tune Beer-Lambert coefficients** — Reduce `exp(-d * 5.0)` to `exp(-d * 1.5)` for less aggressive attenuation.
4. **Add 2-3 light march samples** — For better self-shadowing (post-fix improvement).
5. **Update MEMORIES.md** — Document the cloud push constant fix.

---

## 7. Files to Change

| File | Change |
|------|--------|
| `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` | Add debugMode/axisOverlay/groundPlane/lightCount to CloudPushConstant (if Option A) |
| `src/Graphics/Haskan/Render/Deferred.hs` | Cloud pass uses same packing as lighting (if Option A), or write new packing (if Option B) |
| `src/Graphics/Haskan/Vulkan/DeferredResources.hs` | Update cloudPushConstantRange size if needed |
| `.opencode/MEMORIES.md` | Document fix |
