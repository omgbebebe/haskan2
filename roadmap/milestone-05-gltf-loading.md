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

### Task 5.1: GLTF Parser (reuse gltf-loader)
**File:** `src/Graphics/Haskan/Scene/GLTF.hs`

The project uses `gltf-loader-0.3.0.0` (patched fork via `cabal.project`). Loads GLTF JSON + binary via `GLTF.fromJsonByteString`.

**Status:** Complete. `gltf-loader` parses JSON and binary data. JSON pre-processing fixes missing image mime types (`fixImageMimeTypes`).

### Task 5.2: Texture Loading from GLTF
**File:** `src/Graphics/Haskan/Scene/GLTF.hs`

GLTF textures reference images (PNG/JPEG) and samplers (wrap modes, filters).

**Status:** Complete. `loadTextures` loads all images as Vulkan textures via `Texture.createTextureFromBytesCached` (uses asset cache). Handles embedded image data (base64 or buffer view). Fallback to grid texture if no image data.

### Task 5.3: Material Loading from GLTF
**File:** `src/Graphics/Haskan/Scene/GLTF.hs`

Convert GLTF materials to texture handles:

**Status:** Complete. `buildMaterialTextures` resolves `baseColorTexture` → texture → image → `TextureHandle`. Returns `[Maybe TextureHandle]` indexed by material index.

### Task 5.4: Mesh Loading from GLTF
**File:** `src/Graphics/Haskan/Scene/GLTF.hs`

GLTF meshes have multiple primitives (each with its own material). For simplicity, merge primitives into one mesh or create one entity per primitive.

**Status:** Complete. All primitives merged into single mesh per glTF mesh with index offsets. `loadMesh` accumulates vertices and indices with primitive offsetting. Supports multi-primitive meshes. `mrBounds` computed from vertices for scene bounds.

### Task 5.5: Node Hierarchy → ECS
**File:** `src/Graphics/Haskan/Scene/GLTF.hs`

Traverse GLTF node tree, create ECS entities:

**Status:** Complete. `buildSceneGraph` traverses nodes recursively. Creates entity per node. Sets transform from TRS (translation, rotation, scale). Sets mesh + material components. Parent-child hierarchy via `setParent`. Root entity returned.

### Task 5.6: PBR Shader (FIR)
**File:** `src/Graphics/Haskan/Shaders/PBR.hs`

Write FIR shaders for PBR metallic/roughness workflow.

**Status:** Deferred. Current g-buffer fragment shader uses simple diffuse + texture sampling. Full PBR BRDF deferred to Milestone 7/8 when material system is refactored for bindless descriptors.

## Testing

```haskell
-- Load Khronos sample: Avocado.gltf
result <- importGLTF rm physicalDevice device queue cmdBuf cache "glTF-Sample-Assets/Models/Avocado/glTF/Avocado.gltf"

-- Avocado should appear with correct texture, position, scale
-- RenderDoc: verify textures bound, g-buffer attachments populated
```

## Success Criteria

- [x] Can load Box.gltf (geometry only)
- [x] Can load BoxTextured.gltf (geometry + texture)
- [x] Can load Duck.gltf (full material with texture)
- [x] Can load Avocado.gltf (multi-primitive, multiple textures)
- [x] Node hierarchy renders with correct transforms
- [x] Materials use texture mapping (baseColorTexture)
- [x] Engine no longer hardcodes mesh/texture paths (supports both OBJ and GLTF via CLI)
- [ ] PBR workflow (metallic/roughness) — deferred
