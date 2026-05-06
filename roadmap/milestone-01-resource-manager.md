# Milestone 1: Resource Manager

## Goal
Replace scope-based `MonadManaged` resource allocation with an explicit registry that supports runtime load/unload by handle.

## Why This Matters First

Every subsequent milestone depends on resources. If resources are tied to `runManaged` scopes:
- **ECS** can't reference meshes by handle — they're raw `VkBuffer` values
- **Render Graph** can't rebuild without reloading all resources
- **GLTF** loading requires destroying the render loop to free old scenes

## Deliverables

1. `Graphics.Haskan.Vulkan.Resources` — handle types + registry
2. `Graphics.Haskan.Vulkan.Buffer` — `createVertexBuffer`/`createIndexBuffer` returning handles
3. `Graphics.Haskan.Vulkan.Texture` — `createTexture` returning handle
4. `Graphics.Haskan.Vulkan.Memory` — allocator abstraction (dedicated for now)
5. Updated `Engine.hs` — uses `ResourceManager` instead of `managed*` inside `renderLoop`

## Design

### Handle Types

```haskell
newtype BufferHandle  = BufferHandle { unBufferHandle :: Word64 }
  deriving (Eq, Ord, Show, Hashable)

newtype ImageHandle   = ImageHandle { unImageHandle :: Word64 }
  deriving (Eq, Ord, Show, Hashable)

newtype MeshHandle    = MeshHandle { unMeshHandle :: Word64 }
  deriving (Eq, Ord, Show, Hashable)

newtype TextureHandle = TextureHandle { unTextureHandle :: Word64 }
  deriving (Eq, Ord, Show, Hashable)
```

### Resource Types

```haskell
data BufferResource = BufferResource
  { brHandle       :: !BufferHandle
  , brVkBuffer     :: !VkBuffer
  , brMemory       :: !VkDeviceMemory
  , brSize         :: !Word64
  , brDestroy      :: !(IO ())  -- calls vkDestroyBuffer + vkFreeMemory
  }

data MeshResource = MeshResource
  { mrHandle       :: !MeshHandle
  , mrVertexBuffer :: !BufferResource
  , mrIndexBuffer  :: !BufferResource
  , mrIndexCount   :: !Int
  }

data TextureResource = TextureResource
  { trHandle       :: !TextureHandle
  , trImage        :: !VkImage
  , trImageView    :: !VkImageView
  , trMemory       :: !VkDeviceMemory
  , trSampler      :: !(Maybe VkSampler)  -- separate from image
  , trDestroy      :: !(IO ())
  }
```

### ResourceManager

```haskell
data ResourceManager = ResourceManager
  { rmDevice        :: !VkDevice
  , rmPhysicalDevice:: !VkPhysicalDevice
  , rmNextId        :: !(TVar Word64)
  , rmBuffers       :: !(TVar (HashMap BufferHandle BufferResource))
  , rmMeshes        :: !(TVar (HashMap MeshHandle MeshResource))
  , rmTextures      :: !(TVar (HashMap TextureHandle TextureResource))
  }

createResourceManager :: VkDevice -> VkPhysicalDevice -> IO ResourceManager

loadMesh :: ResourceManager -> FilePath -> IO MeshHandle
unloadMesh :: ResourceManager -> MeshHandle -> IO ()
getMesh :: ResourceManager -> MeshHandle -> IO (Maybe MeshResource)

loadTexture :: ResourceManager -> FilePath -> IO TextureHandle
unloadTexture :: ResourceManager -> TextureHandle -> IO ()
getTexture :: ResourceManager -> TextureHandle -> IO (Maybe TextureResource)
```

### Reference Counting (Optional Phase 1.5)

For shared textures (multiple meshes using the same texture):

```haskell
data Resource a = Resource
  { resHandle  :: !a
  , resRefCount:: !(TVar Int)
  , resDestroy :: !(IO ())
  }

acquire :: Resource a -> IO ()  -- increment ref
release :: Resource a -> IO ()  -- decrement ref, destroy if 0
```

## Tasks

### Task 1.1: Define Handle + Resource Types
**File:** `src/Graphics/Haskan/Vulkan/Resources.hs`

Create newtypes for handles and record types for resources. Include destroy actions.

**Acceptance:** Types compile, no Vulkan-specific logic yet.

### Task 1.2: Extract Buffer Creation from MonadManaged
**File:** `src/Graphics/Haskan/Vulkan/Buffer.hs`

Add `createVertexBuffer` and `createIndexBuffer` that:
1. Create `VkBuffer`
2. Allocate `VkDeviceMemory`
3. Bind memory
4. Copy vertex/index data
5. Return `BufferResource` with destroy action

Keep existing `managedVertexBuffer`/`managedIndexBuffer` as wrappers:
```haskell
managedVertexBuffer pdev dev vertices = do
  res <- liftIO $ createVertexBuffer pdev dev vertices
  alloc_ "vertex buffer" (pure $ brVkBuffer res) (brDestroy res)
```

**Acceptance:** Old code still compiles, new functions tested in REPL.

### Task 1.3: Extract Texture Creation
**File:** `src/Graphics/Haskan/Vulkan/Texture.hs`

Add `createTexture` returning `TextureResource`. Same pattern as buffers.

**Acceptance:** Texture loads and displays correctly.

### Task 1.4: Build ResourceManager Registry
**File:** `src/Graphics/Haskan/Vulkan/Resources.hs`

Implement `ResourceManager` with `loadMesh`, `unloadMesh`, `getMesh`, etc.

The registry is a `HashMap` in a `TVar` for thread-safe access.

**Acceptance:** Can load 2 meshes, render one, unload the other, reload.

### Task 1.5: Update Engine.hs
**File:** `src/Graphics/Haskan/Engine.hs`

Replace `renderLoop` resource creation:
```haskell
-- OLD (inside runManaged):
vertexBuffer <- managedVertexBuffer pdev dev vertices

-- NEW (ResourceManager created outside):
vertexBuffer <- getMeshBuffer rm meshHandle
```

ResourceManager is created in `mainLoop` and passed to `renderLoop`.

**Acceptance:** Engine still renders single mesh. No behavior change.

## Testing

```haskell
-- In REPL:
rm <- createResourceManager dev pdev
h1 <- loadMesh rm "cube.obj"
h2 <- loadMesh rm "torus.obj"
Just m1 <- getMesh rm h1
Just m2 <- getMesh rm h2
-- render both
unloadMesh rm h1
-- h1 no longer valid, h2 still works
```

## Risks

| Risk | Mitigation |
|------|-----------|
| Destroy order wrong (free memory before buffer) | `brDestroy` uses `bracket` internally |
| Thread-safety on registry | Use `STM` or `MVar` for registry updates |
| Memory leak if unload forgotten | Add `withMesh` bracket wrapper, finalizer on `ResourceManager` cleanup |

## Success Criteria

- [ ] Load/unload mesh at runtime without restart
- [ ] Load/unload texture at runtime
- [ ] Multiple meshes can coexist in registry
- [ ] Destroy actions called in correct order (buffer → memory)
- [ ] No memory leaks (verify with `vkDeviceWaitIdle` + validation layers)
