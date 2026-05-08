# Haskan2 Engine — Development Roadmap

## Project Vision

Haskan2 is a research project exploring the feasibility and ergonomics of building a modern game engine using Haskell and Vulkan. The ultimate goal is to demonstrate that Haskell's type system, purity, and compositional patterns can produce a competitive, production-capable engine core.

**Target capabilities:**
- Runtime resource management (load/unload without restart)
- Entity-Component-System (ECS) architecture
- Deferred rendering pipeline
- GLTF scene loading
- Geometry/tessellation/mesh shaders
- Bindless descriptor rendering
- GPU-driven rendering (indirect draw, compute culling)

## Architecture Philosophy

The engine follows a **layered architecture** where each layer is independently replaceable:

```
Layer 4: Scene (ECS, GLTF, transforms, lights)
Layer 3: Render Graph (passes, barriers, scheduling)
Layer 2: Resources (GPU memory, handles, lifetime management)
Layer 1: GPU Commands (command buffers, queues, synchronization)
```

**Key principle:** *Abstract early, implement late.* Each layer defines interfaces that upper layers depend on. The implementation can evolve (e.g., switch from dedicated allocations to VMA) without rewriting draw code.

## Milestones

| # | Milestone | Goal | Estimated LOC |
|---|-----------|------|---------------|
| 1 | [Resource Manager](milestone-01-resource-manager.md) | Runtime load/unload with typed handles | ~500 |
| 2 | [ECS Foundation](milestone-02-ecs.md) | Scene representation as entities + components | ~600 |
| 3 | [Render Graph](milestone-03-render-graph.md) | Declarative multi-pass rendering | ~800 |
| 4 | [Deferred Rendering](milestone-04-deferred-rendering.md) | G-buffer + lighting passes | ~700 |
| 5 | [GLTF Loading](milestone-05-gltf-loading.md) | Full scene import from GLTF 2.0 | ~900 |
| 6 | [Advanced Shaders](milestone-06-advanced-shaders.md) | Geometry, tessellation, mesh shaders | ~600 |
| 7 | [Bindless Rendering](milestone-07-bindless-rendering.md) | Descriptor indexing, texture arrays | ~500 |
| 8 | [GPU-Driven Rendering](milestone-08-gpu-driven.md) | Compute culling, indirect draw | ~800 |

## Current State

**Milestone 1 complete:** Resource manager with typed handles (`MeshHandle`, `TextureHandle`), STM-backed registry, runtime load/unload.

**Milestone 2 complete:** Sparse-set ECS (`IntMap`-based component storage), `World` with entities, transforms, meshes, materials, parent-child hierarchy.

**Milestone 3 complete:** Render graph infrastructure — builder monad, topological sort compiler, forward pass integration. Multi-pass support active in deferred pipeline.

**Milestone 4 complete:** Deferred rendering with g-buffer (position/normal/albedo) + fullscreen lighting pass. Per-swapchain-image g-buffer resources. G-buffer MRT shaders in FIR.

**Milestone 5 complete:** glTF 2.0 loading via `gltf-loader` library. Node hierarchy → ECS entities. Material→texture mapping. JSON mime type fix for embedded images. Multi-primitive mesh merging.

**Milestone 6 complete:** Geometry shader wireframe overlay (vertex/geometry/fragment pipeline). `ShaderProgram` type with optional tessellation/geometry stages. Runtime wireframe toggle (F3). Device feature enablement via `VkPhysicalDeviceFeatures2` pNext chaining.

**Milestone 7 partial:** `Texture2DArray` support patched into FIR (upstreamable). Texture array created from all unique scene textures, resized to 256×256, bound once per frame. Material index pushed per draw call via `vkCmdPushConstants`. True descriptor runtime arrays (`OpTypeRuntimeArray` + `NonUniform`) deferred — requires FIR AST surgery.

**Milestone 8 not started.**

**Asset preprocessor skeleton complete:** `AssetCache` with djb2-based file cache under `.haskan2-cache/`. `TexturePreprocessor` with bilinear resize, PoT rounding, serialize/deserialize. Wired into glTF texture loading path.

**Critical lessons learned:**
- `linear`'s `M44` is row-major; Vulkan/GLSL reads `mat4` as column-major — always `transpose` before uniform buffer upload
- `Projection.lookAt` is correct for view matrix
- OBJ loader produces clockwise-wound triangles; glTF uses counter-clockwise — disable culling for glTF
- Fence wait/reset must precede `vkAcquireNextImageKHR`
- Descriptor pool type must exactly match layout type
- Per-frame command buffer re-recording inside `renderImage`; command pool has `RESET_COMMAND_BUFFER_BIT`
- Dynamic uniform buffer offsets with 256-byte alignment for per-entity MVP data
- Matrix transpose at upload only — `linear` row-major `M44` transposed in `Buffer.updateUniformBufferRegion`
- glTF index `componentType` must be respected — `UNSIGNED_BYTE` (5121) and `UNSIGNED_INT` (5125) are valid
- FIR scalar math: `dot` returns `Scalar v`; avoid scalar-scalar `*`
- FIR `normalise`: British spelling required
- FIR `if-then-else`: ambiguous with polymorphic literals; convert indices to `Code Float` first
- GPU selection: score by device type; discrete GPU strongly preferred over llvmpipe
- Vulkan API version raw value `4211000` = Vulkan 1.4.312
- Texture array dimensions: all layers must be identical size; resize to common size at load time
- `nextPowerOfTwo` must use `finiteBitSize` bound to avoid infinite loop on Int overflow

## Next Milestone

**Milestone 7 completion:** Material system stores texture indices, single descriptor set bind per frame.

**Milestone 8:** GPU-driven rendering — compute culling, indirect draw commands.

## Documentation

- [Architecture Overview](ARCHITECTURE.md) — Layer descriptions, data types, interfaces
- [Subsystem Diagram](subsystem-diagram.md) — Module dependencies and responsibilities
- [Data Flow Diagram](dataflow-diagram.md) — Frame lifecycle, resource flow, synchronization
- [Frame Inspector](frame-inspector.md) — Capture, serialize, analyze pipeline
