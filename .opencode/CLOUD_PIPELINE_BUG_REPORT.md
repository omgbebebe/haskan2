# Cloud Pipeline Bug Report: Flickering & Side Pixelation

## Bugs

### Bug 1: Flickering on Forward/Backward Camera Movement

**Symptom**: Screen flickers when orbital camera moves forward/backward (height changes). Left/right movement is stable.

**Root Cause**: Two interacting issues.

#### 1a. Slab Intersector Discontinuity (`Clouds.hs:248-250`)

```haskell
dirY_safe = if dirY > 0.001
  then dirY
  else (if dirY < (-0.001) then dirY else 0.001)
```

When `dirY` passes through the `(-0.001, 0.001)` dead zone, `tToBottom` and `tToTop` swap discontinuously. For near-horizontal rays, this causes `tNear`/`tFar` to flip, changing `totalRayLength` and `stepCountF` abruptly between frames.

The orbital camera couples forward/backward motion to elevation changes. As elevation shifts, each pixel's `dirY` passes through the dead zone at slightly different rates, causing per-pixel step count discontinuity — visible as whole-screen flickering.

Left/right movement keeps elevation constant, so `dirY` per pixel is stable — no flickering.

#### 1b. Y-Axis Noise Aliasing (`Clouds.hs:323`)

```haskell
sy = fract ((py + wy) * noiseScale)  -- noiseScale = 0.0003
```

Texture repeats every `1/0.0003 = 3333` world units on Y. Domain warp `wy = wy1 + wy2` where `wy1` has amplitude `300.0` — nearly 10% of the repeat period. Camera height changes shift `py` across this highly-warped space, causing the noise pattern to jump between structurally different regions per frame.

**Fix**:

1. Replace the dead zone with a smooth transition:
   ```haskell
   dirY_safe = dirY + (0.001 - abs(dirY)) * step (abs dirY) 0.001
   ```
   Or simpler — just use a small epsilon unconditionally:
   ```haskell
   dirY_safe = if abs(dirY) < 0.001 then 0.001 else dirY
   ```

2. Reduce Y-axis domain warp amplitude. Currently `warpAmp1 = 300.0` applies equally to all axes. Either:
   - Scale it down globally to `150.0`, or
   - Add a Y-specific damping factor: `wy1 = cos(...) * warpAmp1 * 0.5`

**Effort**: 30 minutes.

---

### Bug 2: Clouds Pixelated From Sides

**Symptom**: Clouds look blocky/pixelated when viewed from the side (horizontal rays). Top and bottom views are fine.

**Root Cause**: Half-resolution render target + insufficient step count for long horizon rays.

#### 2a. Half-Resolution Cloud Pass (`DeferredResources.hs:94-97`)

```haskell
cloudExtent = createVk
  ( set @"width"  (getField @"width"  extent `div` 2)
  &* set @"height" (getField @"height" extent `div` 2)
  )
```

Clouds render at half resolution. The result is bilinearly upsampled when the lighting pass samples `cloud_result` at full-res UVs. This is fine for vertical/overhead views but introduces visible blockiness for wide horizontal cloud bands.

#### 2b. Adaptive Step Count Too Low (`Clouds.hs:257-258`)

```haskell
stepCountF = max 32.0 (min 64.0 (totalRayLength / 120.0))
adaptiveStepSize = totalRayLength / stepCountF
```

| View Direction | `totalRayLength` | `stepCountF` | Step Size | Noise UV per step |
|---|---|---|---|---|
| Straight up (`|dirY|=1`) | ~800m | 32 (clamped min) | 25m | 0.0075 |
| 45° elevation | ~1131m | 32 (clamped) | 35m | 0.0106 |
| Near horizon (`|dirY|=0.01`) | 10000m (capped) | 64 (clamped max) | **156m** | **0.047** |

Horizon rays traverse 10km with 156m steps. Each step covers `156 * 0.0003 = 0.047` UV units — coarse sampling of the noise volume. Combined with half-resolution rendering, this creates visible pixelation on side views.

Top/bottom views are fine because `totalRayLength` is short (~800m) and steps are small (25m), giving dense noise sampling.

**Fix Options** (pick one):

| Option | Change | Effect | GPU Cost |
|--------|--------|--------|----------|
| A: More steps | `max 32 (min 128 (totalRayLength / 80.0))` | Horizon: 128 steps × 78m = 10km | ~2x cloud pass cost |
| B: Shorter rays | Cap `totalRayLength` at 5000m instead of 10000m | Horizon: 64 steps × 78m = 5km | None (less work) |
| C: Full resolution | Remove `/2` in `DeferredResources.hs:95-96` | Eliminates bilinear upscaling artifact | ~4x cloud pass cost |
| A+B (recommended) | Both | Horizon: 128 steps × 39m = 5km, dense sampling | ~2x cloud pass cost |

**Effort**: 15 minutes.

---

## Parameter Compliance: Generator vs Shader

Generator (`generate_cloud_noise.py`) and shader (`Clouds.hs`) are **correctly aligned**. No parameter mismatches.

| Parameter | Generator | Shader | Status |
|-----------|-----------|--------|--------|
| Noise resolution | `SIZE = 256` (256³) | `Texture3D RGBA8 UNorm` | Match |
| R: Perlin-Worley blend | `perlin * 0.65 + worley(4³) * 0.35` | Sampled as `nr`, macro shape | Match |
| G: Worley | `worley(8³)` | Weight `0.3` in detail erosion | Match |
| B: Worley | `worley(16³)` | Weight `0.15` in detail erosion | Match |
| A: Worley | `worley(32³)` | Weight `0.075` in detail erosion | Match |
| Detail formula | `G*0.3 + B*0.15 + A*0.075` | `ng*0.3 + nb*0.15 + na*0.075` (line 330) | Match |
| Tiling | Tileable via periodic KD-tree | Tileable via `fract()` | Match |

**One stale comment**: Generator docstring (line 28) says `noiseScale = 0.0008`, but the shader uses `0.0003`. Cosmetic only — the generator doesn't use `noiseScale`.

## Files to Change

| File | Change |
|------|--------|
| `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs:248-250` | Smooth `dirY_safe` dead zone |
| `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs:271-275` | Reduce Y-axis warp amplitude |
| `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs:257-258` | Increase max step count to 128, reduce ray length cap to 5000 |
| `scripts/generate_cloud_noise.py:28` | Update stale `noiseScale` comment |

## Effort

| Task | Time |
|------|------|
| Fix dirY_safe discontinuity | 15 min |
| Reduce Y-axis warp | 15 min |
| Increase step count + cap | 15 min |
| Visual validation | 30 min |
| **Total** | **~75 min** |
