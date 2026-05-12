# Cloud Shader Seam Analysis

## Current Implementation

File: `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Lighting.hs`, lines 173--217.

The cloud system maps sky-ray directions to a 2D noise texture via **equirectangular projection**:

```
sphereV = asin(clamp(rayDirY, -1, 1)) / pi + 0.5
rawU    = atan2(rayDirZ, rayDirX) / (2*pi) + 0.5
```

A hash-based 2D value noise with 3-octave fBm is sampled at `(cloudU, cloudV) * cloudScale`. A height mask restricts clouds to a horizon band. Animated drift shifts UVs by `sunAzimuth`.

## Root Cause of the Seam

The `atan2` function has a branch cut: its output jumps from +pi to -pi when the ray crosses the negative-X half-plane. After normalizing to `[0,1]` via `/ (2*pi) + 0.5`, this becomes a discontinuity where `rawU` wraps from ~1.0 to ~0.0.

The value noise function uses `floor`/`fract` to locate grid cells and bilinearly interpolates hashed corner values. At the seam, two adjacent texels sample noise coordinates on opposite sides of the U domain boundary. One corner gets `U ~ 0.99`, its neighbor gets `U ~ 0.01`. The bilinear blend interpolates across the full noise domain rather than across the seam, producing a visible hard edge.

The pole-blend workaround (lines 210--211):

```
poleBlend = smoothstep 0.65 0.75 sphereV
sphereU   = mix rawU 0.5 poleBlend
```

only masks the zenith singularity (where all longitudes converge). It does not address the horizontal seam at the `U = 0 / 1` boundary, which is the actual visible artifact.

## Why Equirectangular Projection Is Fundamentally Wrong Here

Any 2D noise sampled on equirectangular coordinates suffers from three problems that cannot be fixed by parameter tuning:

1. **U-seam**: The `atan2` discontinuity creates a hard boundary where the noise domain wraps incorrectly.
2. **Pole pinching**: Longitude lines converge toward the poles, causing the noise to stretch to infinite frequency in U near zenith/nadir.
3. **Non-uniform sampling**: Equal angular steps in `(theta, phi)` map to unequal solid angles on the sphere, producing visible density variation.

The pole blend trades pinching for a featureless blob. The U-seam has no fix within this approach.

## Alternative Approaches

### Option A: 3D Noise (Recommended)

Sample a 3D noise function directly using the ray direction vector as input. No UV mapping, no projection, no seam.

```
hash3(x, y, z) = fract(sin(x*127.1 + y*311.7 + z*74.7) * 43758.5453)

valueNoise3D(p) =
  trilinear interpolation of 8 hash3 corners at floor(p)..floor(p)+1

fbm3D(dir) = (noise3D(dir) + 0.5*noise3D(2*dir) + 0.25*noise3D(4*dir)) / 1.75

noiseVal = fbm3D(rayDir * cloudScale)
```

| Aspect | Detail |
|--------|--------|
| Seam | Eliminated (no angular parameterization) |
| Pole pinching | Eliminated (sampling is direction-uniform) |
| Instruction cost | ~2x per octave (8 hash lookups vs 4 for bilinear). 3 octaves = 24 hashes. Acceptable. |
| Code change | Replace `hash2`/`valueNoise`/`fbm` with 3D versions. Remove `sphereU`/`sphereV`/`rawU`/`poleBlend`. Feed `rayDir * scale` directly. |
| Height mask | Keep as-is (`sphereV` from `asin rayDirY` has no seam --- it's monotonic in Y) |
| Animation | Rotate rayDir before sampling instead of shifting UVs |

The hash function `sin(x*C)` may show axis-aligned artifacts in 3D. If visible, replace with an integer hash (e.g., H1/H2 from [Browne 2019] or the `xxhash32`-style bit-mix). This is a tuning concern, not a correctness one.

### Option B: Cube-Map Face Noise

Select one of 6 cube faces based on the dominant component of `rayDir`, project onto that face's 2D UV, and sample 2D noise per face. Blend at face edges with a wide transition band.

| Aspect | Detail |
|--------|--------|
| Seam | Eliminated (each face is locally flat) |
| Instruction cost | ~6x code paths for face selection + edge blending. More SPIR-V. |
| Complexity | High. 6 face projections, 12 edge blends, corner handling. |
| Verdict | Strictly worse than Option A for this use case. |

### Option C: Ray-Marched Volumetric Clouds

March the sky ray through a 3D density field (weather texture + procedural noise), accumulating extinction and in-scattering at each step. This is the production approach used in Horizon Zero Dawn (Decima), Unreal Engine 5 (Niagara/Volumetrics), and Unity HDRP.

| Aspect | Detail |
|--------|--------|
| Visual quality | Physically-based. Clouds have depth, self-shadowing, silver lining, anisotropic scattering. |
| Cost | 32--128 ray steps per pixel. Each step samples noise + computes density +Beer-Lambert extinction. |
| Architecture | Requires a dedicated render pass (compute or fragment). Cannot coexist in the current deferred lighting shader without exceeding the FIR/SPIR-V budget. |
| Verdict | Correct long-term goal. Not viable as a drop-in fix for the current seam. |

## Recommendation

**Implement Option A (3D noise).** It eliminates the seam with minimal code change and no architectural impact. The full scope is:

1. Replace `hash2` with `hash3` (add Z term).
2. Replace `valueNoise` (bilinear, 4 corners) with `valueNoise3D` (trilinear, 8 corners).
3. Replace `fbm` with `fbm3D` (same octave structure, 3D noise).
4. Remove `sphereU`, `rawU`, `poleBlend` lines entirely.
5. Keep `sphereV` for height mask only (it is seam-free).
6. Replace `cloudU`/`cloudV` drift with a small Y-axis rotation of the ray direction before noise sampling.

If 3D hash quality is insufficient (visible axis bands), upgrade to a bit-mix integer hash as a follow-up.
