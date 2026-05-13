# FIR Math Operations Milestone Plan

## Goal

Add component-wise vector math operations to FIR so that Haskan2 shaders (especially Clouds and Lighting) can use vector arithmetic instead of scalar unpacking. The workflow is test-driven: write tests first, implement operations, verify tests pass, then refactor shaders.

---

## Phase 0: Test Infrastructure (est. 1–2 hours)

### Tasks

1. Create a dedicated `Math` test folder under `test/Tests/Math/`.
2. Add test registrations to `test/Tests.hs` under a new `Math` folder.
3. Verify one trivial test compiles and validates before adding real operations.

### Validation

```bash
cd 3rdparty/fir
cabal test fir-tests --test-options="Math"
```

---

## Phase 1: Component-wise Vector Arithmetic (est. 3–4 hours)

These are used in nearly every shader. Current workaround: unpack into scalars, multiply individually, repack.

### Operations

| # | Operation | FIR syntax | GLSL equivalent | Used in |
|---|-----------|-----------|-----------------|---------|
| 1 | Component-wise vector mul | `^*^` | `vec * vec` | Clouds (noise*, density*) |
| 2 | Component-wise vector div | `^/^` | `vec / vec` | Clouds |
| 3 | Vector `min` / `max` | `minV` / `maxV` | `min(vec, vec)` | Clouds, Lighting |
| 4 | Vector `clamp` | `clampV` | `clamp(vec, low, high)` | Clouds (height func) |
| 5 | Vector `mix` / `lerp` | `mixV` | `mix(a, b, t)` | Clouds, Lighting |
| 6 | Vector `step` | `stepV` | `step(edge, x)` | Clouds, Lighting |
| 7 | Vector `smoothstep` | `smoothstepV` | `smoothstep(e0, e1, x)` | Clouds |
| 8 | Vector `fract` | `fractV` | `fract(vec)` | Clouds (noise coords) |
| 9 | Vector `abs` | `absV` | `abs(vec)` | Clouds, Lighting |
| 10 | Vector `sign` | `signV` | `sign(vec)` | Clouds |

### Implementation Approach

For each operation:

1. **Add SPIR-V primop** in `SPIRV/PrimOp.hs` (e.g. `Vectorise Mul`, `Vectorise Clamp`).
   - Some already exist as scalar primops (`SPIRV.Clamp`, `SPIRV.Mix`, etc.); verify OpenCL backend support.
   - For operations without SPIR-V builtins, use `fmapAST` / `<$$>` with the scalar version.

2. **Add `PrimOp` instance** in `FIR/Prim/Op.hs` for `V n a`.

3. **Add convenience operator/function** in `Math.Linear` or `Math.Algebra.Class`.
   - For `^*^`, add a new infix operator alongside `^+^`, `^-^`.
   - For `clampV`, `mixV`, etc., add vector-overloaded variants.

4. **Write test** in `test/Tests/Math/VectorArith.hs`.
   - Each operation gets a simple shader that uses it.
   - Test type: `Validate` (must generate valid SPIR-V).

5. **Run test** → fix → repeat.

### Test Structure Example

```haskell
-- test/Tests/Math/VectorArith.hs
module Tests.Math.VectorArith where

import FIR
import Math.Linear

type Defs = '[ "in_a"  ':-> Input  '[Location 0] (V 3 Float)
             , "in_b"  ':-> Input  '[Location 1] (V 3 Float)
             , "out"   ':-> Output '[Location 0] (V 3 Float)
             , "main"  ':-> EntryPoint '[] Vertex
             ]

program :: Module Defs
program = Module $ entryPoint @"main" @Vertex do
  a <- get @"in_a"
  b <- get @"in_b"
  let c = a ^*^ b          -- component-wise mul
      d = clampV c (Vec3 0 0 0) (Vec3 1 1 1)
      e = mixV a b (Vec3 0.5 0.5 0.5)
      f = stepV (Vec3 0.5 0.5 0.5) d
      g = smoothstepV (Vec3 0 0 0) (Vec3 1 1 1) e
      h = fractV f
      i = absV g
      j = signV h
  put @"out" (i ^+^ j)
```

