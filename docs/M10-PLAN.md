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

## Phase 2: Skybox Background
**Goal:** Proper environment background instead of black clear color.

### Tasks
1. **Skybox render pass** — draw cubemap as background before/after lighting
   - Option A: Fullscreen triangle with cubemap sampling (cheaper)
   - Option B: Inverted cube mesh (classic, easier with depth)
2. **Depth handling** — skybox at infinity (Z=1.0), no depth write
3. **IBL integration** — ensure skybox matches irradiance/radiance cubemaps

### Deliverable
Scene renders with visible sky background. `--no-sky` flag to disable.

---

## Phase 3: Dynamic Day/Night Cycle
**Goal:** Moving sun, changing sky color, time-of-day lighting.

### Tasks
1. **Sun trajectory** — spherical coordinates (azimuth, elevation) driven by time
2. **Atmospheric scattering** — simple analytic sky model:
   - Option A: Preetham sky model (analytic, no textures)
   - Option B: Hosek-Wilkie (better sunsets, still analytic)
   - Option C: LUT-based (baked gradients, fastest)
3. **Dynamic IBL** — rotate radiance/irradiance cubemaps with sun direction
   - OR: blend between day/night cubemap presets
4. **Exposure adaptation** — auto-exposure based on average luminance
5. **Time control** — `TimeOfDay` component + debug keys (speed up/slow down)

### Deliverable
`--time 12:00` flag. Sun moves, sky color changes, shadows (if CSM ready) rotate.

---

## Phase 4: Volumetric Clouds
**Goal:** Modern cloud rendering without pre-baking.

### Approach Options

| Technique | Quality | Performance | Complexity | Best For |
|-----------|---------|-------------|------------|----------|
| **Raymarched noise** (Worley/Perlin) | High | Medium | High | Cinematic, close-ups |
| **Billboard cloud layers** | Medium | Fast | Low | Distant clouds, mobile |
| **Voxel-based (SDF)** | High | Medium | Medium | Stylized, editable |
| **Neural/ML-based** | Very High | Slow | Very High | Research, not real-time |

**Recommended:** Raymarched Worley noise in fullscreen pass
- 3D noise texture (128³ or 256³)
- Ray march from camera through atmosphere shell
- Beer-Lambert extinction + Henyey-Greenstein phase
- Temporal reprojection for stability

### Tasks
1. **Noise generation** — 3D Worley-Perlin hybrid, generate on CPU or load from file
2. **Raymarch shader** — compute pass or fullscreen fragment shader
3. **Cloud shaping** — coverage, density, height gradients
4. **Integration** — composite clouds into skybox before lighting pass
5. **Wind animation** — time-driven noise offset

### Deliverable
`--clouds` flag. Animated clouds with proper shadowing on scene (optional).

---

## Milestone Structure

```
M10.1  Multi-Light Benchmark      (1 week)
M10.2  Skybox Background          (3 days)
M10.3  Day/Night Cycle            (1 week)
M10.4  Volumetric Clouds          (2 weeks)
```

**Total: ~4-5 weeks** (depending on cloud quality target)

---

## Technical Decisions Needed

1. **Light limit**: Hard cap (e.g., 256) or tile/cluster deferred?
2. **Sky model**: Analytic (Preetham) or LUT-based for performance?
3. **Cloud approach**: Raymarched (quality) or billboards (performance)?
4. **Shadows for sun**: Blocked until CSM implemented — shadowless day/night acceptable for M10?

---

## Success Criteria

- [ ] 1000 lights benchmarked with <16ms frame time
- [ ] Sky visible in all scenes
- [ ] Day/night cycle runs at 1hr/sec smoothly
- [ ] Clouds render at 60fps (or configurable quality)

## Next Step

Implement M10.1 (multi-light) first, or jump to skybox depending on priorities.
