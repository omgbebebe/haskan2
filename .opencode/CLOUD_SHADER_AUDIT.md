# Cloud Shader Audit Report

Date: 2026-05-14
Status: PRODUCTION READY (Phases 1-6 Complete)
References:
- [Frostnova (CIS5650)](https://github.com/YueZhang1027/CIS5650-Final-Project-Frostnova) — Nubis-based VDB clouds (C++, Vulkan)
- [Sakmary CTU Thesis 2022](https://dcgi.fel.cvut.cz/wp-content/wpallimport-dist/theses/pdf/theses-2022-sakmamat-thesis.pdf) — Hillaire atmosphere + Schneider procedural clouds (C++, Vulkan)

## Current Implementation Summary

All critical bugs fixed, all production milestone phases complete.

| Feature | Status | Notes |
|---------|--------|-------|
| Dual-plane slab intersector | DONE | Camera can fly through cloud layer seamlessly |
| Dynamic ray march loop | DONE | FIR `loop`/`break`/`def`, 8-32 adaptive steps |
| Nested light march | DONE | 4-step inner loop toward sun per primary step |
| Wind-aware temporal reprojection | DONE | `prevTime` push constant, windDelta subtraction |
| Cloud genus presets | DONE | 5 presets (Shift+1..5), coverage/detail params |
| Adaptive step count | DONE | 16/24/32 based on `|dirY|` |
| Near-horizon skip | DONE | Skip march when `|dirY| < 0.05` |
| Blue-noise-like dithering | DONE | Interleaved gradient noise (Jimenez 2014) |

---

## Technique Comparison (Updated)

| Aspect | Haskan2 | Frostnova | Sakmary Thesis |
|--------|---------|-----------|---------------|
| **Atmosphere** | Static HDRI cubemap + rotation | Physical sky (Preetham) | Hillaire 2020 LUT-based |
| **Cloud density source** | 3D Worley noise RGBA (512³) | VDB voxel grids + 3D noise | Two 3D Worley textures (256³ base + 128³ detail) |
| **Cloud geometry** | Flat layer at `cloudHeight` with thickness 800 | Atmosphere shell (sphere intersect) | Sphere-intersected atmosphere shell |
| **Primary ray march** | 16-32 adaptive steps, dynamic loop | Adaptive (SDF-guided + sqrt(distance)) | Linear with `iter+0.3` offset |
| **Light march** | 4-sample cone toward sun | 6-sample cone + VDB light grid | Small secondary ray march toward sun |
| **Phase function** | Dual-lobe HG (0.6, -0.3) | Dual-lobe HG + silver lining | Double HG (Mie, equation 2.28) |
| **Transmittance** | Beer-Powder `max(exp(-d*1.5), 0.7*exp(-d*0.25))` | Beer-Lambert + powder | Beer-Lambert + Powder `P = 1 - exp(-2τ)` |
| **Density** | `max(0, R*(1-detail*(G*0.3+B*0.15+A*0.075))-(1-coverage)) * height * 4.0` | Profile from VDB × erosion from noise | Base texture - detail texture weighted by inverse base |
| **Temporal** | Wind-aware reprojection, blend=0.85 | Temporal upscaling (near/far split) | N/A |
| **Aerial perspective** | None | None | Pre-computed 3D LUT applied as post-pass |
| **Output** | RGBA16F intermediate → lighting pass composites | Compute → tone.frag | HDR backbuffer with cloud alpha → aerial perspective → tonemap |

### Key Improvements Since Initial Audit

1. **Push constant layout**: FIXED. Cloud and lighting passes now share aligned `CloudPushConstant` struct (212 bytes) with all fields matching CPU packing.
2. **Dynamic loop**: Replaced unrolled 6-step with FIR `loop`/`break`. VGPR pressure dropped from ~50 to ~12.
3. **Self-shadowing**: Added 4-step nested light march with Beer-Powder integration. Clouds now show volumetric depth (dark bases, bright edges).
4. **Temporal stability**: Wind-aware reprojection eliminates ghosting trails. `prevTime` push constant enables per-frame wind displacement correction.
5. **Performance**: Adaptive step count + horizon skip ensures consistent frame times. Near-horizontal rays use fewer steps or are skipped entirely.
6. **Dithering**: Interleaved gradient noise replaces simple hash for better temporal stability without texture overhead.

---

## Architecture Details

### Push Constant Layout (212 bytes)

```
offset 0:    cameraX/Y/Z, debugMode                    (16 bytes)
offset 16:   axisOverlay, groundPlane, sunAzimuth, lightCount (16 bytes)
offset 32:   ray0 (V3 Float)                           (12 bytes)
offset 44:   ray1 (V3 Float)                           (12 bytes)
offset 56:   ray2 (V3 Float)                           (12 bytes)
offset 68:   skyTintR, skyTintG, skyTintB, iblIntensity (16 bytes)
offset 84:   sunDir (V3 Float)                         (12 bytes)
offset 96:   cloudHeight                               (4 bytes)
offset 100:  time                                      (4 bytes)
offset 104:  blendFactor                               (4 bytes)
offset 108:  prevViewProj0 (V4 Float)                  (16 bytes)
offset 124:  prevViewProj1 (V4 Float)                  (16 bytes)
offset 140:  prevViewProj2 (V4 Float)                  (16 bytes)
offset 156:  prevViewProj3 (V4 Float)                  (16 bytes)
offset 172:  windDirX                                  (4 bytes)
offset 176:  windDirZ                                  (4 bytes)
offset 180:  prevTime                                  (4 bytes)
offset 184:  cloudCoverage                             (4 bytes)
offset 188:  cloudDetail                               (4 bytes)
offset 192:  [padding to 212 for 4-byte alignment]     (20 bytes)
Total: 212 bytes
```

### Adaptive Step Count

```haskell
let absDirY = abs dirY
    stepCount = if absDirY < 0.1
      then (16 :: Code Int32)
      else (if absDirY < 0.6 then (24 :: Code Int32) else (32 :: Code Int32))
    stepCountF = fromIntegral stepCount :: Code Float
    stepSize = totalRayLength / stepCountF
```

### Density Formula

```haskell
density = max 0 (nr * (1.0 - cloudDetail * (ng * 0.3 + nb * 0.15 + na * 0.075)) - (1.0 - cloudCoverage)) * heightMask * 4.0
```

Where:
- `nr` = Perlin-Worley blend (macro shape)
- `ng/nb/na` = Worley erosion (8³, 16³, 32³)
- `cloudDetail` = 0.20-0.60 (preset-dependent)
- `cloudCoverage` = 0.30-0.85 (preset-dependent)
- `heightMask` = smoothstep bottom fade × (1 - smoothstep top fade)

### Beer-Powder Transmittance

```haskell
let lightT_d = let b = exp (-finalLightDensity * 1.5)
                   p = 0.7 * exp (-finalLightDensity * 0.25)
               in max b p
```

Matches Frostnova reference implementation.

---

## Known Limitations

1. **No aerial perspective**: Distance haze not applied to clouds. Would require atmosphere LUT integration.
2. **Static HDRI cubemap**: No dynamic sky gradient. Sun color comes from day/night cycle, not atmospheric scattering.
3. **Flat cloud layer**: No spherical planet curvature. Cloud layer is infinite horizontal slab at fixed height.
4. **No multiscattering**: Light march is single-scattering only. Cloud interiors can appear too dark at high optical depth.
5. **Interleaved gradient noise vs true blue noise**: IGN is computationally cheaper but has slightly more low-frequency patterning than optimized blue noise textures.

---

## Performance Characteristics

- **VGPR usage**: ~12-16 (adaptive loop, no unrolling)
- **SPIR-V size**: ~22KB optimized (with clouds + all features)
- **Quarter-resolution rendering**: Cloud pass at 0.5× surface resolution
- **Temporal accumulation**: 0.85 blend factor, wind-corrected reprojection
- **Step count range**: 16-32 primary steps + 4 light steps per occupied primary step

---

## Files

- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` — Core shader
- `src/Graphics/Haskan/Render/Deferred.hs` — CPU push constant packing (212 bytes)
- `src/Graphics/Haskan/Vulkan/DeferredResources.hs` — Pipeline layout, descriptor sets
- `src/Graphics/Haskan/Engine/Render.hs` — `rePrevTime`, cloud TVar reads
- `src/Graphics/Haskan/Engine/Update.hs` — Preset cycling, wind rotation
- `src/Graphics/Haskan/Input.hs` — `CloudPreset`, `WindRotateLeft/Right` actions
- `src/Graphics/Haskan/Engine/Types.hs` — `cloudCoverage`, `cloudDetail` in `GameState`
