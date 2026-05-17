# FIR Pipeline Fixes — Unblocking EEVEE-Parity Rendering

**Status**: Not started
**Priority**: P0 — blocks all advanced rendering milestones
**Estimate**: ~6 weeks total
**Branch**: feature/fir-pipeline-fixes (branched from FIR fork at `3rdparty/fir`)

---

## Overview

Four gaps in FIR prevent haskan2 from implementing EEVEE-class rendering features. Each gap is a missing SPIR-V capability in the EDSL, not a missing algorithm. This milestone closes all four.

| Gap | Blocks | Severity |
|-----|--------|----------|
| No atomic operations | Clustered lighting, virtual shadows, volumetric occupancy | **Critical** |
| Broken `if-then-else` on `Code` types | All complex shaders (raymarching early exit, culling branches) | **Critical** |
| No specialization constants | Multi-variant shader compilation, material permutations | **High** |
| No `OpSelect` codegen | `mix` on vectors, clean conditionals | **High** |

---

## Fix 1: Atomic Operations

**Status**: Not started
**Estimate**: 2 weeks
**SPIR-V Ops**: `OpAtomicLoad`, `OpAtomicStore`, `OpAtomicExchange`, `OpAtomicCompareExchange`, `OpAtomicIIncrement`, `OpAtomicIDecrement`, `OpAtomicIAdd`, `OpAtomicISub`, `OpAtomicSMin`, `OpAtomicSMax`, `OpAtomicUMin`, `OpAtomicUMax`, `OpAtomicAnd`, `OpAtomicOr`, `OpAtomicXor`

### Problem

FIR defines `AtomicCounter` storage class (`SPIRV/Storage.hs:52`) and `AtomicCounterMemory` sync scope (`SPIRV/Synchronisation.hs:126`) but emits **zero** atomic SPIR-V instructions. No `OpAtomic*` exists anywhere in the codebase. `Int64Atomics` and `AtomicStorage` capabilities are declared (`SPIRV/Capability.hs:79-80, 105-106`) but unused.

### What EEVEE Uses

- `atomicAdd` on storage buffers for light grid assignment (clustered lighting)
- `atomicAdd` on image for virtual shadow map page reference counting
- `atomicOr` on 3D image for volumetric occupancy grid
- `atomicExchange`/`atomicCompareExchange` for lock-free data structures
- `atomicCounter` increment/decrement for indirect dispatch count

### Implementation

#### Phase 1A: Type-Level API (3-4 days)

**File**: `3rdparty/fir/src/FIR/Prim/Op.hs`

Add primop definitions for atomic operations. Each atomic op needs:
- Result type (value + optional "original value")
- Memory scope (`Device`, `Workgroup`, `Subgroup`, `Invocation`)
- Memory semantics (`None`, `Acquire`, `Release`, `AcquireRelease`, `SequentiallyConsistent`)

```haskell
data AtomicIAdd
data AtomicISub
data AtomicSMin
data AtomicSMax
data AtomicUMin
data AtomicUMax
data AtomicAnd
data AtomicOr
data AtomicXor
data AtomicExchange
data AtomicCompareExchange
data AtomicIIncrement
data AtomicIDecrement
data AtomicLoad
data AtomicStore
```

Each follows the `PrimOp` pattern:

```haskell
instance (PrimTy a, Integral a) => PrimOp AtomicIAdd a where
  type PrimOpAugType AtomicIAdd a = AugType a
  op = ...
  opName = "AtomicIAdd"
```

Memory scope and semantics as type-level parameters:

```haskell
data MemoryScope = ScopeDevice | ScopeWorkgroup | ScopeSubgroup | ScopeInvocation
data MemorySemantics = SemNone | SemAcquire | SemRelease | SemAcquireRelease | SemSequentiallyConsistent
```

#### Phase 1B: AST Nodes (2-3 days)

**File**: `3rdparty/fir/src/FIR/AST.hs`

Add AST constructors for atomic operations. These are not standard unary/binary ops — they require a pointer (storage buffer or image), memory scope, and memory semantics:

```haskell
pattern AtomicOp :: ... -> AST
```

