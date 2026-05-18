# Cloud & Atmosphere Diagnostic Report

> Generated from code audit of `Clouds.hs`, `DeferredResources.hs`, `Engine/Render.hs`, `Setup.hs`, `DayNight.hs`, and noise/weather generation shaders.

---

## Issue 1: Low Framerate (45–70 FPS)

### Root Cause: Excessive Per-Pixel Work

The cloud shader performs **200 primary raymarch steps**, and **each primary step does 2–4 light-march steps**. Each light-march step samples the 3D noise texture with full domain-warp computation.

| Metric | Value |
|--------|-------|
| Primary steps | 200 max (with geometric growth) |
| Light steps per primary | 2–4 (distance-dependent) |
| Total texture lookups per pixel (worst case) | 400–800 |
| Render resolution | Half-res (960×540 @ 1080p) |
| Total lookups per frame (worst case) | ~200–400 million |

This is **1–2 orders of magnitude** more expensive than reference implementations:
- leoawen: 800 primary steps but **single light sample** (not multi-step light march)
- Guerrilla/Naughty Dog: 64–128 primary steps, 6 light steps **total** (not per primary step)

### Contributing Factors

1. **Nested light march**: The light march is inside the primary loop (`Clouds.hs:465-503`). Each of 200 primary steps spawns 2–4 light steps. This is fundamentally wrong — light march should be a **fixed small number of steps per ray** (6–8 total), not per primary step.

2. **No 3D texture mipmaps**: The cloud noise texture is loaded as `RGBA8 UNorm` 256³ but **mipmaps are never generated** (`DeferredResources.hs:143-149`). The shader passes `LOD noiseLod` to `textureLod()`, but without mipmaps, all lookups sample LOD 0. Distant clouds perform full-resolution noise sampling.

3. **Empty-space skip is weak**: Skip multiplier caps at 4× (`maxEmptySkip = 4.0`) and only triggers when density is exactly ≤ 0.001. For partially cloudy regions, this provides little benefit.

4. **Over-computed light march**: Light march recomputes full height profile, weather map, and domain warp for every sample. The weather map is re-sampled per light step even though the comment says "weather varies slowly."

### Fix

Move light march **outside** the primary loop. Accumulate light density in a separate uniform or texture. Or reduce to a **single light sample** at each primary step (like leoawen) with a precomputed transmittance LUT.

---

## Issue 2: Ghosting Depending on Camera Angle and Time of Day

### Root Cause 1: Critical Shader Bug — Uninitialized Variable

**`Clouds.hs:602`**:
```glsl
alphaDiff = abs (cloudOpacity - histA)
```

**`Clouds.hs:608`**:
```glsl
cloudOpacity = 1.0 - finalTransmittance
```

`cloudOpacity` is **defined after it is used**. In FIR's `RebindableSyntax`, `let` bindings in a `do` block compile to sequential GLSL assignments. If the code generator emits `alphaDiff` before `cloudOpacity`, the shader reads an **uninitialized value** for ghost suppression.

**Impact**: `ghostSuppress` is computed from garbage, so temporal blending is **not properly rejected** when history disagrees with current frame. This causes ghost trails on all camera movement.

### Root Cause 2: Wrong Reprojection Anchor Point

The reprojection uses `tNear` (slab entry point) as the world-space anchor:
```glsl
worldX = camX + dirX * tNear
```

This is the **front of the cloud slab**, not the actual cloud position. When the camera moves:
- The same world point has a different `tNear` (slab intersection changes)
- The reprojected UV jumps discontinuously
- History is sampled from the wrong location, creating smearing

**Fix**: Use the **average cloud hit position** or the **centroid of accumulated density** as the reprojection anchor. For empty rays, skip reprojection entirely.

### Root Cause 3: `prevViewProj` Layout Mismatch

`Engine/Render.hs:409`:
```haskell
cloudPrevViewProj = view !*! projection
```

The shader manual matrix multiply (`Clouds.hs:570-578`) expects a specific layout. The comment claims this stores transpose(P×V), but the shader code does:
```glsl
prevClipX = m00*wx + m01*wy + m02*wz + m03
```

This treats the matrix as **column-major with world as column vector**. If `cloudPrevViewProj` is stored as row-major (Haskell default), the reprojection is mathematically wrong, causing UV drift.

### Root Cause 4: `rayHitCloud` Includes Empty Slab Rays

```glsl
rayHitCloud = step 0.1 totalRayLength
```

This is `1.0` for ANY ray that intersects the cloud slab, even if the slab is empty (no cloud density). Empty-slab rays still get temporal blending, causing ghosting in clear sky regions near the cloud layer.

**Fix**: Use actual opacity: `rayHitCloud = step 0.01 cloudOpacity`.

### Root Cause 5: Wind Delta Mismatch

Primary march wind offset:
```glsl
windOffsetX = time * windSpeed * windDirX  -- speed = 0.05
```

Reprojection wind delta:
```glsl
windDeltaX = dt * windSpeed * windDirX  -- speed = 0.05, dt ~ 0.016
```

Both use `windSpeed = 0.05`, but the reprojection subtracts `dt * 0.05` while the primary march adds `time * 0.05`. Over many frames, these diverge. The reprojection tries to "un-wind" the clouds but uses the **same speed** as the forward wind, creating a double-wind effect.

---

## Issue 3: No Visible God Rays

### Status: Feature Not Implemented

God rays require a new render pass:
1. Occlusion mask (sun disc blocked by clouds/geometry)
2. Screen-space radial blur toward sun position
3. Composite onto final image

This is a **new feature**, not a bug. Estimated 2–3 weeks (see `MILESTONE_CLOUD_PRODUCTION.md` Phase 4).

