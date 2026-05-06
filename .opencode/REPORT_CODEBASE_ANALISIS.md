# Haskan2 Codebase Analysis Report

**Date:** 2026-05-06  
**Project:** haskan2 (Haskell Vulkan Game Engine)  
**Total LOC:** ~3,700 (src + app)  
**Files Analyzed:** 36 `.hs` modules

---

## 1. Critical Bugs (P0)

### 1.1 `modifiersToList` is broken due to off-side rule
- **Location:** `src/Graphics/Haskan/Engine.hs:496-519`
- **Severity:** P0
- **Current code:**
  ```haskell
  modifiersToList :: SDL.KeyModifier -> [KeyModifier]
  modifiersToList SDL.KeyModifier {..} =
    []
      <> if keyModifierLeftShift
        then [LShift]
        else
          []
            <> if keyModifierRightShift
              then [RShift]
              else
                ...
  ```
- **Problem:** Due to Haskell's layout rule, when `keyModifierLeftShift` is `True`, the entire rest of the expression is nested inside the `else` branch and is **never evaluated**. The function returns `[LShift]` alone, dropping all other active modifiers.
- **Proposed fix:**
  ```haskell
  modifiersToList :: SDL.KeyModifier -> [KeyModifier]
  modifiersToList SDL.KeyModifier {..} = catMaybes
    [ if keyModifierLeftShift  then Just LShift  else Nothing
    , if keyModifierRightShift then Just RShift  else Nothing
    , if keyModifierLeftCtrl   then Just LCtrl   else Nothing
    , if keyModifierRightCtrl  then Just RCtrl   else Nothing
    , if keyModifierLeftAlt    then Just LAlt    else Nothing
    , if keyModifierRightAlt   then Just RAlt    else Nothing
    , if keyModifierLeftGui    then Just LGUI    else Nothing
    , if keyModifierRightGui   then Just RGUI    else Nothing
    , if keyModifierNumLock    then Just NumLock else Nothing
    , if keyModifierCapsLock   then Just CapsLock else Nothing
    , if keyModifierAltGr      then Just AltGr   else Nothing
    ]
  ```
- **Feasibility:** Trivial. Verified with GHC 9.8.

### 1.2 `Buffer.hs` crashes on empty vertex/index/uniform lists
- **Location:** `src/Graphics/Haskan/Vulkan/Buffer.hs:36`, `99`, `134`
- **Severity:** P0
- **Current code:**
  ```haskell
  let size = fromIntegral ((length data') * (Foreign.sizeOf (head data')))
  ```
- **Problem:** `head data'` is a partial function. Passing an empty mesh (zero vertices or indices) causes a runtime crash.
- **Proposed fix:**
  ```haskell
  let size = fromIntegral (sum (map Foreign.sizeOf data'))
  ```
  (Same pattern already used safely in `updateUniformBuffer` at line 134.)
- **Feasibility:** Trivial. `sum (map sizeOf []) == 0`, which is the correct size for an empty buffer.

---

## 2. High Priority Issues (P1)

### 2.1 Engine.hs is a monolithic 540-line module
- **Location:** `src/Graphics/Haskan/Engine.hs`
- **Severity:** P1
- **Problem:** Contains main loop, render loop, state update loop, input handling, camera updates, event parsing, and key bindings all in one module. This violates the 300-500 line threshold and makes the file hard to maintain.
- **Proposed fix:** Split into:
  - `Graphics.Haskan.Engine.Core` — `mainLoop`, `EngineConfig`
  - `Graphics.Haskan.Engine.Render` — `renderLoop`, `renderFrameLoop`, `modelMatrix`, `projectionMatrix`
  - `Graphics.Haskan.Engine.State` — `stateUpdateLoop`, `updateCamera`
  - `Graphics.Haskan.Engine.Input` — `inputLoop`, `payloadToActionEvent`, `keyToAction`, `mouseMotionToAction`, `modifiersToList`, `defaultBindings`
- **Feasibility:** Achievable. `Engine.hs` already imports its dependencies explicitly; moving functions out only requires moving the corresponding imports. `GameState` and `WorldState` can stay in a small `Graphics.Haskan.Engine.Types` module.

### 2.2 `fromJust` anti-pattern in Model.hs
- **Location:** `src/Graphics/Haskan/Model.hs:224`, `238`
- **Severity:** P1
- **Current code:**
  ```haskell
  let minIndex = fromJust (elemIndex (minimum [a, b, c]) [a, b, c])
  ```
