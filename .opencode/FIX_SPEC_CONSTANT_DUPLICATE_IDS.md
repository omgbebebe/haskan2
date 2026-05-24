# Fix: FIR specConstant Duplicate IDs → Invalid SPIR-V

**Status**: Planned  
**Priority**: P0 (invalid SPIR-V, Vulkan validation failure, potential driver crash)  
**Scope**: `3rdparty/fir/` (4 files) + new regression test

---

## Root Cause Analysis

### The Bug

When `specConstant @N @T defaultVal` is referenced more than once in a FIR shader, the compiler generates:

1. **N fresh result IDs** — one per codegen encounter
2. **N `OpDecorate ... SpecId` instructions** — one per ID (accumulated in `decorations` map)
3. **Only 1 `OpSpecConstant` definition** — the last one (overwrites previous in `knownConstants` map)

This produces invalid SPIR-V: IDs are decorated and used in body instructions but never defined.

### Why It Happens — Code Trace

**`CodeGen/IDs.hs:452-482` — `specConstantID`**:

```haskell
specConstantID specId a = do
  ...
  SScalar {} ->
    createID _knownAConstant        -- ← BUG: always creates NEW, never checks cache
      ( \v -> do
           addSpecIdDec v            -- adds decoration for each fresh ID
           return Instruction { ... }
      )
  where
    _knownAConstant = _knownConstant (aConstant a)  -- key = value only
```

`createID` (from `CodeGen/Monad.hs:133-135`) unconditionally generates a fresh ID:

```haskell
createID _key mk = fst <$> create _key mk

create _key mk = do
  v <- fresh          -- always new ID
  a <- mk v           -- always runs mk (adds decoration + builds instruction)
  assign _key (Just a) -- OVERWRITES previous entry at same key
  pure (v, a)
```

Each call:
1. Generates fresh ID (187, 196, 204, ..., 307)
2. Adds `SpecId` decoration for that ID → accumulated, never removed
3. Stores `Instruction` in `knownConstants` at key `AConstant a` → overwrites previous
4. Returns the fresh ID → body instructions (OpFMul etc.) reference it

**After N calls**:
- `decorations` map: `{187: {SpecId 0}, 196: {SpecId 0}, ..., 307: {SpecId 0}}` — N entries
- `knownConstants` map: `{AConstant 0.0003: Instruction{resID=307}}` — 1 entry (last wins)
- Body instructions reference IDs 187, 196, etc. — **undefined**

### Why Regular Constants Work

`constID` (line 327) uses `tryToUseWith` which checks the cache FIRST:

```haskell
constID a =
  tryToUseWith _knownAConstant      -- checks cache, reuses if found
    ( fromJust . resID )
    do ...                           -- only creates if not cached
```

### Why `astMemo` Doesn't Prevent It

FIR has an AST-level memoization table (`astMemo :: IntMap [(StableName (), ID, SPIRV.PrimTy)]`) that uses `StableName` for object identity. In theory, shared AST nodes should be memoized. In practice:

1. **Loop/conditional resets**: `CFG.hs:498` restores `astMemo` to pre-loop state after loop body codegen. Spec constants used in loops lose memoization.
2. **GHC optimizer may duplicate thunks**: Pure `let noiseScale = specConstant ...` bindings can be duplicated by GHC's inliner, creating separate heap objects with different `StableName`s.
3. **Fragile by design**: `StableName`-based memoization is an optimization, not a correctness mechanism. The correct deduplication must happen at the constant-definition level.

### Additional Deficiency: Cache Key Collision

The cache key `aConstant a` is **value-only** — it does not include `specId`. Two bugs result:

1. **Spec-to-spec collision**: `specConstant @0 1.0` and `specConstant @1 1.0` share key `AConstant 1.0`. Second call overwrites first's `knownConstants` entry → wrong SpecId on the definition.
2. **Spec-to-regular collision**: `specConstant @0 1.0` and `Lit 1.0` share key `AConstant 1.0`. If regular const is emitted first, spec constant reuses it → no `OpSpecConstant`, no SpecId decoration.

---

## Fix Design

### Strategy: Separate Spec Constant Cache

Add a dedicated `knownSpecConstants` map with a key that includes SpecId, and change `specConstantID` to check this cache before creating.

### Changes Required

#### 1. New cache key type — `FIR/Prim/Types.hs`

```haskell
data ASpecConstant where
  ASpecConstant :: PrimTy ty => Word32 -> ty -> ASpecConstant

deriving instance Show ASpecConstant

instance Eq ASpecConstant where
  ASpecConstant (sid1 :: ty1) (a1 :: t1) == ASpecConstant (sid2 :: ty2) (a2 :: t2)
    = sid1 == sid2
    && case eqT @t1 @t2 of
         Just Refl -> a1 == a2
         Nothing   -> False

instance Ord ASpecConstant where
  ASpecConstant (sid1 :: ty1) (a1 :: t1) `compare` ASpecConstant (sid2 :: ty2) (a2 :: t2)
    = case compare sid1 sid2 of
        EQ -> case eqT @t1 @t2 of
                Just Refl -> compare a1 a2
                Nothing   -> compare (primTy @t1) (primTy @t2)
        c  -> c
```

#### 2. New state field — `CodeGen/State.hs`

Add to `CGState`:
```haskell
, knownSpecConstants :: Map ASpecConstant Instruction
```

Initial value: `Map.empty`

Add lenses:
```haskell
_knownSpecConstants :: Lens' CGState (Map ASpecConstant Instruction)
_knownSpecConstants = lens knownSpecConstants (\s v -> s { knownSpecConstants = v })

_knownSpecConstant :: ASpecConstant -> Lens' CGState (Maybe Instruction)
_knownSpecConstant sc = _knownSpecConstants . at sc
```

