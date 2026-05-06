# Milestone 5: GLTF Loading

## Goal
Load full 3D scenes from GLTF 2.0 files into the ECS + ResourceManager.

## Why This Matters

OBJ files contain: vertices, normals, UVs, faces.

GLTF files contain:
- Node hierarchy (transforms, parenting)
- Meshes (with multiple primitives)
- Materials (PBR: metallic/roughness, normal maps, emissive)
- Textures (with samplers)
- Animations (skins, morph targets)
- Cameras, lights
- Scene graph structure

GLTF is the industry standard. Supporting it proves the engine can handle real assets.

## Deliverables

1. `Graphics.Haskan.Scene.GLTF` — parser + importer
2. `Graphics.Haskan.Render.Material.PBR` — PBR material type
3. Updated `ResourceManager` — material loading
4. Updated `Engine.hs` — load GLTF scene at startup

## Design

### GLTF Import Pipeline

```haskell
data GLTFImportResult = GLTFImportResult
  { girWorld       :: !World          -- ECS entities
  , girMeshes      :: ![MeshHandle]   -- loaded meshes
  , girTextures    :: ![TextureHandle]-- loaded textures
  , girMaterials   :: ![MaterialHandle]-- loaded materials
  , girDefaultScene:: !EntityId      -- root entity of default scene
  }

importGLTF :: ResourceManager -> FilePath -> IO GLTFImportResult
importGLTF rm path = do
  gltf <- parseGLTF path
  -- 1. Load textures
  -- 2. Load materials (referencing textures)
  -- 3. Load meshes (referencing materials)
  -- 4. Create ECS entities from nodes
  -- 5. Set up hierarchy
  ...
```

### GLTF to ECS Mapping

| GLTF Concept | Engine Concept |
|-------------|----------------|
| `scene` | Root entity + children |
| `node` | Entity with Transform + optional Mesh/Material |
| `node.children` | Parent component in ECS |
| `node.matrix` / `node.translation+rotation+scale` | Transform component |
| `mesh.primitives` | MeshHandle (engine merges primitives) |
| `material` | MaterialHandle |
| `texture` | TextureHandle |
| `sampler` | VkSampler configuration |
| `skin` | Skin component (future: animation milestone) |
| `animation` | Animation component (future) |

### PBR Material

```haskell
data PBRMaterial = PBRMaterial
  { pbrBaseColorFactor     :: !(V4 Float)
  , pbrBaseColorTexture    :: !(Maybe TextureHandle)
  , pbrMetallicFactor      :: !Float
  , pbrRoughnessFactor     :: !Float
  , pbrMetallicRoughnessTexture :: !(Maybe TextureHandle)
  , pbrNormalTexture       :: !(Maybe TextureHandle)
  , pbrNormalScale         :: !Float
  , pbrEmissiveFactor      :: !(V3 Float)
  , pbrEmissiveTexture     :: !(Maybe TextureHandle)
  }
```

### Material System Extension

Current material is hardcoded texture + uniform buffer. Extend to support PBR:

```haskell
data Material
  = MaterialBasic BasicMaterial    -- current: diffuse texture
  | MaterialPBR PBRMaterial        -- new: full PBR
```

Each material variant has its own shader program. The `MaterialHandle` resolves to the variant + pipeline.

## Tasks

### Task 5.1: GLTF Parser (reuse gltf-codec)
**File:** `src/Graphics/Haskan/Scene/GLTF.hs`

The project already has `gltf-codec` as a dependency (via submodule). Use it to parse GLTF JSON + binary.

```haskell
import qualified Codec.GLTF as GLTF

parseGLTF :: FilePath -> IO GLTF.GLTF
parseGLTF path = ...
```

**Acceptance:** Can parse a simple GLTF file (e.g., Box.gltf from Khronos samples).

### Task 5.2: Texture Loading from GLTF
**File:** `src/Graphics/Haskan/Scene/GLTF.hs`