- **Problem:** `fromJust` throws a generic exception on `Nothing`. While `elemIndex` on `[a,b,c]` searching for `minimum [a,b,c]` is technically safe, it is brittle under refactoring.
- **Proposed fix:** Replace with a total helper:
  ```haskell
  rotateToMin :: Ord a => (a, a, a) -> (a, a, a)
  rotateToMin triplet@(a, b, c) = case minimum [a, b, c] of
    x | x == a -> triplet
      | x == b -> (b, c, a)
      | x == c -> (c, a, b)
  ```
- **Feasibility:** Trivial.

### 2.3 Partial functions `head`/`tail` in `normPass`
- **Location:** `src/Graphics/Haskan/Model.hs:269`
- **Severity:** P1
- **Current code:**
  ```haskell
  normPass faces = scanl (\b a -> if compareFst3 a b == EQ then rotateFace 1 a else a) (head faces) (tail faces)
  ```
- **Problem:** Crashes on empty or single-element lists.
- **Proposed fix:**
  ```haskell
  normPass :: [(Int, Int, Int)] -> [(Int, Int, Int)]
  normPass [] = []
  normPass (f:fs) = scanl go f fs
    where go b a = if compareFst3 a b == EQ then rotateFace 1 a else a
  ```
- **Feasibility:** Trivial.

### 2.4 `fail` used in pure function
- **Location:** `src/Graphics/Haskan/Model.hs:220`
- **Severity:** P1
- **Current code:**
  ```haskell
  stride [] = []
  stride _ = fail "index list must contain triplets"
  ```
- **Problem:** `fail` in a pure list context desugars to `error` (via `MonadFail []`). It throws a runtime exception instead of encoding failure in `Maybe` or `Either`.
- **Proposed fix:** Return `Maybe`:
  ```haskell
  stride (a : b : c : xs) = Just ((a, b, c) : stride xs)  -- needs recursive Maybe
  ```
  Or keep it local and use `error` explicitly with a `TODO` if this is truly unreachable, or better yet return `Either String [(Int,Int,Int)]`.
- **Feasibility:** Slightly more invasive because `normalizeMesh` callers would need to handle `Either`. However, `normalizeMesh` appears to be dead code (see §2.5), so this may be moot.

### 2.5 Dead / stub code
- **Location:** Multiple files
- **Severity:** P1
- **Items:**
  | File | Line | Issue |
  |------|------|-------|
  | `Engine.hs` | 458 | `data Event` — empty type, never used |
  | `Engine.hs` | 491-494 | `updateGameState` — body is `pure ()`, dead stub |
  | `Engine.hs` | 36 | `import Graphics.Haskan.Events qualified as Events` — `Events` module only exports `managedEvents`, never used in `Engine.hs` |
  | `Engine.hs` | 38 | `import Graphics.Haskan.Face qualified as Face` — unused |
  | `Engine.hs` | 44 | `import Graphics.Haskan.Utils.PieLoader qualified as PieLoader` — unused in `Engine.hs` |
  | `Engine.hs` | 19 | `import Data.Coerce (coerce)` — unused (commented-out code removed) |
  | `Engine.hs` | 15 | `import Control.Lens ((&), (.~))` — unused |
  | `Engine.hs` | 26 | `import Debug.Trace` — unused |
  | `Engine.hs` | 28-31 | `ModuleRequirements`, `Struct`, `runCompilationsTH` from `FIR` — unused |
  | `Engine.hs` | 8 | `QueueFamily` data type — never used |
  | `Model.hs` | 19-26 | `objCube`, `objTorus`, `suzanneCube` — unused |
  | `Model.hs` | 144-194 | `verts`, `indxs` — hardcoded test data embedded in library |
  | `Model.hs` | 196 | `test` — dead test code in library module |
  | `Window.hs` | 17-39 | `managedWindow` — never called; `Engine` uses `createWindow` directly |
  | `Window.hs` | 66-75 | `managedSurface` — never called; `Engine` uses `createSurface` directly |
  | `GlTFLoader.hs` | 12 | `loadGltf = undefined` — unimplemented stub |
  | `GlTFLoader.hs` | 7-8 | `URI`, `ByteString` imports — unused |
  | `ObjLoader.hs` | 20 | `import Text.Megaparsec.Debug` — unused |
  | `ObjLoader.hs` | 14 | `import Graphics.Haskan.Vertex qualified as Haskan` — unused |
  | `Camera.hs` | 11 | `import Linear.Projection qualified` — unused |
  | `Camera.hs` | 9 | `import Linear.Epsilon (Epsilon)` — unused |
  | `Camera.hs` | 5 | `import Control.Lens ((&), (.~))` — unused |
  | `Camera.hs` | 58 | `xAxis = V3 1.0 0.0 0.0` in `where` of `defaultOrbitalCamera` — unused |
  | `Vertex.hs` | 8 | `import Data.Functor.Contravariant` — `Contravariant` comes via `Divisible`, but actually `Contravariant` class is in `base` since 4.12; however the import is needed if `contravariant` package re-exports it? Actually with `base >=4.17`, `Data.Functor.Contravariant` is in `base`. The explicit import is unnecessary if `Divisible` is imported from `contravariant`, but harmless. |
  | `DescriptorSet.hs` | 5 | `import Data.Traversable (for)` — unused |
  | `PipelineLayout.hs` | 5 | `import Data.Traversable (for)` — unused |
  | `Render.hs` | 16 | `import Data.Traversable (for)` — `for_` from `Data.Foldable` is used instead |