---

## Issue 4: Clouds Form Straight Lines on Skydome

### Root Cause 1: Weather Map Planar Projection

```glsl
weatherUV = Vec2 (px * weatherScale - offsetX) (pz * weatherScale - offsetZ)
weatherScale = 0.00005  -- 1 wrap per 20,000 world units
```

For grazing angles (low sun, horizon view), a ray through the 800m cloud slab travels **10,000–20,000 horizontal units**. The weather pattern wraps **1–2 times** across the visible cloud layer, creating visible bands of coverage.

**Fix**: Use **spherical projection**:
```glsl
weatherU = atan(pz, px) / (2*pi)  -- longitude
weatherV = asin(clamp(py/earthRadius, -1, 1)) / pi  -- latitude
```

### Root Cause 2: Domain Warping Creates Wavefronts

The sine-based domain warp:
```glsl
wx = sin(py*freq + pz*freq*0.7) * amp
```

This is a **pure sine wave** in world space. At large distances, the wavefronts are clearly visible as parallel lines, especially on the Y-axis (`wy`). The two octaves (freq 0.0015 and 0.0042) interfere to create a moiré pattern.

**Fix**: Replace with **Worley/cellular noise-based warp** or use **3D Perlin noise** for displacement. Sine waves are too regular.

### Root Cause 3: Noise Texture Periodicity

```glsl
sx = fract((px + wx) * noiseScale - windOffsetX)
noiseScale = 0.0003
```

With `fract` wrapping on a 256³ texture, the noise repeats every `1/0.0003 = 3333` world units. A typical cloud view spans 5000–10000 units, so the pattern repeats **2–3 times** across the sky.

The domain warp is supposed to break this, but the warp amplitude (150 + 80 = 230 units) is only **7%** of the period (3333). The warp is too weak to fully disguise the tiling.

**Fix**: Increase warp amplitude to ~500–1000 units, or use a **larger noise texture** (512³), or generate **aperiodic noise** (no wrapping).

---

## Issue 5: Clouds Look Like Layered Objects

### Root Cause 1: Subtractive Detail Erosion

```glsl
shapedNoise = nr * (1.0 - effectiveDetail * (ng*0.3 + nb*0.15 + na*0.075))
```

This **subtracts** detail from the base shape. The result is a flat sheet with holes punched through it — not volumetric cloud masses. Real clouds have **3D billowing structure** where detail adds positive density (bubbles, cauliflower edges).

**Fix**: Use **additive detail** with remapping:
```glsl
detailFBM = ng*0.625 + nb*0.25 + na*0.125  -- leoawen weights
shapedNoise = nr - detailFBM * effectiveDetail  -- subtractive (current)
-- OR --
shapedNoise = mix(nr, detailFBM, effectiveDetail)  -- blending
```

### Root Cause 2: Height Profile Creates Bands

```glsl
heightProfile = bottomFunnel * topShape * baseFadeIn * topFadeOut
```

Four smoothsteps multiplied together create **density bands** at specific heights. The cloud looks like a stack of pancakes rather than an organic volume.

**Fix**: Use a **single parametric curve** for height profile:
```glsl
heightProfile = pow(h, baseCurve) * exp(-h * topDecay)
```

### Root Cause 3: No Separate Detail Texture

The reference repo uses a **dedicated 32³ RGB detail texture** with 3 Worley frequencies (2×, 4×, 8× scale). Haskan2 packs detail into the same 256³ texture's G/B/A channels, which:
1. Limits detail resolution (must share 256³ with base shape)
2. Prevents independent LOD (detail fades with same mip as base)
3. Forces all detail to be subtractive (same texture, can't add)

**Fix**: Add a separate 32³ or 64³ detail texture (3 channels of Worley at different frequencies).

### Root Cause 4: Smart Remap Creates Hard Edges

```glsl
remappedNoise = clamp((shapedNoise - (1.0 - combinedCoverage)) / combinedCoverage, 0, 1)
```

This linear remap stretches the noise range. When coverage is low (~0.3), the remap divides by 0.3, amplifying small noise differences into sharp on/off thresholds. Clouds become binary (cloud/no-cloud) instead of gradual.

**Fix**: Use smooth remap with wider transition:
```glsl
remappedNoise = smoothstep(1-coverage, 1.0, shapedNoise)
```

---

## Summary Table

| Issue | Severity | Root Cause | Fix Complexity |
|-------|----------|------------|----------------|
| Low FPS | Critical | 200× nested light march (400–800 samples/pixel) | Medium — move light march outside loop |
| Ghosting | Critical | Uninitialized `cloudOpacity` in alphaDiff + wrong reprojection anchor | Small — fix let ordering + use opacity for rayHitCloud |
| God rays | Medium | Feature not implemented | Large — new render pass |
| Straight lines | High | Planar weather UV + weak sine warp + noise tiling | Medium — spherical projection + better warp |
| Layered look | High | Subtractive detail + banded height profile + hard remap | Medium — additive detail + parametric height |

---

## Recommended Fix Order

1. **Immediate (this session)**: Fix `cloudOpacity` ordering in `Clouds.hs:602-608` and change `rayHitCloud` to use actual opacity. This alone should dramatically reduce ghosting.
2. **This week**: Move light march outside primary loop (6–8 fixed steps total, not per-step). This should double or triple FPS.
3. **Next week**: Implement spherical weather projection and stronger domain warp. Fixes straight lines.
4. **Following weeks**: Additive detail model and parametric height profile. Fixes layered look.
5. **Later**: God rays render pass (Phase 4 of milestone).
