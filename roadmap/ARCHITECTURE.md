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
data CommandPool      -- per-thread command buffer allocation
data CommandBuffer    -- PRIMARY (frame) or SECONDARY (pass)
data QueueSubmission  -- fence/semaphore tracking
```

**Why it matters:** Deferred rendering requires parallel recording of multiple passes into secondary command buffers. This layer abstracts command buffer level so upper layers just say "record this pass."

**Current state:** `CommandBuffer.hs`, `CommandPool.hs` exist but only support PRIMARY level.

### Layer 2: Resources

**Responsibility:** GPU memory allocation, resource lifetime, handle registry.

**Key types:**
```haskell
newtype BufferHandle  = BufferHandle Word64
newtype ImageHandle   = ImageHandle Word64
newtype MeshHandle    = MeshHandle Word64
newtype ShaderHandle  = ShaderHandle Word64

data ResourceManager  -- registry + allocator abstraction
```

**Why it matters:** Currently, `VkBuffer` values are passed directly to render code. When you add VMA or bindless descriptors, every call site changes. Handles isolate the change to the resource manager.

**Current state:** Direct `MonadManaged` allocation. No registry, no handles.

### Layer 3: Render Graph

**Responsibility:** Define rendering passes, their inputs/outputs, and execution order. Insert barriers automatically.

**Key types:**
```haskell
data RenderGraph = RenderGraph
  { rgPasses        :: [RenderPassNode]
  , rgResources     :: [GraphResource]
  , rgDependencies  :: HashMap PassId [PassId]
  }

data RenderPassNode = RenderPassNode
  { rpName     :: Text
  , rpInputs   :: [ResourceId]
  , rpOutputs  :: [ResourceId]
  , rpRecord   :: CommandBuffer -> IO ()
  }
```

**Why it matters:** Forward rendering has one pass. Deferred has 3+. Without a graph, you manually track image layouts and barriers between passes. The graph compiler does this for you.

**Current state:** Hardcoded single pass in `Render.hs:createRenderContext`.

### Layer 4: Scene

**Responsibility:** Game world representation — entities, components, transforms, scene graph.

**Key types:**
```haskell
data World = World
  { wEntities    :: TVar (IntSet EntityId)
  , wTransforms  :: TVar (Vector Transform)
  , wMeshes      :: TVar (Vector (Maybe MeshHandle))
  , wMaterials   :: TVar (Vector (Maybe MaterialHandle))
  }
```

**Why it matters:** GLTF scenes have nodes with local transforms, instanced meshes, animations. A tree of `Object` values doesn't scale. ECS stores components in contiguous arrays for cache-friendly iteration.

**Current state:** No scene concept. `mainLoop meshName` loads one OBJ.

## Cross-Cutting Concerns

### Material System

Materials bridge Layer 4 (Scene) and Layer 3 (Render Graph). A material specifies:
- Shader program (vert + frag + optional geom/tess)
- Pipeline configuration (blend, depth, rasterization)
- Texture bindings
- Uniform buffer layout

```haskell
data Material = Material
  { matShader    :: ShaderProgram
  , matPipeline  :: PipelineHandle  -- cached VkPipeline
  , matTextures  :: [TextureHandle]
  }
```

Pipeline compilation is cached by `(ShaderProgram, VertexFormat, RenderPass)` key. When you switch from forward to deferred, materials reference different shader programs for g-buffer vs. lighting passes — the material system doesn't change.

### Synchronization Strategy

Vulkan synchronization is the #1 source of bugs. The engine uses a **frame-consistent** approach:

1. **Per-frame fences** — one `VkFence` per in-flight frame (`maxFramesInFlight = 2`)
2. **Binary semaphores** — imageAvailable → renderFinished → present
3. **Pipeline barriers** — inserted by Render Graph compiler between passes
4. **Resource transitions** — image layout tracked per-resource, barriers generated automatically

No manual `vkCmdPipelineBarrier` in user pass code.

## Memory Strategy (Evolution)

| Phase | Strategy | When |
|-------|----------|------|
| 1-2 | Dedicated allocation per resource | Now, <50 resources |
| 3-4 | Per-type memory pools | Deferred rendering, transient attachments |
| 5-6 | Vulkan Memory Allocator (VMA) | GLTF scenes, 100+ resources |
| 7-8 | VMA with defragmentation | Streaming, long-running sessions |

The `ResourceManager` abstraction makes this transparent. Render code never calls `vkAllocateMemory`.

## Type Safety Goals

Haskell's type system should prevent:
1. **Using a freed resource** — `ResourceHandle` invalidated on unload, checked at record time
2. **Wrong image layout** — Render Graph tracks layouts, barriers auto-inserted
3. **Missing descriptor binding** — Material validates texture slots at load time
4. **Pipeline/shader mismatch** — `ShaderProgram` type encodes vertex format compatibility
5. **Frame overlap bugs** — Per-frame resource versioning prevents read-after-write across frames

## Module Organization

```
src/Graphics/Haskan/
├── Core/
│   ├── Types.hs          -- engine-wide types (EntityId, Handle types)
│   └── Math.hs           -- linear algebra helpers
├── Vulkan/
│   ├── Command.hs        -- Layer 1: command buffers, queues
│   ├── Resources.hs      -- Layer 2: ResourceManager, handles
│   ├── Memory.hs         -- allocation strategies (dedicated → VMA)
│   ├── RenderGraph.hs    -- Layer 3: graph builder + compiler
│   └── Types.hs          -- Vulkan-specific types
├── Render/
│   ├── Pass.hs           -- pass definition DSL
│   ├── Material.hs       -- material + pipeline cache
│   └── Forward.hs        -- forward rendering passes (initial)
├── Scene/
│   ├── ECS.hs            -- Layer 4: World, entities, components
│   ├── Transform.hs      -- local/world matrix computation
│   └── GLTF.hs           -- GLTF import → ECS + resources
├── Shaders/
│   ├── Texture.hs        -- current FIR shaders
│   └── Deferred.hs       -- deferred shader programs
└── Main.hs
```
