# Milestone 2: ECS Foundation

## Goal
Represent the game world as entities with components, replacing the hardcoded single-mesh render path.

## Why This Matters

Current code: `mainLoop meshName` loads one OBJ and passes it directly to render.

Target state: A `World` contains entities. Each entity may have:
- `Transform` (position, rotation, scale)
- `Mesh` (reference to `MeshHandle` in ResourceManager)
- `Material` (reference to `MaterialHandle`)
- `Visibility` (bool for culling)

This enables:
- Multiple objects in scene
- Instancing (same mesh, different transforms)
- GLTF node hierarchy
- Frustum culling

## Deliverables

1. `Graphics.Haskan.Scene.ECS` — `World`, `EntityId`, component storage
2. `Graphics.Haskan.Scene.Transform` — local/world matrix computation
3. `Graphics.Haskan.Render.RenderSystem` — extract visible entities, build draw list
4. Updated `Engine.hs` — create `World`, populate with entity, run systems

## Design

### EntityId

```haskell
newtype EntityId = EntityId { unEntityId :: Word32 }
  deriving (Eq, Ord, Show, Hashable)
```

### World

Archetype-based or sparse-set storage. For Haskell, **sparse sets** are simplest and cache-friendly:

```haskell
data World = World
  { wNextEntity    :: !(TVar EntityId)
  , wTransforms    :: !(TVar (IntMap Transform))     -- entityId → transform
  , wMeshes        :: !(TVar (IntMap MeshHandle))    -- entityId → mesh
  , wMaterials     :: !(TVar (IntMap MaterialHandle))-- entityId → material
  , wParents       :: !(TVar (IntMap EntityId))      -- entityId → parent
  }

-- IntMap indexed by (fromIntegral . unEntityId)
```

Alternative: **Archetype storage** (like Bevy, Flecs)
```haskell
data Archetype = Archetype
  { archEntities   :: !(Vector EntityId)
  , archTransforms :: !(Vector Transform)
  , archMeshes     :: !(Vector MeshHandle)
  }

data World = World
  { wArchetypes    :: !(TVar (HashMap ComponentMask Archetype))
  , wEntityLocations :: !(TVar (HashMap EntityId (ComponentMask, Int)))
  }
```

**Recommendation:** Start with sparse sets (`IntMap`). Migrate to archetypes only if profiling shows cache misses.

### Transform

```haskell
data Transform = Transform
  { tPosition :: !(V3 Float)
  , tRotation :: !(Quaternion Float)
  , tScale    :: !(V3 Float)
  }

defaultTransform :: Transform
defaultTransform = Transform (V3 0 0 0) (Quaternion 1 (V3 0 0 0)) (V3 1 1 1)

toMatrix :: Transform -> M44 Float
toMatrix Transform{..} =
  let scaleM     = scale (V4 tScale._x tScale._y tScale._z 1)
      rotationM  = fromQuaternion tRotation
      translateM = identity & translation .~ tPosition
   in translateM !*! rotationM !*! scaleM
```

### Systems

Systems are functions that read/write `World`:

```haskell
type System = World -> IO ()

updateTransforms :: System
updateTransforms world = do
  parents <- readTVarIO (wParents world)
  transforms <- readTVarIO (wTransforms world)
  -- compute world matrices from local + parent world
  let worldMatrices = computeWorldMatrices parents transforms
  -- store or compute on-demand
  pure ()

frustumCull :: Frustum -> System
frustumCull frustum world = do
  -- read transforms, meshes
  -- write visibility component
  pure ()
```

### RenderSystem

```haskell
extractDrawList :: World -> ResourceManager -> IO [(MeshResource, Transform, MaterialResource)]
extractDrawList world rm = do
  meshes <- readTVarIO (wMeshes world)
  transforms <- readTVarIO (wTransforms world)
  materials <- readTVarIO (wMaterials world)

  catMaybes <$> for (IntMap.toList meshes) \(eid, meshHandle) -> do
    let mTransform = IntMap.lookup (fromIntegral eid) transforms
        mMaterial  = IntMap.lookup (fromIntegral eid) materials
    mMeshRes     <- getMesh rm meshHandle
    mMatRes      <- case mMaterial of
                      Just h  -> getMaterial rm h
                      Nothing -> pure Nothing

    pure $ case (mMeshRes, mTransform, mMatRes) of
      (Just mesh, Just trans, Just mat) -> Just (mesh, trans, mat)
      _ -> Nothing
```