- **Proposed fix:** Delete unused imports, types, and stub functions. Move `test`, `verts`, `indxs` to a separate test module or delete if no tests exist.
- **Feasibility:** Trivial. Deleting dead code has no downstream impact if the dependency graph confirms no external callers.

### 2.6 `Render.hs` re-exports types defined in `Types.hs`
- **Location:** `src/Graphics/Haskan/Vulkan/Render.hs:4-11`
- **Severity:** P1
- **Problem:** `RenderContext` and `RenderResult` are defined in `Types.hs` but re-exported from `Render.hs`. This creates two public sources of truth for the same type. `Engine.hs` already imports `Types` directly.
- **Proposed fix:** Remove `RenderContext` and `RenderResult` from `Render.hs` export list. Keep them exclusively in `Types.hs`.
- **Feasibility:** Trivial. `Engine.hs` already imports `Types`, so no breakage.

---

## 3. Medium Priority Issues (P2)

### 3.1 Phantom type constraints on `Face` / `QuadFace`
- **Location:** `src/Graphics/Haskan/Face.hs:5-6`, `11-12`, `14-15`, `19-24`, `26-27`, `29-30`
- **Severity:** P2
- **Current code:**
  ```haskell
  instance Eq a => Eq (Face a) where ...
  instance Ord a => Ord (Face a) where ...
  instance Show a => Show (Face a) where ...
  ```
- **Problem:** `a` is phantom — it does not appear in the right-hand side of the `newtype`. The constraints `Eq a`, `Ord a`, `Show a` are unnecessary and misleading.
- **Proposed fix:**
  ```haskell
  instance Eq (Face a) where ...
  instance Ord (Face a) where ...
  instance Show (Face a) where ...
  ```
  Same for `QuadFace`.
- **Feasibility:** Verified with GHC 9.8. Trivial change.

### 3.2 Unnecessary parentheses
- **Location:** Multiple files
- **Severity:** P2
- **Items:**
  | File | Line | Current | Better |
  |------|------|---------|--------|
  | `Engine.hs` | 210 | `imageAvailableSemaphores !! (frameNumber)` | `imageAvailableSemaphores !! frameNumber` |
  | `Engine.hs` | 219 | `renderFinishedSemaphores !! (fromIntegral imageIndex)` | `renderFinishedSemaphores !! fromIntegral imageIndex` |
  | `Engine.hs` | 248 | `((frameNumber + 1) \`mod\` Render.maxFramesInFlight)` | `(frameNumber + 1) \`mod\` Render.maxFramesInFlight` |
  | `Engine.hs` | 420 | `((fromIntegral x) / frameDelay)` | `fromIntegral x / frameDelay` |
  | `Engine.hs` | 420 | `((fromIntegral y) / frameDelay)` | `fromIntegral y / frameDelay` |
  | `Engine.hs` | 175 | `catMaybes $ map (...)` | `catMaybes $ map ...` (outer `$` already has low precedence) |
  | `Camera.hs` | 107 | `Orientation = (Linear.Quaternion.Quaternion Float)` | `Orientation = Linear.Quaternion.Quaternion Float` |
  | `Buffer.hs` | 36 | `((length data') * (...))` | `(length data' * ...)` |
  | `Buffer.hs` | 99 | `((length data') * (...))` | `(length data' * ...)` |

