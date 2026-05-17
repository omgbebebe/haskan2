# Milestone: FIR Array Support for Lookup Tables & Shader Data

## Motivation

Hosek-Wilkie sky model requires 27 coefficients (9 params × 3 RGB channels) stored as
polynomial tables indexed by turbidity. Similar lookup tables appear in GGX prefiltering,
color grading LUTs, and noise permutation tables. FIR needs ergonomic support for declaring,
initializing, and indexing constant arrays in shaders.

## Current State

FIR already has:

- **`Array n a`** — fixed-size, type-level `Nat`-indexed arrays (`FIR.Prim.Array`)
- **`RuntimeArray a`** — SSBO-backed dynamic arrays (read-only in shader)
- **`Lit $ MkArray vec`** — compile-time constant arrays → `OpConstantComposite`
- **`view @(AnIndex Word32) i arr`** — runtime indexing → `OpAccessChain` + load
- **`view @(Index n) arr`** — compile-time static index → `OpCompositeExtract`
- **`pure`, `<$$>`, `traverse`** — Applicative/Functor/Traversable instances (loop-based codegen)

Used in haskan2: `Cull.hs` (frustum planes `Array 6`, draw commands `Array 16384`),
`LightData.hs` (`Array 256`), `EntityData.hs` (`Array 16384`).

## Gaps

### Gap 1: No Ergonomic Table Literal Syntax

**Problem:** Building a constant array requires:
```haskell
Lit $ MkArray (fromJust $ Vector.fromList [1.0, 2.0, 3.0, ...])
```
Verbose, partial (`fromJust`), no type inference for element types.

**Fix:** Add a TH splice or typeclass-driven literal constructor:
```haskell
-- Option A: Template Haskell
$(arrayLit [ 1.0, 2.0, 3.0, ... ])  -- infers n from length

-- Option B: OverloadedLists + KnownNat n
[1.0, 2.0, 3.0] :: Array 3 Float
```

**Estimated effort:** 4–6h (TH splice is simpler, OverloadedLists needs type-level proof)

**Files:** `FIR.Prim.Array`, new `FIR.Syntax.Literals` or TH module

### Gap 2: No Multi-Dimensional Constant Tables

**Problem:** HW needs `Array TurbiditySteps (Array 9 (V 3 Float))` — a 2D lookup.
`Lit $ MkArray` works for flat arrays but nesting requires manual `Vector.fromList` of
`MkArray` values, fighting the type system at each level.

**Fix:** Support nested `Array` in `OpConstantComposite`:
```haskell
type HWTable = Array 10 (Array 9 (V 3 Float))
-- Should emit OpConstantComposite of OpConstantComposite
```
Already works at SPIR-V level — just needs the FIR `Syntactic` instance chain verified
and possibly extended for nested `MkArray`.

**Estimated effort:** 2–3h (mostly verification + test cases)

**Files:** `FIR.Prim.Array` (Syntactic instance), `CodeGen.IDs` (constID for nested)

### Gap 3: No `const`-Qualified Local Variables

**Problem:** `def @"myTable" $ Lit table` creates a mutable function-local variable.
SPIR-V has no `const` qualifier (constants are `OpConstant` instructions, not variables),
but the optimizer should fold these. Still, large tables materialized as variables waste
registers and prevent constant-folding in unoptimized SPIR-V.

**Fix:** Either:
- (A) Detect that all assigns to a `def` are `OpConstantComposite` and emit `OpConstant`
  instead of `OpVariable + OpStore`
- (B) Add a `constDef` variant that asserts immutability and emits `OpConstant` directly
- (C) Document that `spirv-opt --constant-propagation` handles this (zero-effort option)

**Estimated effort:** Option C = 0h, Option A = 8–12h, Option B = 4–6h

**Files:** `CodeGen.Definition`, `CodeGen.IDs`

### Gap 4: No Built-In Runtime Array Iteration

**Problem:** Iterating over `RuntimeArray` requires manual `while` loop with counter
and `arrayLength`. No `forM_`, `imapM_`, or `fold` combinators.

**Fix:** Add `traverseArray_` and `ifoldArray_` combinators:
```haskell
traverseArray_ :: (Code Word32 -> Code a -> Sem s ()) -> Name "field" -> Sem s ()
ifoldArray_ :: (Code Word32 -> Code a -> Sem s ()) -> ... -> Sem s ()
```
Emits `while` loop with `OpArrayLength` bound + `OpAccessChain` per iteration.

**Estimated effort:** 6–8h

**Files:** New `FIR.Prim.Array` combinators or `FIR.Control.Loop`

### Gap 5: No `RuntimeArray` Write Path

**Problem:** `storeAtTypeThroughAccessChain` explicitly errors on `RuntimeArray`
(`CodeGen.Optics:813-814`). This means compute shaders cannot append to SSBO arrays.

**Not needed for HW** (coefficients are read-only in shader). Relevant for future
GPU particle systems, GPU-driven culling output, etc.

**Estimated effort:** 12–16h (requires careful memory model reasoning)

**Files:** `CodeGen.Optics`, `FIR.Validation.Definitions`

## Priority for Hosek-Wilkie

| Gap | Needed? | Priority |
|-----|---------|----------|
| 1. Table literal syntax | Nice to have | Low |
| 2. Multi-dimensional tables | Yes (or flatten) | Medium |
| 3. const-qualified locals | Optional (spirv-opt) | Low |
| 4. RuntimeArray iteration | No | — |
| 5. RuntimeArray write | No | — |

**Minimum viable path:** Flatten HW coefficients into a single `Array 90 (V 3 Float)`
(10 turbidity steps × 9 params), pass via expanded UBO or small SSBO. Use existing
`view @(AnIndex Word32)` for indexing. No FIR changes required — just verbose Haskell.

**Recommended path:** Implement Gap 1 (TH literal) + verify Gap 2 (nested arrays).
Makes all future lookup table work ergonomic. ~6–9h total.

## Total Estimated Effort

| Scope | Hours |
|-------|-------|
| Minimum (no FIR changes, flatten tables) | 0h FIR + 8h HW implementation |
| Recommended (Gap 1 + 2) | 6–9h FIR + 8h HW implementation |
| Full (Gap 1–4) | 20–29h FIR |
| Full + write (Gap 1–5) | 32–45h FIR |