The AST representation needs:
- Pointer to storage buffer variable (via `Index` optic) or image coordinate
- Atomic operation kind
- Memory scope (enum)
- Memory semantics (enum)
- Operand value (for binops)

#### Phase 1C: Code Generation (3-4 days)

**File**: `3rdparty/fir/src/FIR/AST/CodeGeneration.hs` (or equivalent serialization module)

Emit SPIR-V binary for each atomic op. Format per SPIR-V spec:

```
OpAtomicIAdd %result_type %result %pointer %scope %semantics %value
```

Where:
- `%pointer` = result of indexing into storage buffer or image coordinate
- `%scope` = `Literal` word32 (Device=1, Workgroup=2, Subgroup=3, Invocation=4)
- `%semantics` = `Literal` word32 (bitfield: None=0, Acquire=2, Release=4, etc.)
- `%value` = operand

For `OpAtomicCompareExchange`, two semantics fields and a comparator operand.

Image atomics need `OpImageTexelPointer` to get a pointer into an image at a coordinate.

#### Phase 1D: User-Facing Syntax (2 days)

**File**: `3rdparty/fir/src/FIR/Syntax/AST.hs`

Expose atomic operations in the monadic DSL:

```haskell
-- Storage buffer atomics
atomicAdd :: (HasStorageBuffer name i, PrimTy a, Integral a)
          => Proxy name -> Code Word32    -- index
          -> Code a                       -- value to add
          -> Program i i (Code a)         -- returns original value

atomicExchange :: ... -> Program i i (Code a)

-- Image atomics
atomicImageAdd :: (HasImage name i, ...)
               => Proxy name -> Code (V 3 Word32)  -- coordinate
               -> Code Word32                        -- value
               -> Program i i (Code Word32)
```

#### Phase 1E: Validation & Tests (2 days)

- `spirv-val` must accept generated SPIR-V
- Test: atomic counter increment in compute shader, read back result
- Test: atomic image add on 2D storage image
- Test: `AtomicCompareExchange` for spinlock pattern

### Deliverables

| Item | File |
|------|------|
| 15 atomic primop type families | `FIR/Prim/Op.hs` |
| AST constructors for atomics | `FIR/AST.hs` |
| SPIR-V binary emission for all `OpAtomic*` | CodeGen module |
| `OpImageTexelPointer` emission | CodeGen module |
| User-facing `atomicAdd`, `atomicExchange`, etc. | `FIR/Syntax/AST.hs` |
| Capability emission (`Int64Atomics`, `AtomicStorage`) | CodeGen module |
| Test: atomic counter in compute shader | `test/Tests/Atomics/` |
| Test: image atomic | `test/Tests/Atomics/` |

### Dependencies

- `FIR/Prim/Op.hs` pattern (existing 857 lines of primop infrastructure)
- `SPIRV/Capability.hs` (capabilities already declared)
- `SPIRV/Storage.hs` (`AtomicCounter` already defined)

---

## Fix 2: `if-then-else` on Code Types (Choose Instance Resolution)

**Status**: Not started (see `MILESTONE_FIR_GAPS.md` Issues 2 & 5)
**Estimate**: 1.5 weeks
**SPIR-V Ops**: `OpSelect`, `OpBranchConditional`

### Problem

`if-then-else` on `Code Float` / `Code (V n Float)` fails with overlapping instances in `Chooser` type class. Every conditional in haskan2 uses branchless `step()` workarounds. Both branches always execute, generating dead SPIR-V.

Root cause: `FIR/Syntax/IfThenElse.hs:69-101` — four `Choose` instances with `OVERLAPPABLE` and `INCOHERENT` pragmas. When `x ~ Code Float` and `y ~ Code Float`, GHC cannot resolve between:
- `OVERLAPPABLE` instance (line 69) — general case using `Chooser PureChoice`
- The `Chooser PureChoice` instance (line 106) — requires `PrimTy (InternalType z)`, which works for `Float`
- GHC picks the wrong instance or gives up with "Overlapping instances"

### Implementation

#### Phase 2A: Dedicated `OpSelect` Primop (3-4 days)

**File**: `3rdparty/fir/src/FIR/Prim/Op.hs`

