# FIR EDSL Gap Analysis & Fix Milestone

## Background

During implementation of cloud rendering features (ambient lighting, multi-scattering, day-night cycle, curved Earth, per-step jitter), multiple gaps in the FIR (Functional Intermediate Representation) EDSL were encountered. These are **not bugs in application code** — they are missing functionality or type system limitations in FIR itself.

All workarounds currently live in `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs`. This milestone tracks upstream fixes in `3rdparty/fir/`.

**Regression tests:** `3rdparty/fir/test/Tests/FirGaps/` — 7 tests, all passing with workaround code.

---

## Issue 1: No `lerp` Function

**Severity:** Low (has workaround, trivial fix)
**Location:** FIR math library
**Test:** `3rdparty/fir/test/Tests/FirGaps/Issue1_NoLerp.hs`

### Problem
The milestone doc and common graphics literature use `lerp(a, b, t)`. FIR only exposes GLSL's `mix` (same function, different name). This is confusing for developers coming from HLSL/Unity/Unreal conventions.

### Workaround
```haskell
-- Manual lerp as vector arithmetic
lerpV a b t = a ^* (1.0 - t) ^+^ b ^* t
```

### Fix
Add `lerp = mix` synonym in `FIR.Syntax.AST` or `Math.Algebra.Class`.

### Files
- `3rdparty/fir/src/Math/Algebra/Class.hs:417` — add `lerp = mix`
- `3rdparty/fir/src/FIR/Syntax/AST.hs:388` — re-export as `lerp`

---

## Issue 2: `if-then-else` on `Code Float` Fails with Overlapping Instances

**Severity:** High (no workaround, requires branchless code)
**Location:** FIR `Choose` type class
**Test:** `3rdparty/fir/test/Tests/FirGaps/Issue2_IfThenElse.hs`

### Problem
Any `if-then-else` expression where branches return `Code Float` or `Code (V n Float)` produces:
```
Overlapping instances for Choose
    (Code Bool)
    '(EGADT fir-0.1.0.0:FIR.AST.AllOpsF (Val Float),
      EGADT fir-0.1.0.0:FIR.AST.AllOpsF (Val Float), t0)
```

This prevents natural conditional logic in shaders. Every branch must be rewritten with `step()`:
```haskell
-- BAD: Natural but fails to compile
absDirY = if dirY > 0.0 then dirY else 0.0 - dirY

-- WORKAROUND: Branchless step
absDirY = step 0.0 dirY * dirY + step dirY 0.0 * (0.0 - dirY)
```

### Impact
Clouds.hs has 4+ instances of this workaround:
- `absDirY` computation
- `dirY_safe` clamping
- Any conditional parameter tuning

### Fix
The `Choose` instance for `Code a` / `Code b` needs `IncoherentInstances` or a more specific overlapping strategy. Alternatively, provide a dedicated `ifThenElse` primop that doesn't use `Choose`.

### Files
- `3rdparty/fir/src/FIR/Syntax/AST.hs` — `Choose` instances
- `3rdparty/fir/src/FIR/Prim/Op.hs` — `Select` or `IfThenElse` primop

---

## Issue 3: No `abs` for `Code` Types

**Severity:** Medium (has workaround, common operation)
**Location:** FIR math library
**Test:** `3rdparty/fir/test/Tests/FirGaps/Issue3_NoAbs.hs`

### Problem
`abs` is not available for `Code Float` or `Code (V n Float)`. The standard `Prelude.abs` does not work in FIR's EDSL context.

### Workaround
```haskell
absF x = step 0.0 x * x + step x 0.0 * (0.0 - x)
```

### Fix
Add `abs` to `GLSLMath` type class or as a primop.

### Files
- `3rdparty/fir/src/Math/Algebra/Class.hs` — add `abs` to `GLSLMath`
- `3rdparty/fir/src/FIR/Syntax/AST.hs` — re-export `abs`

---

## Issue 4: Vector vs Scalar Operator Confusion

**Severity:** Medium (sharp edge, type-safe but ergonomic pain)
**Location:** FIR operator overloading
**Test:** `3rdparty/fir/test/Tests/FirGaps/Issue4_VectorScalarOps.hs`

### Problem
Scalars use `+`, `*`, `-`, `/`.
Vectors use `^+^`, `^*^`, `^-^`, `^/`.

There is no unified `Num` or `Fractional` instance. When mixing scalars and vectors (very common in graphics), it's easy to use the wrong operator and get cryptic `ScalarTy` errors.

### Example
```haskell
-- BAD: + is scalar-only
directLight + ambientTerm
-- Error: No instance for ScalarTy (V 3 Float)

-- OK: ^+^ is vector
directLight ^+^ ambientTerm
```

### Fix
Option A: Unified operators that dispatch on type.
Option B: Better error messages that say "use ^+^ for vectors, not +".
Option C: Type class `Additive` / `Multiplicative` with unified operators.

### Files
- `3rdparty/fir/src/Math/Linear.hs` — operator definitions
- `3rdparty/fir/src/FIR/Syntax/AST.hs` — error message customization

---

## Issue 5: `mix` for Vectors Fails with Overlapping Instances

**Severity:** High (same root cause as Issue 2)
**Location:** FIR `FMix` primop / `mixV`
**Test:** `3rdparty/fir/test/Tests/FirGaps/Issue5_MixVector.hs`

