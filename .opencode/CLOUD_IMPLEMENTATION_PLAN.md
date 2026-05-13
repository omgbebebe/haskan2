# Cloud Rendering Implementation Plan

## Current State

### What Works
- 6-step ray marcher through 800m cloud layer (`Lighting.hs:188-399`)
- 3D noise texture (128³ RGBA8) with tileable multi-frequency Worley
  - R: low-freq shape (4³ cells), G: med detail (8³), B: fine detail (16³), A: Perlin
- Front-to-back Beer-Lambert compositing
- HG phase function (g=0.3), modified Beer's law (powder effect)
- Height-based density falloff (smoothstep 0-15% / 85-100%)
- Push constant `cloudHeight` controls layer altitude (keyboard `[`/`]`)
- Coordinate wrapping via `fract()` (sampler is CLAMP_TO_EDGE, shared with all textures)
- Domain warp via sin/cos displacement breaks regular grid

### Known Issues
- **6 visible horizontal slices** — fixed step offsets (0.5, 1.5, 2.5...) create banding
- **Hardcoded light march** — `lightDensity = 0.3` constant, no self-shadowing from texture
- **No wind/dynamics** — static texture, no time-based offset
- **No empty-space skipping** — every background pixel does 6 texture samples
- **Full-resolution** — clouds computed per-fragment, no temporal accumulation

---

## Phase 0: Split Monolithic Shader (Code Hygiene)

**Goal**: Break `Lighting.hs` (~837 lines) into logical Haskell modules.
Pure refactoring — no SPIR-V output changes, no visual changes.

**Constraint**: Only `let`-level pure code can be extracted. Monadic actions
(`use`, `get`, `assign`) must stay in the main `shader do` block because FIR's
`Program` indexed monad makes monadic helpers impractical.

**Module structure**:

```
Shaders/Deferred/
  Lighting.hs        -- main orchestrator (~200 lines)
  Types.hs           -- push constant types, FragmentDefs
  Cloud.hs           -- cloud coordinate computation, density, compositing
  PBR.hs             -- PBR lighting (Cook-Torrance BRDF, light accumulation)
  IBL.hs             -- image-based lighting (irradiance, specular, BRDF LUT)
  Debug.hs           -- debug mode selection/output
```

**What moves where**:

| Module | Current lines | What it contains |
|--------|--------------|-----------------|
| `Types.hs` | 1-130 | `CameraPushConstant`, `FragmentDefs`, debug mode constants |
| `Cloud.hs` | 188-399 | `computeSamplePositions`, `computeDensities`, `compositeClouds` — all pure `Code Float → Code Float` functions |
| `PBR.hs` | ~400-580 | `cookTorranceBRDF`, `accumulateLights` (4 unrolled lights) |
| `IBL.hs` | ~580-660 | `diffuseIBL`, `specularIBL`, Fresnel, BRDF LUT sampling |
| `Debug.hs` | ~700-800 | Debug mode selection logic, output routing |
| `Lighting.hs` | remaining | `shader do` block: read inputs → call helpers → write output |

**Cloud.hs example**:
```haskell
module Cloud where

data CloudParams = CloudParams
  { cpDirX, cpDirY, cpDirZ    :: Code Float
  , cpCamX, cpCamY, cpCamZ    :: Code Float
  , cpCloudBottom              :: Code Float
  , cpSunDirX, cpSunDirY, cpSunDirZ :: Code Float
  }

data CloudStep = CloudStep
  { csSx, csSy, csSz :: Code Float  -- warped texture coords (for monadic sampling)
  , csHeightF        :: Code Float   -- height factor
  }

computeSteps :: CloudParams -> [CloudStep]
computeSteps params = ...

computeDensity :: Code Float -> Code Float -> Code Float -> Code Float
computeDensity shape medDetail fineDetail = ...

compositeClouds :: [Code Float] -> Code Float -> ... -> CloudResult
compositeClouds densities stepSize ... = ...
```

**Lighting.hs becomes**:
```haskell
fragment = shader do
  -- Monadic: read inputs
  uv <- get @"in_uv"
  rayDir <- get @"in_ray"
  cameraPos <- get @"cameraPos"

  -- Monadic: texture samples
  ~(Vec4 posX ...) <- use @(ImageTexel "gbuf_position") NilOps uv
  ...
  -- Cloud texture samples using coords from Cloud.computeSteps
  let cloudSteps = Cloud.computeSteps params
  ~(Vec4 n0r ...) <- use @(ImageTexel "cloud_noise") NilOps (Vec3 (csSx s0) ...)

  -- Pure: all computation
  let cloudResult = Cloud.compositeClouds densities ...
      litColor = PBR.accumulateLights material lights ...
      iblColor = IBL.specularIBL ...
      finalColor = Debug.selectOutput debugMode ...

  -- Monadic: write output
  assign @"out_colour" (Vec4 finalR finalG finalB 1.0)
```

