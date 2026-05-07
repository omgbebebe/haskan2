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

**Milestone 1 complete:** Resource manager with typed handles.

**Milestone 2 complete:** Sparse-set ECS, 3 entities rendering with correct transforms, view matrix, front face culling.

**Milestone 3 complete:** Render graph infrastructure — builder monad, topological sort compiler, forward pass integration. Single-pass graph produces identical output to previous hardcoded path. Multi-pass support and automatic barriers deferred to Milestone 4.

**Critical lessons learned:**
- `linear`'s `M44` is row-major; Vulkan/GLSL reads `mat4` as column-major — always `transpose` before uniform buffer upload
- `Projection.lookAt` is correct for view matrix
- OBJ loader produces clockwise-wound triangles
- Fence wait/reset must precede `vkAcquireNextImageKHR`
- Descriptor pool type must exactly match layout type

## Next Milestone

**Milestone 4: Deferred Rendering** — G-buffer + lighting passes using the render graph infrastructure.

## Documentation

- [Architecture Overview](ARCHITECTURE.md) — Layer descriptions, data types, interfaces
- [Subsystem Diagram](subsystem-diagram.md) — Module dependencies and responsibilities
- [Data Flow Diagram](dataflow-diagram.md) — Frame lifecycle, resource flow, synchronization
