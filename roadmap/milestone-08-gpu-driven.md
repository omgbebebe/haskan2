# Milestone 8: GPU-Driven Rendering

## Goal
Move entire render submission to GPU: compute culling generates indirect draw commands, eliminating CPU bottleneck for high object counts.

## Why This Matters

CPU-driven: ECS extracts visible entities → builds draw list → records command buffers → submits. CPU cost scales with object count.

GPU-driven: Compute shader culls + generates `VkDrawIndexedIndirectCommand` array. CPU only submits one `vkCmdDrawIndexedIndirect` call. GPU cost scales, CPU cost is constant.

Modern engines (Unreal 5 Nanite, Frostbite) use GPU-driven pipelines for thousands of objects.

## Deliverables

1. `Graphics.Haskan.Render.GPUDriven` — indirect draw pipeline
2. `Graphics.Haskan.Render.MeshShader` — task/mesh shader pipeline (optional)
3. Compute shaders for: culling, LOD selection, draw command generation
4. Demo: 10,000+ objects at 60 FPS

## Design

### GPU-Driven Pipeline

```
CPU: Update transforms, write to SSBO
     |
GPU Compute: Frustum cull → visible object list
             LOD select → mesh LOD index
             Generate indirect draw commands
     |
GPU Draw: vkCmdDrawIndexedIndirect (one call, N draws)
     |
GPU Fragment: Shade visible pixels
```

### Indirect Draw Commands

```haskell
data DrawCommand = DrawCommand
  { dcIndexCount    :: !Word32
  , dcInstanceCount :: !Word32
  , dcFirstIndex    :: !Word32
  , dcVertexOffset  :: !Int32
  , dcFirstInstance :: !Word32
  }

-- GPU generates array of DrawCommand
-- CPU submits: vkCmdDrawIndexedIndirect buffer offset stride drawCount
```

### Scene Data Structures (GPU Buffers)

```haskell
data SceneGPUData = SceneGPUData
  { sgdTransforms     :: !BufferHandle  -- SSBO: mat4[] world matrices
  , sgdAABBs          :: !BufferHandle  -- SSBO: vec4 min, vec4 max[]
  , sgdMaterials      :: !BufferHandle  -- SSBO: material indices
  , sgdDrawCommands   :: !BufferHandle  -- SSBO: DrawCommand[] (written by compute)
  , sgdVisibleCount   :: !BufferHandle  -- atomic counter (written by compute)
  }
```

### Compute Shader: Cull + Generate

```glsl
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0) readonly buffer Transforms {
    mat4 transforms[];
};

layout(set = 0, binding = 1) readonly buffer AABBs {
    vec4 aabbMin[];
    vec4 aabbMax[];
};

layout(set = 0, binding = 2) writeonly buffer DrawCommands {
    DrawCommand commands[];
};

layout(set = 0, binding = 3) buffer VisibleCount {
    uint count;
};

layout(push_constant) uniform PushConstants {
    mat4 viewProj;
    uint objectCount;
} pc;

void main() {
    uint gid = gl_GlobalInvocationID.x;
    if (gid >= pc.objectCount) return;

    // Transform AABB to world space
    vec3 worldMin = (transforms[gid] * vec4(aabbMin[gid].xyz, 1.0)).xyz;
    vec3 worldMax = (transforms[gid] * vec4(aabbMax[gid].xyz, 1.0)).xyz;

    // Frustum cull
    if (!frustumCull(worldMin, worldMax, pc.viewProj)) return;

    // Visible: append draw command
    uint idx = atomicAdd(count, 1);
    commands[idx] = DrawCommand(
        indexCounts[gid],    // per-object index count
        1,                   // instance count
        indexOffsets[gid],   // first index
        vertexOffsets[gid],  // vertex offset
        gid                  // first instance (for gl_InstanceIndex)
    );
}
```

### Mesh Shader Pipeline (Optional, Vulkan 1.3+)

```
CPU: Update transforms, write to SSBO
     |
GPU Task Shader: Decide which meshlets to process
     |
GPU Mesh Shader: Generate vertices/indices per meshlet
     |
GPU Fragment: Shade
```

No vertex buffers, no index buffers. Everything generated on GPU.

### Multi-Draw Indirect (MDI)

```haskell
cmdDrawIndexedIndirect :: CommandBuffer
                       -> BufferHandle  -- draw commands buffer
                       -> Word64        -- offset
                       -> Word32        -- drawCount
                       -> Word32        -- stride
                       -> IO ()
```

One call draws all visible objects.

## Tasks

