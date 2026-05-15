# Cloud Shader Production Milestone

## Current Status (as of 2025-05-15)

| Phase | Feature | Status | Commit |
|-------|---------|--------|--------|
| 1 | Dual-plane slab intersector | ✅ Complete | pre-master |
| 2 | Dynamic 24-step ray march loop | ✅ Complete | pre-master |
| 3 | Nested 4-step light march (Beer-Powder) | ✅ Complete | ca1af99 |
| 4 | Wind-aware temporal reprojection | ✅ Complete | pre-master |
| 5 | Cloud genus presets (5 types) | ✅ Complete | e542a4d |
| 6a | Adaptive step count (16/24/32) | ✅ Complete | b49f724 |
| 6b | Near-horizon skip (|dirY| < 0.05) | ✅ Complete | b49f724 |
| 6c | Blue noise dithering texture | ✅ Complete | da8e2a2 |
| 7 | Automated visual regression tests | ❌ Not started | — |

**Total effort to date:** ~8 hours (header fix, lightStepSize, absorption presets, adaptive steps, blue noise)

---

## Rendering Quality Issues (from code review)

### 1. CRITICAL — No tone mapping / gamma for cloud pixels

**Problem:** `Lighting.hs:639-646` — geometry pixels go through Reinhard tone map + sqrt gamma. Cloud pixels bypass both — raw linear HDR goes straight to framebuffer.

A linear value of 0.1 should display as ~0.316 after gamma, but stays 0.1. This directly causes the "clouds too dark" symptom.

**Fix:** Apply same tone map + gamma to `cloudSkyR/G/B` before multiplying by tint:
```haskell
cloudMapR = cloudSkyR / (cloudSkyR + 1.0)
cloudGamR = sqrt cloudMapR
tintedSkyR = cloudGamR * skyTintR
```

**Files:** `Lighting.hs:639-646`

**Effort:** 30 minutes

---

### 2. CRITICAL — Density × 4.0 is catastrophically too high for step sizes

**Problem:** `Clouds.hs:315` — density formula multiplies by 4.0. With near-horizontal rays:
- `totalRayLength` up to 10,000 units
- `adaptiveStepSize` = 10000 / 32 ≈ 312 units per step
- Per-step optical depth: `density × stepSize = 4.0 × 312 = 1248`
- `exp(-1248) = 0` — transmittance drops to zero in a single step

Light march is equally broken: `lightStepSize = 800 / 4 = 200`, `4.0 × 200 = 800` per step, `exp(-3200 × 1.5) = 0`. Zero light reaches any interior point.

The × 4.0 was tuned for old hash-noise (tiny implicit step sizes). The new 3D texture with large explicit steps needs density in 0.01–0.1 range.

**Fix:** Remove `* 4.0` from density formula. Let noise provide 0..1 range. Tune `cloudCoverage` and `cloudAbsorption` for actual step sizes.

**Files:** `Clouds.hs:315, 342`

**Effort:** 1 hour (testing + parameter tuning)

---

### 3. Moderate — X-axis banding from domain warping

**Problem:** `Clouds.hs:304-306` — all three warp axes use the same base frequency `warpFreq = 0.002` with only minor mix coefficients (0.5/0.6/0.7). `wy` depends only on `px` and `pz`, creating bands parallel to Y axis. Amplitude 170 is ~51% of noise tile size (1/0.003 ≈ 333), excessive.

**Fix:** Use 3 distinct frequencies (e.g., 0.0013, 0.0017, 0.0023). Reduce amplitude to 50–80. Or add second warp octave.

**Files:** `Clouds.hs:267-268` (warpFreq, warpAmp)

**Effort:** 1 hour (visual iteration)

---

### 4. Moderate — Noise scale too small (small clouds, not sparse)

**Problem:** `Clouds.hs:270` — `noiseScale = 0.003` means each tile spans ~333 world units. With `cloudThickness = 800`, only ~2.4 tiles fit vertically. Cloud features are small relative to visible sky dome.

Real volumetric renderers use `noiseScale ~ 0.0003–0.001` for cumulus-scale features.

**Fix:** Reduce to `noiseScale = 0.0008` (tile size ~1250 units, ~1.5 tiles through thickness). Produces larger, more realistic masses. Increase `cloudCoverage` threshold slightly to compensate.

**Files:** `Clouds.hs:270`

**Effort:** 30 minutes (visual iteration)

---

### 5. Minor — Sky tint applied twice

**Problem:** `Clouds.hs:374-379` applies `skyTintR/G/B`. Then `Lighting.hs:641` applies it again. At night (tint ~0.1), double-tinting gives 0.01 — essentially invisible.

**Fix:** Remove tint from one location. Simpler to remove from `Clouds.hs` (output raw cloud radiance) and let `Lighting.hs` apply tint once.

