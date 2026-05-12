# SPIR-V ID Bound Overflow Analysis

**Date**: 2026-05-12
**Error**: `Invalid SPIR-V. The id bound is larger than the max id bound 4194303.`
**Shader**: `light_frag.spv` (deferred lighting fragment shader)

---

## Root Cause

FIR's code generator allocates SPIR-V IDs with a **monotonically increasing counter** (`fresh = supply <<%= succ` in `CodeGen/Monad.hs:123`). This counter **never resets or compacts**. Every call to `fresh` consumes one ID, regardless of whether that ID ends up in the final binary.

**Measured ID waste ratio**: 572:1 (for the working version — 569,042 bound for 995 actual instructions, only 335 result IDs used).

The trilinear cloud noise code in commit `db3c2d8` increased the instruction count enough to push the bound past the SPIR-V maximum of 4,194,303.

---

## Why the Noise Code is the Trigger

### Previous working version (`0ee1ec4`)

The hash function was a single expression:
```haskell
hash3 (Vec3 x y z) = fract (sin (x * 127.1 + y * 311.7 + z * 74.7) * 43758.5453)
```
~6 SPIR-V ops per hash call × 24 hash calls = ~144 noise ops. Total shader: ~1,100 ops. Bound: ~598K.

### Broken version (`db3c2d8`)

The hash function expanded to 10 `let` bindings:
```haskell
hash3 (Vec3 x y z) =
  let x1 = fract (x * 0.1031)
      y1 = fract (y * 0.1031)
      z1 = fract (z * 0.1031)
      dotP = x1 * (y1 + 33.33) + y1 * (z1 + 33.33) + z1 * (x1 + 33.33)
      x2 = x1 + dotP
      y2 = y1 + dotP
      z2 = z1 + dotP
  in fract ((x2 + y2) * z2)
```
~20 SPIR-V ops per hash call × 24 hash calls = ~480 noise ops. Plus all Vec3 constructions/destructions.

The 3-octave `fbm3D` inlines `valueNoise3D` 3 times, which inlines `hash3` 8 times each. **Total: 24 full copies of the hash function body** in the AST, each generating ~20 SPIR-V instructions plus Vec3 churn.

### The compounding effect

FIR's ID waste is **super-linear** with instruction count because:
1. Each instruction calls `fresh` for its result ID
2. Each instruction may call `typeID`/`constID` for operands (cached, but first use consumes IDs)
3. Intermediate pointer types from `OpAccessChain` chains consume IDs
4. `constID` for new literal values creates fresh IDs for each unique constant
5. The noise code introduces **many new literal constants** (0.1031, 33.33, 0.5, 0.25, 1.75, 2, 4, etc.) that weren't in the previous version

The hash function with 10 bindings introduces ~10 new unique literal constants. With 24 inlined copies, this creates pressure on the constant cache (even though deduplicated, the first allocation still consumes an ID).

---

## Where the 569K IDs Go (Working Version)

| Category | Estimated Count |
|----------|----------------|
| SPIR-V instruction results | ~335 |
| Type declarations (cached) | ~50 |
| Constant declarations (cached) | ~30 |
| **Unaccounted (wasted)** | **~568,000** |

The ~568K unaccounted IDs are consumed during codegen but don't appear in the binary. Likely sources:
- Internal `typeID`/`constID` calls that allocate fresh IDs during recursive resolution before the cache check completes for sub-types
- Temporary IDs allocated during the `declareGlobals` phase for deeply nested storage buffer types
- Possible repeated allocation in the monadic AST traversal that allocates then discards IDs for intermediate nodes

**This is a FIR bug.** The ID allocation mechanism needs compaction or deferred allocation.

---

## Fix Applied (Uncommitted)

The uncommitted fix replaces the integer-mix hash with a simplified 2-octave nearest-neighbor approach:

```haskell
hash3 (Vec3 x y z) = fract (sin (x * 127.1 + y * 311.7 + z * 74.7) * 43758.5453)

fbm3D (Vec3 x y z) =
  let n1 = hash3 (Vec3 (floor x) (floor y) (floor z))
      n2 = hash3 (Vec3 (floor (x*2)) (floor (y*2)) (floor (z*2))) * 0.5
  in (n1 + n2) / 1.5
```

This reduces hash calls from 24 to 2 and eliminates all trilinear interpolation (no `mix`, no smoothstep, no 8-corner sampling). Result: bound drops to ~569K, well under the limit.

---

## Recommended Long-Term Fixes

### In FIR (addresses root cause)

| Priority | Fix | Impact | Effort |
|----------|-----|--------|--------|
| **P0** | **ID compaction pass**: after codegen, renumber IDs contiguously before writing binary | Eliminates all wasted IDs | Medium |
| P1 | Defer `fresh` calls: only allocate when actually emitting (not during recursive type resolution) | Reduces waste at source | Medium |
| P2 | ID reuse pool: recycle IDs from instructions that get optimized away | Further reduction | Low |

### In the Shader (avoids the problem)

| Priority | Fix | Impact | Effort |
|----------|-----|--------|--------|
| **P0** | Keep noise functions simple (avoid deeply nested `let` bindings with many literals) | Stays under bound | Done |
| P1 | Use SPIR-V `OpFunction` for repeated computations (if FIR supports it) | Reduces inlined code | Unknown |
| P2 | Move complex noise to a compute shader | Eliminates noise from fragment shader entirely | High |

---

## ID Compaction Implementation Sketch (for FIR)

The fix belongs in `CodeGen/Binary.hs`, between codegen and serialization:

```haskell
-- Before putModule:
--   1. Collect all IDs actually used in the binary
--   2. Build a mapping: old ID -> new compact ID
--   3. Rewrite all ID references in instructions
--   4. Update the bound in the header

compactModule :: CGState -> CGState
compactModule state = ...
  where
    allUsedIDs = collectUsedIDs state
    idMap = Map.fromList (zip (Set.toList allUsedIDs) [1..])
    newBound = fromIntegral (Map.size idMap) + 1
```

This would turn 569,042 → ~1,000 for the working version, and would allow arbitrarily complex shaders without hitting the 4M limit.

---

*The ID compaction fix in FIR is the correct long-term solution. The shader-side fix is a workaround.*
