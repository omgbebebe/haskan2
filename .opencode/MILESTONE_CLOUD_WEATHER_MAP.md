# Cloud Weather Map Subsystem Milestone

## Objective
Replace the uniform global `cloudCoverage` threshold with a 2D weather map texture that provides spatially-varying cloud coverage, cloud type (height profile), and storm intensity across the sky dome.

## Problem
Current density formula (`Clouds.hs:329`):
```haskell
density = max 0 (nr * (1.0 - cloudDetail * (...)) - (1.0 - cloudCoverage)) * heightMask
```

`cloudCoverage` is a single uniform float — identical everywhere in the sky. The 3D noise is structurally homogeneous, so clouds form as a uniform grid with no variation. Real skies have clear patches, scattered cumulus clusters, and overcast sheets coexisting.

The weather map decouples **macro distribution** (where clouds form) from **structural detail** (3D noise shape), giving spatially varying coverage.

## What the Weather Map Does

A 2D texture (`512x512 RGBA8`) sampled by world horizontal position (X, Z), covering a ~20km area before tiling:

| Channel | Meaning | Value Range | Effect |
|---------|---------|-------------|--------|
| R | Local coverage | 0.0–1.0 | 0 = clear sky, 1 = thick overcast |
| G | Cloud type / height | 0.0–1.0 | 0 = low stratus, 1 = towering cumulonimbus |
| B | Storm darkness | 0.0–1.0 | Darkens bellies for heavy rain/thunderstorm |
| A | Reserved | — | Future use (precipitation mask, wind variation) |

The global `cloudCoverage` uniform is **repurposed** as a `globalCoverage` multiplier:
```
combinedCoverage = clamp(weatherMap.R * globalCoverage, 0.0, 1.0)
```

The cloud type channel (G) dynamically adjusts the height mask profile per region:
```
heightMin = lerp(0.1, 0.0, cloudType)  -- stratus sits low, cumulus starts at ground
heightMax = lerp(0.4, 1.0, cloudType)  -- stratus caps early, cumulus towers high
```

---

## Phase 1: Weather Map Texture Generator
**Priority:** Critical — Blocks shader integration
**Estimate:** 2-3 hours
**Risk:** Low — Standalone Python script, no engine changes

### Tasks
1. Create `scripts/generate_weather_map.py`:
   - Output: `512x512 RGBA8` PNG + raw binary
   - R channel: Multi-octave Perlin 2D noise (3 octaves), normalized to [0,1]
     - Large feature scale (~8km) to create weather zones
     - Medium features (~2km) for cloud cluster variation
     - Fine features (~500m) for edge feathering
   - G channel: Low-frequency gradient (1-2 octaves) for cloud type zones
     - 0.0 = stratus regions (flat, low)
     - 0.5 = cumulus regions (puffy, medium height)
     - 1.0 = cumulonimbus regions (towering)
   - B channel: Derived from R channel — high coverage → darker (storm potential)
     - `storm = smoothstep(0.7, 1.0, coverage) * coverage`
   - A channel: Reserved (all 0.5 for now)
2. Make it tileable (same periodic technique as cloud noise)
3. Save as `data/textures/weather/weather_map.png` and `weather_map.raw`
4. Visual validation: save R/G/B channels as separate grayscale PNGs for inspection

### Deliverables
- 512x512 RGBA8 weather map texture
- Tileable, visually distinct weather zones (clear, scattered, overcast, storm)

### Files
- `scripts/generate_weather_map.py` (new)
- `data/textures/weather/weather_map.png` (new)

---

## Phase 2: GPU Resource Setup
**Priority:** Critical — Weather map needs Vulkan texture + descriptor binding
**Estimate:** 2-3 hours
**Risk:** Low — Follows existing pattern for `cloud_noise` texture

### Tasks
1. Load weather map texture at startup (follow `cloud_noise` loading pattern):
   - Read `data/textures/weather/weather_map.raw`
   - Create `VkImage` (2D, 512x512, `VK_FORMAT_R8G8B8A8_UNORM`)
   - Create `VkImageView`
   - Upload via staging buffer
2. Add weather map descriptor binding (Binding 5 in cloud descriptor set):
   - `DescriptorSetLayout.hs:186` — add `weatherBinding` at binding 5
   - Same as existing texture bindings: `COMBINED_IMAGE_SAMPLER`, fragment stage
3. Update `updateCloudDescriptorSets` (`DescriptorSet.hs:497`) to accept and bind weather map view
4. Thread weather map view through `DeferredResources` creation
5. Store in `DeferredResources` as `drWeatherMapView`

### Current Binding Layout (do NOT change)
| Binding | Resource | Type |
|---------|----------|------|
| 0 | `env_map` | TextureCube RGBA8 |
| 1 | `cloud_noise` | Texture3D RGBA8 |
| 2 | `cloud_history` | Texture2D RGBA16F |
| 3 | `blue_noise` | Texture2D RGBA8 |
| 4 | `cloud_frame_data` | Uniform Buffer |
| **5** | **`weather_map`** | **Texture2D RGBA8 (NEW)** |