Add `OpSelect` as a first-class primop. This bypasses the `Choose` type class entirely:

```haskell
data Select

instance PrimTy a => PrimOp Select a where
  type PrimOpAugType Select a = AugType a
  -- OpSelect: select between two values based on condition
```

SPIR-V spec: `OpSelect %result_type %result %condition %true_value %false_value`

Works for scalars, vectors, and booleans. This is the correct GPU-native conditional — no branching, no `step()` hacks.

**File**: `3rdparty/fir/src/FIR/AST.hs` + CodeGen

Add AST node for `Select` and emit `OpSelect` in SPIR-V binary.

#### Phase 2B: Fix Choose Instances (2-3 days)

**File**: `3rdparty/fir/src/FIR/Syntax/IfThenElse.hs`

**Option A (Recommended)**: Replace the `OVERLAPPABLE` instance with explicit instances for common types:

```haskell
-- Pure Code values: use OpSelect directly
instance ( PrimTy a
         , x ~ Code a, y ~ Code a, z ~ Code a
         )
      => Choose (Code Bool) '(x, y, z) where
  choose c t f = fromAST (Select :$ c :$ toAST t :$ toAST f)

-- Monadic branches: use OpBranchConditional via IfM
instance ...
```

Remove `OVERLAPPABLE` and `INCOHERENT`. Each instance is unambiguous.

**Option B**: Keep `Chooser` but add `INCOHERENT` to the `PureChoice` instance at line 106. Fragile — may break on other GHC versions.

**Option C**: Add a type family that disambiguates before instance resolution:

```haskell
type family IsPureCode (x :: Type) :: Bool where
  IsPureCode (Code _) = 'True
  IsPureCode _ = 'False
```

Then dispatch on `IsPureCode` in the `Choose` instance head.

#### Phase 2C: Replace `step()` Workarounds in Haskan2 (2 days)

Mechanical replacement across all shader modules:

| File | Pattern | Replace With |
|------|---------|-------------|
| `Clouds.hs` (4+ sites) | `step 0.0 x * x + step x 0.0 * (0.0 - x)` | `if x > 0.0 then x else 0.0 - x` |
| `Lighting.hs` | `step`-based conditionals | `if-then-else` |
| `GBuffer.hs` | any branchless patterns | `if-then-else` |

Also replace manual `lerp` with `mix` (was blocked by Issue 5 in `MILESTONE_FIR_GAPS.md`).

#### Phase 2D: Tests (1 day)

- Test: `if-then-else` on `Code Float`
- Test: `if-then-else` on `Code (V 3 Float)`
- Test: nested `if-then-else`
- Test: `mix a b t` on `Code (V 4 Float)`
- Verify `spirv-val` on all tests

### Deliverables

| Item | File |
|------|------|
| `OpSelect` primop + codegen | `FIR/Prim/Op.hs`, `FIR/AST.hs`, CodeGen |
| Fixed `Choose` instances | `FIR/Syntax/IfThenElse.hs` |
| `mix` on vectors works | Same root fix |
| `abs` for Code types (bonus) | `FIR/Syntax/AST.hs` |
| Migrated shaders | `Clouds.hs`, `Lighting.hs`, `GBuffer.hs` |
| 5 regression tests | `test/Tests/Choose/` |

---

## Fix 3: Specialization Constants

**Status**: Not started
**Estimate**: 1.5 weeks
**SPIR-V Ops**: `OpSpecConstant`, `OpSpecConstantTrue`, `OpSpecConstantFalse`, `OpSpecConstantComposite`, `OpSpecConstantOp`

### Problem

FIR has zero support for specialization constants. No `OpSpecConstant*` anywhere in the codebase. This means:
- Cannot compile one shader with multiple constant configurations
- Must create separate SPIR-V modules per permutation
- EEVEE compiles each material with up to 12 `#define` flags (MAT_DIFFUSE, MAT_SUBSURFACE, MAT_REFRACTION, etc.)

### What Haskan2 Needs

Not full material permutation (has single PBR closure). But useful for:
- Deferred lighting closure count (1 vs 2 vs 3)
- Shadow cascade count (2/3/4)
- SSS sample count
- Volumetric step count
- Debug mode flags (0/1)
- Workgroup size specialization for compute shaders

