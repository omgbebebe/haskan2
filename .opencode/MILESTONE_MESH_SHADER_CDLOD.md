# Milestone: Mesh Shaders + CDLOD Terrain

## Hardware Target
RTX 40+ series (Ada Lovelace). `VK_EXT_mesh_shader` required.

---

## Vulkan Binding Strategy

**Decision: Keep `vulkan-api`, add `vulkan-3.26.6` as local source package for mesh shader code.**

We already mix both packages in `Backend.hs` with conversion helpers (`toVulkanDevice`, `toVulkanCommandBuffer`, etc.). This is the minimal-friction path.

### Why not replace `vulkan-api` entirely?
- 43+ files import `Graphics.Vulkan.*` (the `vulkan-api` namespace)
- `vulkan` package uses `Vulkan.Core10.*`, `Vulkan.Extensions.*` namespaces
- Complete replacement = refactor every Vulkan call in the project

### How the mix works

| `vulkan-api` (`Graphics.Vulkan`) | `vulkan` (`Vulkan.*`) |
|---|---|
| All existing code | New mesh shader code only |
| `VkDevice`, `VkCommandBuffer`, etc. | `Device`, `CommandBuffer`, etc. |
| Pass-through via `castPtr`/`coerce` | Native for mesh shader calls |

### Conversion helpers already exist

`Backend.hs` shows the pattern:

```haskell
toVulkanDevice :: Graphics.Vulkan.VkDevice -> Vulkan.Core10.Handles.Device
toVulkanCommandBuffer :: Graphics.Vulkan.VkCommandBuffer -> Vulkan.Core10.Handles.CommandBuffer
```

We'll add reverse conversions in a new `Graphics.Haskan.Vulkan.Interop` module:

```haskell
fromVulkanDevice :: Vulkan.Core10.Handles.Device -> Graphics.Vulkan.VkDevice
fromVulkanPipelineLayout :: Vulkan.Core10.Handles.PipelineLayout -> Graphics.Vulkan.VkPipelineLayout
```

### Cabal changes

Add local source package to `cabal.project`:

```cabal
packages:
  ./haskan2.cabal
  ./vulkan-3.26.6/vulkan.cabal
```