#### 3. Fix `specConstantID` — `CodeGen/IDs.hs`

Replace `createID` with `tryToUseWith`:

```haskell
specConstantID specId a = do
  resTyID <- typeID (primTy @a)
  let addSpecIdDec v = addDecoration v (SPIRV.SpecId @Word32 specId)
      _key = _knownSpecConstant (ASpecConstant specId a)
  tryToUseWith _key
    ( fromJust . resID )
    ( case primTySing @a of
        SBool ->
          createID _key
            ( \v -> do
                 addSpecIdDec v
                 return Instruction
                   { operation = if a then SPIRV.Op.SpecConstantTrue else SPIRV.Op.SpecConstantFalse
                   , resTy     = Just resTyID
                   , resID     = Just v
                   , args      = EndArgs
                   }
            )
        SScalar {} ->
          createID _key
            ( \v -> do
                 addSpecIdDec v
                 return Instruction
                   { operation = SPIRV.Op.SpecConstant
                   , resTy     = Just resTyID
                   , resID     = Just v
                   , args      = Arg a EndArgs
                   }
            )
        _ -> throwError "specConstantID: only scalar and bool types are supported"
    )
```

This mirrors how `constID` uses `tryToUseWith`: check cache first, create only if missing.

#### 4. Binary serialization — `CodeGen/Binary.hs`

Update `putTypesAndConstants` to include `knownSpecConstants`:

```haskell
putTypesAndConstants
  :: Map types     Instruction
  -> Map constants Instruction
  -> Map specConst Instruction
  -> Binary.Put
putTypesAndConstants ts cs scs
  = traverse_ putInstruction
      ( sortOn resID $ Map.elems ts ++ Map.elems cs ++ Map.elems scs )
```

Update `putModule` to pass `knownSpecConstants` to `putTypesAndConstants`.

#### 5. ID compaction — `CodeGen/Binary.hs`

Update `compactIDs` and `rewriteCGState`:

```haskell
-- In collectCGStateIDs:
for_ (Map.elems $ knownSpecConstants s) addInstructionIDs

-- In rewriteCGState:
, knownSpecConstants = Map.map (mapInstructionIDs f) (knownSpecConstants s)
```

#### 6. Update imports/exports — `CodeGen/State.hs`, `CodeGen/IDs.hs`

Export `knownSpecConstants`, `_knownSpecConstants`, `_knownSpecConstant`, `ASpecConstant`.

#### 7. Show instance update — `CodeGen/State.hs`

Add `knownSpecConstants` to the `Show CGState` instance (or omit for brevity like `astMemo`).

---

## Regression Test

Create `3rdparty/fir/test/Tests/SpecConstants/RepeatedUse.hs`:

```haskell
module Tests.SpecConstants.RepeatedUse where

import FIR
import Math.Linear

-- Test: spec constant used multiple times should produce single OpSpecConstant
type Defs =
  '[ "in_col"  ':-> Input  '[ Location 0 ] (V 4 Float)
   , "out_col" ':-> Output '[ Location 0 ] (V 4 Float)
   , "main"    ':-> EntryPoint '[ OriginLowerLeft ] Fragment
   ]

program :: Module Defs
program = Module $ entryPoint @"main" @Fragment do
  col <- get @"in_col"
  let scale = specConstant @0 @Float 1.0
  -- Use scale 4 times — should produce exactly 1 OpSpecConstant
  let r = (col ^. _x) * scale
      g = (col ^. _y) * scale
      b = (col ^. _z) * scale
      a = (col ^. _w) * scale
  put @"out_col" (Vec4 r g b a)
```

**Validation**: compile with FIR, run `spirv-val` on output. Should pass (currently fails with "ID has not been defined").

---

## Migration Path for haskan2

After FIR fix:

1. Update FIR submodule to include fix
2. Re-enable spec constants in affected shaders:
   - `APVolume.hs`: `noiseScale = specConstant @0 @Float 0.0003`
   - `Lighting.hs`: `nearVal`, `farVal` as spec constants
   - `LightingProcedural.hs`: same
   - `Clouds.hs`: `stepCountF = specConstant @0 @Float 96.0` (already works — single use)
3. Revert hardcoded literal workarounds
4. Validate all shaders with `spirv-val`
5. Add runtime specialization via `Specialization.hs` infrastructure

---

## Risk Assessment

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Key collision with existing `knownConstants` | None | Separate map entirely |
| Break existing single-use spec constants | Low | `tryToUseWith` falls through to `createID` on cache miss |
| ID compaction misses spec constants | Low | Explicit `collectCGStateIDs` update |
| spirv-opt interaction | Low | Spec constants are pre-optimization; compaction handles renumbering |

---

## Files Modified (FIR)

| File | Change |
|------|--------|
| `src/FIR/Prim/Types.hs` | Add `ASpecConstant` type, Eq, Ord instances |
| `src/CodeGen/State.hs` | Add `knownSpecConstants` field + lenses |
| `src/CodeGen/IDs.hs` | Fix `specConstantID`: `createID` → `tryToUseWith` with spec key |
| `src/CodeGen/Binary.hs` | Update `putTypesAndConstants`, `compactIDs`, `rewriteCGState` |
| `test/Tests/SpecConstants/RepeatedUse.hs` | New regression test |

## Files Modified (haskan2) — After FIR Fix

| File | Change |
|------|--------|
| `3rdparty/fir` | Submodule update |
| `src/.../Shaders/Compute/APVolume.hs` | Re-enable `noiseScale = specConstant @0 @Float 0.0003` |
| `src/.../Shaders/Deferred/Lighting.hs` | Re-enable `nearVal`/`farVal` spec constants |
| `src/.../Shaders/Deferred/LightingProcedural.hs` | Same |
