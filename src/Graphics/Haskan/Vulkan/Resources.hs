{-# LANGUAGE DeriveGeneric #-}

module Graphics.Haskan.Vulkan.Resources
  ( -- Handle types
    BufferHandle (..),
    MeshHandle (..),
    TextureHandle (..),
    -- Resource types
    BufferResource (..),
    MeshResource (..),
    TextureResource (..),
    -- ResourceManager
    ResourceManager,
    newResourceManager,
    allocHandle,
    -- ResourceManager fields (for internal use)
    rmNextId,
    rmBuffers,
    rmMeshes,
    rmTextures,
    -- Registration
    registerBuffer,
    registerMesh,
    registerTexture,
    -- Lookup
    lookupBuffer,
    lookupMesh,
    lookupTexture,
    updateMesh,
    -- Destruction
    destroyBuffer,
    destroyMesh,
    destroyTexture,
    destroyAllResources,
  )
where

import Control.Concurrent.STM (TVar)
import Control.Concurrent.STM qualified as STM
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Foldable (for_)
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HashMap
import Data.Hashable (Hashable)
import Data.Int (Int32)
import Data.Vector.Storable (Vector)
import Data.Word (Word32, Word64, Word8)
import GHC.Generics (Generic)
import Graphics.Haskan.BoundingBox (BBox)
import Graphics.Haskan.Vertex (Vertex)
import Vulkan qualified

-- | Opaque handle for buffer resources.
newtype BufferHandle = BufferHandle {unBufferHandle :: Word64}
  deriving (Eq, Ord, Show, Generic)

instance Hashable BufferHandle

-- | Opaque handle for mesh resources.
newtype MeshHandle = MeshHandle {unMeshHandle :: Word64}
  deriving (Eq, Ord, Show, Generic)

instance Hashable MeshHandle

-- | Opaque handle for texture resources.
newtype TextureHandle = TextureHandle {unTextureHandle :: Word64}
  deriving (Eq, Ord, Show, Generic)

instance Hashable TextureHandle

-- | GPU buffer with embedded cleanup.
data BufferResource = BufferResource
  { brVkBuffer :: !Vulkan.Buffer,
    brMemory :: !Vulkan.DeviceMemory,
    brSize :: !Word64,
    brDestroy :: !(IO ())
  }

-- | Mesh composed of vertex and index buffers.
data MeshResource = MeshResource
  { mrHandle :: !MeshHandle,
    mrVertexBuffer :: !BufferResource,
    mrIndexBuffer :: !BufferResource,
    mrIndexCount :: !Int,
    mrFirstIndex :: !Word32,
    mrVertexOffset :: !Int32,
    mrBounds :: !BBox,
    mrVertices :: ![Vertex],
    mrIndices :: ![Word32]
  }

-- | Texture with image, view, memory, and cleanup action.
data TextureResource = TextureResource
  { trHandle :: !TextureHandle,
    trImage :: !Vulkan.Image,
    trImageView :: !Vulkan.ImageView,
    trMemory :: !Vulkan.DeviceMemory,
    trWidth :: !Int,
    trHeight :: !Int,
    trPixelData :: !(Maybe (Data.Vector.Storable.Vector Word8)),
    trDestroy :: !(IO ())
  }

-- | Central registry for all GPU resources.
data ResourceManager = ResourceManager
  { rmNextId :: !(TVar Word64),
    rmBuffers :: !(TVar (HashMap BufferHandle BufferResource)),
    rmMeshes :: !(TVar (HashMap MeshHandle MeshResource)),
    rmTextures :: !(TVar (HashMap TextureHandle TextureResource))
  }

newResourceManager :: (MonadIO m) => m ResourceManager
newResourceManager = liftIO $ do
  ResourceManager
    <$> STM.newTVarIO 0
    <*> STM.newTVarIO HashMap.empty
    <*> STM.newTVarIO HashMap.empty
    <*> STM.newTVarIO HashMap.empty

allocHandle :: (MonadIO m) => TVar Word64 -> m Word64
allocHandle ref = liftIO $ STM.atomically $ do
  h <- STM.readTVar ref
  STM.writeTVar ref (h + 1)
  pure h

-- | Register a buffer resource and return its handle.
registerBuffer :: (MonadIO m) => ResourceManager -> BufferResource -> m BufferHandle
registerBuffer rm resource = do
  handle <- BufferHandle <$> allocHandle (rmNextId rm)
  liftIO $ STM.atomically $ STM.modifyTVar' (rmBuffers rm) (HashMap.insert handle resource)
  pure handle

-- | Register a mesh resource and return its handle.
registerMesh :: (MonadIO m) => ResourceManager -> MeshResource -> m MeshHandle
registerMesh rm resource = do
  let handle = mrHandle resource
  liftIO $ STM.atomically $ STM.modifyTVar' (rmMeshes rm) (HashMap.insert handle resource)
  pure handle

-- | Register a texture resource and return its handle.
registerTexture :: (MonadIO m) => ResourceManager -> TextureResource -> m TextureHandle
registerTexture rm resource = do
  let handle = trHandle resource
  liftIO $ STM.atomically $ STM.modifyTVar' (rmTextures rm) (HashMap.insert handle resource)
  pure handle

-- | Look up a buffer by handle.
lookupBuffer :: (MonadIO m) => ResourceManager -> BufferHandle -> m (Maybe BufferResource)
lookupBuffer rm handle = liftIO $ STM.atomically $ HashMap.lookup handle <$> STM.readTVar (rmBuffers rm)

-- | Look up a mesh by handle.
lookupMesh :: (MonadIO m) => ResourceManager -> MeshHandle -> m (Maybe MeshResource)
lookupMesh rm handle = liftIO $ STM.atomically $ HashMap.lookup handle <$> STM.readTVar (rmMeshes rm)

-- | Update an existing mesh resource in the registry.
updateMesh :: (MonadIO m) => ResourceManager -> MeshHandle -> MeshResource -> m ()
updateMesh rm handle resource =
  liftIO $ STM.atomically $ STM.modifyTVar' (rmMeshes rm) (HashMap.insert handle resource)

-- | Look up a texture by handle.
lookupTexture :: (MonadIO m) => ResourceManager -> TextureHandle -> m (Maybe TextureResource)
lookupTexture rm handle = liftIO $ STM.atomically $ HashMap.lookup handle <$> STM.readTVar (rmTextures rm)

-- | Destroy a buffer resource and remove it from the registry.
destroyBuffer :: (MonadIO m) => ResourceManager -> BufferHandle -> m ()
destroyBuffer rm handle = liftIO $ do
  mResource <- STM.atomically $ do
    mRes <- HashMap.lookup handle <$> STM.readTVar (rmBuffers rm)
    STM.modifyTVar' (rmBuffers rm) (HashMap.delete handle)
    pure mRes
  for_ mResource brDestroy

-- | Destroy a mesh resource (including its buffers) and remove it from the registry.
destroyMesh :: (MonadIO m) => ResourceManager -> MeshHandle -> m ()
destroyMesh rm handle = liftIO $ do
  mResource <- STM.atomically $ do
    mRes <- HashMap.lookup handle <$> STM.readTVar (rmMeshes rm)
    STM.modifyTVar' (rmMeshes rm) (HashMap.delete handle)
    pure mRes
  for_ mResource $ \mesh -> do
    brDestroy (mrVertexBuffer mesh)
    brDestroy (mrIndexBuffer mesh)

-- | Destroy a texture resource and remove it from the registry.
destroyTexture :: (MonadIO m) => ResourceManager -> TextureHandle -> m ()
destroyTexture rm handle = liftIO $ do
  mResource <- STM.atomically $ do
    mRes <- HashMap.lookup handle <$> STM.readTVar (rmTextures rm)
    STM.modifyTVar' (rmTextures rm) (HashMap.delete handle)
    pure mRes
  for_ mResource trDestroy

-- | Destroy all resources in the manager and clear all registries.
destroyAllResources :: (MonadIO m) => ResourceManager -> m ()
destroyAllResources rm = liftIO $ do
  meshes <- STM.atomically $ STM.readTVar (rmMeshes rm)
  for_ meshes $ \mesh -> do
    brDestroy (mrVertexBuffer mesh)
    brDestroy (mrIndexBuffer mesh)

  textures <- STM.atomically $ STM.readTVar (rmTextures rm)
  for_ textures trDestroy

  buffers <- STM.atomically $ STM.readTVar (rmBuffers rm)
  for_ buffers brDestroy

  STM.atomically $ do
    STM.writeTVar (rmMeshes rm) HashMap.empty
    STM.writeTVar (rmTextures rm) HashMap.empty
    STM.writeTVar (rmBuffers rm) HashMap.empty
    STM.writeTVar (rmNextId rm) 0