**Files:** `Clouds.hs:374-379` or `Lighting.hs:641`

**Effort:** 15 minutes

---

## Infrastructure Issues (from code review)

### 6. Push Constant Size Exceeds Vulkan Minimum

**Problem:** Cloud push constant is 216 bytes. Vulkan spec guarantees only 128 bytes (`maxPushConstantsSize`). Integrated/mobile GPUs may enforce 128.

**Fix:** Migrate cloud pass data to per-frame UBO. Reduce push constant to 32 bytes max.

**Files:** `Clouds.hs`, `DeferredResources.hs`, `Render/Deferred.hs`, `PassRecording.hs`

**Effort:** 4-6 hours

---

### 7. Missing Explicit COLOR_ATTACHMENT → TRANSFER Barrier

**Problem:** `layerTransition` wrapper has no explicit case for `COLOR_ATTACHMENT_OPTIMAL → TRANSFER_SRC_OPTIMAL`. Hits catch-all `ALL_COMMANDS_BIT` — safe but slow.

**Fix:** Add explicit case:
```haskell
(Vulkan.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, Vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL) ->
  ( Vulkan.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
    Vulkan.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
    Vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT,
    Vulkan.VK_ACCESS_TRANSFER_READ_BIT )
```

**Files:** `CommandBuffer.hs`

**Effort:** 30 minutes

---

### 8. Render Graph Dependencies Not Declared

**Problem:** `rpInputs = []` and `rpOutputs = []` for all passes. Framework cannot auto-insert barriers or reorder.

**Fix:** Populate `rpInputs`/`rpOutputs` in `buildDeferredGraph`.

**Files:** `Render/Deferred.hs`, `Render/Graph.hs`

**Effort:** 2-3 hours

---

### 9. Blue Noise Tileability

**Problem:** 64×64 blue noise may not be tileable. Screen-edge UVs sample discontinuous noise.

**Fix:** Verify repeat sampler handles it, or regenerate with toroidal void-and-cluster.

**Files:** `scripts/generate_blue_noise.py`

**Effort:** 1 hour

---

## Priority Fix Order

| # | Task | Priority | Category | Effort |
|---|------|----------|----------|--------|
| 1 | Remove `* 4.0` from density formula | **Critical** | Rendering | 1h |
| 2 | Add tone map + gamma for cloud pixels | **Critical** | Rendering | 30m |
| 3 | Fix double sky tint | **High** | Rendering | 15m |
| 4 | Reduce noiseScale to ~0.0008 | **High** | Rendering | 30m |
| 5 | Fix domain warping (3 frequencies, lower amp) | **High** | Rendering | 1h |
| 6 | Migrate push constant to UBO | **Critical** | Infra | 4-6h |
| 7 | Add COLOR_ATTACHMENT → TRANSFER barrier | **High** | Infra | 30m |
| 8 | Populate render graph dependencies | **Medium** | Infra | 2-3h |
| 9 | Verify blue noise tileability | **Low** | Visual | 1h |
| 10 | `--cloud-test` automated screenshot mode | **Low** | Testing | 3-4h |
| 11 | RenderDoc VGPR profiling | **Info** | Performance | 2h |

**Recommended order:** Fix rendering issues 1–5 first (they affect correctness and are quick). Then tackle infrastructure 6–8. Finally polish 9–11.

---

## Default Parameters

| Parameter | Current | Target |
|-----------|---------|--------|
| `cloudHeight` | 1500 (preset-dependent) | Keep presets |
| `cloudCoverage` | 0.45 (preset-dependent) | Keep presets |
| `cloudDetail` | 0.35 (preset-dependent) | Keep presets |
| `cloudAbsorption` | 1.5 (preset-dependent) | Keep presets |
| `cloudThickness` | 800.0 | Keep |
| `noiseScale` | 0.003 | **0.0008** |
| `warpFreq` | 0.002 | **Split: 0.0013, 0.0017, 0.0023** |
| `warpAmp` | 170.0 | **~60.0** |
| `densityMultiplier` | 4.0 | **1.0 (remove)** |

---

## Notes

- **FIR `while` codegen:** Single-pass phi approach is stable. All 12 Control tests pass including `NestedLoop`.
- **Noise texture:** 256³ RGBA8 (64MB raw), generator at `scripts/generate_cloud_noise.py`.
- **Blue noise:** 64×64 RGBA8 (16KB raw), generator at `scripts/generate_blue_noise.py`.
- **SPIR-V validation:** Cloud fragment shader passes `spirv-val` cleanly.
- **Build command:** `~/bin/env-wrap cabal build exe:haskan2`
- **Kill hanging procs:** `ps ax | rg 'haskan2' | awk '{print $1}' | xargs -I% kill -9 %`
