# Cloud Rendering Roadmap

## Current: 3-Step Ray Marcher (Implemented)

### Features
- **World-space ray-plane intersection** at cloud layer (y = 150-250)
- **3 march steps** along view ray through cloud volume
- **2-step light march** toward sun per sample (single-octave noise for performance)
- **Beer-Lambert transmittance** for volume absorption
- **Modified Beer (powder effect)** using `max(exp(-d*15), 0.7*exp(-d*0.25))`
- **Henyey-Greenstein phase function** with g = 0.3 for forward scattering
- **Height-based density modulation** (more clouds in middle of layer)
- **Sun direction from push constants** (reused from day/night cycle)

### Performance
- `light_frag.spv`: ~7,800 SPIR-V instructions
- Init time: ~5 seconds
- Safe margin under ID bound (7,904 vs 4,194,303 limit)

## Phase 2: 6-Step Ray Marcher (Planned)

### Improvements
- **Double ray steps** (3 → 6) for smoother volume gradient
- **Step size**: ~16.7m per step (100m layer / 6)
- **Reduced banding** when camera approaches cloud layer
- **Better light shaft definition** from finer transmittance variation

### Performance Impact
- Estimated ~12,000-14,000 SPIR-V instructions
- Still well within safe limits
- Init time: ~8-10 seconds

### Implementation Notes
- Copy current `cloudStep` logic, add steps 3, 4, 5
- Same light march (2 steps) per sample
- No new math functions needed

## Phase 3: Quality Improvements (Future)

### 3D Noise Textures
- Replace procedural `fbm3D` with precomputed 3D texture lookup
- Reduce fragment shader from ~7,800 to ~2,000 instructions
- Enable more octaves / worley noise without cost explosion
- Requires: texture loading, 3D texture support in FIR

### Temporal Accumulation
- Render clouds at half resolution in compute shader
- Jitter ray origin per frame, accumulate with exponential moving average
- Eliminates banding without adding more ray steps
- Requires: compute shader pipeline, ping-pong textures

### Multiple Scattering
- Secondary ray march from each step toward hemisphere of directions
- Precompute in spherical harmonics or baked into 3D texture
- Gives clouds their characteristic "glow" from internal scattering
- Expensive; usually done offline or in temporal pass

### Wind Animation
- Offset sample positions by `windDir * speed * time`
- Simple addition to sample position calculation
- Can reuse existing `time` uniform or add `cloudTime` push constant

### Atmospheric Scattering Integration
- Use Preetham/Hosek sky model instead of cubemap skybox
- Cloud color naturally blends with physically-computed sky gradient
- Removes "clouds on top of skybox" layering artifact

## Technical Constraints

### FIR Limits
- SPIR-V ID bound: 4,194,303 (we're at ~8,000)
- `exp`, `pow` (`**`), `sin`, `cos`, `clamp`, `mix`, `smoothstep` all available
- No loops in `let` blocks (must unroll manually)
- `def` workaround or StableName memoization essential for shared AST nodes

### Performance Budget
- Target: < 15,000 instructions for lighting fragment shader
- Current 3-step: ~7,800 instructions (good headroom)
- 6-step target: ~13,000 instructions (still safe)
- Compute shader offload would bring this down to ~3,000