### 3.3 `Texture.hs` converts Vector to List unnecessarily
- **Location:** `src/Graphics/Haskan/Vulkan/Texture.hs:47`
- **Severity:** P2
- **Current code:**
  ```haskell
  let dataList = Vector.toList imgData
  ...
  Haskan.managedBuffer dev dataList Vulkan.VK_BUFFER_USAGE_TRANSFER_SRC_BIT
  ```
- **Problem:** `JuicyPixels` gives a storable `Vector Word8`. The code immediately converts it to a list, only for `Buffer.managedBuffer` to compute `length` and `sizeOf . head`, then poke it back into memory. This is an unnecessary O(n) allocation and conversion.
- **Proposed fix:** Change `managedBuffer` / `createBuffer` / `copyDataToDeviceMemory` to accept `Vector.Storable.Vector a` (or any `Storable` foldable) instead of `[a]`. Alternatively, add an overload `managedBufferVector`.
- **Feasibility:** Medium. It requires changing the Buffer API, which is used by vertex buffer, index buffer, and uniform buffer. All call sites pass lists today, so adding a polymorphic variant is safe:
  ```haskell
  createBuffer :: (MonadFail m, MonadIO m, Storable a, Foldable t) => Vulkan.VkDevice -> t a -> ...
  ```
  But `Foreign.Marshal.pokeArray` requires a list. You would need `Vector.unsafeWith` instead. This is feasible but slightly more work.

### 3.4 `all id` instead of `and`
- **Location:** `src/Graphics/Haskan/Model.hs:271`
- **Severity:** P2
- **Current code:**
  ```haskell
  isNormalized faces = all id $ isNormalized' faces
  ```
- **Proposed fix:**
  ```haskell
  isNormalized = and . isNormalized'
  ```
- **Feasibility:** Trivial.

### 3.5 `updateCamera` is a trivial wrapper
- **Location:** `src/Graphics/Haskan/Camera.hs:91-92`
- **Severity:** P2
- **Current code:**
  ```haskell
  updateCamera :: Camera c => c -> [Modifier Foreign.C.CFloat] -> c
  updateCamera cam mods = update cam mods
  ```
- **Proposed fix:** Eta-reduce to `updateCamera = update`, or remove entirely and use `Camera.update` directly at call sites. `Engine.hs` already defines its own `updateCamera` with a `TVar`, so the `Camera` module's `updateCamera` is redundant.
- **Feasibility:** Trivial. Check that `Engine.hs` doesn't import this specific `updateCamera` (it doesn't; it defines its own).

### 3.6 `modelMatrix` is identity composition
- **Location:** `src/Graphics/Haskan/Engine.hs:371-375`
- **Severity:** P2
- **Current code:**
  ```haskell
  modelMatrix :: M44 Foreign.C.CFloat
  modelMatrix =
    let rotate = identity
        translate = identity
     in translate !*! rotate
  ```
- **Proposed fix:**
  ```haskell
  modelMatrix :: M44 Foreign.C.CFloat
  modelMatrix = identity
  ```
- **Feasibility:** Trivial.

### 3.7 `if exit then pure () else do ...` pattern
- **Location:** `src/Graphics/Haskan/Engine.hs:357-363`
- **Severity:** P2
- **Current code:**
  ```haskell
  outerLoop exit = do
    if exit
      then pure ()
      else do
        renderFrameLoopFinished <- ...
        outerLoop renderFrameLoopFinished
  ```
- **Proposed fix:**
  ```haskell
  outerLoop exit = unless exit $ do
    renderFrameLoopFinished <- ...
    outerLoop renderFrameLoopFinished
  ```
- **Feasibility:** Trivial.

### 3.8 `Vertex` `alignment` hardcoded to 64
- **Location:** `src/Graphics/Haskan/Vertex.hs:26`
- **Severity:** P2
- **Current code:**
  ```haskell
  alignment _ = 64
  ```
- **Problem:** Hardcoded alignment that may not match the actual `vertexFormat` stride. If the format changes, this becomes a silent bug.
- **Proposed fix:**
  ```haskell
  alignment _ = strideSize vertexFormat
  ```
- **Feasibility:** Trivial and more correct.

### 3.9 `Vertex` `peek`/`poke` manually computes offsets
- **Location:** `src/Graphics/Haskan/Vertex.hs:27-44`
- **Severity:** P2
- **Problem:** The offset calculation duplicates knowledge already encoded in `vertexFormat`. If a new attribute is added to `Vertex` but `vertexFormat` is updated, the `Storable` instance may go out of sync.
- **Proposed fix:** Derive offsets from `vertexFormat` using `scanl (+) 0 (map componentSize (getComponents vertexFormat))`. This requires exposing a helper from `VertexFormat`.
- **Feasibility:** Medium. Requires adding a helper to `VertexFormat` to extract the component list, but improves maintainability.

