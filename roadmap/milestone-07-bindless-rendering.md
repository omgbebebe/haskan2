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

**Acceptance:** `vkCreateDevice` succeeds with descriptor indexing enabled.

### Task 7.2: Bindless Descriptor Set
**File:** `src/Graphics/Haskan/Vulkan/DescriptorSet.hs`

Create descriptor set layout with `descriptorCount = 4096` and `PARTIALLY_BOUND` flag.

Allocate descriptor set from pool with `UPDATE_AFTER_BIND`.

**Acceptance:** Can create bindless descriptor set.

### Task 7.3: Texture Upload to Bindless Array
**File:** `src/Graphics/Haskan/Render/Bindless.hs`

Upload textures into the bindless array:

```haskell
updateBindlessTexture :: ResourceManager
                      -> VkDescriptorSet
                      -> Word32        -- index in array
                      -> TextureHandle
                      -> IO ()
```

**Acceptance:** Texture accessible in shader by index.

### Task 7.4: Bindless Shaders (FIR)
**File:** `src/Graphics/Haskan/Shaders/Bindless.hs`

Write shaders that:
- Take texture index as push constant or vertex attribute
- Sample from `texture2D textures[]` array

**Acceptance:** Shader compiles, renders textured mesh.

### Task 7.5: Update Material System
**File:** `src/Graphics/Haskan/Render/Material.hs`

`Material` stores texture indices instead of `TextureHandle`. Material loading converts handles to indices.

**Acceptance:** Materials reference textures by index, not handle.

### Task 7.6: Single Descriptor Set Per Frame
**File:** `src/Graphics/Haskan/Render/RenderSystem.hs`

Render system:
1. Binds bindless descriptor set once
2. For each draw: pushes texture index via push constants
3. Draws mesh

**Acceptance:** Frame renders with only one `vkCmdBindDescriptorSet` call.

### Task 7.7: GPU Frustum Culling (Compute)
**File:** `src/Graphics/Haskan/Render/GPUCulling.hs`

Compute shader:
- Input: array of AABBs + transforms
- Output: visible object indices

```haskell
data CullInput = CullInput
  { ciAABB       :: !(Vector AABB)      -- object bounding boxes
  , ciTransform  :: !(Vector (M44 Float))
  , ciFrustum    :: !Frustum
  }

data CullOutput = CullOutput
  { coVisibleIndices :: !(Vector Word32)
  , coVisibleCount   :: !Word32
  }

runGPUCulling :: CommandBuffer -> CullInput -> IO CullOutput
```

**Acceptance:** Compute shader correctly culls objects outside frustum.

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

- [ ] Descriptor indexing enabled and working
- [ ] All textures accessible from one descriptor set
- [ ] Materials use texture indices, not handles
- [ ] Single descriptor set bind per frame
- [ ] GPU frustum culling compute shader works
- [ ] Performance improves vs per-draw binding (measure draw call overhead)
