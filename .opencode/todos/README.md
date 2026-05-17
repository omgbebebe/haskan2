# FIR Pipeline Fixes — Master Todo List

**Goal**: Implement all four FIR fixes to unblock EEVEE-parity rendering.
**Branch**: `feature/fir-pipeline-fixes` (from `3rdparty/fir` fork)
**Total Estimate**: ~4 weeks (2 fixes already done)

---

## Status Update (2026-05-17)

**Fixes 2 and 4A are ALREADY COMPLETE** in the current FIR submodule. Verified by:
- `if-then-else` on `Code Float` compiles and works (used extensively in haskan2 shaders)
- `abs`/`signum` on `Code a` compiles and works (`Signed (Code a)` instance exists)
- `mix`/`mixV` on vectors compiles and works (`GLSLMath (Code a)` instance exists)

The `MILESTONE_FIR_GAPS.md` and `MILESTONE_FIR_PIPELINE_FIXES.md` documents are **outdated** — they describe issues that were fixed in earlier FIR commits but the test files were never updated to reflect the fixes.

---

## Execution Order (Reordered for Impact)

| # | Fix | Priority | Duration | Status | File |
|---|-----|----------|----------|--------|------|
| 1 | **Fix 2**: if-then-else on `Code` types | — | — | **DONE** | Already works |
| 2 | **Fix 4A**: `abs`/`sign` for `Code` types | — | — | **DONE** | Already works |
| 3 | **Fix 1**: Atomic operations | **P0** | 2 weeks | Not started | [`fix1-atomics.md`](fix1-atomics.md) |
| 4 | **Fix 3**: Specialization constants | **P1** | 1.5 weeks | Not started | [`fix3-spec-constants.md`](fix3-spec-constants.md) |
| 5 | **Fix 4B-4D**: Supporting improvements | **P2** | 1 week | Not started | [`fix4b-4d-supporting.md`](fix4b-4d-supporting.md) |

---

## Immediate Next Action

Start [`fix1-atomics.md`](fix1-atomics.md) — this is the only P0 remaining item.
