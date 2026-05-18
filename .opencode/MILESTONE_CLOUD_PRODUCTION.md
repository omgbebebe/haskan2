# MILESTONE: Cloud & Atmosphere Production Quality

> Synthesized from comparison with leoawen/volumetric_cloud_atmosphere_scattering, MEMORIES.md issues, and current haskan2 capabilities.

## Current State Summary

| Feature | Status | Quality |
|---------|--------|---------|
| Atmosphere model (Hosek-Wilkie) | Implemented | High — physically validated coefficients |
| Dynamic sky regeneration | **BROKEN (P0)** | Cubemaps generated once, never updated |
| Cloud noise (baked 256³) | Working | Medium — 4-channel Perlin-Worley + Worley cascade |
| Weather map (512²) | Working | Medium — coverage/type/storm channels |
| Height profile | Working | Basic — 2-smoothstep band by cloud type |
| Raymarching (48–96 adaptive steps) | Working | Medium — no empty-space skip |
| Multi-scatter (3-term exp) | Working | Good — ms0+ms1+ms2 |
| Phase function (dual HG) | Working | Good — forward + backward lobe |
| Ambient (height-graded presets) | Working | Medium — hardcoded day/sunset/night |
| Temporal reprojection | Working | Medium — wind-aware, basic ghost clamp |
| Sky LUT (200²) | Generated | **Unused** — dead code |
| God rays | Not implemented | — |
| Detail erosion LOD | Not implemented | — |
| Noise GPU baking | Not implemented | — |
| Empty-space skipping | Not implemented | — |
| Powder effect | Not implemented | — |
| Floating origin | Not implemented | — |
| Cloud self-shadow caching | Not implemented | — |

---

## Phase 0 — Fix Dynamic Sky Regeneration (P0 blocker)

**Status**: ✅ Complete

**Why**: The Hosek-Wilkie model is wasted if cubemaps never update. Day/night cycle currently changes the analytic sky in the cloud shader but IBL/reflections stay frozen at startup values.

**Tasks**:
1. ✅ Wire `needsSkyRegen` flag to actually dispatch the 3 compute shaders (RadianceGen, SkyLUTGen, IrradianceGen)
2. ✅ Update `SkyGenUniforms` with current sun direction from `DayNight.hs` before each dispatch
3. ✅ Regenerate on sun elevation change > 2° (existing threshold in `Update.hs:263`)
4. ⬜ Verify: sunset should produce reddish cubemap, night should be dark, dawn should warm up
5. ⬜ Delete or integrate the unused 200² SkyLUT (either wire it into the lighting shader or remove the dispatch)

**Files**: `Engine/Render.hs:320-326`, `Engine/Render/Internal/Setup.hs:498+`, `Engine/Types.hs:537`, `DayNight.hs`

**Exit criteria**: Sun movement visibly updates sky cubemap, IBL reflections change with time of day.

---

## Phase 1 — Cloud LOD & Empty-Space Skipping

**Why**: Current fixed 48–96 steps with no empty-space skip wastes GPU time on clear sky. leoawen achieves 800 steps efficiently via geometric growth + skip.

**Tasks**:
1. **Geometric step growth**: Start at ~200m, grow by 1.001–1.01× per step (configurable). This naturally allocates more samples near camera where detail matters.
2. **Empty-space skip**: When density reads 0, multiply step size by configurable factor (2–4×). Resume normal stepping on first hit.
3. **3D texture mipmapping**: Generate mipmaps on the cloud noise 3D texture. Use `textureLod()` with distance-based LOD level (0 at near, up to 4 at far).
4. **Detail erosion LOD**: Fade detail channels (G/B/A) beyond configurable distance. Near = full detail, far = R channel only.
5. **Increase max steps**: With geometric growth + empty skip, raise cap to 200+ without perf regression.

**Files**: `Clouds.hs:298-370`, `DeferredResources.hs` (mipmap generation)

**Exit criteria**: Distant clouds are softer (mipmapped), empty sky is cheap, nearby detail is preserved.

---

## Phase 2 — Improved Density Model

**Why**: leoawen uses a 4-layer vertical profile (base funnel + top cutoff + dual fade + opacity clamp) that produces more realistic cloud shapes. Our 2-smoothstep band is flat.

