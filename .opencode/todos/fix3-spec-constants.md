# Fix 3: Specialization Constants

**Priority**: P1 — needed for shader permutations
**Estimate**: 1.5 weeks
**Status**: Codegen complete, runtime + tests pending

---

## Implementation Summary

Simplified approach: scalar + bool only, `Word32` specId parameter.

### Done

- `SpecConstantF` GADT in `FIR/AST/Prim.hs` with pattern `SpecConstant`
- `SpecConstantF` added to `AllOpsF` in `FIR/AST.hs` + boot files
- `specConstantID` in `CodeGen/IDs.hs`: emits `OpSpecConstant`/`True`/`False` + `SpecId` decoration
- `CodeGen (SpecConstantF AST)` instance in `CodeGen/CodeGen.hs`
- `specConstant` user-facing helper in `FIR/Syntax/Program.hs`

### Pending

- [ ] Vulkan runtime API (`VkSpecializationInfo` integration)
- [ ] Test suite (`test/Tests/SpecConstants/WorkgroupSize.hs`)
- [ ] Verify with `spirv-val`

---

## Files Changed

- `src/FIR/AST/Prim.hs` — `SpecConstantF` GADT, pattern, Display
- `src/FIR/AST/Prim.hs-boot` — role annotation
- `src/FIR/AST.hs` + boot — `AllOpsF` extension
- `src/CodeGen/IDs.hs` — `specConstantID` + export
- `src/CodeGen/CodeGen.hs` — `CodeGen (SpecConstantF AST)` instance
- `src/FIR/Syntax/Program.hs` — `specConstant` helper

---

## Next Steps

1. Write `test/Tests/SpecConstants/WorkgroupSize.hs`
2. Run `spirv-val` on generated SPIR-V
3. Implement Vulkan runtime specialization (deferred)
