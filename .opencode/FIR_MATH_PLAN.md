# FIR Math Extension Plan

## Goal
Implement missing GLSL-standard math functions in FIR so we can build proper volumetric clouds, dynamic sky models, cubemap rotation, and grid effects without workarounds.

## Missing Functions (by priority)

### P0 — Blocking M10.4 Clouds + Sky
1. **`sin :: Code Float -> Code Float`** — Sine for noise, spherical coords
2. **`cos :: Code Float -> Code Float`** — Cosine for noise, spherical coords  
3. **`atan2 :: Code Float -> Code Float -> Code Float`** — Arctangent(y,x) for spherical UV conversion
4. **`pow :: Code Float -> Code Float -> Code Float`** — Power for contrast, falloff curves
5. **`clamp :: Code Float -> Code Float -> Code Float -> Code Float`** — Clamp for bounds
6. **`smoothstep :: Code Float -> Code Float -> Code Float -> Code Float`** — Smooth interpolation for noise, edges
7. **`mix :: Code Float -> Code Float -> Code Float -> Code Float`** — Linear interpolation (lerp)

### P1 — Blocking M10.3 IBL Fix + Grid
8. **`floor :: Code Float -> Code Float`** — Floor for grid cells, integer quantization
9. **`fract :: Code Float -> Code Float`** — Fractional part for repeating patterns
10. **`step :: Code Float -> Code Float -> Code Float`** — Step function for hard thresholds
11. **`sign :: Code Float -> Code Float`** — Sign function for directional logic

### P2 — Nice to Have
12. **`asin :: Code Float -> Code Float`** — Arcsine for elevation angles
13. **`acos :: Code Float -> Code Float`** — Arccosine for angle computation
14. **`tan :: Code Float -> Code Float`** — Tangent for projections
15. **`mod :: Code Float -> Code Float -> Code Float`** — Float modulo for repeating coordinates

## Implementation Strategy

### Where to Add
FIR math is defined in `3rdparty/fir/src/FIR/Syntax/AST.hs` and SPIR-V ops in `3rdparty/fir/src/SPIRV/Operation.hs`.

### Step 1: SPIR-V Operation Definitions
Add to `3rdparty/fir/src/SPIRV/Operation.hs`:

```haskell
pattern FAbs         = Code  4   -- already exists
pattern FSign        = Code  6   -- already exists  
pattern FFloor       = Code  8   -- already exists
pattern FCeil        = Code  9
pattern FFract       = Code 10
pattern FSin         = Code 13
pattern FCos         = Code 14
pattern FTan         = Code 15
pattern FAsin        = Code 16
pattern FAcos        = Code 17
pattern FAtan        = Code 18
pattern FAtan2       = Code 19  -- extended instruction set
pattern FExp         = Code 20  -- already exists
pattern FLog         = Code 21
pattern FPow         = Code 26
pattern FMix         = Code 46
pattern FStep        = Code 48
pattern FSmoothStep  = Code 49
```

Note: `atan2`, `sin`, `cos` may require **GLSL.std.450 extended instruction set** instead of core SPIR-V. Need to check FIR's current approach.

### Step 2: FIR AST Integration
In `3rdparty/fir/src/FIR/Syntax/AST.hs`, add to the `Floating` typeclass or create new typeclass:

```haskell
class PrimTy a => Trig a where
  sin :: Code a -> Code a
  cos :: Code a -> Code a
  tan :: Code a -> Code a

class PrimTy a => Angles a where
  asin :: Code a -> Code a
  acos :: Code a -> Code a
  atan2 :: Code a -> Code a -> Code a

class PrimTy a => AdvancedMath a where
  pow :: Code a -> Code a -> Code a
  clamp :: Code a -> Code a -> Code a -> Code a
  mix :: Code a -> Code a -> Code a -> Code a
  step :: Code a -> Code a -> Code a
  smoothstep :: Code a -> Code a -> Code a -> Code a
  floor :: Code a -> Code a  -- already exists for Integral, add for Float
  fract :: Code a -> Code a
  mod :: Code a -> Code a -> Code a
```

### Step 3: Code Generation
In `3rdparty/fir/src/CodeGen/Prim.hs` or similar, map FIR AST nodes to SPIR-V instructions.

For core SPIR-V ops (`FAbs`, `FFloor`, `FSin`, `FCos`, `FPow`, `FStep`, `FSmoothStep`, `FMix`):
- Direct 1:1 mapping to `OpExtInst` with GLSL.std.450

For `atan2`:
- GLSL.std.450 `Atan2` (instruction 25)
- Requires importing extended instruction set

### Step 4: Testing
Create test shader in `3rdparty/fir/fir-examples`:
```haskell
-- Test sin/cos in fragment shader
fragment = shader do
  let x = sin 1.0
      y = cos 1.0
      z = atan2 y x
      w = pow x 2.0
      c = clamp x 0.0 1.0
      s = smoothstep 0.0 1.0 x
      m = mix x y 0.5
  put @"out_color" (Vec4 x y z 1.0)
```

## File Changes Required

1. `3rdparty/fir/src/SPIRV/Operation.hs` — Add operation patterns
2. `3rdparty/fir/src/FIR/Syntax/AST.hs` — Add typeclasses and instances
3. `3rdparty/fir/src/FIR.hs` — Re-export new functions
4. `3rdparty/fir/src/CodeGen/Prim.hs` — Add code generation mappings
5. `3rdparty/fir/fir-examples/examples/shaders/TestMath.hs` — Test shaders

## Post-FIR: What Becomes Possible

### Immediate (same session)
1. **Fix M10.3 IBL**: Rotate cubemap sampling by sun azimuth using `sin`/`cos` matrix
2. **1-unit grid cells**: Use `floor` in lighting shader for debug grid overlay
3. **Clouds v0.1**: Screen-space 2D cloud layers with animated UV distortion

### Next Session
4. **Volumetric clouds**: Raymarched 3D noise in fullscreen pass using `sin`/`cos` for spherical coordinates, `pow`/`smoothstep` for density shaping
5. **Procedural sky**: Hosek-Wilkie or Preetham analytic model with `pow`, `clamp`, `smoothstep`
6. **Better grid overlay**: Proper `floor`-based grid with `step` for anti-aliased lines

## Risk Assessment

- **Low risk**: `floor`, `fract`, `step`, `clamp`, `mix` — these exist in SPIR-V core or GLSL.std.450
- **Medium risk**: `sin`, `cos`, `pow` — may require GLSL.std.450 extended instruction set; FIR may not currently support this
- **Higher risk**: `atan2` — definitely requires extended instruction set; need to verify FIR's extinst support

## Mitigation

If FIR doesn't support extended instruction sets:
1. Implement `sin`/`cos` via Taylor series approximation in FIR (slow but works)
2. Implement `atan2` via CORDIC or lookup table
3. Use `pow(a,b) = exp(b * log(a))` if `exp`/`log` exist

But given FIR already has `exp` and `floor`, it likely supports GLSL.std.450.

## Verification Steps

1. Add one function (e.g., `sin`) end-to-end
2. Compile test shader to SPIR-V
3. Validate with `spirv-val`
4. Test in Haskan2 lighting shader
5. If works, batch-add remaining functions
6. If fails, investigate extinst support

## Commit Strategy

Single commit: `FIR: add GLSL math functions (sin, cos, atan2, pow, clamp, smoothstep, mix, floor, fract, step)`

Then separate commits for each feature that uses them:
- `M10.3: rotate IBL cubemap sampling with sun direction`
- `M10.4: volumetric cloud raymarching`
- `M10.x: 1-unit grid overlay with floor`
