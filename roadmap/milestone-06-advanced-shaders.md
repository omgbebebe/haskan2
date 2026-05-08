# Milestone 6: Advanced Shaders

## Goal
Support geometry, tessellation, and mesh shaders in the pipeline system.

## Why This Matters

**Geometry shaders:** Generate geometry on GPU (wireframe, fur, particle expansion).

**Tessellation shaders:** Dynamic LOD for terrain, displacement mapping.

**Mesh shaders:** GPU-driven geometry generation (task shader → mesh shader), replaces vertex/tessellation/geometry pipeline.

These are standard in modern engines. The pipeline system must support them without rewriting material/shader infrastructure.

## Deliverables

1. `Graphics.Haskan.Render.ShaderProgram` — shader stage management
2. `Graphics.Haskan.Render.Pipeline` — pipeline state with all shader stages
3. FIR shaders for geometry, tessellation, mesh
4. Demo: wireframe overlay via geometry shader

## Design

### ShaderProgram Type

```haskell
data ShaderProgram = ShaderProgram
  { spVertex         :: !ShaderHandle
  , spTessControl    :: !(Maybe ShaderHandle)  -- optional
  , spTessEvaluation :: !(Maybe ShaderHandle)  -- optional
  , spGeometry       :: !(Maybe ShaderHandle)  -- optional
  , spFragment       :: !ShaderHandle
  }
  deriving (Eq, Ord)

-- Mesh shader variant (Vulkan 1.2+ / extension)
data MeshShaderProgram = MeshShaderProgram
  { mspTask    :: !(Maybe ShaderHandle)  -- optional task shader
  , mspMesh    :: !ShaderHandle
  , mspFragment :: !ShaderHandle
  }
```

### Pipeline State

```haskell
data PipelineState = PipelineState
  { psShaderProgram    :: !ShaderProgram
  , psVertexFormat     :: !VertexFormat
  , psPrimitiveTopology:: !VkPrimitiveTopology
  , psPolygonMode      :: !VkPolygonMode
  , psCullMode         :: !VkCullModeFlags
  , psFrontFace        :: !VkFrontFace
  , psDepthTest        :: !Bool
  , psDepthWrite       :: !Bool
  , psBlendMode        :: !BlendMode
  , psTessPatchSize    :: !(Maybe Int)  -- for tessellation
  }
```

Pipeline cache key: `(ShaderProgram, PipelineState, RenderPass)`

### Geometry Shader Example: Wireframe

```haskell
-- Vertex shader: pass through position
-- Geometry shader: input = triangle, output = 3 lines
--   emit 3 line segments from triangle edges
-- Fragment shader: output solid color

wireframeProgram :: ShaderProgram
wireframeProgram = ShaderProgram
  { spVertex   = wireframeVert
  , spGeometry = Just wireframeGeom
  , spFragment = wireframeFrag
  }
```

### Tessellation Example: Displacement

```haskell
-- Vertex shader: pass position + normal + UV
-- Tess Control: set tess levels based on distance to camera
-- Tess Eval: displace vertices along normal by displacement map
-- Fragment: standard PBR

displacementProgram :: ShaderProgram
displacementProgram = ShaderProgram
  { spVertex         = dispVert
  , spTessControl    = Just dispTessCtrl
  , spTessEvaluation = Just dispTessEval
  , spFragment       = pbrFrag
  }
```

### Mesh Shader Example: Procedural Cube

```haskell
-- Task shader: decide how many mesh shader workgroups to launch
-- Mesh shader: generate cube vertices/indices procedurally
-- Fragment: standard shading

proceduralCubeProgram :: MeshShaderProgram
proceduralCubeProgram = MeshShaderProgram
  { mspTask     = Just decideCubes
  , mspMesh     = generateCube
  , mspFragment = pbrFrag
  }
```

## Tasks

### Task 6.1: Extend ShaderProgram Type
**File:** `src/Graphics/Haskan/Render/ShaderProgram.hs`

Add optional tessellation + geometry stages to `ShaderProgram`.

**Status:** Complete. `ShaderProgram` type with `spVertex`, `spTessControl`, `spTessEvaluation`, `spGeometry`, `spFragment` (all `Maybe` except vertex/fragment). `toPipelineStages` converts to variable-length `VkPipelineShaderStageCreateInfo` array.

