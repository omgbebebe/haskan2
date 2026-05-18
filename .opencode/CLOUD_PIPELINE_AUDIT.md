# Cloud Pipeline Audit Report

> Systematic audit of Clouds.hs, Deferred.hs, DescriptorSet.hs, DescriptorPool.hs,
> DeferredResources.hs, LightingProcedural.hs, Setup.hs, Engine/Render.hs.
> Cross-referenced with leoawen/volumetric_cloud_atmosphere_scattering math.

---

## 0. BLACK SCREEN — Root Cause

### P0-CRITICAL: Descriptor Pool Undersized (`DescriptorPool.hs:124`)

```haskell
samplerPoolSize =
  Vulkan.createVk
    ( set @"type" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
        &* set @"descriptorCount" (fromIntegral (numSets * 4))  -- ← BUG: should be * 5
    )
```

The cloud descriptor set has **5 combined image sampler bindings** (env_map=0, cloud_noise=1, cloud_history=2, blue_noise=3, weather_map=5). The pool allocates only `numSets * 4` sampler descriptors.

When `vkUpdateDescriptorSets` writes binding 5 (weather_map), it exceeds the pool allocation. Vulkan validation may report this, but without validation layers, the result is **undefined behavior**: either the write silently fails (binding 5 stays uninitialized → shader reads garbage texture → black/undefined output), or `vkAllocateDescriptorSets` fails earlier.

**This alone can cause a black screen.** Fix: change `numSets * 4` to `numSets * 5`.

---

## 1. Vulkan Data Padding

### CloudFrameData UBO — CORRECT

FIR Extended layout (std140-like) for the struct. Byte-by-byte verification:

| FIR Offset | CPU Offset | Field | Status |
|-----------|-----------|-------|--------|
| 0 | 0 | cameraX | ✓ |
| 4 | 4 | cameraY | ✓ |
| 8 | 8 | cameraZ | ✓ |
| 16 | 16 | ray0 (V3) | ✓ (4-byte pad at 12) |
| 32 | 32 | ray1 (V3) | ✓ (4-byte pad at 28) |
| 48 | 48 | ray2 (V3) | ✓ (4-byte pad at 44) |
| 64 | 64 | sunDir (V3) | ✓ (4-byte pad at 60) |
| 76 | 76 | cloudHeight | ✓ |
| 80 | 80 | time | ✓ |
| 84 | 84 | blendFactor | ✓ |
| 96 | 96 | prevViewProj0 (V4) | ✓ (8-byte pad at 88-95) |
| 112 | 112 | prevViewProj1 (V4) | ✓ |
| 128 | 128 | prevViewProj2 (V4) | ✓ |
| 144 | 144 | prevViewProj3 (V4) | ✓ |
| 160 | 160 | windDirX | ✓ |
| 164 | 164 | windDirZ | ✓ |
| 168 | 168 | prevTime | ✓ |
| 172 | 172 | cloudCoverage | ✓ |
| 176 | 176 | cloudDetail | ✓ |
| 180 | 180 | cloudAbsorption | ✓ |
| 184 | 184 | weatherCoverageScale | ✓ |
| 188 | 188 | weatherTypeBias | ✓ |
| 192 | 192 | stormIntensity | ✓ |
| 196 | 196 | weatherAnimSpeed | ✓ |
| 200 | 200 | frameIndex | ✓ |

FIR struct total: 204 bytes, rounded up to 208 (Extended alignment rounds to 16).
CPU list: 53 floats = 212 bytes. **4-byte overrun** past the UBO boundary. Harmless if the buffer is ≥208 bytes (typically allocated at 256 due to minUBOAlignment). But should be cleaned up to 52 floats.

### Lighting Push Constants — NOT AUDITED (separate concern, no changes reported)

---

## 2. Shader Math Audit (vs. leoawen reference)

### 2a. Density Composition — HASKAN2 IS WRONG

**Haskan2** (`Clouds.hs:439-440`):
```glsl
detailFBM = ng * 0.625 + nb * 0.25 + na * 0.125
shapedNoise = mix nr detailFBM effectiveDetail  -- ← WRONG
```

`mix(base, detail, t) = base*(1-t) + detail*t`. When `effectiveDetail = 1.0`, this **replaces** the base shape entirely with detail noise. Detail noise (Worley FBM from G/B/A) is high-frequency erosion — it looks like a cellular pattern, not cloud macro-structure. Setting `shapedNoise = detailFBM` at full detail destroys the Perlin-Worley base shape.

