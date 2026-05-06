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
**File:** `src/Graphics/Haskan/Render/Material.hs`

Add optional tessellation + geometry stages to `ShaderProgram`.

**Acceptance:** Type compiles, old shaders still work (Nothing for optional stages).

### Task 6.2: Pipeline Creation with All Stages
**File:** `src/Graphics/Haskan/Render/Pipeline.hs`

Update `createGraphicsPipeline` to handle:
- `pStages` array with 3-5 shader stages
- `pTessellationState` if tessellation present
- `pDynamicState` for viewport, scissor

**Acceptance:** Pipeline with geometry shader compiles and links.

### Task 6.3: Geometry Shader — Wireframe
**File:** `src/Graphics/Haskan/Shaders/Wireframe.hs`

FIR geometry shader that takes triangles and outputs line strips:

```haskell
wireframeGeom :: Shader "main" GeometryShader GeometryInput GeometryOutput _
wireframeGeom = do
  -- input: triangles
  -- output: line_strip, max_vertices = 6
  -- emit 3 edges per triangle
  ...
```

**Acceptance:** Wireframe visible over solid mesh.

### Task 6.4: Tessellation Shader — Terrain LOD
**File:** `src/Graphics/Haskan/Shaders/Terrain.hs`

Tessellation control shader sets tess levels based on distance.
Tessellation evaluation shader samples heightmap.

**Acceptance:** Terrain mesh tessellates more near camera, less in distance.

### Task 6.5: Mesh Shader — Procedural Geometry
**File:** `src/Graphics/Haskan/Shaders/Mesh.hs`

Mesh shader generates cube without vertex buffer.
Requires `VK_EXT_mesh_shader` or Vulkan 1.3.

**Acceptance:** Cube renders with no vertex/index buffer bound.

### Task 6.6: Feature Detection
**File:** `src/Graphics/Haskan/Vulkan/Device.hs`

Check device capabilities:
- `geometryShader` feature
- `tessellationShader` feature
- `meshShader` extension (VK_EXT_mesh_shader)

Gracefully fall back if features unavailable.

**Acceptance:** Engine runs on devices without geometry shaders (uses fallback).

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

- [ ] ShaderProgram supports vertex + optional tessellation + optional geometry + fragment
- [ ] Pipeline creation handles all stage combinations
- [ ] Geometry shader demo: wireframe overlay
- [ ] Tessellation shader demo: terrain LOD
- [ ] Mesh shader demo: procedural cube (if device supports)
- [ ] Graceful fallback when features unavailable
