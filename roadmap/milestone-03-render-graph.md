# Milestone 3: Render Graph

## Goal
Replace the hardcoded single-pass render pipeline with a declarative render graph that can compose multiple passes.

## Why This Matters

Current code (`Render.hs:createRenderContext`) does everything in one function:
- Creates swapchain
- Creates render pass with one subpass
- Creates graphics pipeline
- Records command buffers

For deferred rendering, you need:
1. **G-buffer pass** — writes position, normal, albedo to attachments
2. **Lighting pass** — reads g-buffer, writes lit scene
3. **Post-process pass** — reads lit scene, writes swapchain

Each pass has different:
- Render passes
- Framebuffers
- Pipelines
- Input/output attachments
- Barrier requirements

Without a graph, you manually track image layouts and insert `vkCmdPipelineBarrier` between passes. This is error-prone and Vulkan-specific.

## Deliverables

1. `Graphics.Haskan.Render.Graph` — graph builder + compiler
2. `Graphics.Haskan.Render.Pass` — pass definition DSL
3. `Graphics.Haskan.Render.Forward` — forward rendering pass (current behavior)
4. Updated `Engine.hs` — builds graph from scene, compiles per frame

## Design

### Graph Resource Types

```haskell
data GraphResource
  = GRImage ImageDesc        -- transient render target
  | GRBuffer BufferDesc      -- SSBO, UBO
  | GRPersistent ResourceId  -- reference to ResourceManager handle

data ImageDesc = ImageDesc
  { idFormat   :: !VkFormat
  , idExtent   :: !VkExtent2D
  , idUsage    :: !VkImageUsageFlags
  , idSamples  :: !VkSampleCountFlagBits
  }
```

### Pass Definition

```haskell
data RenderPassNode = RenderPassNode
  { rpName        :: !Text
  , rpInputs      :: ![ResourceId]   -- color/depth to read
  , rpOutputs     :: ![ResourceId]   -- color/depth to write
  , rpRecord      :: !PassRecordFunc
  }

type PassRecordFunc = PassContext -> IO ()

data PassContext = PassContext
  { pcCommandBuffer  :: !CommandBuffer
  , pcPipeline       :: !VkPipeline
  , pcPipelineLayout :: !VkPipelineLayout
  , pcDescriptorSet  :: !VkDescriptorSet
  , pcFramebuffer    :: !VkFramebuffer
  }
```

### Graph Builder

```haskell
newtype RenderGraphBuilder a = RenderGraphBuilder
  { runBuilder :: State GraphBuildState a }

data GraphBuildState = GraphBuildState
  { gbsResources :: !(HashMap ResourceId GraphResource)
  , gbsPasses    :: ![RenderPassNode]
  }

addResource :: ResourceId -> GraphResource -> RenderGraphBuilder ()
addPass     :: RenderPassNode -> RenderGraphBuilder ()

-- Helper for transient images
transientImage
  :: Text -> VkFormat -> VkExtent2D -> VkImageUsageFlags
  -> RenderGraphBuilder ResourceId
```

### Graph Compilation

The compiler takes a `RenderGraph` and produces:
1. **Topological sort** of passes based on read/write dependencies
2. **Image layout transitions** — tracks layout per resource, inserts barriers
3. **Memory barriers** — ensures writes complete before reads
4. **Command buffer recording** — records passes in order into primary/secondary CBs

```haskell
compileGraph
  :: DeviceContext
  -> RenderGraph
  -> IO CompiledGraph

data CompiledGraph = CompiledGraph
  { cgCommandBuffer :: !CommandBuffer  -- primary CB with all passes
  , cgFences        :: ![VkFence]      -- per-frame fences
  }
```

### Forward Rendering Pass (Current Behavior)

```haskell
buildForwardGraph
  :: DeviceContext
  -> SwapchainContext
  -> [Renderable]        -- from ECS
  -> RenderGraphBuilder ()
buildForwardGraph devCtx swapCtx renderables = do
  let swapImage = swapchainImage swapCtx
      depthImage = transientImage "depth"
                     VK_FORMAT_D16_UNORM
                     (swapExtent swapCtx)
                     VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT

  addPass RenderPassNode
    { rpName    = "forward"
    , rpInputs  = []
    , rpOutputs = [swapImage, depthImage]
    , rpRecord  = \ctx -> do
        -- bind pipeline, set viewport/scissor
        -- for each renderable: bind descriptor, draw
        for_ renderables $ \r -> do
          cmdBindVertexBuffers ctx (meshVertexBuffer $ rMesh r)
          cmdDrawIndexed ctx (meshIndexCount $ rMesh r)
    }
```