**Leoawen**:
```glsl
float highFreqFBM = detailR * 0.625 + detailG * 0.25 + detailB * 0.125;
density = remap(density, erosionPattern * currentStrength, 1.0, 0.0, 1.0);
```

Leoawen uses a **separate detail texture** (32³, not from the same 256³). The detail is applied as **remap/erosion** — it can only reduce density, never increase it. The base shape is always preserved.

**Fix**: Replace `mix` with subtractive erosion:
```glsl
shapedNoise = max(0, nr - detailFBM * effectiveDetail)
```

Or better, match leoawen's `remap`:
```glsl
shapedNoise = clamp((nr - (1.0 - (1.0 - detailFBM * effectiveDetail))) / (detailFBM * effectiveDetail), 0.0, 1.0)
```

### 2b. Height Profile — DIFFERENT BUT VALID

**Haskan2** (`Clouds.hs:435-437`):
```glsl
heightProfile = (hPct ** baseCurve) * exp(-hPct * topDecay)
```
Single parametric curve. `baseCurve` controls bottom taper (0.4–0.8 by cloud type), `topDecay` controls top falloff (2.0–4.0).

**Leoawen**: 4-layer with `pow(smoothstep(...), curve) * (1-smoothstep(...)) * fade_in * fade_out`.

Both approaches produce a hump-shaped profile. Haskan2's is simpler and valid. No bug here.

### 2c. Smart Remap — HASKAN2 USES `smoothstep` INSTEAD OF `remap`

**Haskan2** (`Clouds.hs:442-444`):
```glsl
remappedNoise = if combinedCoverage > 0.001
                  then smoothstep (1.0 - combinedCoverage) 1.0 shapedNoise
                  else 0.0
```

**Leoawen**:
```glsl
density = remap(baseDensity, 1.0 - dynamicCoverage, 1.0, 0.0, 1.0)
// where remap(value, originalMin, originalMax, newMin, newMax)
// = (value - originalMin) / (originalMax - originalMin)
```

Haskan2 uses `smoothstep` which applies a **sigmoid curve** to the transition. `smoothstep(edge0, edge1, x)` gives a smooth S-curve, NOT a linear remap. This makes the coverage control non-linear — small coverage changes near 0 or 1 are compressed, while mid-range changes are amplified. This doesn't match the Decima/Hillaire "smart remap" technique.

The standard smart remap is:
```
remapped = clamp((noise - (1 - coverage)) / coverage, 0, 1)
```
This is a **linear** remap that makes coverage an exact dial (0 = no cloud, 1 = fully filled). `smoothstep` breaks this property.

**Impact**: Coverage slider doesn't produce predictable results. Clouds appear at different coverage values than expected.

### 2d. Light March — HASKAN2 USES SINGLE SAMPLE (GOOD)

**Haskan2** (`Clouds.hs:461-494`):
Single light sample at midpoint of light path. Approximates integral with `finalLightDensity = ld * lightStepCount * lightStepSize`.

**Leoawen**: Also single shadow sample (`shadowPos = pos + sunDir * shadowOffset`).

Both use the same approach. Haskan2's approximation `ld * count * stepSize` assumes constant density along the light path, which is reasonable for a single sample.

### 2e. Multi-Scatter — HASKAN2 HAS IT, LEOWEN DOESN'T

**Haskan2** (`Clouds.hs:497-500`):
```glsl
ms0 = exp(-d * 1.0)
ms1 = exp(-d * 0.25) * 0.5
ms2 = exp(-d * 0.05) * 0.25
lightT_d = ms0 + ms1 + ms2
```

**Leoawen**: Single `exp(-d * absorption)` (Beer-Lambert only).

Haskan2 is more physically accurate here. Good.

### 2f. Phase Function — BOTH DUAL-LOBE, DIFFERENT PARAMS

**Haskan2**: `0.7 * HG(0.6) + 0.3 * HG(-0.3)` — strong forward + moderate backward
**Leoawen**: `mix(HG(0.6), HG(-0.2), 0.5)` — even blend forward + backward

Both valid. Haskan2's is slightly more forward-biased.

### 2g. Powder Effect — BOTH IMPLEMENTED

**Haskan2** (`Clouds.hs:502-503`):
```glsl
powderTerm = 1.0 - exp(-density * 2.0)
powderBoost = mix 1.0 (powderTerm * 2.0 + 1.0) 0.3
```

**Leoawen**:
```glsl
powderTerm = 1.0 - exp(-shadowDens * uPowderScale * 2.0)
illumination = beerLaw * mix(1.0, powderTerm * 2.0 + 1.0, uPowderIntensity)
```