(The `vulkan` package is already a cabal dependency, but we'll point it to the local copy.)

---

## FIR Compiler: Mesh Shader Support

### Current State
- `SPIRV/Stage.hs`: `Task` and `Mesh` stage types exist
- `SPIRV/Capability.hs`: `MeshShadingNV` exists (NV extension)
- `SPIRV/Extension.hs`: `SPV_NV_mesh_shader` exists
- **Missing**: `SPV_EXT_mesh_shader`, `MeshShadingEXT`, mesh shader builtins, output array codegen

### Required FIR Additions

#### 1. SPIR-V primitives

| Addition | File | Details |
|---|---|---|
| `MeshShadingEXT` capability | `SPIRV/Capability.hs` | Standard EXT capability |
| `SPV_EXT_mesh_shader` extension | `SPIRV/Extension.hs` | Standard EXT extension |
| `OpSetMeshOutputsEXT` | `SPIRV/Operation.hs` | Sets vertex/primitive output counts |
| `OpEmitMeshTasksEXT` | `SPIRV/Operation.hs` | Task shader dispatches mesh workgroups |
| Mesh shader builtins | `SPIRV/Builtin.hs` | `Position`, `PrimitiveTriangleIndicesEXT`, `CullPrimitiveEXT`, `ViewportIndex`, `Layer` per-vertex/per-primitive |

#### 2. FIR builtins (`FIR/Builtin.hs`)

Mesh shaders need **output arrays** with declared max size:

```
Per-vertex outputs (array indexed by vertex ID):
  gl_MeshVertexPosition :: Index -> Code (V 4 Float)   -- write
  gl_MeshVertexViewportIndex :: Index -> Code Word32   -- write
  gl_MeshVertexLayer :: Index -> Code Word32           -- write

Per-primitive outputs (array indexed by primitive ID):
  gl_MeshPrimitiveTriangleIndices :: Index -> Code (V 3 Word32)  -- write (3 vertex indices)
  gl_MeshPrimitiveCullPrimitive :: Index -> Code Bool            -- write
  gl_MeshPrimitiveViewportIndex :: Index -> Code Word32          -- write
  gl_MeshPrimitiveLayer :: Index -> Code Word32                  -- write
```

**Syntax question for Sergey:** How should FIR represent these array outputs?

Option A: Special builtins with index parameter:
```haskell
gl_MeshVertexPosition index \=\> vec4 x y z 1
```

Option B: Output block record with array semantics:
```haskell
data VertexOut \= VertexOut { position :: V 4 Float }
writeMeshVertex :: Int -> VertexOut -> Code ()
```

Option C: Implicit output arrays via `out` declarations with array size:
```haskell
out [64] position :: V 4 Float   -- declares 64-element output array
position ! index \=\> vec4 x y z 1
```

I recommend **Option A** for minimal syntax changes — it's closest to how FIR already handles builtins.

#### 3. CodeGen changes (`CodeGen/Functions.hs`)

- Entry point generation for `ExecutionModelMeshEXT` and `ExecutionModelTaskEXT`
- Output variable array declarations with `Output` storage class
- `OpSetMeshOutputsEXT` call before writing outputs

#### 4. Pipeline validation (`FIR/Validation/Pipeline.hs`)

- Accept `Task -> Mesh -> Fragment` or `Mesh -> Fragment` stage sequences
- Reject `Vertex` + `Mesh` in same pipeline
- Validate mesh output limits (vertex count, primitive count, topology)

---

## CDLOD + Mesh Shader Algorithm

### RTX 4090 Mesh Shader Limits

From `PhysicalDeviceMeshShaderPropertiesEXT`:
- `maxMeshOutputVertices`: typically 256
- `maxMeshOutputPrimitives`: typically 256 (triangles) or 512 (lines)
- `maxMeshWorkGroupSize`: typically (256, 1, 1)
- `maxMeshWorkGroupInvocations`: typically 256
- `maxPreferredMeshWorkGroupInvocations`: typically 128 or 256

These limits are **per workgroup**, not per draw call. A single `vkCmdDrawMeshTasksEXT` dispatches many workgroups.

### Patch Size Decision

Given 256 vertex / 256 primitive limit:

| Patch Size | Vertices | Triangles | Fit? |
|---|---|---|---|
| 16×16 | 256 | 450 | Yes (barely) |
| 8×8 | 64 | 98 | Yes (comfortable) |
| 32×32 | 1024 | 1922 | No |

**Decision: 8×8 patches.**

- 64 vertices + 98 triangles per workgroup
- Leaves headroom for additional outputs (normals, UVs, climate indices)
- Better occupancy (more workgroups in flight)

### LOD Levels

| LOD | Patch Grid | World Size | Vertices/Patch | Triangles/Patch |
|---|---|---|---|---|
| 0 (full) | 8×8 | 256m | 64 | 98 |
| 1 | 4×4 | 512m | 16 | 18 |
| 2 | 2×2 | 1024m | 4 | 2 |
| 3 | 1×1 | 2048m | 1 | 0 (point?) |

Actually for CDLOD, the mesh shader emits a **dense grid** at variable density:

```
LOD 0: every vertex (8×8 grid)
LOD 1: every 2nd vertex (4×4 grid from 8×8 data)
LOD 2: every 4th vertex (2×2 grid)
LOD 3: every 8th vertex (1×1 = single triangle pair)
```

Each LOD level is still emitted by one workgroup, just with fewer active vertices/primitives via `OpSetMeshOutputsEXT`.

### CDLOD Node Tree → Mesh Workgroups

**Option A: CPU-side quadtree, GPU mesh shader just emits patches**
- CPU frustum-culls quadtree nodes
- Each visible node = one `vkCmdDrawMeshTasksEXT` workgroup
- Mesh shader samples heightmap, generates patch at node LOD
- **Pros**: Simple, CPU already knows node bounds
- **Cons**: One draw call per node, CPU overhead

**Option B: GPU-driven via task shader**
- Task shader reads compact node list from GPU buffer
- Each task workgroup processes one node, decides children visibility
- Emits mesh workgroups for visible leaf nodes
- **Pros**: Zero CPU overhead for culling
- **Cons**: Requires indirect dispatch, more complex

**Decision: Start with Option A (CPU quadtree).** GPU-driven culling (Option B) is Phase 2 optimization.

### Crack-Free Transitions (CDLOD Key Feature)

At LOD boundaries, vertices on the edge of the higher-LOD patch are **morphed** (geomorphing) to match the lower-LOD height. This eliminates T-junctions without skirts or stitching.

Implementation in mesh shader:

```glsl
// For each vertex, compute morph factor based on distance to camera
float morphFactor = computeMorphFactor(vertexWorldPos, cameraPos, nodeLOD);

// Sample height at full LOD
float heightFull = sampleHeightmap(uv, lod);

// Sample height at parent LOD (coarser)
float heightParent = sampleHeightmap(uv, lod + 1);

// Morph between them
float height = mix(heightParent, heightFull, morphFactor);
```

The morph zones are defined as a fraction of the node's size (e.g., outer 20% of each edge morphs).

### Per-Patch Data (Passed as UBO/SSBO)

Each mesh workgroup needs:

```
struct TerrainNode {
    vec2 worldOffset;      // Node world-space origin (x, z)
    float worldSize;       // Node edge length in world units
    float heightScale;     // Heightmap meters per texel
    int lodLevel;          // 0 = finest, N = coarsest
    int heightmapLayer;    // Texture array layer for this node's heightmap
    int climateLayer;      // Texture array layer for climate data
    float morphStart;      // Distance where morphing begins (0.0 = no morph, 1.0 = full morph zone)
};
```

Nodes are stored in a GPU SSBO. Each draw call references a range of nodes.

---

## Architecture

### New Modules

```
src/Graphics/Haskan/Terrain/
  CDLOD.hs             -- Quadtree, node selection, LOD decisions
  MeshShader.hs        -- Mesh shader pipeline creation (using vulkan package)
  MeshRender.hs        -- Per-frame mesh terrain render pass recording

src/Graphics/Haskan/Vulkan/
  Interop.hs           -- vulkan-api <-> vulkan package conversions
  MeshPipeline.hs      -- createMeshPipeline using vulkan package types

3rdparty/fir/src/
  SPIRV/Capability.hs  -- Add MeshShadingEXT
  SPIRV/Extension.hs   -- Add SPV_EXT_mesh_shader
  SPIRV/Builtin.hs     -- Add mesh shader builtins
  SPIRV/Operation.hs   -- Add OpSetMeshOutputsEXT, OpEmitMeshTasksEXT
  FIR/Builtin.hs       -- Add mesh output builtins
  CodeGen/Functions.hs -- Mesh/task entry point generation
  FIR/Validation/Pipeline.hs -- Mesh pipeline validation
```

### Modified Modules

```
src/Graphics/Haskan/Engine/Render/
  Internal/PassRecording.hs  -- Add mesh terrain draw call
  Internal/Setup.hs          -- Create mesh shader modules, terrain node SSBO
  
src/Graphics/Haskan/Vulkan/
  DescriptorSetLayout.hs     -- Add terrain node SSBO binding
  DescriptorPool.hs          -- Mesh terrain descriptor pool
  DescriptorSet.hs           -- Update terrain node descriptor sets
  DeferredResources.hs       -- Mesh pipeline, node SSBO
```

---

## Implementation Order

### Phase 1: FIR Mesh Shader Foundation (1-2 sessions)
1. Add `MeshShadingEXT`, `SPV_EXT_mesh_shader` to FIR SPIR-V primitives
2. Add mesh shader builtins to `FIR/Builtin.hs`
3. Add `OpSetMeshOutputsEXT` to `SPIRV/Operation.hs`
4. Update `CodeGen/Functions.hs` for mesh entry points
5. Update `FIR/Validation/Pipeline.hs` for mesh stage sequences
6. Write a minimal "hello mesh" shader: emit single triangle, verify compilation

### Phase 2: Host-Side Mesh Pipeline (1 session)
1. Add `vulkan-3.26.6` as local source package
2. Create `Graphics.Haskan.Vulkan.Interop` — bidirectional handle conversions
3. Create `Graphics.Haskan.Vulkan.MeshPipeline` — `createMeshPipeline` using `vulkan` package
4. Extension query: `VK_EXT_mesh_shader` in device creation
5. Feature enable: `PhysicalDeviceMeshShaderFeaturesEXT`
6. Draw command: `cmdDrawMeshTasksEXT` wrapper

### Phase 3: CDLOD Data Structures (1 session)
1. Create `Terrain/CDLOD.hs` — quadtree, node selection, morph factor computation
2. Terrain node SSBO layout and update logic
3. Heightmap texture array (reuse existing texture upload)
4. CPU-side frustum culling of quadtree nodes

### Phase 4: Mesh Shader Terrain (2-3 sessions)
1. Write FIR mesh shader:
   - Read node data from SSBO (`gl_WorkgroupID` indexes node)
   - Sample heightmap texture array
   - Emit 8×8 vertex grid with morphing
   - Output normals (from heightmap derivatives)
   - Pass UVs + climate layer to fragment shader
2. Write FIR fragment shader:
   - Sample climate texture array
   - Apply elevation-based + climate-driven color
3. Integrate into deferred renderer
4. Render after G-buffer pass (or as G-buffer? Need to decide)

### Phase 5: Task Shader GPU Culling (Optional, 2 sessions)
1. FIR task shader: read node list, frustum cull, emit mesh tasks
2. Indirect dispatch: `cmdDrawMeshTasksIndirectEXT`
3. GPU-driven LOD selection

---

## Open Questions

1. **G-buffer integration**: Does terrain go into G-buffer (albedo + normal + depth) or render as forward pass on top?
   - **Recommendation**: Deferred. Terrain mesh shader outputs to G-buffer MRT, then lighting shaders sample it. This matches existing deferred architecture.

2. **Heightmap precision**: API returns int16. At 8×8 patch with 256m world size, each texel = 32m. Height precision needs to be sub-meter for close-up detail. Options:
   - Finer heightmap fetch (API supports multiple scales)
   - Procedural noise detail added in mesh shader
   - **Recommendation**: Use scale=8 (32m per texel) for far, scale=4 (16m) for mid, scale=2 (8m) for near. Multiple texture arrays per LOD.

3. **Normal computation**: Central differencing on heightmap in mesh shader, or precomputed normal texture?
   - **Recommendation**: Compute in mesh shader (3 heightmap samples per vertex = cheap).

4. **Physics integration**: Heightfield from which LOD level?
   - **Recommendation**: Coarsest LOD (scale=1, 256m per texel) for physics, refined with raycasts for detailed collision.

---

## Success Criteria

- [ ] FIR compiles mesh shader SPIR-V that passes `spirv-val`
- [ ] `vkCreateGraphicsPipelines` succeeds with mesh + fragment stages
- [ ] `vkCmdDrawMeshTasksEXT` renders visible terrain patches
- [ ] Camera movement triggers LOD changes (visible mesh density variation)
- [ ] No cracks between adjacent LOD levels
- [ ] 60 FPS at 1080p with 5×5 visible tile grid
- [ ] Validation layers clean (no mesh shader-related errors)

---

## Related Documents
- `.opencode/MEMORIES.md`
- `.opencode/MILESTONE_TERRAIN_SYSTEM.md`
- `.opencode/MILESTONE_JOLT_PHYSICS.md`
