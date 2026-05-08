# Milestone 7: Bindless Rendering

## Goal
Use descriptor indexing (bindless descriptors) to bind all textures in one descriptor set, eliminating per-draw descriptor set binding.

## Why This Matters

Current code: each draw call binds a descriptor set with texture + uniform buffer. 1000 draw calls = 1000 `vkCmdBindDescriptorSet` calls.

Bindless: one descriptor set with an array of 1000 textures. Each draw references textures by index (push constant or SSBO). One bind per frame.

Also enables:
- GPU-driven rendering (compute shader writes draw commands with texture indices)
- Material sorting by pipeline state, not texture
- Unlimited unique materials (limited only by descriptor pool size)

## Deliverables

1. `Graphics.Haskan.Render.Bindless` — bindless descriptor setup
2. Updated `Material` — texture indices instead of raw handles
3. Updated shaders — sample from texture array by index
4. `Graphics.Haskan.Render.GPUCulling` — compute-based frustum culling (preparation for M8)

## Design

### Descriptor Indexing (Vulkan 1.2)

Enable features:
```haskell
features = VkPhysicalDeviceDescriptorIndexingFeatures
  { shaderSampledImageArrayNonUniformIndexing = VK_TRUE
  , descriptorBindingSampledImageUpdateAfterBind = VK_TRUE
  , descriptorBindingPartiallyBound = VK_TRUE
  }
```

### Bindless Descriptor Set Layout

```haskell
bindlessLayout :: VkDescriptorSetLayout
bindlessLayout =
  -- Binding 0: sampled image array[4096]
  -- Binding 1: uniform buffer array[256]
  -- Binding 2: storage buffer (draw data)
  createDescriptorSetLayout
    [ VkDescriptorSetLayoutBinding
        { binding = 0
        , descriptorType = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE
        , descriptorCount = 4096
        , stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT
        }
    , VkDescriptorSetLayoutBinding
        { binding = 1
        , descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
        , descriptorCount = 256
        , stageFlags = VK_SHADER_STAGE_VERTEX_BIT .|. VK_SHADER_STAGE_FRAGMENT_BIT
        }
    ]
```

### Texture Array in Shaders

```glsl
// Fragment shader
layout(set = 0, binding = 0) uniform texture2D textures[4096];
layout(set = 0, binding = 1) uniform sampler samplers[16];

layout(push_constant) uniform PushConstants {
    uint textureIndex;
    uint samplerIndex;
} pc;

void main() {
    vec4 color = texture(sampler2D(textures[pc.textureIndex], samplers[pc.samplerIndex]), uv);
    ...
}
```

### Material with Texture Indices

```haskell
data BindlessMaterial = BindlessMaterial
  { bmBaseColorTextureIndex :: !Word32
  , bmNormalTextureIndex    :: !Word32
  , bmMetallicRoughnessIndex:: !Word32
  , bmSamplerIndex          :: !Word32
  , bmPipeline              :: !PipelineHandle
  }
```

### Texture Atlas Management

Instead of individual textures, use a **texture atlas** or **array texture**:

```haskell
data TextureAtlas = TextureAtlas
  { taImage        :: !VkImage
  , taImageView    :: !VkImageView
  , taLayers       :: !Int           -- number of textures packed
  , taExtent       :: !VkExtent2D   -- per-texture size
  }

-- Add texture to atlas, return layer index
addTextureToAtlas :: TextureAtlas -> TextureHandle -> IO Word32
```

Alternative: keep individual textures in bindless array (simpler, less packing overhead).

## Tasks

### Task 7.1: Enable Descriptor Indexing
**File:** `src/Graphics/Haskan/Vulkan/Device.hs`

Check for `VK_EXT_descriptor_indexing` or Vulkan 1.2. Enable required features.

**Status:** Complete. `queryDeviceCapabilities` reads `VkPhysicalDeviceDescriptorIndexingFeatures`. Reports `nonUniform`, `updateAfterBind`, `partiallyBound`, `runtimeArray` booleans. Vulkan 1.2+ required for `vkGetPhysicalDeviceFeatures2`.

### Task 7.2: Bindless Descriptor Set
**File:** `src/Graphics/Haskan/Vulkan/DescriptorSetLayout.hs`, `DescriptorPool.hs`

Create descriptor set layout with `descriptorCount = 4096` and `PARTIALLY_BOUND` flag.

**Status:** Skeleton complete. `managedBindlessDescriptorSetLayout` with `UPDATE_AFTER_BIND` + `PARTIALLY_BOUND` exists. Not yet integrated into main pipeline — `Texture2DArray` + push constants are the active approach.

### Task 7.3: Texture Upload to Bindless Array
**File:** `src/Graphics/Haskan/Render/Bindless.hs`

Upload textures into the bindless array.

**Status:** Skeleton complete. `BindlessSet`, `createBindlessSet`, `registerTexture` exist. `updateBindlessTexture` writes array index to descriptor set. Not yet integrated into main render loop.

