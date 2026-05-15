# Cloud Shader Analysis — v1 (pre-fix)

Date: 2026-05-15

## Symptoms
- Clouds too dark, almost black at center with brownish edges
- Each cloud small relative to whole sky, not sparse
- Wavy bands over X-axis

## Findings

### 1. CRITICAL — No tone mapping / gamma for cloud pixels
**File**: `Lighting.hs:639-646`

Geometry pixels: Reinhard → sqrt(gamma).
Cloud pixels: raw linear HDR × tint → framebuffer. No tone map, no gamma.
A linear value of 0.1 displays as 0.1 instead of ~0.316.

### 2. CRITICAL — Density `* 4.0` too high for step sizes
**File**: `Clouds.hs:315`

With step sizes ~312 units (primary) and 200 units (light march):
- Per-step optical depth: 4.0 × 312 = 1248 → exp(-1248) = 0
- Light march: 4.0 × 200 × 4 steps = 3200 → exp(-4800) = 0
- Zero light reaches any interior point → black clouds
- Even density=0.5 gives exp(-156) ≈ 0

### 3. Moderate — X-axis banding from domain warping
**File**: `Clouds.hs:304-306`

Single warpFreq (0.002) with different axis mixes creates coherent directional bands.
wy depends only on px, pz → bands parallel to Y.
Amplitude 170 = 51% of noise tile size, dominates over noise.

### 4. Moderate — Noise scale too small
**File**: `Clouds.hs:270`

noiseScale=0.003 → tile size ~333 units. Only ~2.4 tiles through 800-unit thickness.
Real renderers use ~0.0003-0.001.

### 5. Minor — Sky tint applied twice
Clouds.hs:374-379 applies tint. Lighting.hs:641 applies it again.
At night (tint 0.1): double-tinting → 0.01 = invisible.

### 6. Push Constant Layout — CORRECT
FIR uses Base layout (std430): Float align=4, V3 Float align=16/size=12, V4 Float align=16/size=16.
Cloud PC: 54 floats = 216 bytes. Lighting PC: 29 floats = 116 bytes. Both match FIR offsets.

### 7. Noise Generator — Match OK
Generator produces RGBA8 [0,1] normalized noise matching shader channel layout.

## Priority Fix Order
1. Remove `* 4.0` from density
2. Add tone map + gamma for cloud pixels in Lighting.hs
3. Fix double-tinting
4. Reduce noiseScale to ~0.0008
5. Fix domain warping (multiple frequencies, lower amplitude)
