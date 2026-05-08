# Architecture Overview

## Design Principles

1. **Layer Isolation** — A layer only depends on the layer directly below it. Layer 4 (Scene) never calls Vulkan directly.
2. **Handle-Based Resources** — GPU resources are referenced by typed handles, not raw Vulkan types. This enables refactoring allocators without touching render code.
3. **Explicit Over Implicit** — Resource lifetimes, data dependencies, and synchronization are explicit in types. No hidden global state.
4. **Composability** — Rendering features are added by composing passes in a graph, not by branching inside monolithic functions.

## The Four Layers

### Layer 1: GPU Commands

**Responsibility:** Low-level Vulkan operations — command buffer recording, queue submission, synchronization primitives.

**Key types:**
```haskell
data CommandPool      -- per-frame command pool (has RESET_COMMAND_BUFFER_BIT)
data CommandBuffer    -- PRIMARY level, re-recorded each frame
data Fence            -- per-frame-in-flight fence
data Semaphore       -- imageAvailable → renderFinished → present
```

**Why it matters:** Deferred rendering requires parallel recording of multiple passes. Per-frame command buffer re-recording inside `renderImage`.

**Current state:** `CommandBuffer.hs` supports one-time submit helper (`withCommandBufferOneTime`). `CommandPool.hs` creates pool with `RESET_COMMAND_BUFFER_BIT`. Primary CBs only.

### Layer 2: Resources

**Responsibility:** GPU memory allocation, resource lifetime, handle registry.

**Key types:**
```haskell
newtype MeshHandle    = MeshHandle { unMeshHandle :: Word64 }
newtype TextureHandle = TextureHandle { unTextureHandle :: Word64 }

data TextureResource = TextureResource
  { trHandle    :: !TextureHandle
  , trImage     :: !VkImage
  , trImageView :: !VkImageView
  , trMemory    :: !VkDeviceMemory
  , trWidth     :: !Int
  , trHeight    :: !Int
  , trPixelData :: !(Maybe (Vector Word8))  -- for texture array building
  , trDestroy   :: !(IO ())
  }

data MeshResource = MeshResource
  { mrHandle     :: !MeshHandle
  , mrVertexBuffer :: !VkBuffer
  , mrIndexBuffer  :: !VkBuffer
  , mrIndexCount   :: !Int
  , mrBounds       :: !BBox
  }

data ResourceManager = ResourceManager
  { rmNextId    :: !(TVar Word64)
  , rmTextures  :: !(TVar (HashMap TextureHandle TextureResource))
  , rmMeshes    :: !(TVar (HashMap MeshHandle MeshResource))
  }

registerTexture :: ResourceManager -> TextureResource -> IO TextureHandle
lookupTexture   :: ResourceManager -> TextureHandle -> IO (Maybe TextureResource)
registerMesh    :: ResourceManager -> MeshResource -> IO MeshHandle
lookupMesh      :: ResourceManager -> MeshHandle -> IO (Maybe MeshResource)
```

**Why it matters:** Render code references `TextureHandle` and `MeshHandle`, not raw Vulkan types. Enables runtime scene changes (load/unload glTF without restart).

**Current state:** `ResourceManager` with STM-backed `HashMap` registries. `TextureResource` stores pixel data for texture array construction. `MeshResource` includes `BBox` for scene bounds.

### Layer 3: Render Graph

**Responsibility:** Define rendering passes, their inputs/outputs, and execution order.

**Key types:**
```haskell
data RenderPassNode = RenderPassNode
  { rpName     :: !Text
  , rpInputs   :: ![ResourceId]
  , rpOutputs  :: ![ResourceId]
  , rpRecord   :: !PassRecordFunc
  }

type PassRecordFunc = PassContext -> IO ()

data PassContext = PassContext
  { pcCommandBuffer  :: !VkCommandBuffer
  , pcPipeline       :: !VkPipeline
  , pcPipelineLayout :: !VkPipelineLayout
  , pcDescriptorSet  :: !VkDescriptorSet
  , pcFramebuffer    :: !VkFramebuffer
  , pcRenderPass     :: !VkRenderPass
  , pcExtent         :: !VkExtent2D
  }

newtype RenderGraphBuilder a = RenderGraphBuilder
  { runBuilder :: State GraphBuildState a }

data GraphBuildState = GraphBuildState
  { gbsResources :: !(HashMap ResourceId GraphResource)
  , gbsPasses    :: ![RenderPassNode]
  }

data CompiledGraph = CompiledGraph
  { cgPasses :: ![CompiledPass]
  }

data CompiledPass = CompiledPass
  { cpPass   :: !RenderPassNode
  , cpInputs :: ![ResourceId]
  , cpOutputs:: ![ResourceId]
  }
```