### Implementation

#### Phase 3A: Type-Level API (2-3 days)

**File**: `3rdparty/fir/src/FIR/Prim/SpecConstant.hs` (new)

```haskell
-- Declaration in module definition
data SpecConstant (name :: Symbol) (ty :: Type) (defaultVal :: k)

-- Usage in shader
specConstant @"closure_count" @Word32 -- yields Code Word32
specConstant @"enable_sss" @Bool      -- yields Code Bool
```

Type-level default values via `KnownNat` / `KnownSymbol` / type literals.

#### Phase 3B: Decoration and Layout (2 days)

**File**: `3rdparty/fir/src/FIR/Decoration.hs` (or equivalent)

Specialization constants use `Decoration SpecId` with a literal ID. Need to:
- Assign sequential `SpecId` during shader compilation
- Track spec constants in `ProgramState`
- Support `SpecConstantOp` for computed specialization constants (`OpSpecConstantOp` allows using spec constants in constant expressions)

#### Phase 3C: Code Generation (2-3 days)

Emit SPIR-V binary:

```
OpDecorate %spec_const SpecId <n>
OpSpecConstant %type %spec_const <default_value>
-- or
OpSpecConstantTrue %type %spec_const
OpSpecConstantFalse %type %spec_const
-- or
OpSpecConstantComposite %type %spec_const %component1 %component2 ...
-- or
OpSpecConstantOp %type %spec_const <opcode> %operand1 ...
```

#### Phase 3D: Runtime Specialization API (2 days)

**File**: `src/Graphics/Haskan/Vulkan/ShaderSpecialization.hs` (new)

Vulkan side: `VkSpecializationInfo` + `VkSpecializationMapEntry`:

```haskell
data SpecInfo = SpecInfo
  { specEntries :: [VkSpecializationMapEntry]
  , specData    :: ByteString
  }

-- Build from FIR-compiled shader metadata
buildSpecInfo :: [(Word32, Word32, SpecValue)] -> SpecInfo
```

Integration into pipeline creation (`VkGraphicsPipelineCreateInfo` → `pSpecializationInfo`).

#### Phase 3E: Tests (1 day)

- Test: spec constant for workgroup size in compute shader
- Test: spec constant bool for feature toggle in fragment shader
- Test: multiple spec constants in one shader
- Verify `spirv-val` on all tests

### Deliverables

| Item | File |
|------|------|
| `SpecConstant` type-level API | `FIR/Prim/SpecConstant.hs` (new) |
| SpecId decoration tracking | `FIR/Decoration.hs` or `ProgramState.hs` |
| `OpSpecConstant*` codegen | CodeGen module |
| `OpSpecConstantOp` codegen | CodeGen module |
| Vulkan specialization info builder | `Vulkan/ShaderSpecialization.hs` (new) |
| Integration with pipeline creation | `Vulkan/Pipeline.hs` |
| 3 regression tests | `test/Tests/SpecConstant/` |

---

## Fix 4: Supporting Improvements

**Status**: Not started
**Estimate**: 1 week

### 4A: `abs` and `sign` for Code Types (1 day)

Already tracked in `MILESTONE_FIR_GAPS.md` Issue 3. Add to `GLSLMath` type class or as primops.

**File**: `3rdparty/fir/src/Math/Algebra/Class.hs`

```haskell
abs :: a -> a
sign :: a -> a
```

Both map to SPIR-V `OpGLSL500.ExtInst` (GLSLstd450FAbs, GLSLstd450FSign) or direct `OpFNegate` + `OpSGreaterThan` patterns.

### 4B: Improved Error Messages for Vector Operators (2 days)

Tracked in `MILESTONE_FIR_GAPS.md` Issue 4. Add custom type errors:

```haskell
instance TypeError (Text "Use ^+^ for vector addition, not +") => Additive (Code (V n Float)) where
  ...
```

Or provide unified operators via newtype wrapper.

### 4C: Debug Printf Support (2 days)

