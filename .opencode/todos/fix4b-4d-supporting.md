# Fix 4B-4D: Supporting Improvements

**Priority**: P2 — nice to have, can be parallelized
**Estimate**: 1 week total
**Status**: Not started

---

## 4A: `abs`/`sign` for Code Types

**Note**: This is P0 and tracked separately in [`fix4a-abs-sign.md`](fix4a-abs-sign.md).

---

## 4B: Improved Error Messages for Vector Operators (2 days)

- [ ] Add custom type errors in `Math/Algebra/Class.hs`
- [ ] `TypeError` when using `+` on `Code (V n Float)` → suggest `^+^`
- [ ] Consider unified operators via newtype wrapper (alternative)
- [ ] Verify error messages are helpful

---

## 4C: Debug Printf Support (2 days)

- [ ] Examine existing `FIR.Syntax.DebugPrintf` module
- [ ] Wire to `OpDebugPrintf` (requires `DebugInfo` capability, SPIR-V 1.4+)
- [ ] Add capability emission
- [ ] Test with simple shader

---

## 4D: Group/Subgroup Operations (2 days)

- [ ] Verify existing group ops (`GroupAdd`, `GroupMul`) emit correct SPIR-V
- [ ] Add subgroup operations if missing (`OpGroupNonUniform*`)
- [ ] Test with compute shader

---

## Definition of Done

- [ ] Vector operator misuse gives clear type error
- [ ] Debug printf works in shader (if supported by driver)
- [ ] Group operations validated
- [ ] Subgroup operations added (if needed)
