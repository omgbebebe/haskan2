# Cloud Lighting: Ambient Energy & Multiple Scattering Milestone

## Objective
Fix dark cloud interiors by adding height-graded ambient illumination and multi-scattering octave approximation to the existing cloud ray march in `Clouds.hs`.

## Problem
The current illumination model (`Clouds.hs:366`) is **purely single-scattered direct light**:
```haskell
s_scatter = cloudBase ^* (lightT_d * phase * density * adaptiveStepSize)
```

No ambient term exists. Thick cloud bellies and interior cavities that the 4-step light march can't reach render jet-black because single-scattering Beer's Law treats all bounced energy as lost. Real clouds have albedo ~0.99 — photons bounce many times internally, illuminating from within.

## Already Implemented (do NOT touch)

| Feature | Location | Status |
|---------|----------|--------|
| Dynamic ray march loop (24-64 adaptive steps) | `Clouds.hs:293-375` | Done |
| Nested 4-step light march with domain warp | `Clouds.hs:325-359` | Done |
| Beer-Powder transmittance | `Clouds.hs:362-364` | Done — will be replaced |
| Dual-plane slab intersection | `Clouds.hs:248-258` | Done |
| Dual-lobe Henyey-Greenstein phase | `Clouds.hs:286-290` | Done |
| 2-octave domain warping | `Clouds.hs:305-313` | Done |
| Height mask | `Clouds.hs:321` | Done |
| Wind-aware temporal reprojection | `Clouds.hs:396-441` | Done |
| Blue noise dithering | `Clouds.hs:261-263` | Done |

---

## Phase 1: Height-Graded Ambient Term
**Priority:** High — Biggest visual impact for least code
**Estimate:** 30 minutes
**Risk:** None — Pure additive term, no structural changes

### What
Add a vertical gradient ambient that simulates ground-reflected light at cloud base and sky scatter at cloud top. Integrated into the radiance accumulation without any additional texture samples or light march steps.

### Math
```
I_ambient(h) = lerp(ground_albedo, sky_color, h) * AmbientStrength
I_step = (I_sun * Phase * ShadowTransmittance) + (I_ambient(h) * Density)
```

Where `h` is the normalized height within the cloud layer (0.0 at bottom, 1.0 at top), already computed at `Clouds.hs:320`.

### Implementation

After the `heightMask` computation (line 321), add ambient term:

```haskell
-- Height-graded ambient: warm ground bounce at bottom, cool sky scatter at top
let groundAmbient = Vec3 0.35 0.30 0.25
    skyAmbient    = Vec3 0.50 0.60 0.80
    ambientTerm   = lerp groundAmbient skyAmbient h ^* 0.18
```

Modify the scatter accumulation (currently line 366). Change from:
```haskell
let s_scatter = cloudBase ^* (lightT_d * phase * density * adaptiveStepSize)
```
To:
```haskell
let directLight  = cloudBase ^* (lightT_d * phase)
    s_scatter = (directLight + ambientTerm) ^* (density * adaptiveStepSize)
```

### Deliverables
- Cloud bottoms show warm ground-bounce illumination instead of black
- Cloud tops show cool sky-scatter tint
- No additional GPU cost (0 texture samples, 1 lerp, 1 add per step)

### Files
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` — lines ~321, ~366

### Tuning Parameters
| Parameter | Default | Range | Effect |
|-----------|---------|-------|--------|
| `groundAmbient` | `Vec3 0.35 0.30 0.25` | — | Warm ground bounce color (lower clouds) |
| `skyAmbient` | `Vec3 0.50 0.60 0.80` | — | Cool sky scatter color (upper clouds) |
| `AmbientStrength` | `0.18` | 0.05–0.30 | Overall ambient intensity |

---

## Phase 2: Multiple Scattering Octave Approximation
**Priority:** High — Fixes dark interiors in thick cloud masses
**Estimate:** 30 minutes
**Risk:** Low — Replaces existing 2-term Beer-Powder with 3-term sum

### What
Replace the current 2-term Beer-Powder model with a 3-octave cascading attenuation (Schneider-Villanueva trick). Each octave represents a deeper scattering bounce where effective density is lower, forcing thin/medium sections to illuminate from within.

### Math (current — 2-term Beer-Powder)
```
b = exp(-density * σ)
p = 0.7 * exp(-density * σ * 0.167)
lightT = max(b, p)
```

### Math (new — 3-octave multi-scatter)
```
E_multi = Σ_{k=0}^{2} a^k * exp(-density * σ * b^k)
  a = 0.50  (energy attenuation per bounce)
  b = 0.25  (density attenuation per bounce)

= exp(-d*σ*1.00) * 1.00    -- primary scatter
+ exp(-d*σ*0.25) * 0.50    -- secondary (deeper penetration)
+ exp(-d*σ*0.05) * 0.25    -- tertiary (deepest penetration)
```

This sum is always >= the current `max(b,p)`, so clouds will never be darker than before. The additional terms add translucency to medium-density regions.

### Implementation

Replace lines 362-364. Change from:
```haskell
finalLightDensity <- get @"lightDensity"
let lightT_d = let b = exp (-finalLightDensity * cloudAbsorption)
                   p = 0.7 * exp (-finalLightDensity * cloudAbsorption * 0.167)
               in max b p
```
To:
```haskell
finalLightDensity <- get @"lightDensity"
let d = finalLightDensity * cloudAbsorption
    ms0 = exp (-d * 1.0)           -- primary scatter
    ms1 = exp (-d * 0.25) * 0.5    -- secondary scatter
    ms2 = exp (-d * 0.05) * 0.25   -- tertiary scatter
    lightT_d = ms0 + ms1 + ms2