**Tasks**:
1. **4-layer height profile**:
   - Bottom funnel: `pow(smoothstep(0, base, h%), curve)` — tapered base
   - Top shape: `1 - smoothstep(top, 1.0, h%)` — rounded top
   - Dual coverage fade: separate base-in and top-out smoothsteps
   - Final opacity clamp at bottom and top boundaries
2. **Smart remap**: `remap(noise, 1 - coverage, 1, 0, 1)` — makes coverage an exact control (0 = no cloud, 1 = fully filled)
3. **Dynamic cloud height**: Cloud top varies with coverage — `heightMax * coverage^curve`. Thicker weather = taller clouds.
4. **Separate detail texture**: Currently packed in same 256³ RGBA. Consider adding a dedicated 32³ or 64³ detail-only texture for sharper erosion (like leoawen's 32³ RGB with 3 Worley frequencies).
5. **Weather map spherical projection**: Current weather map is flat UV. Switch to `atan(z,x) → u, asin(y) → v` with pole masking for consistent planet-wide coverage.

**Files**: `Clouds.hs:390-410`, weather map generation, `DeferredResources.hs`

**Exit criteria**: Clouds have tapered bases and rounded tops. Coverage control is predictable (0→clear, 1→overcast). Taller clouds in storm areas.

---

## Phase 3 — Powder Effect & Ambient Improvements

**Why**: Haskan2 has good multi-scatter but lacks the powder effect (brightens cloud edges facing sun) and uses hardcoded ambient presets instead of sampling actual sky.

**Tasks**:
1. **Powder effect**: `1 - exp(-density * powderScale * 2.0)` applied to direct light. This counter-intuitively brightens thin cloud edges facing the sun (more light passes through thin regions).
   ```
   lightTerm = beerLaw * mix(1.0, powderTerm*2+1, powderIntensity)
   ```
2. **Ambient from sky cubemap**: Replace hardcoded day/sunset/night presets with sampling the irradiance cubemap (already generated in Phase 0). This gives physically consistent ambient that changes with time of day.
3. **Height-graded ambient**: Sample cubemap at different elevations (high = sky blue, low = ground bounce). Weight by cloud height `h`.
4. **Skylight occlusion**: `exp(-shadowDensity * skylightAbsorption * 0.5)` — reduces ambient in dense regions.
5. **Internal scattering approximation**: `1 + density * 0.5` boost to ambient in dense regions.

**Files**: `Clouds.hs:400-470`, `LightingProcedural.hs`

**Exit criteria**: Cloud edges facing sun are brighter (powder). Ambient color matches sky color at all times of day. Dense cloud interiors are darker.

---

## Phase 4 — God Rays

**Why**: Major visual feature missing. leoawen implements screen-space radial blur which is efficient and visually effective.

**Tasks**:
1. **Occlusion mask pass**: Render cloud alpha + scene depth to a half-res texture. Cloud alpha threshold via `smoothstep(0, threshold, cloudAlpha)`.
2. **Sun visibility state**: 1×1 texture tracking whether sun is visible. 13-point sampling of occlusion mask around screen-space sun position. Hysteresis (lerp 0.1) prevents flickering.
3. **Radial blur shader**: Half-res pass. 64–80 samples from each pixel toward screen-space sun position. Accumulate occlusion with configurable decay/weight/exposure.
4. **Composition**: Add god rays to final image: `final += godRays * sunColor * intensity * sunVisibility`.
5. **Configurable uniforms**: density, decay, weight, exposure, intensity.

**Files**: New shader `GodRays.hs`, new render pass in `Deferred.hs`, new resources in `DeferredResources.hs`

**Exit criteria**: Visible god rays through cloud gaps. Sun behind clouds dims rays. No flickering during camera movement.

---

## Phase 5 — Improved Temporal Reprojection

**Why**: Current TAA has basic ghost suppression (brightness clamp). leoawen uses alpha-diff threshold + distance-dependent noise modes.

**Tasks**:
1. **Alpha-diff ghost suppression**: `|current.a - history.a|` threshold. High difference → reject history, keep current.
2. **Distance-dependent noise**: Near camera uses static noise (reduces swimming), far uses sliding noise (reduces ghosting).
3. **Motion weight**: `1 - smoothstep(0, ghostingSuppression, alphaDiff)` — smooth rejection instead of hard cutoff.
4. **Increase blend factor**: From 0.25 to ~0.3 now that ghost suppression is better.
5. **Sub-pixel jitter**: Golden ratio offset on blue noise per frame: `(frame * goldenRatio) % 1.0`.

**Files**: `Clouds.hs:483-538`, `Deferred.hs` (history copy)

**Exit criteria**: Less ghosting on moving objects. Less swimming on static clouds. Smooth temporal convergence.

---

## Phase 6 — GPU Noise Baking

**Why**: Current 256³ raw file is generated externally and loaded from disk. leoawen bakes noise at startup via GPU ortho rendering. This allows parameter tweaking without offline tools.

**Tasks**:
1. **Base noise compute shader**: Generate 256³ Perlin FBM (4 oct) + Worley FBM (3 oct) mixed. Output slice-by-slice to 2D storage image, copy each slice to 3D texture.
2. **Detail noise compute shader**: Generate 32³ or 64³ with 3 Worley frequencies (2x/4x/8x) in RGB channels.
3. **Weather map generation**: Procedural FBM Perlin → coverage, with spherical projection and pole masking.
4. **Runtime parameters**: Expose noise seed, octaves, frequency, persistence as uniforms for live tweaking via ImGui.
5. **Mipmap generation**: GPU `generateMipmaps` on both 3D textures after bake.

**Files**: New shaders in `Shaders/Compute/`, new bake pipeline in `Setup.hs` or dedicated module, `DeferredResources.hs`

**Exit criteria**: Cloud noise generated at startup, not loaded from file. ImGui sliders control noise parameters with live preview.

---

## Phase 7 — Polish & Planetary Scale

**Why**: Final production quality pass. Floating origin prevents precision issues at large distances. Existing earth curvature correction is a good start.

**Tasks**:
1. **Floating origin**: Camera always at origin, world offset inversely. Prevents float precision degradation at distance.
2. **Cloud self-shadow caching**: Store light march results in a 2D texture (cloud-plane projection). Reuse across frames when sun angle hasn't changed significantly. Reduces light march cost by ~50%.
3. **Cloud type variation via weather map**: Wire weather map G channel to control cumulus vs stratus vs cirrus shapes with different noise parameters per type.
4. **Precipitation hint**: Wire weather map B channel (storm) to darken ambient, increase absorption, and tint clouds darker at base.
5. **Render barrier correctness**: Add explicit COLOR_ATTACHMENT → TRANSFER barrier before history copy. Declare cloud pass inputs in render graph.
6. **Blue noise verification**: Confirm 64×64 blue noise tiles seamlessly at quarter-res. Replace with larger texture if needed.

**Files**: `Clouds.hs`, `Deferred.hs`, `DeferredResources.hs`, render graph declarations

**Exit criteria**: No visual artifacts at large camera distances. Cloud pass has correct barriers. Weather map controls visible cloud type variation.

---

## Dependency Graph

```
Phase 0 (dynamic sky) ──┬──→ Phase 3 (ambient from cubemap)
                         │
Phase 1 (LOD/skip)  ────┤
                         │
Phase 2 (density)   ────┼──→ Phase 5 (better TAA)
                         │
Phase 4 (god rays)  ────┤
                         │
Phase 6 (GPU bake)  ────┴──→ Phase 7 (polish)
```

Phases 0–2 are independent and can be done in parallel.
Phase 3 benefits from Phase 0 (needs live cubemap).
Phase 4 is independent.
Phase 5 is independent.
Phase 6 is independent but large.
Phase 7 is last.

## Estimated Effort

| Phase | Scope | Weeks |
|-------|-------|-------|
| 0 | Small — wire existing code | 0.5 |
| 1 | Medium — shader rework | 1–2 |
| 2 | Medium — density model rewrite | 1–2 |
| 3 | Small — powder + ambient lookup | 1 |
| 4 | Large — new render pass + shader | 2–3 |
| 5 | Small — TAA tuning | 0.5–1 |
| 6 | Large — GPU bake pipeline | 2–3 |
| 7 | Medium — polish pass | 1–2 |
| **Total** | | **9–15** |