---

## Phase 2: Vector Transcendental Functions (est. 2–3 hours)

These already have scalar primops and `'Vectorise'` variants in FIR. The gap is a `Floating` instance for `Code (V n a)` so they can be called directly.

### Operations

| # | Operation | Current workaround | Desired usage |
|---|-----------|-------------------|---------------|
| 11 | `sin`, `cos`, `tan` on vectors | `sin <$$> vec` | `sin vec` |
| 12 | `sqrt` on vectors | `sqrt <$$> vec` | `sqrt vec` |
| 13 | `pow` on vectors | `pow <$$> vec <**> scalar` | `pow vec exp` |
| 14 | `exp`, `log` on vectors | `exp <$$> vec` | `exp vec` |

### Implementation Approach

Option A: Add `Floating (Code (V n a))` instance.
- Delegates each method to the `'Vectorise'` primop.
- Cleanest: `sin myVec` works directly.
- Risk: May conflict with existing scalar `Floating` instance or cause ambiguous type errors.

Option B: Keep `fmapAST` but add vector-specific aliases.
- `sinV = sin <$$>`, `cosV = cos <$$>`, etc.
- Safer, no instance conflicts.
- Less ergonomic.

**Recommendation**: Try Option A first. If type inference breaks, fall back to Option B.

### Test Structure

```haskell
-- test/Tests/Math/VectorTrig.hs
let v = Vec3 1.0 2.0 3.0
    s = sin v
    c = cos v
    r = sqrt v
    p = pow v (Vec3 2.0 2.0 2.0)
    e = exp v
    l = log v
put @"out" (s ^+^ c ^+^ r)
```

---

## Phase 3: Geometric Vector Functions (est. 2–3 hours)

Already partially supported. Add missing ones.

### Operations

| # | Operation | Status | Notes |
|---|-----------|--------|-------|
| 15 | `refract` | **Missing** | GLSL `refract(I, N, eta)` |
| 16 | `faceforward` | **Missing** | GLSL `faceforward(N, I, Nref)` |
| 17 | `reflect` | Exists | `reflect` in `Math.Linear` |
| 18 | `normalize` | Exists | `normalise` in `Math.Linear` |
| 19 | `distance` | Exists | `distance` in `Math.Linear` |
| 20 | `length` / `norm` | Exists | `norm` in `Math.Linear` |

### Implementation Approach

- `refract`: Implement via SPIR-V ` Refract` instruction (if available) or manual formula.
- `faceforward`: `if (dot(Nref, I) < 0) N else -N` — can be done with existing ops, but a builtin is cleaner.

### Test Structure

```haskell
let i = Vec3 1 0 0
    n = Vec3 0 1 0
    r = refract i n 0.5
    f = faceforward n i (Vec3 0 (-1) 0)
put @"out" (r ^+^ f)
```

---

## Phase 4: Matrix Utilities (est. 2–3 hours)

### Operations

| # | Operation | Status | Notes |
|---|-----------|--------|-------|
| 21 | `outerProduct` | **Missing** | GLSL `outerProduct(a, b)` → matrix |
| 22 | `matrixCompMult` | **Missing** | GLSL `matrixCompMult(a, b)` — Hadamard for matrices |
| 23 | `inverse` | Partial | Host-side `error`; shader-side works via SPIR-V |
| 24 | `determinant` | Partial | Host-side `error`; shader-side works via SPIR-V |

### Implementation Approach

- `outerProduct`: Manual `M` construction from two vectors, or SPIR-V `OuterProduct`.
- `matrixCompMult`: Component-wise multiply of two matrices — use `liftA2 (liftA2 (*))`.
- `inverse`/`determinant`: Already have SPIR-V primops; host-side errors don't affect shaders. **Skip** unless needed on CPU.

### Test Structure

```haskell
let a = Vec3 1 2 3
    b = Vec3 4 5 6
    m = outerProduct a b        -- M 3 3 Float
    n = matrixCompMult m m
put @"out" (n !*^ a)
```

---

## Phase 5: FIR Test Suite Completion (est. 1 hour)

### Tasks

