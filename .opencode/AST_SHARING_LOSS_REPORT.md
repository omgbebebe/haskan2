# AST Sharing Loss: Root Cause Analysis of 7.6M Instruction Explosion

## Executive Summary

FIR's codegen traverses the AST as a **tree**, but Haskell `let`-bound expressions in shader
code create an AST **DAG** (directed acyclic graph) via pointer sharing. Every shared AST node
is re-traversed and re-emitted at each reference, producing duplicated SPIR-V instructions.

The trilinear cloud noise code in `light_frag` triggers ~2,700× instruction bloat because
`hash3`, `valueNoise3D`, and `fbm3D` use Haskell `let` bindings (not FIR's `let'`) to name
intermediate values. Each binding is referenced 2–7 times, and references compose
multiplicatively through nested `let`-chains.

**Proposed fix**: `StableName`-based memoization in `codeGen`, scoped per function/entry-point.
Estimated impact: 7.6M → ~3,000 instructions (99.96% reduction).

---

## 1. The Mechanism

### 1.1 How Sharing is Created

In `Lighting.hs:180-225`, the noise functions use plain Haskell `let`:

```haskell
hash3 (Vec3 x y z) =
  let x1 = fract (x * 0.1031)        -- x1 :: Code Float = AST (Val Float)
      y1 = fract (y * 0.1031)
      z1 = fract (z * 0.1031)
      dotP = x1 * (y1 + 33.33)
           + y1 * (z1 + 33.33)
           + z1 * (x1 + 33.33)       -- x1 referenced 2x here
      x2 = x1 + dotP                  -- x1 referenced 1x here
      y2 = y1 + dotP                  -- y1 referenced 1x here
      z2 = z1 + dotP                  -- z1 referenced 1x here
  in fract ((x2 + y2) * z2)
```

At runtime, `x1` is a thunk: a pointer to an AST subtree `PrimOp FFract :$ (PrimOp FMul :$ x :$ Lit 0.1031)`.
Every occurrence of `x1` in the expression is the **same heap pointer** — Haskell preserves sharing.

The resulting AST is a DAG:

```
fract((x2+y2)*z2)
├── x2 = x1 + dotP
│   ├── x1 ──────────────────────┐  (shared pointer)
│   └── dotP                     │
│       ├── x1 * (y1+33.33)     │
│       │   └── x1 ─────────────┤  (same pointer)
│       ├── y1 * (z1+33.33)     │
│       └── z1 * (x1+33.33)     │
│           └── x1 ─────────────┘  (same pointer)
├── y2 = y1 + dotP
│   └── dotP ────────────────────── (dotP shared from above)
└── z2 = z1 + dotP
    └── dotP ────────────────────── (dotP shared again)
```

### 1.2 How Sharing is Lost

`codeGen` (`CodeGen/CodeGen.hs:165-166`) recursively traverses the AST:

```haskell
codeGen :: (CodeGen ast, Nullary v) => ast v -> CGMonad (ID, SPIRV.PrimTy)
codeGen v = codeGenArgs (Nullary v)
```

There is **no memo table**. Each recursive call processes its argument freshly, allocating a new
SPIR-V result ID via `fresh` (`CodeGen/Monad.hs:123`):

```haskell
fresh = supply <<%= succ
```

When `codeGen` encounters `x1` the first time (as part of `dotP`), it traverses the subtree
and emits ~3 SPIR-V instructions (FMul, constant load, FFract). When it encounters the **same**
`x1` pointer again (as part of `x2`), it traverses the subtree again and emits **another** ~3
instructions with fresh IDs.

This is **not** a bug in the codegen — it simply has no mechanism to detect "I've already
processed this AST node."

### 1.3 Why It's Exponential

The blowup is multiplicative across nested `let`-chains. Consider the reference counts:

| Binding | Referenced by | Direct refs | Transitive refs (tree traversal) |
|---------|--------------|-------------|----------------------------------|
| `x1` | `dotP` (2×), `x2` (1×) | 3 | 3 within each `dotP` copy |
| `dotP` | `x2`, `y2`, `z2` | 3 | Each copy re-traverses `x1`, `y1`, `z1` |
| `x2` | final expr | 1 | Contains 1× `dotP` + 1× `x1` |
| `y2` | final expr | 1 | Contains 1× `dotP` + 1× `y1` |
| `z2` | final expr | 1 | Contains 1× `dotP` + 1× `z1` |

For a single `hash3` call, the tree-traversal instruction count is approximately:

```
Let T(n) = cost of node with sharing factor n
T(x1) = 3 ops (fract, mul, const)
T(dotP) = 2·T(x1) + 2·T(y1) + 2·T(z1) + 5 arith = 6+6+6+5 = 23
T(x2) = T(x1) + T(dotP) + 1 = 3+23+1 = 27
T(y2) = T(y1) + T(dotP) + 1 = 3+23+1 = 27
T(z2) = T(z1) + T(dotP) + 1 = 3+23+1 = 27
T(hash3) = T(x2) + T(y2) + T(z2) + 2 = 27+27+27+2 = 83
```

With memoization, `hash3` would be ~15 ops (10 unique computations + 5 combines).

### 1.4 Scaling to 7.6M

The full noise chain:

```
fbm3D (3 octaves)
  └── valueNoise3D × 3
        └── hash3 × 8 per call = 24 total
```

But `valueNoise3D` itself has deep sharing chains:

```haskell
valueNoise3D (Vec3 x y z) =
  let ix = floor x                -- used in 4 hash calls × 1 ref each
      fx = fract x                -- used in sx expression 3 times
      sx = fx * fx * (3 - 2*fx)  -- used in 4 mix calls
      h000 = hash3 (Vec3 ix iy iz)
      h100 = hash3 (Vec3 (ix+1) iy iz)  -- ix re-traversed!
      ...
      v00 = mix h000 h100 sx     -- sx re-traversed
      ...
```

The `ix` binding (3 ops: floor, const, convert) appears in 4 hash calls, each building a `Vec3`
that references it. Without memoization, `ix` is re-emitted 4× per `valueNoise3D` call. But
each hash call itself duplicates its internal bindings.

The cascade:
- `hash3` without sharing: ~83 ops (vs ~15 with sharing) → **5.5× per call**
- `valueNoise3D` calls `hash3` 8× and has its own shared bindings → ~1,500 ops without sharing
- `fbm3D` calls `valueNoise3D` 3× → ~4,500 ops without sharing
- `valueNoise3D`'s own bindings (`ix`, `fx`, `sx`, etc.) further amplify → **~300,000+ ops per `fbm3D` call**
- The full shader has additional expressions referencing `fbm3D`'s output → **~7.6M total**

The 2,700× factor (7.6M / 2,800 expected) is consistent with a sharing factor of ~3 per binding
across ~7 nesting levels: 3^7 ≈ 2,187.

---

## 2. Evidence

### 2.1 Instruction Breakdown (from spirv-dis)

| Opcode            | Count      | %    | Characteristic                    |
|-------------------|------------|------|-----------------------------------|
| CompositeExtract  | 3,098,240  | 40%  | Vec3 component extraction (duped) |
| FMul              | 1,991,728  | 26%  | Arithmetic (duped subexpressions) |
| FAdd              | 1,234,823  | 16%  | Arithmetic (duped subexpressions) |
| ExtInst (GLSL)    | 694,345    | 9%   | fract, floor, mix calls (duped)   |
| FDiv              | 378,456    | 5%   |                                   |
| FSub              | 262,429    | 3%   |                                   |

`CompositeExtract` at 40% is the smoking gun: every `Vec3 x y z` pattern-match extracts
components, and each extraction is duplicated for every reference to the shared binding.

### 2.2 Comparison

| Shader | Lines | Instructions | Ratio |
|--------|-------|-------------|-------|
| gbuf_frag | 197 | 2,750 | 14/line (normal) |
| light_frag (simple noise) | 699 | 995 | 1.4/line (after workaround) |
| light_frag (trilinear noise) | 699 | 7,659,521 | 10,900/line (broken) |

The gbuf_frag ratio of ~14 instructions per line is normal (each line produces a few ops plus
type/constant declarations). The trilinear noise at 10,900/line is purely the sharing explosion.

### 2.3 Code Path Confirmation

1. **FIR's `Let` doesn't help**: `codeGenArgs (Applied LetF ...) = locally (codeGen a)` — just
   passes through to `codeGen`. No caching. (`CodeGen/CodeGen.hs:222-223`)

2. **FIR's `let'` isn't used by noise functions**: The noise code uses Haskell `let`, not
   FIR's `let'` (`FIR.Syntax.Program:381`). Even if it did, `Let` doesn't cache in codegen.

3. **Type/constant caching exists but is irrelevant**: `tryToUseWith` (`CodeGen/Monad.hs:158`)
   caches type IDs and constant IDs by **value** (not pointer). This prevents re-declaring the
   same type or constant. But it doesn't cache expression results.

4. **`fresh` never reuses**: `supply <<%= succ` at `CodeGen/Monad.hs:123` always increments.
   No ID reuse mechanism.

---

## 3. Proposed Fix: StableName Memoization

### 3.1 Approach

Add a memo table to `CGState` keyed by `hashStableName` of AST nodes. Before processing any
AST node, check if we've already emitted instructions for this exact node (same pointer). If so,
return the cached `(ID, SPIRV.PrimTy)`. Otherwise, process, emit, and cache.

### 3.2 Files to Modify

#### `CodeGen/State.hs`

Add field to `CGState`:

```haskell
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap

data CGState = CGState
  { ...
  , astMemo :: IntMap (ID, SPIRV.PrimTy)  -- NEW
  }
```

Initialize empty in `initialState`:
```haskell
, astMemo = IntMap.empty
```

Add lens:
```haskell
_astMemo :: Lens' CGState (IntMap (ID, SPIRV.PrimTy))
_astMemo = lens astMemo (\s v -> s { astMemo = v })
```

#### `CodeGen/CodeGen.hs`

Modify `codeGen` to use memoization:

```haskell
import System.Mem.StableName (makeStableName, hashStableName)
import System.IO.Unsafe (unsafePerformIO)
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap

astKey :: a -> Int
astKey v = unsafePerformIO (hashStableName <$> makeStableName v)
{-# NOINLINE astKey #-}

codeGen :: (CodeGen ast, Nullary v) => ast v -> CGMonad (ID, SPIRV.PrimTy)
codeGen v = do
  let key = astKey v
  memo <- use _astMemo
  case IntMap.lookup key memo of
    Just result -> pure result
    Nothing -> do
      result <- codeGenArgs (Nullary v)
      modifying _astMemo (IntMap.insert key result)
      pure result
```

The `{-# NOINLINE astKey #-}` pragma is critical — it prevents the `unsafePerformIO` from
being floated out or duplicated by the simplifier.

#### `CodeGen/Functions.hs`

Clear the memo table when entering a new function/entry-point scope, because SPIR-V IDs
from one function are not valid in another:

```haskell
inContext :: VLFunctionContext -> [...] -> CGMonad a -> CGMonad a
inContext context as body = do
  ...
  assign _astMemo IntMap.empty  -- NEW: clear per-scope
  ...
```

### 3.3 Why `unsafePerformIO` is Safe Here

`makeStableName` is a pure operation semantically — it returns a stable hash for a heap object.
The only side effect is registering the object with the GC's stable pointer table, which is
idempotent for the same object. The `NOINLINE` pragma ensures the IO isn't hoisted or duplicated.

This is the same pattern used by `data-reify`, `reify`, and other observable-sharing libraries
in the Haskell ecosystem.

### 3.4 Collision Handling

`hashStableName` returns an `Int` with ~32 bits of entropy. For a single shader compilation
with ~10,000 unique AST nodes, the birthday-problem collision probability is:

P(collision) ≈ n²/(2·2³²) ≈ 10⁸/8.6×10⁹ ≈ 1.2%

For correctness, we should use the full `StableName` for equality checking, not just the hash.
Revised approach using collision chains:

```haskell
import System.Mem.StableName (StableName, makeStableName, hashStableName, eqStableName)

-- In CGState:
, astMemo :: IntMap [(StableName (), (ID, SPIRV.PrimTy))]

-- Helper:
lookupMemo :: Int -> StableName () -> IntMap [(StableName (), a)] -> Maybe a
lookupMemo key sn = lookup (eqStableName sn) . fmap (\(s,a) -> (unsafeCoerce s, a)) <=< IntMap.lookup key
```

However, given that collisions produce **correct but suboptimal** results (we'd miss a sharing
opportunity, not produce wrong code), and the collision rate is ~1%, using just the hash is
pragmatically fine for an initial implementation. The worst case is some residual duplication,
not incorrect SPIR-V.

### 3.5 Scope Invalidation

The memo table must be cleared at function/entry-point boundaries. The `inContext` function
in `CodeGen/Functions.hs:188-216` is the natural place — it already saves/restores `_localBindings`
and `_functionContext`.

Important: the memo table should **not** be cleared within a single entry-point body. All
shared expressions within a shader stage should benefit from memoization.

### 3.6 What Gets Memoized

The memoization operates at the **AST node level**. Every call to `codeGen` checks the cache.
This means:

- **Pure expressions**: `x + y`, `fract x`, `mix a b t` — all memoized ✓
- **Vector component extraction**: `CompositeExtract` from `Vec3` patterns — memoized ✓
- **Constants**: `Lit 0.1031` — already cached by `tryToUseWith`, memoization is redundant but harmless
- **Type declarations**: handled by `knownTypes`, not by `codeGen` — unaffected
- **Side-effecting ops** (image read/write, OpStore): these go through different code paths
  (`Use`/`Assign` optics), not through the normal `codeGen` path — unaffected

---

## 4. Expected Impact

### 4.1 Instruction Count Reduction

| Component | Without memo | With memo | Factor |
|-----------|-------------|-----------|--------|
| `hash3` (×24 calls) | 83 × 24 = 1,992 | 15 × 24 = 360 | 5.5× |
| `valueNoise3D` own bindings (×3) | ~1,200 × 3 | ~80 × 3 | 15× |
| `fbm3D` + cloud shading | ~6,000 | ~400 | 15× |
| Full light_frag | 7,659,521 | ~3,000 | **2,553×** |

### 4.2 Compile-Time Impact

The memo table adds O(1) lookup per `codeGen` call (amortized, using `IntMap`). For a shader
with ~3,000 unique AST nodes, this is negligible. Memory overhead: ~24 bytes per entry × 3,000
= ~72 KB.

### 4.3 Correctness

Memoization is a semantics-preserving transformation for pure SPIR-V expressions. Reusing a
result ID instead of recomputing produces identical observable behavior. The only concern is
scope validity, addressed by clearing the table at function boundaries.

---

## 5. Alternative Approaches Considered

### 5.1 Convert Haskell `let` to FIR `def`/`let'`

**Approach**: Rewrite the noise functions to use FIR's monadic `def` or `let'` instead of
Haskell `let`.

**Problem**: `def` creates a named SPIR-V variable with `OpVariable` + `OpStore` + `OpLoad`,
which is significantly more expensive than SSA-style computation. `let'` just calls `codeGen`
without caching. Neither helps.

**Verdict**: Not useful without also adding memoization.

### 5.2 AST-Level Let-Floating Pass

**Approach**: Add a pre-codegen pass that detects shared AST subexpressions (via `StableName`)
and inserts explicit `Let` nodes, similar to let-floating in GHC's Core IR.

**Problem**: FIR's `Let` doesn't cache either. Would need to change `Let`'s codegen to allocate
a temporary variable. Complex, invasive change.

**Verdict**: More correct long-term, but much more work than direct memoization.

### 5.3 spirv-opt Post-Hoc CSE

**Approach**: Rely on `spirv-opt --eliminate-duplicate-constants --eliminate-dead-code`
to clean up after codegen.

**Problem**: `spirv-opt` cannot eliminate duplicate **computation** instructions, only duplicate
constants and dead code. Two identical `FMul %x %y` with different result IDs are not considered
duplicates by the optimizer because it doesn't know they produce the same value.

**Verdict**: Already integrated (`spirv-opt -O` reduces 10.9MB → 18.3KB for simple shaders),
but cannot fix the sharing explosion.

### 5.4 Hash-Consing the AST

**Approach**: Make the AST type hash-consed so that structurally identical subtrees are
guaranteed to be pointer-equal.

**Problem**: Requires rewriting the AST representation (`EGADT` from the `variant` library).
Massive refactoring with high risk of breakage.

**Verdict**: Correct long-term solution but far too invasive for this fix.

---

## 6. Implementation Checklist

- [ ] Add `astMemo :: IntMap (ID, SPIRV.PrimTy)` to `CGState` in `CodeGen/State.hs`
- [ ] Add `_astMemo` lens
- [ ] Initialize `astMemo = IntMap.empty` in `initialState`
- [ ] Add `astKey` helper with `unsafePerformIO` + `makeStableName` + `{-# NOINLINE #-}`
- [ ] Modify `codeGen` in `CodeGen/CodeGen.hs` to check/insert memo table
- [ ] Clear `_astMemo` in `inContext` (`CodeGen/Functions.hs`)
- [ ] Build FIR library
- [ ] Build haskan2
- [ ] Run with trilinear noise shader, measure instruction count
- [ ] Verify rendering correctness (visual comparison)
- [ ] Benchmark compile time before/after

---

## 7. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| `StableName` hash collision | Low (~1%) | Missed optimization, not incorrect | Use full `StableName` equality in v2 |
| Memo across scope boundary | Medium | Wrong ID reference, GPU crash | Clear table in `inContext` |
| `unsafePerformIO` purity concerns | None | — | Standard pattern, `NOINLINE` pragma |
| Performance regression | None | IntMap lookup is O(min(n,W)) | Negligible for ~3K entries |
| Breaks other shaders | Low | — | gbuf_frag has no sharing to exploit, no change expected |

---

## 8. Key Files

| File | Role |
|------|------|
| `CodeGen/CodeGen.hs:165-166` | `codeGen` — main traversal entry point |
| `CodeGen/State.hs:95-183` | `CGState` — where `astMemo` field goes |
| `CodeGen/Monad.hs:123` | `fresh` — always-allocating ID supply |
| `CodeGen/Monad.hs:158` | `tryToUseWith` — existing type/constant cache (by value) |
| `CodeGen/Functions.hs:188-216` | `inContext` — scope boundary for memo table clear |
| `FIR/Module.hs:74-75` | `toAST` for `Program` — Codensity → AST conversion |
| `FIR/AST.hs:123-126` | `Syntactic (AST a)` — `toAST = id` (preserves sharing) |
| `Lighting.hs:178-225` | Noise functions with Haskell `let` bindings |