## Tasks

### Task 2.1: Define World + Component Types
**File:** `src/Graphics/Haskan/Scene/ECS.hs`

Create `EntityId`, `World`, component storage. Use `IntMap` for sparse sets.

**Status:** ✅ Complete. `World` with `TVar (IntMap Transform)`, `TVar (IntMap MeshHandle)`, `TVar (IntMap TextureHandle)`, `TVar (IntMap EntityId)` for parents.

### Task 2.2: Implement Transform + Hierarchy
**File:** `src/Graphics/Haskan/Scene/Transform.hs`

Local/world matrix computation. Parent-child hierarchy via `wParents`.

**Status:** ✅ Complete. `Transform` with position/rotation/scale. `toMatrix` computes SRT matrix. `computeWorldMatrices` handles parent hierarchy recursively.

### Task 2.3: Create RenderSystem
**File:** `src/Graphics/Haskan/Render/RenderSystem.hs`

Extract visible entities from `World`, resolve handles via `ResourceManager`, produce draw list.

**Status:** ✅ Complete. `extractDrawList` produces `[DrawCall]` with resolved `MeshResource` and world matrices.

### Task 2.4: Update Engine.hs
**File:** `src/Graphics/Haskan/Engine.hs`

Replace hardcoded mesh loading with ECS world creation.

**Status:** ✅ Complete. Engine spawns 3 entities, uses `extractDrawList`, updates per-entity uniform buffer regions dynamically.

### Task 2.5: Multiple Entities
Load 3 cubes at different positions. Verify all render.

**Status:** ✅ Complete. 3 cubes at `(-2,0,0)`, `(0,0,0)`, `(2,0,0)`. Shared mesh, individual transforms.

## Testing

```haskell
world <- createWorld
e1 <- spawnEntity world
setTransform world e1 (Transform (V3 0 0 0) identity (V3 1 1 1))
setMesh world e1 =<< loadMesh rm "cube.obj"

e2 <- spawnEntity world
setTransform world e2 (Transform (V3 2 0 0) identity (V3 1 1 1))
setMesh world e2 =<< loadMesh rm "cube.obj"  -- same mesh, different transform

drawList <- extractDrawList world rm
length drawList == 2
```

## Risks

| Risk | Mitigation |
|------|-----------|
| Cache misses with IntMap | Keep components in `Vector` for hot paths; use IntMap only for sparse data |
| Parent cycle in hierarchy | Validate on `setParent` — detect cycle, reject |
| World locked during render | Use `STM` for consistent snapshots, or copy draw list once per frame |

## Success Criteria

- [x] Can spawn multiple entities with mesh + transform
- [x] Entities render with correct world transforms
- [x] Parent-child hierarchy updates correctly
- [x] Render system extracts draw list from World
- [x] No hardcoded mesh references in `Engine.hs`

## Implementation Notes

**Completed 2026-05-07.** See commits:
- `bab4176` — milestone-02: ECS Foundation with multi-entity rendering
- `ea25c67` — add structured tracing logger and fix validation errors for ECS rendering
- `37259d2` — fix rendering: correct view matrix, front face winding, projection convention
- `cbd4bda` — fix matrix upload: transpose row-major for column-major Vulkan/GLSL

### Architecture Decisions
- **Sparse sets (`IntMap`)** chosen for component storage — simplest for Haskell, no module cycles
- **Dynamic UBO offsets** — one uniform buffer per frame-in-flight, per-entity data at `entityIdx * 256` byte offsets
- **Per-frame command buffer recording** — command buffers re-recorded each frame inside `renderImage`
- **Resource sharing** — all 3 entities share a single `MeshHandle`, different transforms