### Task 6.2: Pipeline Creation with All Stages
**File:** `src/Graphics/Haskan/Vulkan/GraphicsPipeline.hs`

Update pipeline creation to handle:
- `pStages` array with 3-5 shader stages
- `pTessellationState` if tessellation present
- `pDynamicState` for viewport, scissor

**Status:** Complete. `createGraphicsPipeline` accepts `ShaderProgram`, builds stage array dynamically. `managedFullscreenPipeline` for lighting pass. Geometry shader pipeline uses `TRIANGLE_LIST` input, `LineStrip` output.

### Task 6.3: Geometry Shader — Wireframe
**File:** `src/Graphics/Haskan/Vulkan/Shaders/Wireframe.hs`

FIR geometry shader that takes triangles and outputs line strips.

**Status:** Complete. Wireframe vertex shader (MVP via UBO), geometry shader emits 3 line edges per triangle, fragment shader writes to albedo (Location 2) for visibility in deferred lighting pass. Runtime toggle via F3. `ToggleWireframe` action in input system.

### Task 6.4: Tessellation Shader — Terrain LOD
**File:** `src/Graphics/Haskan/Shaders/Terrain.hs`

Tessellation control shader sets tess levels based on distance.
Tessellation evaluation shader samples heightmap.

**Status:** Not started. Deferred to post-M8 or when terrain demo is needed.

### Task 6.5: Mesh Shader — Procedural Geometry
**File:** `src/Graphics/Haskan/Shaders/Mesh.hs`

Mesh shader generates cube without vertex buffer.
Requires `VK_EXT_mesh_shader` or Vulkan 1.3.

**Status:** Not started. Deferred to post-M8. Device capability query structure in place via `queryDeviceCapabilities`.

### Task 6.6: Feature Detection
**File:** `src/Graphics/Haskan/Vulkan/Device.hs`

Check device capabilities:
- `geometryShader` feature
- `tessellationShader` feature
- `meshShader` extension (VK_EXT_mesh_shader)

Gracefully fall back if features unavailable.

**Status:** Complete. `geometryShader` enabled via `VkPhysicalDeviceFeatures2` pNext chaining. Descriptor indexing features queried via `VkPhysicalDeviceDescriptorIndexingFeatures`. Runtime array support checked.

## Testing

```haskell
-- Wireframe test
let wireframeMat = Material
      { matShader = wireframeProgram
      , matPipeline = ...
      }
setMaterial world entity wireframeMat
-- Should see wireframe cube

-- Tessellation test
let terrainMat = Material
      { matShader = displacementProgram
      , matPipeline = ...
      }
-- Should see tessellated terrain

-- Mesh shader test (if supported)
let meshMat = MaterialMesh
      { matMeshShader = proceduralCubeProgram
      }
-- Should see cube with no vertex buffer
```

## Risks

| Risk | Mitigation |
|------|-----------|
| Mesh shaders require Vulkan 1.3/extension | Feature detection + fallback to traditional pipeline |
| Geometry shaders performance | Use only for debug/visualization, not production paths |
| Tessellation max patch size | Query `maxTessellationPatchSize` at device creation |
| FIR doesn't support mesh shaders | May need raw SPIR-V or GLSL compilation path |

## Success Criteria

- [x] ShaderProgram supports vertex + optional tessellation + optional geometry + fragment
- [x] Pipeline creation handles all stage combinations
- [x] Geometry shader demo: wireframe overlay with runtime toggle
- [ ] Tessellation shader demo: terrain LOD — deferred
- [ ] Mesh shader demo: procedural cube — deferred
- [x] Graceful fallback when features unavailable (wireframe toggle checks device capabilities)

## Implementation Notes

**Completed 2026-05-07.** See commits:
- `92f9e9e` — Milestone 6: Wireframe geometry shader demo
- `f3dccf4` — Milestone 6: wireframe geometry shader with runtime toggle, gltf index fix, device feature enablement

### Architecture Decisions
- `ShaderProgram` over raw shader modules — pipeline accepts variable stage count
- Wireframe vertex shader uses same UBO binding (Set 0, Binding 0) as g-buffer vertex shader for descriptor set layout compatibility
- Geometry shader device feature must be explicitly enabled in `VkPhysicalDeviceFeatures` — cannot rely on availability query alone
- Wireframe fragment shader writes to Location 2 (albedo), not Location 0 (position), to be visible in deferred lighting pass