### Deliverables
- Weather map texture uploaded to GPU
- Descriptor binding 5 wired in cloud pass

### Files
- `src/Graphics/Haskan/Vulkan/DescriptorSetLayout.hs` — add binding 5
- `src/Graphics/Haskan/Vulkan/DescriptorSet.hs` — update cloud descriptor writes
- `src/Graphics/Haskan/Vulkan/DeferredResources.hs` — load texture, store view, thread to descriptor
- `src/Graphics/Haskan/Engine/Render.hs` — pass weather map view to resource creation

---

## Phase 3: Shader Integration — Weather Map Sampling
**Priority:** Critical — Core feature
**Estimate:** 2-3 hours
**Risk:** Medium — FIR shader changes, density formula modification

### Tasks
1. Add weather map texture declaration to `CloudFragmentDefs`:
   ```haskell
   "weather_map"
     ':-> Texture2D
            '[Binding 5, DescriptorSet 0]
            (RGBA8 UNorm),
   ```
2. In the ray march loop, before density computation, sample the weather map:
   ```haskell
   -- Weather map: massive scale, covers ~20km area
   let weatherScale = 0.00005  -- 1/20000
       weatherUV = Vec2 (px * weatherScale) (pz * weatherScale)
   ~(Vec4 weatherR weatherG weatherB _) <- use @(ImageTexel "weather_map") NilOps weatherUV
   ```
3. Replace fixed `cloudCoverage` with weather-modulated coverage:
   ```haskell
   let combinedCoverage = clamp (weatherR * cloudCoverage) 0.0 1.0
   ```
4. Replace fixed height mask with weather-driven height profile:
   ```haskell
   let cloudType = weatherG
       hMin = lerp 0.1 0.0 cloudType    -- stratus low, cumulus from ground
       hMax = lerp 0.4 1.0 cloudType    -- stratus caps early, cumulus towers
       heightMask = smoothstep hMin (hMin + 0.05) h
                  * (1.0 - smoothstep (hMax - 0.1) hMax h)
   ```
5. Replace density formula:
   ```haskell
   density = max 0 (nr * (1.0 - cloudDetail * (...)) - (1.0 - combinedCoverage))
           * heightMask
   ```
   Note: The document's formula divides by `combinedCoverage` for normalization. Add this if coverage transitions look harsh:
   ```haskell
   density = max 0 ((nr - (1.0 - combinedCoverage)) / max 0.01 combinedCoverage)
           * heightMask
   ```
6. Apply same weather sampling to the light march (for consistent coverage/height in shadow computation)

### Deliverables
- Clouds vary spatially: clear patches, scattered clusters, overcast sheets
- Different cloud types (stratus vs cumulus) in different sky regions
- `cloudCoverage` uniform still works as global intensity multiplier

### Files
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` — texture declaration, weather sampling, density formula

---

## Phase 4: Storm Darkness & Ambient Modulation
**Priority:** Medium — Visual polish
**Estimate:** 1-2 hours
**Risk:** Low — Additive changes to existing ambient term

### Tasks
1. Use weather map B channel to darken cloud bellies in storm regions:
   ```haskell
   let stormDarkness = weatherB
       -- Darken ambient in storm regions
       ambientTerm = ambientTerm ^* (1.0 - stormDarkness * 0.6)
   ```
2. Reduce direct light in storm regions:
   ```haskell
   let directLight = cloudBase ^* (lightT_d * phase * (1.0 - stormDarkness * 0.4))
   ```
3. Optional: increase `cloudAbsorption` in storm regions for thicker, darker clouds

### Deliverables
- Storm regions have darker, more ominous cloud bellies
- Clear sky regions remain bright
- Smooth transition between weather zones

### Files
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` — ambient and direct light modulation

### Depends On
- Phase 3

---

## Phase 5: Weather Map Wind Animation
**Priority:** Medium — Weather maps should drift with wind
**Estimate:** 1 hour
**Risk:** Low — Simple UV offset

### Tasks
1. Offset weather map UV by wind:
   ```haskell
   let windOffsetWX = time * 0.002 * windDirX  -- slow drift (4x slower than noise)
       windOffsetWZ = time * 0.002 * windDirZ
       weatherUV = Vec2 (px * weatherScale - windOffsetWX)
                       (pz * weatherScale - windOffsetWZ)
   ```
2. Verify temporal reprojection still works (weather map drifts with noise)

### Deliverables
- Weather zones drift slowly across the sky with wind