GLTF textures reference images (PNG/JPEG) and samplers (wrap modes, filters).

```haskell
loadGLTFTextures :: ResourceManager -> GLTF.GLTF -> IO (HashMap Int TextureHandle)
loadGLTFTextures rm gltf = do
  for (zip [0..] (GLTF.textures gltf)) $ \(i, tex) -> do
    let imagePath = ... -- resolve image URI
        sampler   = GLTF.samplers gltf !! fromIntegral (GLTF.sampler tex)
    handle <- loadTexture rm imagePath
    -- configure sampler from GLTF sampler settings
    pure (i, handle)
```

**Acceptance:** GLTF textures load and display correctly.

### Task 5.3: Material Loading from GLTF
**File:** `src/Graphics/Haskan/Scene/GLTF.hs`

Convert GLTF materials to `PBRMaterial`:

```haskell
loadGLTFMaterials :: ResourceManager
                  -> GLTF.GLTF
                  -> HashMap Int TextureHandle
                  -> IO (HashMap Int MaterialHandle)
```

**Acceptance:** Material properties match GLTF spec (metallic/roughness workflow).

### Task 5.4: Mesh Loading from GLTF
**File:** `src/Graphics/Haskan/Scene/GLTF.hs`

GLTF meshes have multiple primitives (each with its own material). For simplicity, merge primitives into one mesh or create one entity per primitive.

```haskell
loadGLTFMeshes :: ResourceManager
               -> GLTF.GLTF
               -> HashMap Int MaterialHandle
               -> IO (HashMap Int MeshHandle)
```

**Acceptance:** Meshes load with correct vertex data and index buffers.

### Task 5.5: Node Hierarchy → ECS
**File:** `src/Graphics/Haskan/Scene/GLTF.hs`

Traverse GLTF node tree, create ECS entities:

```haskell
buildSceneGraph :: World
                -> GLTF.GLTF
                -> HashMap Int MeshHandle
                -> HashMap Int MaterialHandle
                -> IO EntityId
buildSceneGraph world gltf meshes materials = do
  let scene = GLTF.scenes gltf !! fromIntegral (fromMaybe 0 (GLTF.scene gltf))
  -- for each node in scene.nodes:
  --   create entity
  --   set transform from node.matrix or TRS
  --   if node.mesh, set mesh + material components
  --   recursively process children
  ...
```

**Acceptance:** GLTF scene renders with correct transforms and materials.

### Task 5.6: PBR Shader (FIR)
**File:** `src/Graphics/Haskan/Shaders/PBR.hs`

Write FIR shaders for PBR metallic/roughness workflow:
- Vertex: standard transform + pass TBN matrix
- Fragment: sample albedo, metallic, roughness, normal maps; compute Cook-Torrance BRDF

**Acceptance:** PBR materials look correct under point lights.

## Testing

```haskell
-- Load Khronos sample: Box.gltf, BoxTextured.gltf, Duck.gltf
result <- importGLTF rm "data/gltf/Duck.gltf"

-- Duck should appear with correct texture, position, scale
-- RenderDoc: verify textures bound, PBR uniforms set
```

## Risks

| Risk | Mitigation |
|------|-----------|
| GLTF binary (GLB) format | `gltf-codec` supports both JSON + GLB; test both |
| Draco compression | Not supported by `gltf-codec`; skip Draco files for now |
| Multiple UV sets | Engine currently uses UV0 only; document limitation |
| Complex node hierarchies | Test with `AnimatedMorphCube`, `SimpleSkin` from Khronos |

## Success Criteria

- [ ] Can load Box.gltf (geometry only)
- [ ] Can load BoxTextured.gltf (geometry + texture)
- [ ] Can load Duck.gltf (full PBR material)
- [ ] Node hierarchy renders with correct transforms
- [ ] Materials use PBR workflow (metallic/roughness)
- [ ] Engine no longer hardcodes mesh/texture paths
