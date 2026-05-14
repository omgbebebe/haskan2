# Cloud Shader Production Milestone

## Objective
Transform the prototype volumetric cloud pass into a production-grade renderer matching industry-standard quality (Sakmary CTU 2022 / Frostnova CIS5650 tier).

## Prerequisites (COMPLETED)
- [x] Push constant layout aligned between lighting and cloud passes
- [x] Texture size mismatch fixed (128³ → 512³)
- [x] Ray interpolation fixed (removed pre-normalization in `Scene.hs`)
- [x] Cloud history initial layout transition (UB fix)
- [x] Clouds visible from above (removed `cloudsMask = step 0.01 dirY`)
- [x] Runtime wind direction configurable via `,` / `.` keys
- [x] Wind direction passed to shader via push constants

---

## Phase 1: Robust Camera Traversal (Dual-Plane Slab Intersection)
**Priority:** Critical — Blocks all in-cloud flight scenarios
**Estimate:** 2-4 hours
**Risk:** Low — Pure math, no FIR loops

### Tasks
1. Replace `tEntry = (cloudBottom - camY) / max 0.01 dirY` with slab intersector
2. Handle three camera positions:
   - Below clouds: `tNear = max 0 (min tTop tBottom)`
   - Inside clouds: `tNear = 0`
   - Above clouds: `tNear = max 0 (min tBottom tTop)` (note: ray goes downward)
3. Add early-out when ray misses slab (`tFar < 0 || tNear > tFar`)
4. Clamp `tEntry` to avoid negative values

### Deliverables
- Camera can fly through cloud layer seamlessly
- No visual pops when crossing cloudBottom/cloudTop boundaries

### Files
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` (fragment shader entry math)

---

## Phase 2: Dynamic Ray March Loop
**Priority:** Critical — Fixes banding, aliasing, wood-grain artifacts
**Estimate:** 6-10 hours
**Risk:** Medium — FIR `while`/`loop` syntax, register pressure tuning

### Tasks
1. Replace unrolled `p0-p5` with `while` loop:
   ```haskell
   #step @Int32 #= 0
   #rayPos @Vec3 .= entryPos
   #transmittance @Float #= 1.0
   #accR @Float #= 0
   #accG @Float #= 0
   #accB @Float #= 0
   
   while (step < stepCount && transmittance > 0.01) do
     -- sample density
     -- light march (Phase 3)
     -- accumulate
     rayPos .= rayPos ^+^ dir ^* stepSize
     step %= (+1)
   ```
2. Make `stepCount` configurable via push constant (CPU can tune 16/24/32/64)
3. Keep `stepSize = cloudThickness / stepCount` (adaptive to layer thickness)
4. Benchmark register pressure: target <20 VGPRs per wave

### Deliverables
- No visible banding at any camera angle
- Smooth cloud edges without wood-grain patterns
- GPU performance within 2× of current (6-step unrolled)

### Files
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs`
- `src/Graphics/Haskan/Render/Deferred.hs` (push `stepCount`)
- `src/Graphics/Haskan/Engine/Render/Internal/PassRecording.hs` (thread `stepCount`)

---

## Phase 3: Nested Light March (Beer-Powder Integration)
**Priority:** High — Adds self-shadowing depth, fixes flat lighting
**Estimate:** 4-6 hours
**Risk:** Medium — Nested `while` in FIR, texture sample cost

### Tasks
1. Extract light march into helper function/loop block:
   ```haskell
   lightMarch :: Code (V 3 Float) -> Code Float
   lightMarch p = do
     #lightStep @Int32 #= 0
     #lightPos @Vec3 .= p
     #lightDensity @Float #= 0
     
     while (lightStep < lightStepCount) do
       d <- sampleDensity lightPos
       lightDensity .= lightDensity + max 0 d * lightStepSize
       lightPos .= lightPos ^+^ sunDir ^* lightStepSize
       lightStep %= (+1)
     
     let beer = exp (-lightDensity * 1.5)
         powder = 1.0 - exp (-lightDensity * 2.0)
     pure (max beer (beer * powder * 0.7))
   ```
2. `lightStepCount = 4` (configurable via push constant)
3. `lightStepSize = cloudThickness / lightStepCount`
4. Only execute light march when `density > 0.01` (sparse optimization)

### Deliverables
- Clouds show volumetric self-shadowing (dark bases, bright tops)
- No flat/uniform lighting on thick cloud masses
- Performance cost <50% of Phase 2 baseline

### Files
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs`

---

## Phase 4: Wind-Aware Temporal Reprojection
**Priority:** High — Eliminates ghosting trails from moving clouds
**Estimate:** 3-5 hours
**Risk:** Low — CPU-side math, single shader addition

### Tasks
1. CPU: Compute `windDeltaUV` per frame:
   ```haskell
   windDeltaU = windDirX * timeDelta * windSpeed * noiseScale * cloudResU
   windDeltaV = windDirZ * timeDelta * windSpeed * noiseScale * cloudResV
   ```
2. Add `windDeltaU`, `windDeltaV` to push constants (or compute from existing `time` + `windDir`)
3. Shader: Offset history UV before sampling:
   ```haskell
   let histUV = Vec2 (prevU - windDeltaU) (prevV - windDeltaV)
       valid = step 0.0 histUV.x * step histUV.x 1.0
             * step 0.0 histUV.y * step histUV.y 1.0
   ```
4. Reduce `blendFactor` from 0.92 to 0.85 (less aggressive history blending)

### Deliverables
- Moving clouds do not leave ghost trails
- Temporal accumulation still reduces noise
- History UV stays within [0,1] bounds

### Files
- `src/Graphics/Haskan/Engine/Render.hs` (compute windDelta)
- `src/Graphics/Haskan/Render/Deferred.hs` (push windDelta)
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` (offset histUV)

