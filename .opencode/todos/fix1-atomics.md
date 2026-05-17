# Fix 1: Atomic Operations

**Status**: ✅ **COMPLETE**
**Priority**: P0
**Duration**: ~4 hours (single session)

---

## Summary

Implemented full atomic operation support for storage buffers in FIR EDSL. The implementation includes:

### SPIR-V Layer
- **15 atomic operation patterns** added to `SPIRV.Operation` (`OpAtomicLoad` through `OpAtomicXor`)
- **`AtomicPrimOp` data type** added to `SPIRV.PrimOp` with full `opAndReturnType` support

### AST Layer
- **`AtomicF` GADT constructor** added to `FIR.AST.Prim` for atomic operations on storage buffers
- Registered in `AllOpsF` in `FIR.AST` and boot files
- Pattern synonym `AtomicOp` exported through `FIR.AST`

### Codegen Layer
- **`CodeGen/Atomic.hs`** module implements SPIR-V emission for `AtomicF`
- Handles **array access** via `OpAccessChain` with runtime index
- Handles **struct field access** — automatically accesses field 0 when the storage buffer element is a struct (required by FIR validation)
- Emits correct `OpAtomicIAdd`, `OpAtomicISub`, `OpAtomicAnd`, `OpAtomicOr`, `OpAtomicXor`, etc.

### User-Facing API
Added to `FIR.Syntax.Program`:
- `atomicAdd` — requires `Integral a`
- `atomicSub` — requires `Integral a`
- `atomicAnd` — requires `Bits a`
- `atomicOr` — requires `Bits a`
- `atomicXor` — requires `Bits a`
- `atomicExchange` — no extra constraints
- `atomicSMin` — requires `Ord a, Signed a`
- `atomicUMin` — requires `Ord a, Unsigned a`
- `atomicSMax` — requires `Ord a, Signed a`
- `atomicUMax` — requires `Ord a, Unsigned a`

All functions take: storage buffer name (type application), index, memory scope, memory semantics, value.

### Tests
- **`test/Tests/Atomics/AtomicCounter.hs`** — vertex shader that atomically increments a storage buffer counter
- Test passes FIR validation and `spirv-val`
- Generated SPIR-V contains `OpAtomicIAdd` with correct struct-field pointer access

---

## Files Modified

| File | Change |
|------|--------|
| `3rdparty/fir/src/SPIRV/Operation.hs` | Added 15 atomic operation patterns + showOperation cases |
| `3rdparty/fir/src/SPIRV/PrimOp.hs` | Added `AtomicPrimOp` type + `AtomicOp` constructor + `atomicOp` function |
| `3rdparty/fir/src/FIR/AST/Prim.hs` | Added `AtomicF` GADT + pattern + Display instance |
| `3rdparty/fir/src/FIR/AST/Prim.hs-boot` | Added `AtomicF` declaration + role annotation |
| `3rdparty/fir/src/FIR/AST.hs` | Added `AtomicF` to `AllOpsF` |
| `3rdparty/fir/src/FIR/AST.hs-boot` | Added `AtomicF` to `AllOpsF` and imports |
| `3rdparty/fir/src/FIR/Syntax/Program.hs` | Added 10 atomic user-facing functions |
| `3rdparty/fir/src/CodeGen/Atomic.hs` | **New** — codegen for atomic operations |
| `3rdparty/fir/src/CodeGen/CodeGen.hs` | Imported `CodeGen.Atomic` to register instance |
| `3rdparty/fir/fir.cabal` | Added `CodeGen.Atomic` to modules |
| `3rdparty/fir/test/Tests/Atomics/AtomicCounter.hs` | **New** — validation test |

---

## Known Limitations

1. **Struct field hardcoded to 0**: The codegen automatically accesses field 0 of a struct. For multi-field structs, the user would need a more flexible API (e.g., `atomicAdd @