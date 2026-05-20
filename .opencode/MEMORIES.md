# Haskan2 Project Memories

## Build Commands

```bash
cabal build lib:haskan2          # Build library only (fast)
cabal build exe:haskan2          # Build executable
cabal build                      # Build all
```

## Key Files

- `src/Graphics/Haskan/Engine/Render.hs` — Main render loop, frame submission
- `src/Graphics/Haskan/Engine/Render/Internal/PassRecording.hs` — Command buffer recording, per-frame resources
- `src/Graphics/Haskan/Engine/Scene.hs` — `makeProjectionMatrix`, view/proj math
- `src/Graphics/Haskan/Vulkan/DeferredResources.hs` — Deferred pipeline resource creation
- `src/Graphics/Haskan/Vulkan/RenderPass.hs` — Render pass definitions
- `src/Graphics/Haskan/Render/Deferred.hs` — Render graph builder (`buildDeferredGraph`)
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` — Cloud ray-march shader (FIR EDSL)
- `src/Graphics/Haskan/Vulkan/Shaders/Compute/APVolume.hs` — Aerial perspective compute shader

## Known Pitfalls

### Vulkan Matrix Convention
- All matrices uploaded to GPU are **transposed** (FIR row-major convention)
- CPU math uses standard Linear column-major, then `transpose` before upload
- `makeProjectionMatrix` uses Vulkan Z [0,1], not OpenGL [-1,1]

### Double-Buffered Resources
- Light SSBO: 2 buffers, index by `frameNumber mod 2`
- Cloud frame UBO: per-swapchain-image, index by `imageIdx`
- AP volume UBO: per-swapchain-image, index by `imageIdx`
- Never share single buffer across frames — causes flickering

### Shader EDSL (FIR)
- Rebindable syntax — uses custom `if/then/else`, not Haskell's
- `signum` available via `Signed` typeclass (SPIRV.Sign)
- Vector swizzles via `_x`, `_y`, `_z`, `_w` from Linear.V4
- SPIR-V compiled to `data/shaders/fir/*.spv` at build time

### Coordinate Systems
- World: Y-up
- NDC: Y-down (Vulkan), Z [0,1]
- Cloud slab: `cloudBottom` to `cloudBottom + 800.0`

## API Patterns

### Uploading Buffers
```haskell
uploadStorageBuffer memory offset data   -- SSBO
uploadUniformBuffer memory offset data   -- UBO
Buffer.copyDataToDeviceMemory device memory data  -- Direct
```

### Descriptor Set Updates
- Lighting descriptor sets need `updateLightingLightBuffer` per frame for SSBO binding
- Cloud descriptor sets pre-bound at init (one per swapchain image)
- AP volume descriptor sets pre-bound at init (one per swapchain image)

## GHC Version
- 9.14.1 (uses `-fdefer-type-errors` friendly)

## Git
- Do NOT commit `.opencode/*.md` research files — they are ephemeral analysis
- Only commit source code changes
