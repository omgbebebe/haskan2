# Fix 3: Specialization Constants

**Priority**: P1 — needed for shader permutations
**Estimate**: 1.5 weeks
**Status**: Not started

---

## Phase 3A: Type-Level API (2-3 days)

- [ ] Create `3rdparty/fir/src/FIR/Prim/SpecConstant.hs`
- [ ] Define `SpecConstant (name :: Symbol) (ty :: Type) (defaultVal :: k)`
- [ ] Support `KnownNat` / `KnownSymbol` for default values
- [ ] Add `specConstant` function yielding `Code a`

---

## Phase 3B: Decoration and Layout (2 days)

- [ ] Add `SpecId` decoration tracking to FIR compilation state
- [ ] Assign sequential `SpecId` during shader compilation
- [ ] Support `OpSpecConstantOp` for computed constants
- [ ] Track spec constants in `ProgramState`

---

## Phase 3C: Code Generation (2-3 days)

- [ ] Emit `OpDecorate %const SpecId <n>`
- [ ] Emit `OpSpecConstant` / `OpSpecConstantTrue` / `OpSpecConstantFalse`
- [ ] Emit `OpSpecConstantComposite` for vectors
- [ ] Emit `OpSpecConstantOp` for computed values
- [ ] Verify `spirv-val`

---

## Phase 3D: Vulkan Runtime API (2 days)

- [ ] Create `src/Graphics/Haskan/Vulkan/ShaderSpecialization.hs`
- [ ] Define `SpecInfo` with `VkSpecializationMapEntry` + `ByteString` data
- [ ] Implement `buildSpecInfo` from FIR shader metadata
- [ ] Integrate into pipeline creation (`VkGraphicsPipelineCreateInfo.pSpecializationInfo`)
- [ ] Integrate into compute pipeline creation

---

## Phase 3E: Tests (1 day)

- [ ] `test/Tests/SpecConstant/WorkgroupSize.hs` — specialize compute local size
- [ ] `test/Tests/SpecConstant/BoolFlag.hs` — feature toggle
- [ ] `test/Tests/SpecConstant/MultiSpec.hs` — multiple constants
- [ ] All tests pass `spirv-val`

---

## Definition of Done

- [ ] `specConstant @"foo" @Word32` produces valid SPIR-V with `SpecId`
- [ ] Vulkan runtime can specialize and create pipeline
- [ ] Compute workgroup size specialization works
- [ ] 3 test suites pass
