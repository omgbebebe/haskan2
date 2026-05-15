# Milestone: FIR Compiler Quality-of-Life Improvements

**Status**: COMPLETE
**Priority**: #1 (texture reference checking) is HIGH — saves 20min per typo at scale. #2 and #3 are MEDIUM.
**Estimate**: ~16h total (#1: 6h, #2: 6h, #3: 4h)
**Branch**: feature/fir-qol-improvements (branched from FIR fork at `3rdparty/fir`)

---

## Problem Statement

FIR's compile-time safety is excellent for coordinate types and format consistency, but three pain points cause wasted debugging time:

1. **Texture name typos** produce incomprehensible "rigid skolem" or generic GHC type errors instead of "texture X not found, did you mean Y?"
2. **Descriptor set layouts** must be manually kept in sync between FIR `FragmentDefs` types and `DescriptorSetLayout.hs` — a constant source of binding mismatches
3. **Lazy pattern requirement** (`~(Vec4 r g b a)`) is easy to forget and produces an incomprehensible error when omitted

---

## Improvement #1: Compile-Time Texture Reference Checking (HIGH PRIORITY)

### Current Behavior

When `use @(ImageTexel "weather_map")` references a texture name not in `FragmentDefs`:

1. `ImageTexel "weather_map"` decomposes to `Field_ "weather_map" :.: RTOptic_` (Syntax/Images.hs:137-161)
2. `LookupImageProperties "weather_map" state` calls `Lookup "weather_map" bindingsMap` (Validation/Images.hs:100-102)
3. `Lookup` returns `'Nothing` for missing keys (Data/Type/Map.hs:54-57)
4. `ImagePropertiesFromLookup` matches the `Nothing` case and emits `TypeError "Expected an image, but nothing is bound by name weather_map"` (Validation/Images.hs:112-115)

**This already works for the "name doesn't exist" case.** However, the error is not reached if the problem manifests earlier as a type unification failure in the injective type family `ImageTexel` or the `Gettable` instance constraint resolution — GHC gives up with "rigid skolem" or "could not deduce" before reaching FIR's `TypeError`.

### Root Cause

The error path depends on whether `LookupImageProperties` is actually reduced. If GHC's constraint solver gets stuck earlier (e.g., ambiguous type variable in a polymorphic context), the custom `TypeError` in `ImagePropertiesFromLookup` is never evaluated. The injective type family `ImageTexel` with its `forall i props ops imgCds k` quantification can cause GHC to emit skolem errors before the lookup happens.

### Implementation Plan

#### Phase 1: Improve the existing `ImagePropertiesFromLookup` error message (1h)

**File**: `3rdparty/fir/src/FIR/Validation/Images.hs:104-120`

Enhance the `Nothing` branch to list available texture names:

```haskell
type family AllImageNames (i :: BindingsMap) :: [Symbol] where
  AllImageNames '[] = '[]
  AllImageNames ((k ':-> (Var _ (Image _))) ': rest) = k ': AllImageNames rest
  AllImageNames ((k ':-> (Var _ (RuntimeArray (Image _)))) ': rest) = k ': AllImageNames rest
  AllImageNames (_ ': rest) = AllImageNames rest
```

Then update the error:

```haskell
ImagePropertiesFromLookup k i Nothing
  = TypeError
      ( Text "No image bound by name " :<>: ShowType k :<>: Text "."
      :$$: Text "Available images: " :<>: ShowType (AllImageNames i)
      )
```

**Verification**: Create a test shader with `use @(ImageTexel "typo_name")` and confirm the error lists actual texture names.

#### Phase 2: Add early validation constraint at `use` call sites (2h)

**File**: `3rdparty/fir/src/FIR/Syntax/Images.hs` — the `Gettable` instance for `ImageTexel`

The `Gettable` instance at line 167-191 already requires `LookupImageProperties k i ~ props`. Add a redundant constraint that triggers before unification gets stuck:

```haskell
instance ( ..., CheckImageExists k i ) => Gettable (ImageTexel k) where
```

Where:

```haskell
type family CheckImageExists (k :: Symbol) (i :: ProgramState) :: Constraint where
  CheckImageExists k ('ProgramState bindings _ _ _ _ _ _ _)
    = CheckImageExistsInBindings k bindings (Lookup k bindings)

type family CheckImageExistsInBindings (k :: Symbol) (i :: BindingsMap) (lookup :: Maybe Binding) :: Constraint where
  CheckImageExistsInBindings _ _ (Just (Var _ (Image _))) = ()
  CheckImageExistsInBindings _ _ (Just (Var _ (RuntimeArray (Image _)))) = ()
  CheckImageExistsInBindings k i Nothing =
    TypeError ( Text "Texture " :<>: ShowType k :<>: Text " not declared in shader definitions."
              :$$: Text "Available images: " :<>: ShowType (AllImageNames i)
              )
  CheckImageExistsInBindings k _ (Just other) =
    TypeError ( Text "Name " :<>: ShowType k :<>: Text " exists but is not an image."
              :$$: Text "Found: " :<>: ShowType other
              )
```

This constraint is evaluated during instance resolution, *before* the injective type family unification, ensuring the custom error fires reliably.

**Verification**: Confirm that `use @(ImageTexel "blue_nois")` (typo) produces the enhanced error even in deeply nested monadic contexts.

#### Phase 3: Add `NearbyNames` suggestions for typos (1h)

Add a type family that computes edit-distance-1 candidates from the available names. This is complex at the type level, so a simpler approach: just list all names and let the user spot the typo. If desired, a `Symbol` prefix-match type family can be added:

```haskell
type family NamesWithPrefix (pre :: Symbol) (names :: [Symbol]) :: [Symbol] where
  NamesWithPrefix _ '[] = '[]
  NamesWithPrefix pre (n ': rest) = If (HasPrefix pre n)
    ( n ': NamesWithPrefix pre rest )
    ( NamesWithPrefix pre rest )
```

This is optional polish — Phase 1 and 2 already solve the core problem.

#### Phase 4: Test suite (2h)

Create test shaders that exercise all error paths:
- `Test_TypoTextureName.hs` — typo in texture name
- `Test_NonImageName.hs` — referencing a uniform buffer by name as if it were a texture
- `Test_CorrectTextureName.hs` — baseline, should compile
- `Test_BindlessTextureName.hs` — RuntimeArray of images

Each test should be a standalone FIR program module. Compilation is the test — the error message text can be verified by `cabal check` or `grep` on compiler output.

**Deliverables**:
- Enhanced `TypeError` messages in `Validation/Images.hs`
- New `CheckImageExists` constraint family
- `AllImageNames` type family for listing available textures
- 4 test shaders

**Estimated time**: 6h

---

## Improvement #2: Auto-Generate Descriptor Set Layout Bindings from Shader Types (MEDIUM)

### Current Behavior

Each shader pass requires two manually-maintained artifacts:

1. **FIR type** in e.g. `Shaders/Deferred/Clouds.hs`:
   ```haskell
   type CloudFragmentDefs =
     '[ "cloud_noise" ':-> Texture3D '[Binding 0, DescriptorSet 0] (RGBA8 UNorm)
      , "worley_noise" ':-> Texture3D '[Binding 1, DescriptorSet 0] (RGBA8 UNorm)
      , "curl_noise"  ':-> Texture2D '[Binding 2, DescriptorSet 0] (RGBA8 UNorm)
      , ...
      ]
   ```

2. **Vulkan layout** in `DescriptorSetLayout.hs`:
   ```haskell
   createCloudDescriptorSetLayout dev = do
     createDescriptorSetLayoutSafe dev
       [ Vk.DescriptorSetLayoutBinding
           { binding = 0
           , descriptorType = Vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
           , ...
           }
       , Vk.DescriptorSetLayoutBinding
           { binding = 1
           , descriptorType = Vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
           , ...
           }
       , ...
       ]
   ```

Any mismatch (wrong binding number, wrong descriptor type, missing binding) causes a runtime Vulkan validation error or silent misrendering.

### What's Needed

A Template Haskell splice or type family that reads `CloudFragmentDefs` and produces `[Vk.DescriptorSetLayoutBinding]` at compile time. Since `FragmentDefs` is a type-level list with full binding/descriptor-set/type info, all the data is already there.

### Why TH, Not Type Families

Type families operate at the type level and cannot produce Haskell *values* like `[Vk.DescriptorSetLayoutBinding]`. Template Haskell can:
1. Reify the `CloudFragmentDefs` type at compile time
2. Extract binding numbers, descriptor set indices, and SPIR-V types
3. Emit Haskell code constructing the Vulkan struct values

### Implementation Plan

#### Phase 1: Type-level descriptor extraction families (2h)

**New file**: `3rdparty/fir/src/FIR/TH/DescriptorLayout.hs`

First, define type families that extract the descriptor info FIR already has:

```haskell
-- Extract binding/decorator pairs from Definitions
type family DescriptorBindings (defs :: Definitions) :: [(Nat, Nat, DescriptorKind)] where
  DescriptorBindings '[] = '[]
  DescriptorBindings ((name ':-> Global Storage.UniformConstant decs (Image props)) ': rest)
    = MaybeDescriptorBinding decs ImageDescriptor ': DescriptorBindings rest
  DescriptorBindings ((name ':-> Global Storage.Uniform decs (Struct as)) ': rest)
    = MaybeDescriptorBinding decs UniformBufferDescriptor ': DescriptorBindings rest
  DescriptorBindings ((name ':-> Global Storage.StorageBuffer decs (Struct as)) ': rest)
    = MaybeDescriptorBinding decs StorageBufferDescriptor ': DescriptorBindings rest
  -- skip non-descriptor definitions (inputs, outputs, entry points)
  DescriptorBindings (_ ': rest) = DescriptorBindings rest

type family MaybeDescriptorBinding (decs :: [Decoration Nat]) (kind :: DescriptorKind) :: Maybe (Nat, Nat, DescriptorKind) where
  MaybeDescriptorBinding decs kind = MaybeDescriptorBinding' (ExtractDescriptorSet decs) (ExtractBinding decs) kind

type family MaybeDescriptorBinding' (ds :: Maybe Nat) (b :: Maybe Nat) (k :: DescriptorKind) :: Maybe (Nat, Nat, DescriptorKind) where
  MaybeDescriptorBinding' (Just ds) (Just b) k = Just '(ds, b, k)
  MaybeDescriptorBinding' _ _ _ = Nothing
```

These families reuse `ExtractDescriptorSet` and `ExtractBinding` already defined in `Validation/Definitions.hs:115-125`.

#### Phase 2: Template Haskell splice (3h)

The TH splice `descriptorSetLayoutsFromDefs @CloudFragmentDefs` works as follows:

1. **Reify the type alias** `CloudFragmentDefs` to get its RHS (the type-level list)
2. **Walk the type-level list**: for each `(name ':-> Global storage decs ty)`:
   - Extract `Binding n` and `DescriptorSet m` from `decs`
   - Determine `Vk.DescriptorType` from `storage` and `ty`:
     - `UniformConstant` + `Image _` → `COMBINED_IMAGE_SAMPLER`
     - `UniformConstant` + `RuntimeArray (Image _)` → `COMBINED_IMAGE_SAMPLER` (bindless)
     - `Uniform` + `Struct _` → `UNIFORM_BUFFER`
     - `StorageBuffer` + `Struct _` → `STORAGE_BUFFER`
     - `Image` + `Image _` → `STORAGE_IMAGE`
   - Determine descriptor count (1 for simple, 0/VK_MAX for bindless arrays)
   - Emit `Vk.DescriptorSetLayoutBinding` constructor call
3. **Group by descriptor set index** and return `[Vk.DescriptorSetLayoutBinding]`

```haskell
descriptorSetLayoutBindings :: Name -> Q Exp
descriptorSetLayoutBindings defsName = do
  TyConI (TySynD _ _ defsType) <- reify defsName
  bindings <- extractBindings defsType
  listE $ map mkLayoutBinding bindings
```

The key challenge: TH operates on the AST representation of types, not the type-level values. We need to pattern-match on the TH `Type` representation of things like `'Binding 3`. This is feasible but requires walking `AppT (PromotedT 'Binding) (LitT (NumTyLit n))`.

#### Phase 3: Integration with haskan2's DescriptorSetLayout.hs (1h)

Replace manual layout creation:

```haskell
-- Before:
createCloudDescriptorSetLayout dev = createDescriptorSetLayoutSafe dev [ {- 6 manual bindings -} ]

-- After:
createCloudDescriptorSetLayout dev = createDescriptorSetLayoutSafe dev
  $(descriptorSetLayoutBindings ''CloudFragmentDefs)
```

This produces compile-time errors if `CloudFragmentDefs` is malformed and eliminates the sync burden.

**Caveat**: TH reification of type families can be tricky. If `CloudFragmentDefs` is a type *synonym*, TH can read it directly. If it's a type family instance, it's harder. All haskan2 shader defs are type synonyms, so this should work.

**Deliverables**:
- `FIR.TH.DescriptorLayout` module in FIR fork
- Updated `DescriptorSetLayout.hs` using TH splice for cloud, lighting, and main passes
- Test: change a binding number in `FragmentDefs`, confirm compile-time breakage

**Estimated time**: 6h

---

## Improvement #3: Eliminate the Lazy-Pattern Requirement on Vector Unpack (MEDIUM)

### Current Behavior

FIR's `Program` monad uses `Codensity AST`. The `MonadIxFail` instance for `Codensity AST` is a `TypeError` (Program.hs:1256-1268) — FIR forbids failable patterns entirely.

When you write:
```haskell
Vec4 r g b a <- use @(ImageTexel "cloud_noise") NilOps coords
```

GHC's pattern-match checker sees `Vec4` as a bidirectional pattern synonym with a view pattern (`fromAST -> V4 x y z w`). Since it can't prove the view pattern is exhaustive, it tries to use `MonadIxFail.fail`, which triggers the `TypeError` instance — producing a confusing message about "failable pattern detected."

The fix is to prepend `~`:
```haskell
~(Vec4 r g b a) <- use @(ImageTexel "cloud_noise") NilOps coords
```

This is easy to forget and the error message, while better than "rigid skolem," still doesn't point to the `Vec4` pattern as the problem.

### Root Cause

Two factors:

1. **`Vec4` is a pattern synonym with a view pattern** (`Synonyms.hs:652-655`), so GHC can't prove exhaustiveness
2. **`{-# COMPLETE #-}` pragma exists** (`Synonyms.hs:652`) but GHC still doesn't trust view patterns to be total

### Implementation Plan

#### Phase 1: Add `COMPLETE` pragmas that satisfy GHC's checker (1h)

**File**: `3rdparty/fir/src/FIR/Syntax/Synonyms.hs`

The current `{-# COMPLETE Vec4 #-}` pragma tells GHC that `Vec4` alone is a complete set of patterns for `V 4 a`. However, this doesn't help when the pattern synonym uses a view pattern, because GHC still needs to prove the view (`fromAST -> V4 x y z w`) is total.

**Option A**: Replace the view pattern with a `GADT`-based pattern that GHC can prove exhaustive. This requires changing `fromAST` for `V n a` to produce a `V n (Code a)` directly, which it already does — the issue is the pattern synonym definition.

Current:
```haskell
pattern Vec4 x y z w <- (fromAST -> V4 x y z w)
  where Vec4 x y z w = MkVector (V4 x y z w)
```

The view pattern `fromAST -> V4 x y z w` is the problem. We can instead make `Vec4` a constructor pattern that uses `COMPLETE` and let GHC know it's the only constructor:

**Option B**: Use `pattern` with explicit `ViewPattern` annotation and a `ProvablyTotal` constraint. This is GHC-specific and fragile.

**Option C (Recommended)**: Provide `unpackV4` functions that avoid pattern matching entirely:

```haskell
unpackV4 :: Code (V 4 a) -> (Code a, Code a, Code a, Code a)
unpackV4 v = ( fromAST $ View sLength (opticSing @(Index 0)) :$ v
             , fromAST $ View sLength (opticSing @(Index 1)) :$ v
             , fromAST $ View sLength (opticSing @(Index 2)) :$ v
             , fromAST $ View sLength (opticSing @(Index 3)) :$ v
             )
```

Then shaders use:
```haskell
let (r, g, b, a) = unpackV4 $ use @(ImageTexel "cloud_noise") NilOps coords
```

This is a regular `let` binding, not a pattern match in `do`-notation. No `~` needed. No `MonadIxFail` involved.

#### Phase 2: Provide unpack functions for all vector sizes (1h)

**File**: `3rdparty/fir/src/FIR/Syntax/Synonyms.hs` or new `FIR.Syntax.Unpack`

```haskell
unpackV2 :: Code (V 2 a) -> (Code a, Code a)
unpackV3 :: Code (V 3 a) -> (Code a, Code a, Code a)
unpackV4 :: Code (V 4 a) -> (Code a, Code a, Code a, Code a)
unpackM22 :: Code (M 2 2 a) -> (Code a, Code a, Code a, Code a)
unpackM33 :: Code (M 3 3 a) -> (Code a, ..., Code a)  -- 9 components
unpackM44 :: Code (M 4 4 a) -> (Code a, ..., Code a)  -- 16 components
```

Each one uses `View @(Index i)` directly, identical to what `fromAST` for `V n a` does (AST.hs:1100-1104) but inlined into a tuple-returning function.

#### Phase 3: Update haskan2 shaders to use unpack functions (1h)

Mechanical replacement across all shader files:

```haskell
-- Before:
~(Vec4 r g b a) <- use @(ImageTexel "gbuf_position") NilOps uv

-- After:
let !(r, g, b, a) = unpackV4 $ use @(ImageTexel "gbuf_position") NilOps uv
```

Wait — `use` is monadic, so `let` won't work directly. The actual pattern is:

```haskell
-- Before:
~(Vec4 r g b a) <- use @(ImageTexel "gbuf_position") NilOps uv

-- After:
result <- use @(ImageTexel "gbuf_position") NilOps uv
let !(r, g, b, a) = unpackV4 result
```

This is slightly more verbose but eliminates the `~` footgun entirely. Alternatively, provide a monadic combinator:

```haskell
useV4 :: ... => ops -> coords -> Prog es (Code a, Code a, Code a, Code a)
useV4 ops coords = unpackV4 <$> use @(ImageTexel k) ops coords
```

But this requires the same `ImageTexel k` type application, so it's not cleaner. The two-liner is fine.

#### Phase 4: Keep `Vec4` pattern working with `~` for backwards compat (1h)

Don't remove the pattern synonyms — just add the unpack functions as the recommended API. Update the `MonadIxFail` error message to suggest `unpackV4`:

```haskell
instance TypeError ( Text "Failable pattern detected in 'do' block."
                    :$$: Text ""
                    :$$: Text "For vector unpacking, use:"
                    :$$: Text "  result <- use @(ImageTexel \"name\") NilOps uv"
                    :$$: Text "  let !(r, g, b, a) = unpackV4 result"
                    :$$: Text ""
                    :$$: Text "Or use an irrefutable pattern:"
                    :$$: Text "  ~(Vec4 r g b a) <- use @(ImageTexel \"name\") NilOps uv"
                    ) => MonadIxFail (Codensity AST) where
```

**Deliverables**:
- `unpackV2`, `unpackV3`, `unpackV4` functions in `FIR.Syntax.Synonyms`
- Matrix unpack functions if needed
- Updated error message in `FIR.Syntax.Program`
- Migrated shader code in haskan2
- Old `Vec4` pattern still works with `~` (backwards compatible)

**Estimated time**: 4h

---

## Execution Order

1. **#1 Phase 1** (1h) — quick win, improve error message
2. **#1 Phase 2** (2h) — early validation constraint
3. **#1 Phase 4** (2h) — test suite
4. **#3 Phase 1-2** (2h) — unpack functions in FIR
5. **#3 Phase 3** (1h) — migrate haskan2 shaders
6. **#3 Phase 4** (1h) — update error message
7. **#2 Phase 1** (2h) — type-level extraction families
8. **#2 Phase 2** (3h) — TH splice
9. **#2 Phase 3** (1h) — integrate with haskan2

**Total**: ~16h

---

## Out of Scope

Per the user story:
- Coordinate type checking (Vec2 vs Vec3) — already works
- Format consistency — Vulkan validation's job
- Descriptor pool sizing — runtime concern
- NilOps vs explicit ops — explicit is fine

---

## Key Files Reference

| File | Role |
|------|------|
| `3rdparty/fir/src/FIR/Validation/Images.hs:100-120` | `LookupImageProperties`, `ImagePropertiesFromLookup` — existing error |
| `3rdparty/fir/src/FIR/Syntax/Images.hs:137-191` | `ImageTexel` type family, `Gettable` instance |
| `3rdparty/fir/src/FIR/Syntax/Synonyms.hs:645-655` | `Vec2`, `Vec3`, `Vec4` pattern synonyms |
| `3rdparty/fir/src/FIR/Syntax/AST.hs:1088-1104` | `fromAST` for `V n a` — generates `View @(Index i)` |
| `3rdparty/fir/src/FIR/Syntax/Program.hs:1256-1268` | `MonadIxFail` instance with `TypeError` |
| `3rdparty/fir/src/FIR/Definition.hs:163-166` | `Definition` GADT |
| `3rdparty/fir/src/FIR/Validation/Definitions.hs:115-125` | `ExtractBinding`, `ExtractDescriptorSet` families |
| `3rdparty/fir/src/Data/Type/Map.hs:54-57` | `Lookup` type family |
| `src/Graphics/Haskan/Vulkan/DescriptorSetLayout.hs` | Manual layout creation (to be replaced) |
| `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` | Example shader with `~(Vec4 ...)` patterns |
