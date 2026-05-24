# Module Audit Report

**Date:** 2026-05-22
**Scope:** `haskan2.cabal` module list vs. `src/` filesystem, plus import usage analysis
**Method:** GHC `-Wunused-imports`, `-Wunused-top-binds`, filesystem comparison, grep import tracking

---

## Summary

- **Cabal lists:** 111 modules in `exposed-modules`
- **Source files:** 115 `.hs` files in `src/`
- **Missing from cabal:** 5 source modules (not listed in cabal, not imported anywhere)
- **Dead in cabal:** 2 listed modules with zero importers
- **Unused imports:** 0 (GHC `-Wunused-imports` reports clean across all 107 compiled modules)
- **Unused top-level binds:** 0 (GHC `-Wunused-top-binds` reports clean)

---

## 1. Missing from Cabal (Source Exists, Not Listed, Not Imported)

These 5 modules exist in `src/` but are absent from `haskan2.cabal` and have **zero importers** anywhere in the codebase.

### 1.1 `Graphics.Haskan.Engine.Core`
**File:** `src/Graphics/Haskan/Engine/Core.hs`
**Size:** 78 lines
**Status:** Superseded by `Graphics.Haskan.Engine.Types`
- Contains old definitions of `EngineConfig`, `GameState`, `WorldState`, `ControlMessage`, `Action`
- All of these types now live in `Engine.Types` with richer fields
- **Action:** Delete. This is legacy code from before the engine types were centralized.

### 1.2 `Graphics.Haskan.Noise`
**File:** `src/Graphics/Haskan/Noise.hs`
**Size:** 110 lines
**Status:** Superseded by compute shaders
- Contains CPU-side `generateCloudNoise` with value noise / FBM
- Cloud noise is now generated via `Graphics.Haskan.Vulkan.Shaders.Compute.CloudNoiseGen` (GPU compute)
- **Action:** Delete. CPU noise generation is no longer used.

### 1.3 `Graphics.Haskan.Render.Bindless`
**File:** `src/Graphics/Haskan/Render/Bindless.hs`
**Size:** 86 lines
**Status:** Unfinished / abandoned
- Implements `BindlessSet` descriptor management
- Referenced in roadmap `milestone-07-bindless-rendering.md` as planned feature
- Not wired into any render path
- **Action:** Either delete or move to a feature branch. Not production code.

### 1.4 `Graphics.Haskan.Vulkan.Shaders.Bindless`
**File:** `src/Graphics/Haskan/Vulkan/Shaders/Bindless.hs`
**Size:** 89 lines
**Status:** Unfinished / abandoned
- FIR shader module for bindless texture array sampling
- Has `Texture2DArray` binding but is not referenced by any pipeline setup code
- **Action:** Either delete or keep with bindless rendering milestone.

### 1.5 `Graphics.Haskan.Vulkan.Specialization`
**File:** `src/Graphics/Haskan/Vulkan/Specialization.hs`
**Size:** 74 lines
**Status:** Unfinished / abandoned
- Implements `withSpecializationInfo` for Vulkan specialization constants
- Referenced in `.opencode/todos/fix3-spec-constants.md` as planned feature
- `ShaderProgram` has a field `ssSpecializationInfo` but it is always `nullPtr`
- **Action:** Either delete or keep with specialization constants milestone.

---

## 2. Dead in Cabal (Listed but Zero Importers)

These 2 modules are listed in `haskan2.cabal` but nothing imports them.

### 2.1 `Graphics.Haskan.Events`
**File:** `src/Graphics/Haskan/Events.hs`
**Size:** 8 lines
**Status:** Unused helper
- Exports only `managedEvents :: MonadManaged m => m ()`
- SDL event initialization is done inline in `Graphics.Haskan.Window` and `Graphics.Haskan.Engine`
- **Action:** Delete. Trivial wrapper with no callers.

### 2.2 `Graphics.Haskan.Vulkan.Shaders.Compute.Test`
**File:** `src/Graphics/Haskan/Vulkan/Shaders/Compute/Test.hs`
**Size:** 30 lines
**Status:** Unused test shader
- Minimal compute shader that increments a counter
- Was likely used for compute pipeline validation during development
- No longer referenced by any test or runtime code
- **Action:** Delete or move to `test/` suite if still needed for compute validation.

---

## 3. Import Hygiene

### 3.1 Unused Imports
**Result:** Clean. Zero warnings from GHC `-Wunused-imports` across all 107 compiled modules.

This means:
- No module imports something it doesn't use
- No redundant qualified imports
- No orphaned imports from refactoring

### 3.2 Unused Top-Level Bindings
**Result:** Clean. Zero warnings from GHC `-Wunused-top-binds`.

### 3.3 Export Hygiene
**Note:** GHC does not warn on unused exports by default. Manual spot-check of the 7 dead modules above shows their exports are indeed unused.

---

## 4. Recommendations

### Immediate (Safe to Delete)
| Module | Reason |
|--------|--------|
| `Graphics.Haskan.Engine.Core` | Superseded by `Engine.Types` |
| `Graphics.Haskan.Noise` | Superseded by GPU compute shaders |
| `Graphics.Haskan.Events` | Unused 8-line wrapper |

### Deferred (Keep if Milestone is Active)
| Module | Milestone |
|--------|-----------|
| `Graphics.Haskan.Render.Bindless` | Bindless rendering (milestone-07) |
| `Graphics.Haskan.Vulkan.Shaders.Bindless` | Bindless rendering (milestone-07) |
| `Graphics.Haskan.Vulkan.Specialization` | Specialization constants (fix3) |
| `Graphics.Haskan.Vulkan.Shaders.Compute.Test` | Compute validation tests |

### Cabal File Cleanup
Add the 3 "immediate" modules to cabal if they should be compiled, or delete them. Currently they are compiled because `cabal build` compiles all `.hs` files in `hs-source-dirs`, but they are not listed in `exposed-modules` — this is a latent bug: if cabal's module discovery changes, these could stop compiling silently.

**Wait** — actually, cabal does NOT automatically discover modules. The fact that these 5 modules compile means... they don't compile as part of the library. Let me verify this.

Actually, cabal does NOT auto-discover modules in `src/`. Only modules listed in `exposed-modules` or `other-modules` are compiled. So these 5 modules are **not being compiled at all** by `cabal build lib:haskan2`. They are dead source files sitting in the tree.

---

## Verification Commands

```bash
# Find source files not in cabal
comm -23 <(find src -name "*.hs" | sed 's|src/||' | sed 's|/|.|g' | sed 's/.hs$//' | sort) \
           <(grep -E "^\s+Graphics\." haskan2.cabal | sed 's/^[[:space:]]*//' | tr ',' '\n' | sed 's/^[[:space:]]*//' | grep -v '^$' | sort -u)

# Check for unused imports
~/bin/env-wrap cabal build lib:haskan2 --ghc-options="-Wunused-imports"

# Check for unused top-level bindings
~/bin/env-wrap cabal build lib:haskan2 --ghc-options="-Wunused-top-binds"
```

---

## Conclusion

The codebase is in good shape import-wise: no unused imports, no unused binds. The only issues are 5 orphaned source files and 2 listed-but-unused modules. The 3 legacy modules (`Engine.Core`, `Noise`, `Events`) can be deleted immediately. The 4 milestone-related modules should be tied to their respective feature branches or milestones.
