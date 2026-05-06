# Haskell Codebase Analysis Prompt

Analyze this Haskell codebase for maintainability, performance, correctness, and style. Produce a detailed report at `./.opencode/REPORT_CODEBASE_ANALISIS.md`.

## 1. Architecture & Language Constraints (MUST check first)

- **Type class constraints vs explicit dictionary passing** — identify functions with heavy `MonadIO m, MonadReader Env m, MonadError e m` constraint soup. Can they be simplified?
- **Implicit parameters** (`?var :: Type`) — rare but problematic for refactoring; note if used
- **GADTs and serialization** — check if GADTs derive `Generic`/`ToJSON`/`FromJSON`. GADTs with existential types BREAK automatic Aeson derivation
- **Module dependency graph** — identify cycles, hub modules that everything imports, and leaf modules that could be extracted
- **Import style** — qualified imports (`import Data.Text as T`) vs explicit imports (`import Data.Text (Text, pack)`). Unqualified imports of large modules (e.g., `import Data.List` without qualification) cause name collision risks
- **Unnecessary explicit module qualification** — `Prelude.id` or `Data.List.sort` in code where the module is already imported unqualified or qualified under a short alias
- **`do` notation vs `>>=` chains** — `x >>= \a -> y >>= \b -> z` should be rewritten as `do { a <- x; b <- y; z }` for readability
- **Point-free obsession** — excessively point-free code like `f = g . h . i . j . k` where named arguments would be clearer
- **Mutual recursion blocks** — huge `let`/`where` mutual blocks should use top-level declarations with explicit type signatures
- **Module size** — modules >300-500 LOC should be split into submodules by domain
- **Record fields** — check for namespace pollution from record field names (use `DuplicateRecordFields` or lens prefixes if needed)

## 2. Style Compliance