### 3.10 `Swapchain.hs` depth view log name is generic
- **Location:** `src/Graphics/Haskan/Vulkan/Swapchain.hs:136`
- **Severity:** P2
- **Current code:**
  ```haskell
  alloc "ImageView" (createDepthView ...) ...
  ```
- **Proposed fix:**
  ```haskell
  alloc "DepthImageView" (createDepthView ...) ...
  ```
- **Feasibility:** Trivial.

---

## 4. Architecture & Module Structure

### 4.1 Module dependency graph
- `Engine.hs` is the dependency hub: it imports 22 modules directly. This is acceptable for a top-level orchestrator but exacerbates the monolith problem.
- `Render.hs` imports `Types` and re-exports its types (see §2.6).
- `Model.hs` imports both `ObjLoader` and `PieLoader`, acting as a convergence point for mesh formats. This is fine but contributes to its 276-line size.
- **No circular dependencies detected.**

### 4.2 Vulkan module boilerplate
- **Pattern:** Every Vulkan wrapper module (`Buffer`, `CommandPool`, `DescriptorPool`, `DescriptorSetLayout`, `Device`, `Fence`, `Framebuffer`, `GraphicsPipeline`, `ImageView`, `Instance`, `PipelineLayout`, `RenderPass`, `Semaphore`, `ShaderModule`, `Swapchain`) follows the exact same two-function pattern:
  ```haskell
  managedX :: MonadManaged m => ... -> m VkX
  managedX dev ... = alloc "X" (createX dev ...) (\ptr -> vkDestroyX dev ptr vkNullPtr)

  createX :: MonadIO m => ... -> m VkX
  createX dev ... = do
    let createInfo = createVk (...)
    liftIO $ withPtr createInfo $ \ptr -> allocaAndPeek (vkCreateX dev ptr vkNullPtr)
  ```
- **Assessment:** This is ~15 modules × ~30 lines of near-identical structure. A small TH or generic helper could reduce this, but the Vulkan API has enough per-structure variation that full abstraction may not pay off. A lighter option is a helper:
  ```haskell
  vkAlloc :: (MonadManaged m, MonadIO m) => Text -> (Ptr a -> IO b) -> (b -> IO ()) -> m b
  ```
  But `alloc` already exists in `Resources.hs`. The real duplication is `withPtr createInfo (\ptr -> allocaAndPeek (vkCreateX ... ptr vkNullPtr))`. A helper like:
  ```haskell
  createVkResource :: MonadIO m => (Ptr a -> IO b) -> Vulkan.VkStructureType -> m a -> m b
  ```
  is **blocked** by the fact that each `createInfo` uses different `set`/`setListRef` combinations and different `sType` values. The abstraction would need to accept the entire `createInfo` value, which is what `withPtr` already does. **Conclusion: not worth abstracting further without Template Haskell.**

---

## 5. Test Framework

- **Current state:** The main `haskan2.cabal` has **no test-suite** stanza.
- **3rdparty tests:**
  - `fir` has a comprehensive `test-suite fir-tests`.
  - `gltf-codec` has `test-suite gltf-codec-test`.
- **Assessment:** The main engine has zero automated tests. Given the Vulkan / SDL / threading complexity, this is a significant risk.
- **Proposed fix:** Add a `test-suite haskan2-test` to `haskan2.cabal` using **tasty** or **hspec**. At minimum, unit-test:
  - `ObjLoader` and `PieLoader` parsers against sample files.
  - `Model.normalizeMesh`, `Model.variants`, `Model.normalizeFaces` logic.
  - `Camera` update functions.
  - `Face` / `QuadFace` equality (including rotation invariance).
- **Feasibility:** High. No blockers.

---

## 6. Cabal / Project Structure

### 6.1 Unused / commented dependencies
- **Location:** `haskan2.cabal:108`
- **Current code:**
  ```cabal
  --                     ,gltf-codec
  ```
- **Problem:** Dead comment.
- **Proposed fix:** Delete the line.

