# Fix 3: Specialization Constants

**Priority**: P1 — needed for shader permutations
**Estimate**: 1.5 weeks
**Status**: Complete

---

## Implementation Summary

### FIR Codegen (Done)

- `SpecConstantF` GADT in `FIR/AST/Prim.hs` with pattern `SpecConstant`
- `SpecConstantF` added to `AllOpsF` in `FIR/AST.hs` + boot files
- `specConstantID` in `CodeGen/IDs.hs`: emits `OpSpecConstant`/`True`/`False` + `SpecId` decoration
- `CodeGen (SpecConstantF AST)` instance in `CodeGen/CodeGen.hs`
- `specConstant` user-facing helper in `FIR/Syntax/Program.hs`
- Relaxed `specConstant` constraint from `ScalarTy a` to just `PrimTy a` (Bool is PrimTy but not ScalarTy)

### Vulkan Runtime (Done)

- `Graphics.Haskan.Vulkan.Specialization` module:
  - `SpecEntry` — single specialization map entry (constantID + raw bytes)
  - `SpecializationData` — collection of entries for a shader stage
  - `withSpecializationInfo` — bracket-style C-stack allocation of `VkSpecializationInfo`
- Updated `ShaderStage` to carry optional `Ptr VkSpecializationInfo`
- Added `toPipelineStagesWithSpec` for stages with specialization data
- Updated `createComputePipelineWithSpec` for compute pipelines

### Tests (Done)

- `test/Tests/SpecConstants/WorkgroupSize.hs` — Float spec constant, passes `spirv-val`
- `test/Tests/SpecConstants/BoolFlag.hs` — Bool spec constant, passes `spirv-val`
- `test/Tests/SpecConstants/MultiSpec.hs` — multiple spec constants (Float + Word32), passes `spirv-val`
- Verified SPIR-V contains `OpDecorate %id SpecId N` and `OpSpecConstant`

---

## Files Changed

### FIR
- `src/FIR/AST/Prim.hs` — `SpecConstantF` GADT, pattern, Display
- `src/FIR/AST/Prim.hs-boot` — role annotation
- `src/FIR/AST.hs` + boot — `AllOpsF` extension
- `src/CodeGen/IDs.hs` — `specConstantID` + export
- `src/CodeGen/CodeGen.hs` — `CodeGen (SpecConstantF AST)` instance
- `src/FIR/Syntax/Program.hs` — `specConstant` helper + relaxed constraint

### Haskan2
- `src/Graphics/Haskan/Vulkan/Specialization.hs` — new module
- `src/Graphics/Haskan/Render/ShaderProgram.hs` — `ShaderStage` with spec info
- `src/Graphics/Haskan/Vulkan/ComputePipeline.hs` — `createComputePipelineWithSpec`

---

## Definition of Done

- [x] `specConstant @N @Type` produces valid SPIR-V with `SpecId`
- [x] Vulkan runtime can build `VkSpecializationInfo` and create pipeline
- [x] Compute pipeline specialization works
- [x] 3 test suites pass `spirv-val`