- **Line length** — 80-100 chars (check project's STYLE.md or use 80 as default)
- **Indentation** — 2 spaces, never tabs (or match existing project style)
- **Import organization** — grouped as: external libs, project-internal, qualified last
- **Type signatures** — all top-level bindings must have explicit signatures; warn on missing ones
- **`$` vs parentheses** — `f $ g $ h x` vs `f (g (h x))`; prefer `$` for right-associative chains, but don't overuse
- **Lambda style** — `\x -> x + 1` is fine; `\x -> case x of` should be a named function with pattern matching
- **Blank lines** — between top-level definitions only; no extra blank lines inside `where` blocks
- **Language pragmas** — minimize; don't enable globally what one module needs. Check for redundant pragmas

## 3. Anti-Patterns in Haskell

- **Manual Either chaining** — `case x of Left e -> Left e; Right v -> case y v of ...` should use `ExceptT` or `either` helper
- **Stringly-typed dispatch** — `String`/`Text` used as enums. Check if sum types are feasible given JSON serialization
- **Manual recursion** — `go` loops where `map`, `filter`, `foldl'`, `traverse`, `forM_` would suffice. **Note**: `foldl` is lazy and leaks space; always prefer `foldl'` or `foldr` depending on structure
- **Missing applicative combinators** — `f <$> x <*> y` instead of `do { a <- x; b <- y; pure (f a b) }` when there's no dependency between `x` and `y`
- **`forM_`/`mapM_` vs explicit loops** — manual `loop :: [a] -> IO ()` where `forM_` works
- **Nested `case` chains** — `case x of Just a -> case y of Just b -> ...` should use `Maybe` combinators (`liftA2`, `guard`, etc.) or `do` notation
- **Monolithic modules** — >500 LOC without clear separation of concerns
- **Partial functions** — `head`, `tail`, `fromJust`, `read` without guards. GHC 9.8+ warns on these with `-Wx-partial`; check if warnings are enabled
- **Lazy pattern matching** — `let (a,b) = expensive` when only `a` is used (space leak risk)
- **String instead of Text/ByteString** — `String` (linked list of Char) in performance-critical or IO paths
- **`error`/`undefined`** — runtime crash bombs; prefer `Maybe`, `Either`, or `throwIO`

## 4. Duplicated Code

- Repeated control-flow patterns (load config -> validate -> run)
- Nearly-identical handler functions (CRUD routes)
- Duplicated JSON encoding/decoding logic
- Duplicated SQL query construction
- **BEFORE generalizing**: check if the duplication is locked behind different `Monad` constraints or type class dictionaries that prevent easy extraction
- Check if type class instances can be derived (`DerivingVia`, `GeneralizedNewtypeDeriving`) instead of manual copies

## 5. Unnecessary Verbosity

- Raw string concatenation (`++`) instead of `unlines`, `intercalate`, or Aeson `encode`
- Trivial eta-reduced wrappers (`addOne = (+1)` is fine; `process = f . g . h` with no name might not be)
- Explicit module qualification where unqualified works (e.g., `Prelude.id` when `id` is unambiguous)
- Manual JSON `Object` construction where `ToJSON` deriving or `Aeson` TH works
- Explicit type applications where type inference handles it (`f @Int x` when `f x` compiles)
- Overuse of `{-# LANGUAGE #-}` pragmas in every file instead of centralizing in `.cabal`/`package.yaml`

## 6. Advanced Patterns — WITH FEASIBILITY CHECKS

**Before recommending ANY of the following, verify:**
- **GADTs**: Will type indices break Aeson serialization? Can you use `StandaloneDeriving` or manual instances?
- **MTL-style transformers**: Does the code already use `ReaderT`/`ExceptT`? Can you add `MonadLogger` or similar without constraint explosion?
- **Effect systems** (`effectful`, `polysemy`, `freer-simple`): Is the project large enough to justify the learning curve? Are they in dependencies already?
- **Lens/optics**: For deeply nested record updates. Is `lens` or `optics` already a dependency? If not, is `microlens` or `generic-lens` lighter?
- **DerivingVia**: Can newtype boilerplate be replaced with `deriving X via Y`?
- **StrictData**: Are records lazily accumulating thunks? Would `StrictData` pragma help?

**If a pattern is blocked by language constraints or dependencies, DOCUMENT THE BLOCKER instead of proposing it.**

## 7. Dead Code

- Unused imports (GHC warns with `-Wunused-imports`)
- Top-level bindings not exported and not used internally
- Stub functions (`undefined`, `error "TODO"`, `pure ()`)
- Constructors in sum types with no pattern match case
- Unused language pragmas
- Commented-out code blocks older than last commit
- Dependencies in `.cabal` not actually imported anywhere

## 8. Performance Issues & Function Fusions

- **`foldl` (lazy) instead of `foldl'` (strict)** — classic space leak
- **`map f . map g`** → `map (f . g)` (fusion)
- **`concat . map f`** → `concatMap f`
- **`reverse . sort`** → `sortBy (flip compare)` (if ordering allows)
- **List appends in loops** — `xs ++ [x]` in recursive loops is O(n²); use `DList` or build reversed then `reverse`
- **Repeated `length` on lists** — O(n) each time
- **Boxed vectors where unboxed work** — `Vector Int` vs `U.Vector Int`
- **String/Text conversions in hot loops**
- **Deeply nested `case` chains** where pattern matching at the function head is clearer
- **Redundant `fmap`/`liftM`** — `fmap id` = `id`, `fmap f . fmap g` = `fmap (f . g)`

## 9. Unnecessary Parentheses

- `$` over-parenthesization: `f $ (g x)` → `f $ g x`
- Section syntax: `(+1)` is fine; `(\x -> x + 1)` should be `(+1)`
- Tuple patterns: `f (a,b) = ...` is fine; `f pair = case pair of (a,b) -> ...` should pattern-match in the argument
- Excessive grouping around `.` and `$` composition chains

## 10. Test Framework

- Is there a test suite? (`test-suite` in `.cabal`)
- Current framework: `tasty`, `hspec`, `HUnit`, `QuickCheck`, `hedgehog`?
- Does it suit the codebase? (Property testing for pure logic, golden tests for CLI output, integration tests for API)
- Test coverage: are edge cases tested? Error paths?
- Are tests pure or do they hit external services?
- Would `doctest` help for function documentation examples?
- Is `tasty` used as a unified runner if multiple frameworks are mixed?

## 11. Cabal/Build Configuration

- **Bounds** — are version bounds on dependencies present and accurate? `base` bound should match tested GHC versions
- **Redundant dependencies** — packages listed in `build-depends` but never imported
- **GHC options** — are warnings enabled? (`-Wall`, `-Wcompat`, `-Widentities`, `-Wincomplete-record-updates`, `-Wincomplete-uni-patterns`, `-Wmissing-export-lists`, `-Wmissing-home-modules`, `-Wpartial-fields`, `-Wredundant-constraints`, `-Wtabs`, `-Wunused-packages`)
- **Multiple package versions** — `cabal.project` with `source-repository-package` or `allow-newer` hacks that indicate upstream issues
- **Missing `cabal-version`** field or outdated spec version

---

## MANDATORY OUTPUT FORMAT

For EVERY complaint, provide:

1. **Location** — file and line number
2. **Severity** — P0 (critical: runtime bugs, security), P1 (high: maintainability, performance), P2 (nice to have: style)
3. **Current code** — the problematic pattern (3-10 lines max)
4. **Proposed fix** — the improved code
5. **Feasibility assessment** — whether the fix is actually achievable given:
   - Type class constraints preventing extraction
   - JSON serialization requirements
   - Module dependency constraints
   - Existing monad transformer stack compatibility
   - GHC version limitations
6. **If BLOCKED, document WHY** — don't propose impossible refactorings

## COMPILATION VERIFICATION RULE

If you are unsure whether a proposed refactoring will compile (especially with GADTs, type families, or advanced type features):

1. Create a minimal `.hs` file reproducing the pattern
2. Add it to `dist-newstyle/tmp/` or a temp directory
3. Try to compile with `ghc -c` or `cabal repl`
4. If it fails, adjust the proposal or document the blocker
5. Clean up temp files after verification

Store the final report at `./.opencode/REPORT_CODEBASE_ANALISIS.md`