**Why it matters:** Deferred rendering has 2+ passes (g-buffer, lighting). Without a graph, you manually track image layouts. The graph compiler orders passes topologically.

**Current state:** Builder + compiler (topological sort) working. `buildDeferredGraph` produces g-buffer + lighting passes. `Engine.hs` compiles and executes per frame. Barriers between passes deferred — g-buffer images use `initialLayout = SHADER_READ_ONLY_OPTIMAL` matching actual post-render state.

### Layer 4: Scene

**Responsibility:** Game world representation — entities, components, transforms, scene graph.

**Key types:**
```haskell
newtype EntityId = EntityId { unEntityId :: Word32 }

data World = World
  { wNextEntity :: !(TVar EntityId)
  , wTransforms :: !(TVar (IntMap Transform))
  , wMeshes     :: !(TVar (IntMap MeshHandle))
  , wMaterials  :: !(TVar (IntMap TextureHandle))
  , wParents    :: !(TVar (IntMap EntityId))
  }

data Transform = Transform
  { tPosition :: !(V3 Float)
  , tRotation :: !(Quaternion Float)
  , tScale    :: !(V3 Float)
  }

data DrawCall = DrawCall
  { dcEntityId      :: !Int
  , dcMeshResource  :: !MeshResource
  , dcTransform     :: !Transform
  , dcWorldMatrix   :: !(M44 Float)
  , dcMaterial      :: !(Maybe TextureResource)
  , dcMaterialIndex :: !Word32
  }

extractDrawList :: World -> ResourceManager -> IntMap Word32 -> IO [DrawCall]
```

**Why it matters:** GLTF scenes have nodes with local transforms, instanced meshes, animations. ECS stores components in `IntMap` for sparse data. `extractDrawList` resolves handles and computes world matrices.

**Current state:** Sparse-set ECS working. glTF loader creates entities from node hierarchy. Parent-child transforms computed recursively. `extractDrawList` produces draw calls with resolved `MeshResource` and texture array layer indices.

## Cross-Cutting Concerns

### Material System

Materials bridge Layer 4 (Scene) and Layer 3 (Render Graph). A material specifies:
- Texture reference (`TextureHandle` in ResourceManager, or layer index in texture array)
- Pipeline configuration (blend, depth, rasterization)
- Uniform buffer layout (MVP matrices)

```haskell
data DrawCall = DrawCall
  { dcMeshResource  :: !MeshResource
  , dcTransform     :: !Transform
  , dcMaterial      :: !(Maybe TextureResource)
  , dcMaterialIndex :: !Word32  -- texture array layer
  }
```

**Current state:** Simple diffuse texture per entity. Texture array created from all unique scene textures; `dcMaterialIndex` pushed per draw via `vkCmdPushConstants`. Full PBR deferred to M7/M8.

### Synchronization Strategy

Vulkan synchronization uses a **frame-consistent** approach:

1. **Per-frame-in-flight fences** — `maxFramesInFlight = 2`. `vkWaitForFences` + `vkResetFences` before `vkAcquireNextImageKHR`
2. **Binary semaphores** — `imageAvailableSemaphore[frameIdx]` → submit → `renderFinishedSemaphore[imageIdx]` → present
3. **Per-frame command buffer re-recording** — command pool has `RESET_COMMAND_BUFFER_BIT`, CBs re-recorded inside `renderImage`
4. **Pipeline barriers** — g-buffer images transitioned once at creation; lighting pass reads with `SHADER_READ_ONLY_OPTIMAL` layout

No manual `vkCmdPipelineBarrier` in user pass code (layout transitions handled at resource creation time).

## Memory Strategy (Evolution)

| Phase | Strategy | When | Status |
|-------|----------|------|--------|
| 1-4 | Dedicated allocation per resource | Now, <100 resources | Active |
| 5-6 | Per-type memory pools | Deferred rendering, transient attachments | Partial (g-buffer images per swapchain image) |
| 7-8 | Vulkan Memory Allocator (VMA) | GLTF scenes, 100+ resources | Not started |
| 9+ | VMA with defragmentation | Streaming, long-running sessions | Not started |

