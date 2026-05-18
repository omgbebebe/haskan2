# FIR Choose/IfThenElse Fix

**Status**: Not started
**Priority**: P0 — blocks natural conditionals in all shaders
**Estimate**: 1 week
**Scope**: `3rdparty/fir/src/FIR/Syntax/IfThenElse.hs` + haskan2 shader cleanup

---

## Problem

`if-then-else` on `Code Float` / `Code (V n Float)` fails with overlapping instances. Every conditional in haskan2 uses branchless `step()` workarounds. `mix` on vectors also broken (same root cause).

**Root cause**: `3rdparty/fir/src/FIR/Syntax/IfThenElse.hs:69-101`

```
Line 69: OVERLAPPABLE  Choose (Code b) '(x, y, z)           — general pure case
Line 84:               Choose (Code b) '(x, y, Program i j z) — monadic with Code condition
Line 92: INCOHERENT    Choose b '(x, y, Program i j z)        — catch-all monadic
```

GHC can't resolve `z = Code Float` vs `z = Program i i (Code Float)` when both unify.

---

## Phase 1: Fix Choose Instances (3 days)

### 1A: Replace overlapping instances with explicit ones

**File**: `3rdparty/fir/src/FIR/Syntax/IfThenElse.hs`

Replace the four overlapping instances with non-ambiguous explicit instances:

```haskell
-- Instance 1: Pure Code conditionals (Code Bool -> Code a -> Code a -> Code a)
-- This replaces OVERLAPPABLE + Chooser PureChoice
instance ( PrimTy (InternalType z)
         , SyntacticVal z
         , x ~ z, y ~ z
         )
      => Choose (Code Bool) '(x, y, z) where
  choose c t f = fromAST (If @(InternalType z) :$ c :$ toAST t :$ toAST f)

-- Instance 2: Code condition, monadic branches (Code Bool -> Program i j1 z -> Program i j2 z -> Program i i z)
-- Unchanged from current line 84-91
instance ( b ~ Bool
         , j ~ i
         , SyntacticVal z
         , x ~ Program i j1 z
         , y ~ Program i j2 z
         )
      => Choose (Code b) '(x, y, Program i j z) where
  choose c t f = fromAST (IfM :$ (Return :$ c) :$ toAST t :$ toAST f)

-- Instance 3: Monadic condition, monadic branches
-- Replace INCOHERENT with more specific head
instance ( SyntacticVal z'
         , PrimTy (InternalType z')
         , x' ~ z', y' ~ z'
         , x ~ Program i j1 x'
         , y ~ Program i j2 y'
         , b ~ Program k l (Code Bool)
         )
      => Choose b '(x, y, Program i i z') where
  choose c t f = fromAST (IfM :$ toAST c :$ toAST t :$ toAST f)
```

Key changes:
- Remove `OVERLAPPABLE` and `INCOHERENT` pragmas
- Instance 1 head: `Code Bool` condition, `z` result (pure). GHC can distinguish from Instance 2 where result is `Program i j z`
- Instance 2 head: `Code b` condition, `Program i j z` result. More specific than Instance 1 when result is monadic
- Instance 3 head: `b` is `Program k l (Code Bool)`, result is `Program i i z'` where `z'` has `PrimTy`. Distinguishable from Instance 1 (condition is `Code Bool`, not `Program`) and Instance 2 (condition is `Code b`, not `Program`)

**Risk**: The `Chooser`/`WhichChoice` machinery (lines 103-127) becomes dead code. Remove it.

### 1B: Verify OpSelect codegen path

The `If` AST pattern (used in Instance 1) should already emit `OpSelect` for scalar/vector types. Verify in codegen:

**File**: `3rdparty/fir/src/CodeGen/...` (AST code generation module)

Confirm `If` pattern emits:
- `OpSelect` for scalar/vector `Code` values (correct)
- `OpBranchConditional` for `Program` values (correct)

If `If` pattern does not emit `OpSelect` for pure values, add it.

### 1C: Remove dead Chooser machinery

Delete from `IfThenElse.hs`:
- `Choice` data type (line 103)
- `Chooser` class (line 104)
- `Chooser PureChoice` instance (lines 106-111)
- `Chooser ImpureChoice` instance (lines 112-121)
- `WhichChoice` type family (lines 123-126)