### 6.2 Missing version bounds
- **Location:** `haskan2.cabal:66-86`
- **Problem:** Most dependencies (`bytestring`, `clock`, `stm`, `text`, `vulkan-api`, `managed`, `sdl2`, `lens`, `linear`, `JuicyPixels`, etc.) have **no version bounds**.
- **Proposed fix:** Add lower bounds based on what's available in the Nix flake (`ghc98`, nixos-unstable). For example:
  ```cabal
  build-depends: base >=4.17 && <4.22
               , bytestring >=0.11
               , text >=2.0
               , vulkan-api >=3.23
               , sdl2 >=2.5
               , linear >=1.22
               , lens >=5.2
  ```
- **Feasibility:** Low effort. Use `ghc-pkg list` in the devShell to find current versions and set them as lower bounds.

### 6.3 `executable` depends on `haskan2` library only
- **Location:** `haskan2.cabal:93-111`
- **Problem:** The executable only brings in `base` and `haskan2`. This is correct, but the commented-out `gltf-codec` suggests previous confusion.
- **Assessment:** No action needed beyond cleanup.

### 6.4 `default-extensions` duplication
- **Location:** `haskan2.cabal:89-91`, `111-112`
- **Problem:** `OverloadedStrings` and `DataKinds` are declared in both `library` and `executable` sections. Since the executable only imports the library, it doesn't need `DataKinds` unless `Main.hs` uses it (it doesn't).
- **Proposed fix:** Remove `default-extensions` from the `executable` section entirely, or keep only `OverloadedStrings` if needed.
- **Feasibility:** Trivial.

---

## 7. Summary Table

| # | File | Line | Severity | Category | Fix Effort |
|---|------|------|----------|----------|------------|
| 1 | `Engine.hs` | 496-519 | P0 | Bug (broken logic) | Trivial |
| 2 | `Buffer.hs` | 36, 99 | P0 | Bug (partial function) | Trivial |
| 3 | `Engine.hs` | 1-540 | P1 | Architecture (monolith) | Medium |
| 4 | `Model.hs` | 224, 238 | P1 | Anti-pattern (`fromJust`) | Trivial |
| 5 | `Model.hs` | 269 | P1 | Bug (partial `head`/`tail`) | Trivial |
| 6 | `Model.hs` | 220 | P1 | Anti-pattern (`fail` in pure) | Low |
| 7 | Multiple | Various | P1 | Dead code | Trivial |
| 8 | `Render.hs` | 4-11 | P1 | Duplication (re-export) | Trivial |
| 9 | `Face.hs` | 5-30 | P2 | Verbosity (phantom constraints) | Trivial |
| 10 | Multiple | Various | P2 | Style (parentheses) | Trivial |
| 11 | `Texture.hs` | 47 | P2 | Performance (Vector→List) | Medium |
| 12 | `Model.hs` | 271 | P2 | Style (`all id`) | Trivial |
| 13 | `Camera.hs` | 91-92 | P2 | Verbosity (trivial wrapper) | Trivial |
| 14 | `Engine.hs` | 371-375 | P2 | Verbosity (identity composition) | Trivial |
| 15 | `Engine.hs` | 357-363 | P2 | Style (`if` → `unless`) | Trivial |
| 16 | `Vertex.hs` | 26 | P2 | Bug-risk (hardcoded alignment) | Trivial |
| 17 | `Vertex.hs` | 27-44 | P2 | Maintainability (offset sync) | Medium |
| 18 | `Swapchain.hs` | 136 | P2 | Logging (wrong name) | Trivial |
| 19 | `haskan2.cabal` | — | P2 | Tests (missing) | Medium |
| 20 | `haskan2.cabal` | — | P2 | Build (version bounds) | Low |

---

## 8. Blocked Refactorings

The following patterns were considered but deemed not feasible or not worth the effort:

| Pattern | Blocker |
|---------|---------|
| Generic Vulkan `createVkResource` helper | Each Vulkan `createInfo` has unique `set`/`setListRef` fields and different `sType`. A generic function would need to accept the fully-built `createInfo`, which is what `withPtr` already does. TH could solve it, but TH adds complexity to a low-level graphics project. |
| Merge all `managedX`/`createX` pairs into one function | `alloc` requires separate `create` and `destroy` actions. The `create` action often needs `withPtr` scoping. Keeping them separate is the idiomatic `managed` pattern. |
| Use `Vector` everywhere instead of lists for buffers | Feasible but medium effort. The `Storable` interface for `Vector` requires `unsafeWith`, and all buffer call sites use lists. Recommendation: do this only if profiling shows the list conversion is a bottleneck. |

---

*Report generated by static analysis of the haskan2 codebase. All line numbers refer to the state of the repository as of 2026-05-06.*