The `ResourceManager` abstraction makes this transparent. Render code never calls `vkAllocateMemory` directly.

## Type Safety Goals

Haskell's type system should prevent:
1. **Using a freed resource** — `ResourceHandle` looked up in registry; `Nothing` on invalid handle
2. **Wrong image layout** — G-buffer images created with `initialLayout = SHADER_READ_ONLY_OPTIMAL`; one-time transition after creation
3. **Missing descriptor binding** — Per-entity descriptor sets validated at allocation time; texture array bound globally
4. **Pipeline/shader mismatch** — `ShaderProgram` type encodes stage count; pipeline creation validates all stages present
5. **Frame overlap bugs** — Per-frame resource versioning: `frameMvpBuffers !! frameNumber`, `renderFinishedFences !! frameNumber`

## Module Organization

```
src/Graphics/Haskan/
├── Engine.hs              -- Main loop: world creation, render loop, input, state update
├── Engine/Core.hs         -- GameState, WorldState, Camera class
├── Camera.hs              -- OrbitalCamera with quaternion rotation
├── Input.hs               -- SDL event → Action mapping
├── Logger.hs              -- FastLogger-based structured logging
├── Mesh.hs                -- Procedural mesh generation (ground plane, grid)
├── Vertex.hs              -- Vertex type with position, normal, uv, color
├── BoundingBox.hs         -- BBox, merge, fromPoints
├── Assets/
│   ├── Cache.hs           -- djb2-based file cache
│   ├── TexturePreprocessor.hs -- bilinear resize, PoT, serialize/deserialize
│   └── InternalFormat.hs  -- InternalTexture, InternalMesh, versioned header
├── Render/
│   ├── Graph.hs           -- Render graph builder + compiler
│   ├── Forward.hs         -- Forward rendering pass
│   ├── Deferred.hs        -- Deferred graph builder (g-buffer + lighting)
│   ├── RenderSystem.hs    -- extractDrawList, DrawCall
│   ├── ShaderProgram.hs   -- ShaderProgram with optional stages
│   └── Bindless.hs        -- BindlessSet skeleton (not yet integrated)
├── Scene/
│   ├── ECS.hs             -- World, EntityId, component storage
│   ├── Transform.hs       -- Local/world matrix, hierarchy
│   └── GLTF.hs            -- glTF import → ECS + ResourceManager
├── Vulkan/
│   ├── Buffer.hs          -- Vertex/index/uniform buffer creation
│   ├── CommandBuffer.hs   -- Recording, one-time submit, copy helpers
│   ├── CommandPool.hs     -- Pool creation
│   ├── DeferredResources.hs -- G-buffer + lighting pass resources
│   ├── DescriptorPool.hs  -- Descriptor pool allocation
│   ├── DescriptorSet.hs   -- Descriptor set updates
│   ├── DescriptorSetLayout.hs -- Layout creation
│   ├── Device.hs          -- Logical device creation with feature chaining
│   ├── DeviceCapabilities.hs -- Capability queries
│   ├── Fence.hs           -- Fence management
│   ├── GraphicsPipeline.hs -- Pipeline creation with all stages
│   ├── ImageView.hs       -- Image view creation (2D, 2D array)
│   ├── Instance.hs        -- Vulkan instance creation
│   ├── Memory.hs          -- Memory allocation
│   ├── PhysicalDevice.hs  -- GPU selection scoring
│   ├── PipelineLayout.hs  -- Pipeline layout with push constants
│   ├── Render.hs          -- drawFrame, presentFrame, RenderContext
│   ├── Resources.hs       -- ResourceManager, handles, registry
│   ├── Semaphore.hs       -- Semaphore creation
│   ├── Shaders/
│   │   ├── Deferred/
│   │   │   ├── GBuffer.hs -- G-buffer vertex/fragment shaders (FIR)
│   │   │   └── Lighting.hs -- Lighting fullscreen shaders (FIR)
│   │   └── Wireframe.hs   -- Wireframe vertex/geometry/fragment shaders (FIR)
│   ├── Swapchain.hs       -- Swapchain creation
│   ├── Texture.hs         -- Texture loading, texture array creation
│   └── Window.hs          -- SDL window creation
└── Utils/
    └── ObjLoader.hs       -- OBJ file parsing
```
