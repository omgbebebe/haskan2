# Milestone 4: Deferred Rendering

## Goal
Implement deferred shading: g-buffer pass + lighting pass.

## Why This Matters

Forward rendering (current): each object loops over all lights. 100 lights × 100 objects = 10,000 light evaluations.

Deferred rendering: render material properties once (g-buffer), then shade pixels once per light. 100 lights + 100 objects = 100 + 100 = 200 evaluations.

Also enables:
- Screen-space ambient occlusion (SSAO)
- Screen-space reflections (SSR)
- Volumetric lighting
- Many lights with good performance

## Deliverables

1. `Graphics.Haskan.Render.Deferred.GBuffer` — g-buffer pass
2. `Graphics.Haskan.Render.Deferred.Lighting` — lighting pass
3. FIR shaders for g-buffer and lighting
4. Updated graph builder — `buildDeferredGraph`

## Design

### G-Buffer Attachments

```haskell
data GBuffer = GBuffer
  { gbPosition :: !ImageHandle   -- RGB16F (world position)
  , gbNormal   :: !ImageHandle   -- RGB16F (world normal)
  , gbAlbedo   :: !ImageHandle   -- RGBA8   (diffuse color)
  , gbDepth    :: !ImageHandle   -- D32F    (linear depth)
  }
```

Alternative: pack position + normal into RGBA16F × 2, use R11G11B10 for albedo.

### G-Buffer Pass

```haskell
gbufferPass :: GBuffer -> [Renderable] -> RenderPassNode
gbufferPass gbuffer renderables = RenderPassNode
  { rpName    = "g-buffer"
  , rpInputs  = []
  , rpOutputs = [gbPosition gbuffer, gbNormal gbuffer, gbAlbedo gbuffer, gbDepth gbuffer]
  , rpRecord  = \ctx -> do
      cmdSetViewport ctx
      cmdSetScissor ctx
      for_ renderables $ \r -> do
        cmdBindPipeline ctx (materialPipeline $ rMaterial r)
        cmdBindDescriptorSet ctx (materialDescriptorSet $ rMaterial r)
        cmdBindVertexBuffers ctx (meshVertexBuffer $ rMesh r)
        cmdDrawIndexed ctx (meshIndexCount $ rMesh r)
  }
```

**Vertex shader:** transforms vertex, writes nothing special
**Fragment shader:** writes position, normal, albedo to MRT (multiple render targets)

### Lighting Pass

Full-screen triangle (or quad) that reads g-buffer and computes lighting.

```haskell
lightingPass :: GBuffer -> [Light] -> ImageHandle -> RenderPassNode
lightingPass gbuffer lights output = RenderPassNode
  { rpName    = "lighting"
  , rpInputs  = [gbPosition gbuffer, gbNormal gbuffer, gbAlbedo gbuffer]
  , rpOutputs = [output]
  , rpRecord  = \ctx -> do
      cmdBindPipeline ctx lightingPipeline
      -- bind g-buffer textures as descriptors
      cmdBindDescriptorSet ctx (lightingDescriptorSet gbuffer)
      -- push constants: light count, camera position
      cmdPushConstants ctx (length lights)
      cmdDraw ctx 3  -- full-screen triangle
  }
```

**Vertex shader:** pass-through fullscreen triangle (no vertex input)
**Fragment shader:**
1. Read UV from fragment coord / screen size
2. Sample position, normal, albedo from g-buffer
3. Loop over lights, accumulate diffuse + specular
4. Output final color

### Graph Structure

```haskell
buildDeferredGraph
  :: DeviceContext
  -> SwapchainContext
  -> [Renderable]
  -> [Light]
  -> RenderGraphBuilder ()
buildDeferredGraph devCtx swapCtx renderables lights = do
  let extent = swapExtent swapCtx

  gbufPos  <- transientImage "gbuf-position" VK_FORMAT_R16G16B16A16_SFLOAT extent VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT
  gbufNorm <- transientImage "gbuf-normal"   VK_FORMAT_R16G16B16A16_SFLOAT extent VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT
  gbufAlb  <- transientImage "gbuf-albedo"   VK_FORMAT_R8G8B8A8_UNORM     extent VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT
  gbufDepth<- transientImage "gbuf-depth"    VK_FORMAT_D32_SFLOAT         extent VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT

  let gbuffer = GBuffer gbufPos gbufNorm gbufAlb gbufDepth
      swapImage = swapchainImage swapCtx

  addPass $ gbufferPass gbuffer renderables
  addPass $ lightingPass gbuffer lights swapImage
```

## Tasks

### Task 4.1: G-Buffer Shader (FIR)
**File:** `src/Graphics/Haskan/Vulkan/Shaders/Deferred/GBuffer.hs`