1. Run full `cabal test fir-tests`.
2. Verify no regressions in existing tests.
3. Ensure all new `Math/` tests pass.
4. If any `Typecheck` tests need golden files, run once to generate, review, commit.

---

## Phase 6: Haskan2 Shader Refactoring (est. 4–6 hours)

### Target: Clouds.hs

Current pattern (lines 96–120, 138–201, etc.):
```haskell
let (Vec3 rayDirX rayDirY rayDirZ) = rayDir
    rayLen = sqrt (rayDirX * rayDirX + ...)
    dirX = rayDirX / rayLen
    dirY = rayDirY / rayLen
    dirZ = rayDirZ / rayLen
```

Refactored:
```haskell
let rayLen = norm rayDir + 0.0001
    dir = rayDir ^/ rayLen
    -- dir is V 3 Float, use directly
```

And for noise coordinates:
```haskell
-- Current: 6 scalar lines per step
p0x = entryX + dirX * (stepSize * 0.5)
p0y = entryY + dirY * (stepSize * 0.5)
p0z = entryZ + dirZ * (stepSize * 0.5)

-- Refactored: 1 vector line
p0 = entryPos ^+^ dir ^* (stepSize * 0.5)
```

And for height falloff:
```haskell
-- Current: smoothstep called 6 times with scalar args
heightF0 = smoothstep 0.0 0.15 ...

-- Refactored: vector smoothstep if we add it
-- (may not apply here since t varies per step)
```

### Target: Lighting.hs

Same pattern — skybox rays, sun direction, etc. can stay as vectors.

### Strategy

1. Pick one shader function at a time.
2. Replace scalar math with vector equivalents.
3. Build after each change.
4. Run `haskan2` and visually verify (clouds still render correctly).
5. Commit.

---

## Phase 7: Performance & Regression Validation (est. 2 hours)

### Tasks

1. **Benchmark**: Measure frame time before/after refactoring with `haskan2` built in release mode.
2. **Visual regression**: Rotate camera, verify no new artifacts.
3. **SPIR-V diff**: Compare generated SPIR-V size. Vector ops should generate identical or smaller SPIR-V (fewer extract/composite instructions).

---

## Future Work (Post-Milestone)

Operations not immediately needed but useful for advanced shaders:

| # | Operation | Use Case |
|---|-----------|----------|
| 25 | Vector comparisons (`lessThan`, `greaterThan`, `equal`) | Deferred lighting stencil masks |
| 26 | `fma` (fused multiply-add) | Precision-critical math |
| 27 | `packUnorm`, `unpackUnorm` | G-buffer compression |
| 28 | `bitCount`, `findLSB`, `findMSB` | Bitmask operations |
| 29 | `interpolateAtCentroid`, `interpolateAtSample` | MSAA resolve |
| 30 | `atomicAdd`, `atomicMin` on images | Compute shaders |
| 31 | Subgroup operations (`subgroupAdd`, `subgroupBroadcast`) | GPU-driven rendering |

---

## Timeline Summary

| Phase | Description | Est. Hours |
|-------|-------------|-----------|
| 0 | Test infrastructure | 1–2 |
| 1 | Component-wise vector arithmetic | 3–4 |
| 2 | Vector transcendental functions | 2–3 |
| 3 | Geometric vector functions | 2–3 |
| 4 | Matrix utilities | 2–3 |
| 5 | FIR test suite completion | 1 |
| 6 | Haskan2 shader refactoring | 4–6 |
| 7 | Performance validation | 2 |
| **Total** | | **17–24 hours** |

---

## Dependencies & Risks

- **OpenCL backend gaps**: `clamp`, `mix`, `step`, `smoothstep`, `determinant`, `inverse` throw `error` in OpenCL backend. We only use Vulkan/GLSL backend, so this is acceptable but should be documented.
- **Type inference**: Adding `Floating (Code (V n a))` may cause ambiguous type errors in existing code. Mitigation: use `TypeApplications` or explicit type signatures.
- **`spirv-val`**: Must be in PATH for tests. Available via `vulkan-validation-layers` in nix or SDK.
- **Build time**: FIR rebuilds are slow (~2–3 min per change). Batch changes when possible.
