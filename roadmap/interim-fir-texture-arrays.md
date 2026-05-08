# Interim Milestone: FIR Texture Array Support for Bindless Rendering

## Context

Milestone 7 (Bindless Rendering) requires indexing into texture arrays at runtime. FIR's `Texture2D` synonym is hardcoded to `NonArrayed`, blocking this feature entirely. This interim milestone patches FIR to support `Texture2DArray` with `Arrayed` SPIR-V images.

**Scope:** `Texture2DArray` support only (single descriptor, arrayed 2D texture). Full bindless descriptor arrays (`Array n (Image props)` under `UniformConstant`) are deferred to a later milestone when the draw-call bottleneck demands it.

## Goal

Add `Texture2DArray` (and related synonyms) to FIR so shaders can:
1. Declare arrayed 2D textures in the shader interface
2. Sample with 3D coordinates `(u, v, layer)`
3. Pass through FIR's type checking, validation, and SPIR-V codegen

## Files to Touch (in FIR submodule: `3rdparty/fir/`)

### 1. Type Synonyms
**File:** `src/FIR/Syntax/Synonyms.hs`

Add arrayed variants of texture/image synonyms alongside existing `Texture2D`/`Image2D`:
```haskell
type Texture2DArray decs fmt = ...  -- Arrayed instead of NonArrayed
type Image2DArray    decs fmt = ...
type SubpassInput2DArray decs fmt = ...
```

**Lines changed:** ~15
**Risk:** Zero — new synonyms, no existing code modified.

### 2. Image Dimension Capabilities
**File:** `src/SPIRV/Requirements.hs`

`dimCapabilities` currently only maps `Cube Arrayed` for sampled images. Add:
```haskell
dimCapabilities True Image.TwoD Image.Arrayed = [Shader, SampledImageArray]
dimCapabilities True Image.ThreeD Image.Arrayed = [Shader, SampledImageArray]
```

**Lines changed:** ~5
**Risk:** Low — additive, existing paths untouched.

### 3. Coordinate Dimension Validation
**File:** `src/FIR/Validation/Images.hs`

`GradCoordinatesDim` and `OffsetCoordinatesDim` hardcode `NonArrayed` at specific lines. Make them propagate the `arr` parameter from image properties instead.

Current (pseudo):
```haskell
GradCoordinatesDim TwoD NonArrayed = 2
GradCoordinatesDim TwoD Arrayed    = 3  -- missing, needs to be added
```

**Lines changed:** ~10
**Risk:** Low — pattern match additions.

### 4. Codegen for Arrayed Images
**File:** `src/CodeGen/Images.hs`

Verify `OpTypeImage` emission includes the `Arrayed` flag correctly. The field already exists in `SPIRV.Image` properties; codegen likely passes it through, but confirm.

**Lines changed:** 0 (verification only, likely already correct)
**Risk:** Zero.

### 5. Tests
**File:** `test/Tests/Images/Arrayed.hs` (new)

Test that compiles a minimal shader using `Texture2DArray`, samples with 3D coordinates, and produces valid SPIR-V.

**Lines changed:** ~30
**Risk:** Zero.

### 6. FIR Examples
**File:** `fir-examples/src/FIR/Examples/ArrayedTexture.hs` (new)

Minimal example shader demonstrating `Texture2DArray` usage.

**Lines changed:** ~20
**Risk:** Zero.

## Integration into Haskan2

### New Shader Module
**File:** `src/Graphics/Haskan/Vulkan/Shaders/Bindless.hs`

Rewrite the stub created earlier to use `Texture2DArray`:
```haskell
-- Pass texture array layer index as a flat integer via push constants
-- or vertex attribute (push constants preferred)
```

### Pipeline Layout Update
**File:** `src/Graphics/Haskan/Vulkan/PipelineLayout.hs`

Add push constant range for material data (texture layer index + metallic + roughness).

### Render Loop Update
**File:** `src/Graphics/Haskan/Engine.hs`

Replace per-entity descriptor set binding with:
1. Bind bindless descriptor set once per frame
2. Push material index + properties per draw via `vkCmdPushConstants`
3. Draw

## Implementation Order

1. **FIR Patch Phase** (estimated 2-3 hours)
   - [ ] Step 1.1: Add `Texture2DArray`/`Image2DArray` synonyms
   - [ ] Step 1.2: Add dimension capabilities in `SPIRV/Requirements.hs`
   - [ ] Step 1.3: Update coordinate validation in `FIR/Validation/Images.hs`
   - [ ] Step 1.4: Verify codegen in `CodeGen/Images.hs`
   - [ ] Step 1.5: Write unit test
   - [ ] Step 1.6: Build FIR and run tests

2. **Integration Phase** (estimated 1-2 hours)
   - [ ] Step 2.1: Rewrite `Shaders/Bindless.hs` to use `Texture2DArray`
   - [ ] Step 2.2: Add push constant support to pipeline layout
   - [ ] Step 2.3: Update render loop to push material indices
   - [ ] Step 2.4: Create texture atlas or pack scene textures into array layers
   - [ ] Step 2.5: Test with MultiUVTest and Avocado

3. **Validation Phase** (estimated 1 hour)
   - [ ] Step 3.1: Verify zero validation errors
   - [ ] Step 3.2: Verify correct texture sampling on all faces
   - [ ] Step 3.3: Performance sanity check (should be ~same or better)

## Acceptance Criteria

- [ ] `Texture2DArray` compiles and passes FIR's internal validation
- [ ] SPIR-V output contains `OpTypeImage ... 2D ... 1` (where 1 = Arrayed)
- [ ] Haskan2 renders textured models correctly with bindless pipeline
- [ ] Zero Vulkan validation errors
- [ ] Performance is not degraded vs. per-entity descriptor sets

## Fallback Plan

If FIR patching proves more complex than estimated:
1. Revert to texture atlas approach (single large texture, UV offsets in push constants)
2. Document FIR limitation and revisit after Milestone 8

## Effort Estimate

- FIR patch: 2-3 hours
- Integration: 1-2 hours
- Testing: 1 hour
- **Total: 4-6 hours**

## Notes

- The FIR patch is **upstreamable** — it's a clean addition of a standard Vulkan feature with no breaking changes
- Keep the patch minimal: only `Texture2DArray`, not general `Array n (Image props)`
- Document the SPIR-V `OpTypeImage` arrayed flag in comments for future maintainers