---

## Phase 2: Regression Tests (2 days)

### 2A: FIR-level tests

**Directory**: `3rdparty/fir/test/Tests/Choose/`

| Test | File | What it verifies |
|------|------|-----------------|
| `IfThenElseFloat.hs` | `if c then a else b :: Code Float` | Basic scalar conditional |
| `IfThenElseVec3.hs` | `if c then a else b :: Code (V 3 Float)` | Vector conditional |
| `IfThenElseVec4.hs` | `if c then a else b :: Code (V 4 Float)` | Vec4 (cloud color) |
| `MixVector.hs` | `mix a b t :: Code (V 3 Float)` | Vector mix/lerp |
| `NestedIf.hs` | `if c1 then (if c2 then a else b) else c` | Nested conditionals |
| `WhenUnless.hs` | `when c action` / `unless c action` | Monadic when/unless |
| `MonadicIf.hs` | `if c then put @"x" a else put @"x" b` | Monadic branches |

Each test must:
1. Compile the FIR shader module without type errors
2. Pass `spirv-val` on generated SPIR-V
3. Contain the natural `if-then-else` syntax (no `step()` workarounds)

### 2B: Existing tests must pass

Run full FIR test suite. Update `Tests/FirGaps/Issue2_IfThenElse.hs` and `Issue5_MixVector.hs` to use the natural syntax instead of workarounds.

---

## Phase 3: Migrate Haskan2 Shaders (2 days)

Mechanical replacement of `step()` workarounds with natural `if-then-else`.

### 3A: Clouds.hs

| Location | Current (workaround) | Target |
|----------|---------------------|--------|
| `absDirY` | `step 0.0 dirY * dirY + step dirY 0.0 * (0.0 - dirY)` | `abs dirY` |
| `dirY_safe` clamping | `step`-based | `if dirY > eps then dirY else eps` |
| Coverage conditional | `step`-based threshold | `if noise > threshold then ... else ...` |
| Light march skip | Inline step | `if accumDensity > maxDensity then break else ...` |
| Any `lerpV` manual | `a ^* (1-t) ^+^ b ^* t` | `mix a b t` |

### 3B: LightingProcedural.hs

| Location | Current | Target |
|----------|---------|--------|
| Geometry mask | Inline conditional | `if hasGeometry then ... else ...` |
| God ray composite | Inline `step` | `if skyOnly then ... else ...` |

### 3C: GBuffer.hs

Audit for any `step()` patterns. Replace if found.

### 3D: Build verification

```
~/bin/env-wrap cabal build exe:haskan2
```

All shaders must compile. Visual output must be identical (behavior is branchless either way — `OpSelect` vs `step()` produce same GPU result, just cleaner SPIR-V).

---

## Deliverables

| Item | File |
|------|------|
| Non-overlapping `Choose` instances | `3rdparty/fir/src/FIR/Syntax/IfThenElse.hs` |
| Dead `Chooser`/`WhichChoice` removed | Same file |
| 7 FIR regression tests | `3rdparty/fir/test/Tests/Choose/` |
| 2 existing gap tests updated | `3rdparty/fir/test/Tests/FirGaps/Issue{2,5}*` |
| Clouds.hs cleaned up | `src/.../Shaders/Deferred/Clouds.hs` |
| LightingProcedural.hs cleaned up | `src/.../Shaders/Deferred/LightingProcedural.hs` |

---

## Dependencies

- None. This is a self-contained FIR fix.
- Does NOT require `OpSelect` primop (the `If` AST pattern already exists and works for pure `Code` values — the issue is only in Haskell-level instance resolution).

---

## Success Criteria

1. `if x > 0 then x else 0 - x` compiles for `x :: Code Float` without errors
2. `mix a b t` compiles for `a :: Code (V 3 Float)` without errors
3. No `OVERLAPPABLE` or `INCOHERENT` pragmas remain in `IfThenElse.hs`
4. All `step()` workarounds in haskan2 shaders replaced with `if-then-else`
5. `spirv-val` passes on all affected shaders
6. Visual output unchanged (behavior-preserving refactor)
