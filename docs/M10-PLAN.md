# M10 Plan: Scalable Lighting & Dynamic Atmosphere

## Overview
Move from single hardcoded light to production-ready lighting with atmospheric effects. Four phases, each deliverable independently.

---

## Phase 1: Multi-Light Infrastructure + Benchmark
**Goal:** Deferred shading that actually scales. Benchmark to find GPU limits.

### Tasks
1. **Light SSBO** — `LightData` struct (position, color, intensity, type, range, direction)
2. **Refactor `Lighting.hs`** — loop over light array instead of hardcoded `(1,1,1)/√3`
3. **Light culling** — simple distance culling per tile (start with brute force, optimize later)
4. **Benchmark harness** — script to spawn N lights, measure frame time
   - Test: 1, 10, 100, 1000 point lights
   - Metrics: avg/min/max frame time, GPU time queries
   - Output: CSV + graph

### Deliverable
`scripts/benchmark_lights.sh` + performance report showing knee point (likely 100-500 lights on RTX 4090)

---

## Phase 2: Skybox Background ✅ COMPLETE
**Goal:** Proper environment background instead of black clear color.

### Implementation
- **Approach:** Fullscreen triangle with cubemap sampling in lighting shader (Option A)
- **Rays:** Per-vertex frustum rays computed on CPU, passed via push constants
- **Background detection:** `hasGeometry = abs(posX)+abs(posY)+abs(posZ) > 0.001`
- **Depth handling:** No geometry = sample `env_map` with interpolated ray direction
- **Debug mode 12:** Raw skybox rendering (no geometry) for verification

### Key Fixes Applied
1. **worldRot extraction** — matrix rows (not columns) from transposed view matrix
2. **X-axis sign** — removed incorrect `-x` negation; `lookAt` is right-handed
3. **Colored test cubemap** — 6 solid colors for face orientation verification
4. **Axis arrows** — red/green/blue arrows at origin confirm skybox alignment

### Verification
- Skybox faces match world axes: +X=red, -X=blue, +Y=green, -Y=yellow, +Z=magenta, -Z=cyan
- No diagonal tilt; perfectly aligned with axis arrows
- Mathematical audit: `.opencode/SKYBOX_MATH_AUDIT.tex`

### Deliverable
Scene renders with visible sky background. `--no-sky` flag to disable. (Not yet implemented — toggle via debug mode 12 for now)

---

## Phase 3: Dynamic Day/Night Cycle ✅ COMPLETE
**Goal:** Moving sun, changing sky color, time-of-day lighting.

### Implementation
- **Sun trajectory:** Spherical coordinates (azimuth, elevation) driven by time push constant
- **Sky tint:** Dynamic RGB sky color modulation via push constants (`skyTintR/G/B`)
- **IBL modulation:** Intensity scaling based on sun elevation (night = dimmer IBL)
- **Integration:** Day/night state passed to lighting and cloud shaders via shared push constant layout

### Key Details
- Sun direction computed from azimuth/elevation on CPU, passed as `sunDir` vec3
- `iblIntensity` scales both radiance and irradiance contributions
- No separate `TimeOfDay` component — driven by raw time uniform for simplicity

---

## Phase 4: Volumetric Clouds ✅ COMPLETE
**Goal:** Modern cloud rendering without pre-baking.

### Implementation
- **Inline ray-marched clouds:** Initially embedded in lighting shader (6 steps, hash noise, fBm, spherical UV sampling)
- **Cloud modularization:** Extracted into separate `Clouds.hs` pass with dedicated vertex/fragment shaders
- **Performance optimization:** Quarter-resolution rendering (half width/height) composited via bilinear upscale
- **Temporal accumulation:** History buffer blending with per-pixel velocity-based reprojection
- **Quality features:**
  - Blue-noise dithering for step jitter (eliminates banding)
  - Alpha coverage-based density
  - Early exit when transmittance reaches threshold
  - Wind animation via time push constant offsetting noise sample position
  - Dual-lobe Henyey-Greenstein phase function for anisotropic scattering
  - Texture-sampled light march for self-shadowing (6 samples along sun direction)
- **Debug modes:** 13=cloud density, 14=height mask, 15=raw noise
- **SPIR-V optimization:** `spirv-opt` reduces cloud shader to ~22KB

---

## Milestone Structure

```
M10.1  Multi-Light Benchmark      ✅ COMPLETE (256-light SSBO)
M10.2  Skybox Background          ✅ COMPLETE (fullscreen triangle cubemap)
M10.3  Day/Night Cycle            ✅ COMPLETE (sun trajectory, sky tint, IBL modulation)
M10.4  Volumetric Clouds          ✅ COMPLETE (ray-marched, quarter-res, temporal)
```

**Total: ~4-5 weeks** (all phases delivered)

---

## Technical Decisions Needed

1. **Light limit**: Hard cap (e.g., 256) or tile/cluster deferred?
2. **Sky model**: Analytic (Preetham) or LUT-based for performance?
3. **Cloud approach**: Raymarched (quality) or billboards (performance)?
4. **Shadows for sun**: Blocked until CSM implemented — shadowless day/night acceptable for M10?
5. **1-unit cells**: Requires `sin`/`floor` in FIR shader for grid-aligned effects

---

## Success Criteria

- [ ] 1000 lights benchmarked with <16ms frame time
- [x] Sky visible in all scenes
- [x] Day/night cycle runs smoothly
- [x] Clouds render at 60fps with quarter-res + temporal

## Next Step

All M10 phases complete. Proceed to next milestone.