### Task 7.4: Texture Array Shaders (FIR)
**File:** `src/Graphics/Haskan/Vulkan/Shaders/Deferred/GBuffer.hs`

Write shaders that sample from `Texture2DArray` using push constant material index.

**Status:** Complete. G-buffer fragment shader declares `Texture2DArray` at binding 1. Samples with `(uv, materialIndex)` where `materialIndex` comes from push constants. FIR `Texture2DArray` synonym patched upstream (see `interim-fir-texture-arrays.md`).

### Task 7.5: Update Material System
**File:** `src/Graphics/Haskan/Render/RenderSystem.hs`

`DrawCall` stores `dcMaterialIndex :: Word32` (texture array layer index). `extractDrawList` builds texture→index mapping from unique scene textures.

**Status:** Complete. `DrawCall` has `dcMaterialIndex`. `extractDrawList` takes `IntMap Word32` texture→index mapping. Per-entity descriptor sets still used for MVP UBO; texture array bound globally.

### Task 7.6: Single Descriptor Set Per Frame
**File:** `src/Graphics/Haskan/Render/Deferred.hs`

Render system:
1. Binds texture array descriptor set once (per-entity sets for MVP still needed)
2. For each draw: pushes material index via `vkCmdPushConstants`
3. Draws mesh

**Status:** Partial. Texture array bound once to all per-entity descriptor sets. Material index pushed per draw call. True single-set bindless (one descriptor set for everything) requires UBO array or SSBO for transforms — deferred to M8.

### Task 7.7: GPU Frustum Culling (Compute)
**File:** `src/Graphics/Haskan/Render/GPUCulling.hs`

Compute shader:
- Input: array of AABBs + transforms
- Output: visible object indices

**Status:** Not started. Deferred to Milestone 8.

## Testing

```haskell
-- Load 100 textures
indices <- forM textures $ \tex -> do
  idx <- addTextureToBindlessArray descSet tex
  pure idx

-- Render 1000 cubes, each with different texture index
forM_ [0..999] $ \i -> do
  cmdPushConstants cmd (indices !! (i `mod` 100))
  cmdDrawIndexed cmd 36

-- Verify: all cubes visible, different textures
```

## Risks

| Risk | Mitigation |
|------|-----------|
| Descriptor indexing not supported | Fallback to traditional descriptor sets |
| Texture array size limits | Query `maxDescriptorSetSampledImages`, split into multiple sets if needed |
| Non-uniform indexing performance | Use `nonuniformEXT` qualifier in GLSL, or sort draws by texture |
| Memory overhead of 4096 textures | Only allocate slots for loaded textures; use partially bound |

## Success Criteria

- [x] Descriptor indexing enabled and working (capabilities queried, device features set)
- [x] `Texture2DArray` accessible from shader (FIR patched, SPIR-V codegen verified)
- [x] Texture array created from scene textures, bound once per frame
- [x] Materials use texture indices (push constants), not per-draw descriptor binds
- [ ] True single descriptor set per frame (requires UBO/SSBO for per-entity transforms) — deferred to M8
- [ ] GPU frustum culling compute shader — deferred to M8
- [ ] Performance improves vs per-draw binding (needs benchmarking)

## Implementation Notes

**Completed 2026-05-08.** See work:
- FIR patch: `Texture2DArray`/`Image2DArray` synonyms in `FIR.Syntax.Synonyms`
- `SPIRV/Requirements.hs`: arrayed sampled image capability
- `FIR/Validation/Images.hs`: array-aware coordinate validation
- `test/Tests/Images/SampleArray.hs`: compilation test
- Integration: `Shaders/Deferred/GBuffer.hs` uses `Texture2DArray` + push constant `materialIndex`
- `Engine.hs`: texture array built from unique scene textures, resized to 256×256, bound globally

### Architecture Decisions
- `Texture2DArray` + push constants as pragmatic bindless — avoids FIR AST surgery for `OpTypeRuntimeArray`
- Texture array dimensions constraint: all layers identical size; resize to common size at load time via bilinear filter
- Per-entity descriptor sets still used for MVP UBO (dynamic offsets); texture array is global binding
- True bindless descriptor arrays (`NonUniform` + `OpTypeRuntimeArray`) deferred until upstream FIR coordination possible
- Asset preprocessor caches preprocessed textures under `.haskan2-cache/` to avoid repeated decode/resize

## True Bindless vs Current Approach

| Feature | Current (Texture2DArray) | True Bindless (Deferred) |
|---------|-------------------------|--------------------------|
| Descriptor binds per frame | 1 (texture array) + N (per-entity UBO) | 1 (global set) |
| Texture array size | Fixed at creation (all scene textures) | Dynamic (runtime register/unregister) |
| Shader sample | `texture(texArray, uv, layer)` | `texture(textures[nonuniformEXT(index)], uv)` |
| Material data | Push constant (4 bytes) | SSBO or push constant |
| FIR support | Working now | Requires `RuntimeArray`, `NonUniform` AST nodes |
| Performance | Good | Potentially better (no push constants per draw) |