### Task 8.1: Scene Data GPU Buffers
**File:** `src/Graphics/Haskan/Render/GPUDriven.hs`

Upload ECS data to GPU buffers each frame:
- Transforms (world matrices)
- AABBs (for culling)
- Material indices
- Mesh metadata (index count, offsets)

**Acceptance:** Data accessible in compute shader.

### Task 8.2: Compute Shader — Cull + Generate
**File:** `src/Graphics/Haskan/Shaders/GPUCulling.hs`

FIR compute shader:
1. Read transform + AABB
2. Transform AABB to world space
3. Test against frustum planes
4. If visible: atomic increment counter, write draw command

**Acceptance:** Compute shader writes correct draw commands.

### Task 8.3: Indirect Draw Buffer
**File:** `src/Graphics/Haskan/Render/GPUDriven.hs`

Create buffer with `VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT`.

Use as both compute shader output and indirect draw input.

**Acceptance:** Buffer usable for both compute write and draw indirect.

### Task 8.4: Render Pass Integration
**File:** `src/Graphics/Haskan/Render/Graph.hs`

Add compute pass to render graph:
```haskell
addComputePass "cull-and-generate"
  [sceneDataSSBO]
  [drawCommandsBuffer, visibleCountBuffer]
  cullShader
```

Then draw pass uses `vkCmdDrawIndexedIndirect` with generated commands.

**Acceptance:** Graph compiles with compute + draw passes.

### Task 8.5: Per-Instance Data
**File:** `src/Graphics/Haskan/Render/GPUDriven.hs`

Use `gl_InstanceIndex` to look up:
- Transform matrix
- Material index
- Texture indices

In vertex shader:
```glsl
layout(set = 0, binding = 0) readonly buffer Transforms {
    mat4 worldMatrices[];
};

void main() {
    mat4 world = worldMatrices[gl_InstanceIndex];
    gl_Position = projView * world * vec4(position, 1.0);
}
```

**Acceptance:** Each instance renders with correct transform.

### Task 8.6: LOD Selection
**File:** `src/Graphics/Haskan/Shaders/GPUCulling.hs`

Extend compute shader to select LOD based on distance:
```glsl
float distance = length(cameraPos - objectCenter);
int lod = selectLOD(distance, lodDistances);
drawCommand.indexCount = lodIndexCounts[lod];
drawCommand.firstIndex = lodIndexOffsets[lod];
```

**Acceptance:** Distant objects use lower LOD, closer use higher.

### Task 8.7: Performance Test
**File:** `app/Main.hs`

Spawn 10,000 cube entities. Measure:
- CPU time per frame (should be ~constant)
- GPU time per frame
- Draw call count (should be 1 indirect call)

**Acceptance:** 60 FPS with 10,000 objects.

## Testing

```haskell
-- Create 10000 entities
world <- createWorld
forM_ [0..9999] $ \i -> do
  e <- spawnEntity world
  setTransform world e (Transform (randomPosition i) identity (V3 1 1 1))
  setMesh world e cubeMesh
  setMaterial world e defaultMaterial

-- Render
renderFrame world rm = do
  uploadTransforms world sceneBuffers
  runComputeCull cmd sceneBuffers frustum
  cmdDrawIndexedIndirect cmd drawCmdBuffer 0 drawCount (sizeOf @DrawCommand undefined)

-- Should see 10000 cubes, culled when off-screen
```

## Risks

| Risk | Mitigation |
|------|-----------|
| GPU memory for 10k transforms | Use `maxMemoryAllocationSize`, batch if needed |
| LOD meshes need separate index buffers | Pack LODs in same buffer with offsets |
| Barrier between compute and draw | Render graph handles this automatically |
| Mesh shaders unsupported | Fallback to indirect draw with vertex buffers |

## Success Criteria

- [ ] Compute shader culls objects correctly
- [ ] Indirect draw buffer generated on GPU
- [ ] Single `vkCmdDrawIndexedIndirect` per frame
- [ ] Per-instance transforms correct
- [ ] LOD selection works
- [ ] 10,000+ objects at 60 FPS
- [ ] CPU frame time constant regardless of object count

## Architecture Impact

This milestone validates the entire engine architecture:
- **ResourceManager** — handles mesh/texture lifetime
- **ECS** — provides scene data for GPU upload
- **Render Graph** — schedules compute + draw passes with barriers
- **Material System** — bindless textures work with indirect draw
- **Pipeline Cache** — multiple pipelines (LOD levels) cached

If all previous milestones are solid, this is "just" wiring them together with compute shaders.
