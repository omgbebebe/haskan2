# Fix 4B-4D: Supporting Improvements

**Priority**: P2 — nice to have, can be parallelized
**Estimate**: 1 week total
**Status**: Complete

---

## 4A: `abs`/`sign` for Code Types

**Note**: This is P0 and tracked separately in [`fix4a-abs-sign.md`](fix4a-abs-sign.md).
**Status**: Already done in FIR fork (`Signed (Code a)` instance).

---

## 4B: Improved Error Messages for Vector Operators (2 days)

**Status**: Complete

- Added overlapping `AdditiveMonoid (Code (V n a))` instance with `TypeError`
- Error message: "Cannot use '+' on Code vectors. Use '^+^' (from Semimodule) instead."
- Verified with `Tests.TypeErrors.VectorNum` golden test

---

## 4C: Debug Printf Support (2 days)

**Status**: Already complete in FIR

- `FIR.Syntax.DebugPrintf` module exists with `debugPrintf` function
- `CodeGen.Debug` emits `OpDebugPrintf` with `SPV_KHR_non_semantic_info` extension
- Test: `test/Tests/Debug/Printf.hs`

---

## 4D: Group/Subgroup Operations (2 days)

**Status**: Already complete in FIR

- `HasGroupAdd`, `HasGroupMul`, `HasGroupMinMax`, `HasGroupBitwise`, `HasGroupLogic` classes in `FIR.Syntax.Program`
- Emits `OpGroupNonUniform*` for Vulkan backend
- Test: `test/Tests/Groups/Group.hs`

---

## Definition of Done

- [x] Vector operator misuse gives clear type error
- [x] Debug printf works in shader
- [x] Group operations validated
- [x] Subgroup operations present