```

### Deliverables
- Thick cloud masses show internal illumination (no longer jet-black bellies)
- Thin cloud edges glow translucently
- Medium-density regions show depth and volume
- Same GPU cost (3 `exp` calls instead of 2 — negligible)
- `cloudAbsorption` uniform (already in `CloudFrameData`) still controls overall extinction

### Files
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` — lines ~362-364

### Tuning Parameters
| Parameter | Default | Effect |
|-----------|---------|--------|
| `a` (energy attenuation) | `0.5, 0.25` | How much energy each octave contributes. Lower = more internal glow |
| `b` (density attenuation) | `1.0, 0.25, 0.05` | How much each octave reduces effective density. Smaller spread = deeper penetration |
| `cloudAbsorption` (existing uniform) | `0.04` | Overall extinction coefficient — higher = darker clouds overall |

---

## Phase 3: Day-Night Cycle Integration
**Priority:** Medium — Ambient colors should respond to time of day
**Estimate:** 1-2 hours
**Risk:** Low — Read existing time-of-day state, modulate ambient colors

### What
The ambient term colors should shift with the day-night cycle:
- **Noon**: bright ambient, neutral white sky scatter
- **Golden hour**: warm orange ground, pink-gold sky
- **Sunset/twilight**: deep orange ground, navy sky
- **Night**: dim blue moonlight ambient, near-zero intensity

### Implementation

The `CloudFrameData` already has `sunDir` (which encodes time of day via its Y component). Use it to modulate the ambient colors computed in Phase 1:

```haskell
-- sunDir.Y encodes elevation: 1.0 = zenith, 0.0 = horizon, <0 = below horizon
let sunElevation = sunDirY  -- already extracted at line 234
    dayFactor = smoothstep (-0.1) 0.3 sunElevation

    -- Noon ambient
    noonGround  = Vec3 0.35 0.30 0.25
    noonSky     = Vec3 0.50 0.60 0.80
    -- Sunset ambient
    sunsetGround = Vec3 0.50 0.25 0.10
    sunsetSky    = Vec3 0.40 0.25 0.35
    -- Night ambient (moonlight)
    nightGround = Vec3 0.02 0.02 0.04
    nightSky    = Vec3 0.03 0.04 0.08

    groundAmbient = lerp nightGround (lerp sunsetGround noonGround dayFactor) (smoothstep 0.0 0.15 sunElevation)
    skyAmbient    = lerp nightSky    (lerp sunsetSky    noonSky    dayFactor) (smoothstep 0.0 0.15 sunElevation)
    ambientStrength = 0.18 * max 0.05 dayFactor
    ambientTerm = lerp groundAmbient skyAmbient h ^* ambientStrength
```

No new uniforms needed — `sunDir` already exists in `CloudFrameData`.

### Deliverables
- Clouds lit appropriately at all times of day
- No glowing clouds at midnight
- Warm sunset coloring on cloud bellies

### Files
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` — ambient term computation

### Depends On
- Phase 1 (ambient term must exist first)

---

## Phase 4: Visual Tuning & Validation
**Priority:** Medium — Ensure quality across all conditions
**Estimate:** 1-2 hours
**Risk:** None — Parameter tweaking only

### Tasks
1. Test with all existing debug modes (13.0=cloud density, 14.0=height mask, 15.0=raw noise)
2. Test camera positions: ground, inside cloud layer, above clouds
3. Test time of day: noon, golden hour, sunset, night
4. Verify temporal accumulation still works (no new ghosting from ambient changes)
5. Screenshot comparison before/after
6. Tune `cloudAbsorption` default if needed (may need to increase slightly to compensate for brighter multi-scatter)

### Tuning Matrix
| Scenario | Adjust | Direction |
|----------|--------|-----------|
| Clouds too bright/washed out | `ambientStrength` | Decrease from 0.18 |
| Clouds still too dark at belly | `a` coefficients | Increase from 0.5/0.25 |
| Too much forward scatter glow | `b` spread | Narrow from 0.25/0.05 |
| Night clouds glowing | `dayFactor` threshold | Increase smoothstep lower bound |

### Files
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` — parameter tuning

### Depends On
- Phase 1, Phase 2, Phase 3

---

## Summary: Effort & Timeline

| Phase | Task | Est. Time | Risk | Dependencies |
|-------|------|-----------|------|--------------|
| 1 | Height-graded ambient term | 30 min | None | None |
| 2 | Multi-scattering octaves | 30 min | None | None |
| 3 | Day-night cycle integration | 1.5 h | Low | Phase 1 |
| 4 | Visual tuning & validation | 1.5 h | None | Phase 1-3 |
| **Total** | | **~4h** | | |

## Recommended Order
1. **Phase 1 + Phase 2** together — both are <30 min each, no dependencies, can be done in one pass
2. **Phase 3** — build on ambient term
3. **Phase 4** — final polish

## Impact on Existing Code
- **No new GPU resources** (no textures, no render passes, no descriptor sets)
- **No new uniforms** (ambient is computed from existing `sunDir` + `h`)
- **No new loops** (ambient is O(1) ALU per step)
- **No changes outside `Clouds.hs`** (everything is in the fragment shader)
- **`cloudAbsorption` uniform behavior changes slightly** — multi-scatter sum always >= old max(b,p), so same absorption value produces brighter clouds. May need to increase default from 0.04 to ~0.06.

## Reference
Source analysis document: `.opencode/clouds_lighting_issues.tex`