### Files
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` — weather UV offset

### Depends On
- Phase 3

---

## Phase 6: CPU-Side Weather State Control
**Priority:** Medium — Runtime weather control
**Estimate:** 2-3 hours
**Risk:** Low

### Tasks
1. Rename `cloudCoverage` TVar to `globalCoverage` (or add alias) — represents weather intensity, not local coverage
2. Add input controls:
   - `[` / `]` keys: decrease/increase `globalCoverage` (0.0–1.0)
   - Existing cloud presets (Shift+F1 etc.) set `globalCoverage` to appropriate values
3. Update cloud preset table (`Engine/Update.hs:155-161`):
   ```haskell
   -- (baseHeight, globalCoverage, detail, absorption)
   (1500.0, 0.30, 0.35, 1.5),  -- Cumulus (scattered)
   (800.0,  0.60, 0.20, 2.0),  -- Stratus (overcast)
   (1000.0, 0.40, 0.30, 1.5),  -- Stratocumulus
   (1000.0, 0.80, 0.50, 3.0),  -- Cumulonimbus (storm)
   (8000.0, 0.20, 0.60, 0.4)   -- Cirrus (wispy)
   ```
   Coverage values are now **multipliers** on the weather map, not absolute thresholds
4. Optional: Add weather state TVar for scripted weather transitions:
   ```haskell
   weatherState :: TVar WeatherState  -- Clear | Fair | Overcast | Storm
   ```
   Lerp `globalCoverage` between states over time

### Deliverables
- `[`/`]` keys control weather intensity at runtime
- Cloud presets tuned for weather map usage
- Clear visual difference between 0.0 (clear) and 1.0 (storm)

### Files
- `src/Graphics/Haskan/Engine/Types.hs` — TVars
- `src/Graphics/Haskan/Engine/Update.hs` — input handling, presets
- `src/Graphics/Haskan/Input.hs` — key bindings

### Depends On
- Phase 3

---

## Phase 7: Weather Map Regeneration & Validation
**Priority:** Low — Polish
**Estimate:** 1-2 hours
**Risk:** None

### Tasks
1. Generate multiple weather map variants (clear day, overcast, storm front)
2. Add CLI option or runtime hot-reload for weather map (`--weather-map PATH`)
3. Validate temporal stability — weather zones shouldn't cause flickering
4. Verify weather map works with all existing debug modes (13.0, 14.0, 15.0)
5. Add debug mode 16.0: visualize weather map coverage (R channel) as overlay

### Deliverables
- Multiple weather map presets
- Debug visualization for weather map
- No temporal artifacts from weather map sampling

### Files
- `scripts/generate_weather_map.py` — preset variants
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` — debug mode 16.0
- `src/Graphics/Haskan/Input.hs` — debug mode key binding

### Depends On
- Phase 3, Phase 4

---

## Summary: Effort & Timeline

| Phase | Task | Est. Hours | Risk | Dependencies |
|-------|------|-----------|------|--------------|
| 1 | Weather map texture generator | 2.5h | Low | None |
| 2 | GPU resource setup (binding 5) | 2.5h | Low | None (parallel with Phase 1) |
| 3 | Shader integration | 2.5h | Medium | Phase 1 + 2 |
| 4 | Storm darkness modulation | 1.5h | Low | Phase 3 |
| 5 | Wind animation | 1h | Low | Phase 3 |
| 6 | CPU weather controls | 2.5h | Low | Phase 3 |
| 7 | Validation & debug | 1.5h | None | Phase 3-5 |
| **Total** | | **~14h** | | |

## Recommended Order
1. **Phase 1 + Phase 2** in parallel — generator script + GPU plumbing
2. **Phase 3** — core shader integration (biggest visual change)
3. **Phase 4 + Phase 5** together — both are small shader additions
4. **Phase 6** — CPU controls (can be done anytime after Phase 3)
5. **Phase 7** — polish and validation

## Impact on Existing Code

| Area | Change |
|------|--------|
| Shader (`Clouds.hs`) | Add 1 texture binding, ~20 lines for weather sampling + density formula |
| Descriptor layout | Add binding 5 (1 new `VkDescriptorSetLayoutBinding`) |
| Descriptor update | Add 1 write for weather map view |
| Deferred resources | Load 1 additional 2D texture at startup |
| CPU state | Rename/reuse `cloudCoverage` as `globalCoverage` multiplier |
| Input | 2 new key bindings (`[`/`]`) |
| No changes to | G-buffer, lighting shader, mesh, camera, ECS, render graph |

## What `cloudCoverage` Becomes

| Before (current) | After (weather map) |
|-------------------|---------------------|
| Uniform threshold everywhere | `globalCoverage` multiplier on weather map R channel |
| 0.45 = same density everywhere | 0.45 = 45% of weather map's local coverage |
| No spatial variation | Spatial variation from weather map |
| Presets change threshold | Presets change multiplier (same values work differently) |

## Key Design Decisions
1. **Weather map at Binding 5** — slots 0-4 are taken, 5 is next available
2. **512x512 resolution** — sufficient for 20km coverage at ~40m/pixel
3. **RGBA8 format** — 8 bits per channel is enough for coverage/type/storm
4. **`noiseScale = 0.00005`** for weather map — covers 20km before tiling (vs 0.0003 for noise = 3.3km)
5. **Wind drift 4x slower than noise** — weather zones are macro-scale, should move slowly
6. **Division by `combinedCoverage`** in density formula — normalizes transition sharpness across all coverage levels (from the document's recommendation)
