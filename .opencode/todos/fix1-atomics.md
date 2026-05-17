# Fix 1: Atomic Operations

**Priority**: P1 — needed for clustered lighting, virtual shadows
**Estimate**: 2 weeks
**Status**: Not started

---

## Phase 1A: Type-Level API (3-4 days)

- [ ] Add 15 atomic data types to `3rdparty/fir/src/FIR/Prim/Op.hs`
  - [ ] `AtomicIAdd`, `AtomicISub`
  - [ ] `AtomicSMin`, `AtomicSMax`, `AtomicUMin`, `AtomicUMax`
  - [ ] `AtomicAnd`, `AtomicOr`, `AtomicXor`
  - [ ] `AtomicExchange`, `AtomicCompareExchange`
  - [ ] `AtomicIIncrement`, `AtomicIDecrement`
  - [ ] `AtomicLoad`, `AtomicStore`
- [ ] Add `MemoryScope` and `MemorySemantics` type-level enums
- [ ] Add `PrimOp` instances for each atomic
- [ ] Verify `cabal build` in FIR

---

## Phase 1B: AST Nodes (2-3 days)

- [ ] Add `AtomicOp` pattern/constructor to `3rdparty/fir/src/FIR/AST.hs`
- [ ] Handle pointer (storage buffer index or image coordinate)
- [ ] Handle memory scope and semantics fields
- [ ] Handle operand value (for binops)

---

## Phase 1C: Code Generation (3-4 days)

- [ ] Emit `OpAtomicIAdd` and all other `OpAtomic*` in CodeGen module
- [ ] Implement `OpImageTexelPointer` for image atomics
- [ ] Emit capabilities: `Int64Atomics`, `AtomicStorage`
- [ ] Handle `OpAtomicCompareExchange` (two semantics + comparator)
- [ ] Verify `spirv-val` on generated SPIR-V

---

## Phase 1D: User-Facing Syntax (2 days)

- [ ] Add `atomicAdd` for storage buffers in `3rdparty/fir/src/FIR/Syntax/AST.hs`
- [ ] Add `atomicExchange` for storage buffers
- [ ] Add `atomicImageAdd` for images
- [ ] Document return value semantics (returns original value)

---

## Phase 1E: Validation & Tests (2 days)

- [ ] `test/Tests/Atomics/AtomicCounter.hs` — counter increment in compute shader
- [ ] `test/Tests/Atomics/AtomicImage.hs` — image atomic add
- [ ] `test/Tests/Atomics/AtomicCAS.hs` — compare-and-swap spinlock
- [ ] `test/Tests/Atomics/AtomicScope.hs` — device vs workgroup scope
- [ ] All tests pass `spirv-val`

---

## Definition of Done

- [ ] `atomicAdd` on storage buffer compiles and passes validation
- [ ] `atomicImageAdd` compiles and passes validation
- [ ] All 15 atomic operations have SPIR-V emission
- [ ] 4 test suites pass