Haskell uses `density` (current sample density), leoawen uses `shadowDens` (light sample density). Leoawen's is more correct — powder effect should be based on the light-path density, not the view-path density. Thin clouds viewed edge-on have high view density but low light density. Using view density would incorrectly brighten these.

### 2h. Weather Map UV — HASKAN2 USES SPHERICAL (GOOD)

**Haskan2** (`Clouds.hs:421-424`):
```glsl
longitude = atan2 pz px / (2.0 * pi)
latitude = curvedY / 2000.0
weatherUV = Vec2 (longitude - offsetX) ((latitude + horizDist * weatherScale) - offsetZ)
```

**Issue**: `latitude = curvedY / 2000.0` normalizes by cloud height, but the V component also adds `horizDist * weatherScale` which mixes planar and spherical coordinates. This hybrid UV produces an uneven projection.

**Leoawen**: Uses spherical projection with `atan(z,x)` and `asin(y)`.

### 2i. Ambient from Cubemap — HASKAN2 SAMPLES EVERY FRAME

**Haskan2** (`Clouds.hs:448-449`):
```glsl
~(Vec4 zenithR zenithG zenithB _) <- use @(ImageTexel "env_map") NilOps (Vec3 0 1 0)
~(Vec4 nadirR nadirG nadirB _) <- use @(ImageTexel "env_map") NilOps (Vec3 0 (-1) 0)
```

Two cubemap samples **per primary step** (200 steps × 2 samples = 400 cubemap lookups per pixel). These sample the zenith and nadir directions. Since the direction is constant `(0,1,0)` and `(0,-1,0)`, the result never changes within a frame. These should be computed **once** outside the loop.

**Leoawen**: Ambient is hardcoded gradients (no texture lookups in the loop).

**Performance impact**: 400 unnecessary cubemap samples per pixel. Significant.

---

## 3. Performance Issues

### 3a. 200 Primary Steps with Single Light Sample (MODERATE)

Single light sample per primary step = 2 texture lookups per step (primary noise + light noise). At 200 steps, that's 400 3D texture lookups + 400 cubemap lookups (ambient) = 800 texture lookups per pixel.

At half-res (960×540): ~415 million texture lookups per frame. This is expensive but not catastrophic for an RTX 4090.

The previous diagnostic report's claim of "400-800 light march steps per pixel" is no longer valid — the light march was moved outside the loop (now a single sample). However, the ambient cubemap lookups inside the loop add a similar cost.

### 3b. Ambient Cubemap Lookups Inside Loop (HIGH)

Lines 448-449 sample the env_map cubemap twice per loop iteration. These constant-direction lookups should be hoisted out of the loop. Currently:
- 200 steps × 2 cubemap samples = 400 cubemap lookups per pixel
- At half-res: ~200 million cubemap lookups per frame

**Fix**: Move zenith/nadir sampling before the loop.

### 3c. Weather Map Sample Inside Loop (MODERATE)

Line 420 samples the weather map every primary step. Weather coverage varies slowly over the cloud volume. Should be sampled once per ray (before the loop) and reused.

### 3d. No 3D Texture Mipmaps (MODERATE)

The cloud noise texture (256³ RGBA8) is loaded without mipmaps. The shader passes `LOD noiseLod` but without generated mipmaps, all lookups hit LOD 0. Distant clouds get full-resolution noise → aliasing + wasted bandwidth.

### 3e. Step Size Growth Too Slow (LOW)

`growthRate = 1.01` — after 200 steps: `30 * 1.01^200 = 30 * 7.3 = 219`. Max step size is 300. After 200 steps, the total distance covered is ~30 * (1.01^200 - 1) / (1.01 - 1) ≈ 30 * 630 ≈ 18,900 units. But `totalRayLength` is capped at 5000. So the ray is covered many times over, wasting steps.

**Fix**: Increase growth rate to 1.02–1.03, or reduce max steps to 64–96.

---

## 4. Hacks, Workarounds, and Placeholders

### 4a. FIR `if-then-else` → `step()` Workaround (EVERYWHERE)

All conditionals in the shader use branchless `step()` / `smoothstep()` instead of `if-then-else`. This is because FIR's `if-then-else` on `Code` types has overlapping instances (MEMORIES.md P0 issue #1).

Examples:
- `dirY_safe` (line 312): `if dirY > 0 then max 0.001 dirY else min (-0.001) dirY` — this actually uses FIR's `if`, which works for simple cases but is fragile.
- `emptySkipMult` (line 459): `if density <= 0.001 then ... else 1.0` — same pattern.
- `remappedNoise` (line 442): `if combinedCoverage > 0.001 then ... else 0.0`