## Tasks

### Task 3.1: Define Graph Types
**File:** `src/Graphics/Haskan/Render/Graph.hs`

Create `RenderGraph`, `RenderPassNode`, `GraphResource`, `CompiledGraph`.

**Acceptance:** Types compile, no Vulkan calls yet.

### Task 3.2: Graph Builder Monad
**File:** `src/Graphics/Haskan/Render/Graph.hs`

Implement `RenderGraphBuilder` with `addResource`, `addPass`, `transientImage`.

**Acceptance:** Can build a graph with 2 passes and 3 resources.

### Task 3.3: Graph Compiler — Topological Sort
**File:** `src/Graphics/Haskan/Render/Graph.hs`

Sort passes by dependency: if Pass B reads resource written by Pass A, A comes before B.

Detect cycles and report error.

**Acceptance:** `compileGraph` produces ordered pass list.

### Task 3.4: Graph Compiler — Barriers
**File:** `src/Graphics/Haskan/Render/Graph.hs`

Track image layout per resource. Between passes, compute required layout transitions.

Insert `vkCmdPipelineBarrier` with:
- `srcStageMask` = previous pass's stage
- `dstStageMask` = next pass's stage
- `imageMemoryBarrier` = layout transition

**Acceptance:** Validation layers report zero synchronization errors.

### Task 3.5: Command Buffer Recording
**File:** `src/Graphics/Haskan/Render/Graph.hs`

Allocate secondary command buffers (one per pass). Record each pass into its CB.

Primary CB: `vkCmdBeginRenderPass` → `vkCmdExecuteCommands` (secondaries) → `vkCmdEndRenderPass`

**Acceptance:** Graph renders single pass correctly (same visual as before).

### Task 3.6: Split Swapchain-Dependent Resources
**File:** `src/Graphics/Haskan/Vulkan/Types.hs`, `Render.hs`

Separate `DeviceContext` (static) from `SwapchainContext` (recreated on resize):

```haskell
data DeviceContext = DeviceContext
  { devDevice     :: !VkDevice
  , devPhysical   :: !VkPhysicalDevice
  , devQueue      :: !VkQueue
  , devCommandPool:: !VkCommandPool
  }

data SwapchainContext = SwapchainContext
  { scSwapchain   :: !VkSwapchainKHR
  , scExtent      :: !VkExtent2D
  , scFramebuffers:: ![VkFramebuffer]
  , scRenderPass  :: !VkRenderPass
  }
```

On resize: recreate `SwapchainContext`, rebuild graph, keep `DeviceContext`.

**Acceptance:** Resize works without reloading meshes/textures.

## Testing

```haskell
-- Build a 2-pass graph (silly example)
graph <- execBuilder $ do
  temp <- transientImage "temp" VK_FORMAT_R8G8B8A8_UNORM extent VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT

  addPass RenderPassNode
    { rpName = "clear"
    , rpOutputs = [temp]
    , rpRecord = \ctx -> cmdClearColor ctx (V4 1 0 0 1)
    }

  addPass RenderPassNode
    { rpName = "copy-to-swapchain"
    , rpInputs = [temp]
    , rpOutputs = [swapchain]
    , rpRecord = \ctx -> cmdBlitImage ctx temp swapchain
    }

compiled <- compileGraph devCtx swapCtx graph
-- Should see red screen
```

## Risks

| Risk | Mitigation |
|------|-----------|
| Barrier insertion incorrect | Enable Vulkan validation layers, fix warnings |
| Secondary CB overhead | Profile vs primary CB; optimize if needed |
| Transient attachment lifetime | Free after graph compilation, recreate each frame if needed |

## Success Criteria

- [ ] Can define multi-pass graph with builder
- [ ] Graph compiler orders passes correctly
- [ ] Barriers inserted automatically, validation clean
- [ ] Swapchain resize recreates only swapchain-dependent resources
- [ ] Forward rendering produces same output as before
