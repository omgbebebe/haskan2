# Fix 4A: `abs` and `sign` for `Code` Types

**Status**: ✅ **ALREADY DONE**

---

## Verification

- `abs x :: Code Float` compiles and emits correct SPIR-V (`OpExtInst GLSLstd450FAbs`)
- `signum x :: Code Float` compiles and emits correct SPIR-V
- Used in `LightingProcedural.hs:339` and `Clouds.hs:253`

## What Was Already Working

- `FIR/Prim/Op.hs:255-266`: `Abs` and `Sign` primops exist with full vectorisation support
- `FIR/Syntax/AST.hs:309-311`: `Signed (Code a)` instance maps `abs`/`signum` to `primOp @a @SPIRV.Abs`/`@SPIRV.Sign`
- `SPIRV/PrimOp.hs:341-348`: Emits `GLSL_FAbs`/`GLSL_SAbs`/`GLSL_FSign`/`GLSL_SSign`

The `MILESTONE_FIR_GAPS.md` test file (`Issue3_NoAbs.hs`) still has the workaround commented out, but uncommenting shows it compiles fine.

## No Action Required

This fix is complete. The todo items below are kept for historical reference only.

---

## Original Plan (Historical)

- [x] ~~Add `abs`/`sign` to `GLSLMath`~~ — Already in `Signed (Code a)` instance
- [x] ~~Implement SPIR-V emission~~ — Already emits `OpExtInst`
- [x] ~~Migrate `step()`-based `abs` workarounds~~ — Shaders already use `abs` directly

---

**Conclusion**: This fix was completed in earlier FIR commits. No further work needed.
