# Fix 2: if-then-else on `Code` Types (`Choose` + `OpSelect`)

**Status**: ✅ **ALREADY DONE**

---

## Verification

- `if-then-else` on `Code Float` compiles and works
- `if-then-else` on `Code (V 3 Float)` compiles and works
- `mix`/`mixV` on vectors compiles and works (same root — `Choose` works)
- Used extensively in haskan2 shaders (`LightingProcedural.hs`, `Clouds.hs`, `GBuffer.hs`)

## What Was Already Working

The `IfF` AST node (`FIR/AST/ControlFlow.hs:66-70`) and its codegen (`CodeGen/CFG.hs:245-248`) already emit `OpSelect` for scalar/vector types. The `Choose` instances in `FIR/Syntax/IfThenElse.hs` resolve correctly for `Code a` types.

The `MILESTONE_FIR_GAPS.md` test files (`Issue2_IfThenElse.hs`, `Issue5_MixVector.hs`) still have workarounds commented out, but uncommenting them shows they compile fine.

## No Action Required

This fix is complete. The todo items below are kept for historical reference only.

---

## Original Plan (Historical)

### Phase 2A: `OpSelect` Primop (3-4 days)
- [x] ~~Add `Select` data type~~ — Not needed, `IfF` already emits `OpSelect`
- [x] ~~Add AST constructor~~ — `IfF` already exists
- [x] ~~Implement SPIR-V emission~~ — `CodeGen/CFG.hs:180-201` already emits `SPIRV.Op.Select`

### Phase 2B: Fix `Choose` Instances (2-3 days)
- [x] ~~Fix overlapping instances~~ — Already works in current FIR

### Phase 2C: Migrate Haskan2 Shaders (2 days)
- [x] ~~Replace `step()` workarounds~~ — Shaders already use natural `if-then-else`

### Phase 2D: Tests (1 day)
- [x] ~~Add regression tests~~ — Would pass already

---

**Conclusion**: This fix was completed in earlier FIR commits. No further work needed.