### Problem
`mixV` (vector mix/lerp) fails with the same overlapping instances error as `if-then-else`:
```haskell
ambientTerm = mix groundAmbient skyAmbient h
-- Error: Overlapping instances for Choose
```

This is because `mix` is implemented via the `Choose` type class for selecting between vector values.

### Workaround
```haskell
-- Manual per-component lerp
ambientTerm = (groundAmbient ^* (1.0 - h) ^+^ skyAmbient ^* h) ^* 0.18
```

### Fix
Same as Issue 2 — fix `Choose` instance resolution or provide dedicated `mix` primop that bypasses `Choose`.

### Files
- Same as Issue 2

---

## Issue 6: Type Inference Cascade from Single Binding

**Severity:** Medium (GHC limitation amplified by FIR)
**Location:** Type checker interaction
**Test:** `3rdparty/fir/test/Tests/FirGaps/Issue6_TypeInferenceCascade.hs` (golden file with expected error)

### Problem
When one binding has a type error (e.g., using `+` instead of `^+^`), GHC infers an ambiguous type variable `a0` for that binding. Because FIR's EDSL is deeply nested in a single `do` block, this ambiguous type **poisons every downstream binding**:

```
ambientTerm :: Code (V 3 a0)  -- a0 is ambiguous
...
lsx = fract ((lpx + lwx) * noiseScale)  -- now fract expects Logic a0, fails
heightMask = smoothstep 0.0 0.15 h       -- smoothstep expects Logic a0, fails
```

A single `+` vs `^+^` mistake produces 50+ cascading error messages.

### Fix
Better type signatures in shader blocks. Consider adding `TypeApplications` hints or `{-# ANN ... #-}` pragmas in FIR's `shader` combinator to improve error localization.

### Files
- `3rdparty/fir/src/FIR/Syntax/Program.hs` — `shader` combinator
- Application code: add explicit type signatures to top-level shader definitions

---

## Issue 7: Literal Type Contamination

**Severity:** Low (rare, confusing when it happens)
**Location:** Type inference for vector literals
**Test:** `3rdparty/fir/test/Tests/FirGaps/Issue7_LiteralTypeContamination.hs`

### Problem
Top-level vector literals like `cloudBase = Vec3 1.0 0.98 0.95` can be inferred as `Code (V 3 (V 3 a0))` instead of `Code (V 3 Float)` if any nearby expression introduces ambiguity.

This then poisons the entire scatter computation:
```
cloudBase :: Code (V 3 (V 3 a0))
directLight :: Code (V 3 (V 3 a0))
s_scatter :: Code (V 3 (V 3 a0))
```

### Fix
Explicit type signatures on literal definitions, or a `vec3` smart constructor with fixed type.

### Workaround
Keep literals close to their use site with explicit context, or use `let cloudBase = Vec3 (1.0 :: Code Float) 0.98 0.95`.

---

## Fix Priority & Order

| Issue | Severity | Effort | Priority | Blocker |
|-------|----------|--------|----------|---------|
| 2: if-then-else Choose | High | Medium | **P0** | Blocks natural conditionals |
| 5: mix for vectors | High | Medium | **P0** | Same root cause as #2 |
| 3: abs | Medium | Low | **P1** | Common operation, ugly workaround |
| 1: lerp synonym | Low | Trivial | **P2** | Convenience only |
| 4: Operator confusion | Medium | High | **P2** | Architectural change |
| 6: Cascade errors | Medium | High | **P3** | GHC limitation |
| 7: Literal types | Low | Low | **P3** | Rare, workaround exists |

---

## Recommended Implementation

### Phase A: Fix Choose (Issues 2, 5)
1. Add `IncoherentInstances` to `Choose` instance for `Code` types in `FIR.Syntax.AST`
2. OR: Replace `if-then-else` → `Choose` with dedicated `Select` primop in SPIRV codegen
3. Add regression test: `if-then-else` with `Code Float` branches

### Phase B: Math Library Gaps (Issues 1, 3)
1. Add `lerp = mix` synonym
2. Add `abs` to `GLSLMath` type class
3. Add `clamp` convenience wrapper (currently requires `minV . maxV`)

### Phase C: Ergonomics (Issues 4, 6, 7)
1. Consider unified operator type classes (research: can `+` work for both?)
2. Add explicit type signature checking to `shader` combinator
3. Add `vec2`/`vec3`/`vec4` smart constructors with fixed scalar types

---

## Regression Tests Needed

```haskell
-- Test 1: if-then-else on Code Float
condFloat :: Code Float -> Code Float -> Code Bool -> Code Float
condFloat a b c = if c then a else b

-- Test 2: mix/lerp on vectors
mixVec3 :: Code (V 3 Float) -> Code (V 3 Float) -> Code Float -> Code (V 3 Float)
mixVec3 a b t = mix a b t

-- Test 3: abs on Code Float
absFloat :: Code Float -> Code Float
absFloat x = abs x

-- Test 4: Vector addition with scalar operators (should fail with clear error)
-- vecAddScalar :: Code (V 3 Float) -> Code (V 3 Float) -> Code (V 3 Float)
-- vecAddScalar a b = a + b  -- Expected: clear "use ^+^ for vectors" error
```

---

## References

- Workarounds in: `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs`
- FIR source: `3rdparty/fir/src/`
- GLSL mix spec: https://registry.khronos.org/OpenGL-Refpages/gl4/html/mix.xhtml