---

## Phase 5: Quality Tuning & Cloud Genus Presets
**Priority:** Medium — Art direction, multiple cloud types
**Estimate:** 4-6 hours
**Risk:** Low — Parameter tweaking, no structural changes

### Tasks
1. Implement cloud genus parameterization (via push constants or uniform buffer):
   | Genus | Base | Top | Coverage | Detail | Absorption |
   |-------|------|-----|----------|--------|------------|
   | Cumulus | 1500 | 3500 | 0.45 | 0.35 | 0.04 |
   | Stratus | 800 | 2000 | 0.85 | 0.20 | 0.06 |
   | Stratocumulus | 1000 | 2500 | 0.60 | 0.30 | 0.04 |
   | Cumulonimbus | 1000 | 6000 | 0.60 | 0.50 | 0.08 |
   | Cirrus | 8000 | 12000 | 0.30 | 0.60 | 0.01 |
2. Add keyboard shortcuts to cycle presets (e.g. `Shift+1` through `Shift+5`)
3. Add coverage threshold to density formula: `density = max(0, baseDensity - (1.0 - coverage))`
4. Tune height mask shape per genus (dome vs flat vs anvil)

### Deliverables
- 5 distinct cloud types selectable at runtime
- Density/coverage/height parameters adjustable per type
- Visual variety matching real-world cloud classification

### Files
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` (density formula)
- `src/Graphics/Haskan/Input.hs` (new key bindings)
- `src/Graphics/Haskan/Engine/Update.hs` (preset cycling)

---

## Phase 6: Performance Optimization & Quarter-Res Refinement
**Priority:** Medium — Ensure 60 FPS at 1080p
**Estimate:** 4-8 hours
**Risk:** Medium — GPU profiling, step count tuning

### Tasks
1. Implement adaptive step count based on view angle:
   - Vertical rays (|dirY| > 0.7): 16 steps
   - Diagonal rays (|dirY| > 0.3): 24 steps
   - Near-horizontal: 32 steps (or skip — see below)
2. Add near-horizon optimization: if `|dirY| < 0.05`, render pure skybox (no cloud march)
3. Blue noise dithering instead of hash-based: precompute 64×64 blue noise texture
4. Profile with RenderDoc: verify VGPR usage < 32, occupancy > 50%
5. If needed: split near/far cloud layers, render far clouds at half resolution

### Deliverables
- 60 FPS on mid-range desktop GPU (GTX 1060 / RX 580 equivalent)
- No frame drops when looking at horizon
- VGPR usage within hardware limits

### Files
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` (adaptive step count)
- `src/Graphics/Haskan/Vulkan/Texture.hs` (blue noise generation/loading)
- `src/Graphics/Haskan/Vulkan/DeferredResources.hs` (blue noise descriptor)

---

## Phase 7: Integration Testing & Documentation
**Priority:** Medium — Prevent regressions, enable future work
**Estimate:** 3-4 hours
**Risk:** Low

### Tasks
1. Create cloud test scenarios in `--cloud-test` mode:
   - Camera path: ground → through clouds → above clouds
   - Time-lapse: 00:00 to 24:00 with day-night cycle
   - Wind stress: maximum wind speed, all directions
2. Screenshot comparison tests (reference images for each genus)
3. Update `.opencode/MEMORIES.md` with:
   - Final push constant layout
   - Step count / performance targets
   - Known limitations (no aerial perspective, no atmosphere LUT)
4. Update `CLOUD_SHADER_AUDIT.md` with resolution notes

### Deliverables
- Automated visual regression tests
- Updated documentation
- Performance benchmark numbers

---

## Summary: Effort & Timeline

| Phase | Task | Est. Hours | Risk | Dependencies |
|-------|------|-----------|------|--------------|
| 1 | Dual-plane slab intersector | 3h | Low | None |
| 2 | Dynamic ray march loop | 8h | Medium | Phase 1 |
| 3 | Nested light march | 5h | Medium | Phase 2 |
| 4 | Wind-aware reprojection | 4h | Low | Phase 2 |
| 5 | Cloud genus presets | 5h | Low | Phase 3 |
| 6 | Performance optimization | 6h | Medium | Phase 2-4 |
| 7 | Testing & documentation | 3h | Low | All above |
| **Total** | | **~34h** | | |

## Recommended Order
1. Start with **Phase 1** (slab intersector) — unblocks camera freedom immediately
2. Then **Phase 2** (dynamic loop) — biggest visual improvement
3. Parallel track: **Phase 4** (wind reprojection) — independent, high impact
4. Then **Phase 3** (light march) — builds on dynamic loop
5. **Phase 5** (presets) — art direction pass
6. **Phase 6** (perf) — polish and validate
7. **Phase 7** (testing) — lock it in

## FIR Capability Checklist
| Feature | FIR Support | Status |
|---------|-------------|--------|
| `while` loop | Yes (`while (cond) do`) | ✅ Available |
| `loop` + `break` | Yes (`loop do` + `break @n`) | ✅ Available |
| Mutable variables | Yes (`#name @Type #= val`) | ✅ Available |
| Nested loops | Yes (confirmed in tests) | ✅ Available |
| No `continue` | Workaround: `when (cond) do` blocks | ✅ Workable |
| Texture sampling inside loops | Yes (SPIR-V OpImageSample) | ✅ Available |
| Early return from function | Limited — use `break` or refactor | ⚠️ Design around it |

All structural fixes are **implementable in FIR**. No SPIR-V assembly or external shader language required.