**Files**:
- New: `Shaders/Deferred/Cloud.hs`, `PBR.hs`, `IBL.hs`, `Debug.hs`, `Types.hs`
- Modify: `Lighting.hs` — strip to orchestrator, import modules

**Cost**: Zero SPIR-V change (pure Haskell refactoring)
**Risk**: Low — same `Code Float` types, same AST, same compiled output
**Effort**: ~2 hrs (mechanical extraction, verify identical SPIR-V)

---

## Phase 1: Blue Noise Dithering (Quick Win)

**Goal**: Eliminate 6-slice banding by jittering ray start offset per-pixel.

**Approach**: Hash-based dithering (no extra texture needed):
```haskell
let -- Blue noise approximation: screen-space hash
    hash2d = fract (sin (uvX * 12.9898 + uvY * 78.233) * 43758.5453)
    jitter = hash2d  -- [0, 1)
    -- Offset all step positions by jittered fraction of stepSize
    jOffset = jitter * stepSize
    p0x = entryX + dirX * (stepSize * 0.5 + jOffset)
    p1x = entryX + dirX * (stepSize * 1.5 + jOffset)
    ... (same for all 6 steps)
```

**Files**: `Lighting.hs` — add hash, add `jOffset` to each step position
**Cost**: ~5 SPIR-V ops per pixel (sin, fract, multiply)
**Impact**: Transforms hard slice boundaries into smooth gradients

---

## Phase 2: Wind Animation

**Goal**: Clouds drift over time.

**Approach**: Offset sample coordinates by `windDir * speed * time`:
```haskell
-- New push constant fields (add to CameraPushConstant):
--   "windDirX" ':-> Float
--   "windDirZ" ':-> Float
--   "cloudTime" ':-> Float
-- Then in shader:
let windX = windDirX * cloudTime * 0.5  -- slow drift
    windZ = windDirZ * cloudTime * 0.5
    -- Add to sample positions BEFORE fract():
    s0x = fract ((p0x + w0x + windX) * noiseScale)
    s0z = fract ((p0z + w0z + windZ) * noiseScale)
```

**Files**:
- `Lighting.hs` — add push constant fields, offset coords
- `Deferred.hs` — add wind params to `DeferredPassData`, push constant array
- `Engine/Update.hs` — keyboard toggle or automatic wind
- `Types.hs` — add TVars for wind state

**Cost**: 2 adds per coordinate × 6 steps × 3 axes = 36 SPIR-V ops
**Impact**: Dynamic, living sky — the single biggest visual improvement

---

## Phase 3: Texture-Sampled Light March

**Goal**: Replace hardcoded `lightDensity = 0.3` with actual texture-based self-shadowing.

**Approach**: For each ray step, sample the 3D texture at `position + sunDir * lightStep`:
```haskell
-- Per ray step, sample 2 additional positions toward sun:
-- l0 = sample at (pos + sunDir * 80m)  -- mid cloud
-- l1 = sample at (pos + sunDir * 160m) -- near top
-- lightDensity = (l0.r + l1.r) * 0.5
```

This doubles the texture samples per pixel (6 → 18 total), but with the memo fix
the instruction count stays manageable (~5,000-6,000 ops estimated).

**Files**: `Lighting.hs` — add 12 more `use @(ImageTexel "cloud_noise")` calls
**Cost**: 12 additional texture samples (monadic `<-` binds)
**Impact**: Self-shadowing, silver lining effect, dramatically more realistic

---

## Phase 4: Quarter-Resolution Rendering

**Goal**: Render clouds at 1/4 resolution, upsample to full screen.

**Approach**:
1. New render pass before lighting: quarter-res fragment shader outputs cloud color + transmittance to two R16F textures
2. Lighting shader samples these textures instead of computing clouds inline
3. Bilinear upsampling during the sample handles smooth interpolation

**Files**:
- New: `CloudPass.hs` — quarter-res cloud fragment shader
- `Deferred.hs` — add cloud pass to render graph
- `Render.hs` — allocate 1/4 res targets, integrate pass
- `Lighting.hs` — remove inline cloud code, sample cloud textures instead

**Cost**: ~6.25% of current per-pixel cost (1/16 pixels)
**Impact**: Enables 12+ ray steps with light march at same frame budget