Write FIR vertex + fragment shaders that output to MRT:
- Position: `layout(location = 0) out vec4 outPosition`
- Normal:   `layout(location = 1) out vec4 outNormal`
- Albedo:   `layout(location = 2) out vec4 outAlbedo`

**Status:** Complete. G-buffer vertex shader transforms vertices and outputs world position, normal, UV. Fragment shader writes to 3 MRT attachments using `FIR` EDSL. Uses `Texture2DArray` with push constant material index for textured albedo.

### Task 4.2: G-Buffer Pass Implementation
**File:** `src/Graphics/Haskan/Vulkan/DeferredResources.hs`

Create render pass with 3 color attachments + 1 depth attachment.
Create framebuffer referencing g-buffer images.
Record draw calls for all renderables.

**Status:** Complete. `DeferredResources` struct holds g-buffer pipeline, framebuffers, images, lighting pass resources. Per-swapchain-image g-buffer resources (one set per swapchain image).

### Task 4.3: Lighting Shader (FIR)
**File:** `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Lighting.hs`

Full-screen triangle vertex shader (generates UVs from `gl_VertexIndex`).
Fragment shader reads g-buffer samplers, computes diffuse lighting.

**Status:** Complete. Fullscreen triangle with corrected UVs (flip Y). Samples position, normal, albedo from g-buffer attachments. Single directional light.

### Task 4.4: Lighting Pass Implementation
**File:** `src/Graphics/Haskan/Vulkan/DeferredResources.hs`

Create render pass reading g-buffer images as input sampled images.
Record full-screen draw.

**Status:** Complete. Lighting render pass with 3 input attachments. Fullscreen pipeline with `TRIANGLE_LIST` topology. Descriptor sets updated per-frame with g-buffer image views.

### Task 4.5: Integrate into Graph
**File:** `src/Graphics/Haskan/Render/Deferred.hs`

Combine g-buffer + lighting into `buildDeferredGraph`.

**Status:** Complete. `buildDeferredGraph` takes `DeferredPassData` and produces g-buffer pass + lighting pass via render graph builder. `Engine.hs` builds deferred graph per frame, compiles, executes.

### Task 4.6: Multiple Lights
Extend lighting shader to loop over N lights (uniform array or SSBO).

**Status:** Deferred. Current lighting pass uses single hardcoded directional light. Multiple lights require SSBO or uniform array — deferred to Milestone 7/8.

## Testing

```haskell
-- In Engine.hs, switch to deferred:
renderGraph <- buildDeferredGraph devCtx swapCtx renderables [light1, light2]
compiled  <- compileGraph devCtx renderGraph

-- Visual check: same scene, same lighting, but via g-buffer
-- RenderDoc: verify g-buffer attachments contain position/normal/albedo
```

## Risks

| Risk | Mitigation |
|------|-----------|
| G-buffer bandwidth heavy | Use R11G11B10 for albedo, pack normal to octahedral |
| MRT not supported | Check `maxColorAttachments` at device creation |
| Transparent objects | Deferred can't do transparency; keep forward path for glass/etc |

## Success Criteria

- [x] G-buffer renders position, normal, albedo correctly
- [x] Lighting pass produces correct illumination
- [ ] 2+ lights work — deferred to M7/M8
- [ ] Performance better than forward for 10+ lights — needs benchmarking
- [x] Can switch between forward and deferred at runtime (compile time switch via `buildForwardGraph`/`buildDeferredGraph`)

## Implementation Notes

**Completed 2026-05-07.** See commits:
- `d735a46` — milestone-4: deferred rendering with g-buffer + lighting pass
- `92f9e9e` — Milestone 6: Wireframe geometry shader demo
- `f3dccf4` — Milestone 6: wireframe geometry shader with runtime toggle, gltf index fix, device feature enablement

### Architecture Decisions
- **Per-swapchain-image g-buffer resources:** One set of 3 g-buffer images + framebuffer per swapchain image. Simplifies synchronization — no need to transition layouts between frames.
- **G-buffer color format:** `VK_FORMAT_R8G8B8A8_UNORM` for position/normal/albedo attachments. Position could use higher precision (R16G16B16A16_SFLOAT) for large scenes.
- **Semaphores indexed by swapchain image:** `renderFinishedSemaphores !! imageIndex` (swapchain image), `renderFinishedFences !! frameNumber` (frame-in-flight slot).
- **Initial layout:** `SHADER_READ_ONLY_OPTIMAL` for g-buffer images matches post-render state; one-time barrier after creation.
- **Fullscreen triangle:** Lighting pass uses 3-vertex triangle covering clip space instead of quad. More efficient (no shared edge vertices).