These work but generate SPIR-V `OpSelect` instead of proper branching. For the density check (`density <= 0.001`), this means both branches are always evaluated, including the expensive light march. This wastes GPU time on empty space.

### 4b. Manual Matrix Multiply (lines 566-569)

```glsl
prevClipX = m00 * windWorldX + m01 * windWorldY + m02 * windWorldZ + m03 * 1.0
```

Manual mat4×vec4 multiply because FIR doesn't have a convenient matrix-vector multiply operation that matches the UBO layout. This is verbose but correct.

### 4c. Sine-Based Domain Warp (lines 400-408)

```glsl
wx = sin(py * freq + pz * freq * 0.7) * amp
```

Pure sine waves for domain warping. Creates visible parallel wavefronts at large distances. Not a hack per se, but inferior to Perlin/Worley-based warp. The warp amplitudes were increased to 500/250 (from 150/80) but the fundamental problem (regular wavefronts) remains.

### 4d. Weather Map Hybrid UV (line 424)

```glsl
weatherUV = Vec2 (longitude - offsetX) ((latitude + horizDist * weatherScale) - offsetZ)
```

Mixes spherical (longitude) with planar (horizDist * weatherScale) coordinates. This isn't proper spherical projection — it's a compromise that avoids polar singularities but produces uneven coverage.

### 4e. God Rays — 3-Sample Approximation (LightingProcedural.hs:350-373)

```glsl
godRayAccum = occ1f * 0.5 + occ2f * 0.3 + occ3f * 0.2
```

Three samples from the cloud_result texture at points between the pixel and the screen-space sun position. This is a crude approximation — not a proper radial blur. Visible as a faint glow near the sun rather than actual god rays.

### 4f. `dirY_safe` Discontinuity (line 312)

```glsl
dirY_safe = if dirY > 0.0 then max 0.001 dirY else min (-0.001) dirY
```

When `dirY` is exactly 0.0 (looking at the horizon), this creates a discontinuity: pixels with `dirY = +0.0001` get `dirY_safe = +0.001`, while `dirY = -0.0001` gets `dirY_safe = -0.001`. The slab intersection changes dramatically, causing a visible seam at the horizon.

### 4g. `norm` Function for Jitter (line 258)

```glsl
dir = jitteredRayDir ^/ (norm jitteredRayDir + 0.0001)
```

`norm` computes the L2 norm of a `Code (V3 Float)`. The `+ 0.0001` epsilon prevents division by zero but biases the normalization slightly. This is a minor workaround.

---

## 5. Summary of Issues by Severity

### P0 — Causes Black Screen

| # | Issue | File | Line |
|---|-------|------|------|
| 1 | **Descriptor pool undersized: `numSets*4` should be `numSets*5`** | DescriptorPool.hs | 124 |

### P1 — Math Errors

| # | Issue | File | Line |
|---|-------|------|------|
| 2 | `mix(base, detail, t)` replaces base at full detail — should be subtractive erosion | Clouds.hs | 440 |
| 3 | `smoothstep` remap is non-linear — should be linear `remap` | Clouds.hs | 443 |
| 4 | Powder effect uses view-density, should use light-density | Clouds.hs | 502 |

### P2 — Performance

| # | Issue | File | Line |
|---|-------|------|------|
| 5 | 400 cubemap lookups/pixel inside loop (constant directions) | Clouds.hs | 448-449 |
| 6 | Weather map sampled per-step, should be once per ray | Clouds.hs | 420 |
| 7 | No 3D texture mipmaps generated | DeferredResources.hs | 143-149 |
| 8 | Step growth too slow (1.01), too many steps (200) | Clouds.hs | 319-324 |

### P3 — Hacks/Placeholders

| # | Issue | File | Line |
|---|-------|------|------|
| 9 | FIR `if-then-else` broken → all branches always evaluated | Clouds.hs | throughout |
| 10 | Sine-based domain warp creates visible wavefronts | Clouds.hs | 400-408 |
| 11 | Hybrid weather UV (spherical + planar) | Clouds.hs | 424 |
| 12 | 3-sample god rays (not proper radial blur) | LightingProcedural.hs | 350-373 |
| 13 | `dirY_safe` discontinuity at horizon | Clouds.hs | 312 |
| 14 | CPU UBO list 53 floats vs FIR struct 52 floats (4-byte overrun) | Deferred.hs | 207-259 |