---

## Phase 5: Empty Space Skipping

**Goal**: Skip ray march for pixels with zero cloud coverage.

**Approach**:
1. Generate a 2D "weather map" texture (64×64, R8) — low-freq coverage
2. Sample in shader: `coverage = textureLod(weatherMap, pos.xz * scale, 0).r`
3. If `coverage < 0.01`, skip all 6 ray steps (output raw skybox)

**Files**:
- `scripts/generate_weather_map.py` — generate 2D coverage texture
- `Lighting.hs` — add weather map sample, conditional skip
- `Texture.hs` — load 2D texture
- `DescriptorSet*.hs` — add binding

**Cost**: 1 texture sample per pixel for skip decision, saves 6 samples for ~50% of sky
**Impact**: ~40-50% reduction in cloud computation cost

---

## Phase 6: Temporal Accumulation

**Goal**: Eliminate banding entirely with sub-pixel jitter across frames.

**Approach**:
1. Jitter ray origin differently each frame (blue noise offset + frame counter)
2. Blend result with previous frame's cloud buffer (exponential moving average, α=0.1)
3. Requires quarter-res render target (Phase 4) + history buffer

**Files**: Depends on Phase 4 infrastructure
**Cost**: 1 extra texture read + blend per pixel
**Impact**: Smooth, banding-free clouds with only 4-6 ray steps

---

## Implementation Priority

| Phase | Effort | Impact | Dependencies |
|-------|--------|--------|-------------|
| 0. Split shader | 2 hrs | Dev velocity | None |
| 1. Blue noise dither | 30 min | High (fixes banding) | None |
| 2. Wind animation | 2 hrs | High (dynamic sky) | Push constant changes |
| 3. Light march | 1 hr | Medium (self-shadowing) | None |
| 4. Quarter-res | 4 hrs | High (perf) | New render pass |
| 5. Empty space skip | 2 hrs | Medium (perf) | Weather map texture |
| 6. Temporal accum | 3 hrs | Medium (quality) | Phase 4 |

**Recommended order**: 0 → 1 → 2 → 3 → 4 → 6 → 5

Phase 5 (empty space skip) is least important because with quarter-res rendering
the per-pixel cost is already low. Phase 6 (temporal) depends on Phase 4 infrastructure.

---

## Push Constant Layout (after Phase 2)

```haskell
type CameraPushConstant = Struct
  '[ "cameraX"      ':-> Float      -- 0
   , "cameraY"      ':-> Float      -- 4
   , "cameraZ"      ':-> Float      -- 8
   , "debugMode"    ':-> Float      -- 12
   , "axisOverlay"  ':-> Float      -- 16
   , "groundPlane"  ':-> Float      -- 20
   , "sunAzimuth"   ':-> Float      -- 24
   , "lightCount"   ':-> Float      -- 28
   , "ray0"         ':-> V 3 Float  -- 32  (align 16, size 12)
   , "ray1"         ':-> V 3 Float  -- 48  (align 16, size 12)
   , "ray2"         ':-> V 3 Float  -- 64  (align 16, size 12)
   , "skyTintR"     ':-> Float      -- 76
   , "skyTintG"     ':-> Float      -- 80
   , "skyTintB"     ':-> Float      -- 84
   , "iblIntensity" ':-> Float      -- 88
   , "sunDir"       ':-> V 3 Float  -- 96  (align 16, size 12)
   , "cloudHeight"  ':-> Float      -- 108
   -- Phase 2 additions:
   -- "cloudTime"    ':-> Float      -- 112
   -- "windDirX"     ':-> Float      -- 116
   -- "windDirZ"     ':-> Float      -- 120
   ]
```

**Important**: std430 layout — `V 3 Float` has size=12, align=16. No padding after vec3
when followed by a scalar. Total = 112 bytes (Phase 1), 124 bytes (Phase 2).
CPU side must match FIR's layout exactly (see `Deferred.hs` push constant array).

---

## Shader Instruction Budget

| Config | Steps | Texture samples | Estimated SPIR-V ops |
|--------|-------|-----------------|---------------------|
| Current (6 steps, no light march) | 6 | 6 | ~3,000 |
| + Blue noise | 6 | 6 | ~3,010 |
| + Wind | 6 | 6 | ~3,050 |
| + Light march (2 per step) | 6 | 18 | ~5,500 |
| Quarter-res (12 steps + light) | 12 | 36 | ~8,000 (at 1/4 res) |

Well within the ~2,800 ops baseline (pre-cloud) + budget. The memo fix ensures
no exponential blowup.