`FIR.Syntax.DebugPrintf` module exists but is not wired to `OpDebugPrintf` (requires `DebugInfo` capability, SPIR-V 1.4+). Enable it for shader debugging.

### 4D: Group/Subgroup Operations (2 days)

FIR already has group operations (`GroupAdd`, `GroupMul`, etc.) in `FIR/Prim/Op.hs`. Verify they emit correct SPIR-V. Add subgroup operations if missing (`OpGroupNonUniform*`) — needed for tiled deferred lighting.

---

## Execution Order

```
Week 1-2: Fix 1 (Atomics)
  Phase 1A → 1B → 1C → 1D → 1E

Week 3-4: Fix 2 (Choose + OpSelect)
  Phase 2A → 2B → 2C → 2D

Week 5: Fix 3 (Specialization Constants)
  Phase 3A → 3B → 3C → 3D → 3E

Week 6: Fix 4 (Supporting improvements)
  4A → 4B → 4C → 4D
```

Fix 2 depends on understanding `OpSelect` (Phase 2A) before fixing `Choose` (Phase 2B).
Fix 3 is independent and can be done in parallel with Fix 2 if desired.
Fix 4 items are all independent and can be parallelized.

---

## Regression Test Plan

All tests go in `3rdparty/fir/test/Tests/`:

```
Atomics/
  AtomicCounter.hs       — atomic increment/decrement in compute
  AtomicImage.hs         — atomic add on storage image
  AtomicCAS.hs           — compare-and-swap pattern
  AtomicScope.hs         — device vs workgroup scope

Choose/
  IfThenElseFloat.hs     — if c then a else b :: Code Float
  IfThenElseVec3.hs      — if c then a else b :: Code (V 3 Float)
  MixVector.hs           — mix a b t :: Code (V 3 Float)
  NestedIf.hs            — nested conditionals
  WhenUnless.hs          — when/unless with Code Bool

SpecConstant/
  WorkgroupSize.hs       — specialize compute local size
  BoolFlag.hs            — specialize feature toggle
  MultiSpec.hs           — multiple spec constants

Supporting/
  AbsCode.hs             — abs on Code Float
  SignCode.hs            — sign on Code Float
```

Each test compiles a FIR shader, runs `spirv-val`, and optionally executes via `spirv-runner` or in haskan2 engine.

---

## Key Files Reference

| File | Role |
|------|------|
| `3rdparty/fir/src/FIR/Syntax/IfThenElse.hs:69-101` | `Choose` instances — the overlap |
| `3rdparty/fir/src/FIR/Prim/Op.hs` | PrimOp infrastructure (857 lines) |
| `3rdparty/fir/src/FIR/AST.hs` | AST nodes — add atomic/select constructors |
| `3rdparty/fir/src/SPIRV/Capability.hs:79-80, 105-106` | `Int64Atomics`, `AtomicStorage` capabilities |
| `3rdparty/fir/src/SPIRV/Storage.hs:52, 69, 119` | `AtomicCounter` storage class |
| `3rdparty/fir/src/SPIRV/Synchronisation.hs:126` | `AtomicCounterMemory` scope |
| `3rdparty/fir/src/Math/Logic/Class.hs` | `Choose` type class definition |
| `3rdparty/fir/src/Math/Algebra/Class.hs` | `GLSLMath` — add `abs`, `sign` |
| `3rdparty/fir/src/FIR/Syntax/Synonyms.hs` | `Vec2`/`Vec3`/`Vec4` patterns |
| `3rdparty/fir/src/FIR/ProgramState.hs` | Shader compilation state — add spec constants |
| `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` | 4+ `step()` workarounds to migrate |
| `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Lighting.hs` | Branchless patterns to migrate |

---

## Success Criteria

1. `if-then-else` works on all `Code` types without `step()` workarounds
2. `atomicAdd` compiles and passes `spirv-val`
3. `specConstant @"foo" @Word32` produces correct SPIR-V with SpecId decoration
4. `abs x` works on `Code Float`
5. `mix a b t` works on `Code (V 3 Float)`
6. All existing haskan2 shaders still compile
7. Cloud shader conditionals rewritten to natural `if-then-else`
8. New test: compute shader with atomic counter produces correct count
