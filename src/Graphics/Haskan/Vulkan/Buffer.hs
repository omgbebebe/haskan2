{-# LANGUAGE DuplicateRecordFields #-}

module Graphics.Haskan.Vulkan.Buffer where

import Control.Monad (unless)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Bits ((.|.))
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HashMap
import Data.Int (Int32)
import Data.List (foldl')
import Data.Maybe (catMaybes)
import Data.Vector qualified as Vector
import Data.Word (Word32)
import Foreign qualified
import Foreign.Marshal qualified
import Foreign.Storable (Storable, sizeOf)
import Graphics.Haskan.BoundingBox (BBox, fromPoints)
import Graphics.Haskan.Logger (LogCategory (..), logDebugIO, showT)
import Graphics.Haskan.Resources (alloc)
import Graphics.Haskan.Vertex (Vertex (..), VertexIndex)
import Graphics.Haskan.Vulkan.Memory qualified as Memory
import Graphics.Haskan.Vulkan.Resources
import Vulkan qualified
import Vulkan.Core10 qualified
import Vulkan.Zero (zero)

managedBuffer ::
  (MonadManaged m, Storable a) =>
  Vulkan.Device ->
  [a] ->
  Vulkan.BufferUsageFlags ->
  m (Vulkan.Buffer, Vulkan.MemoryRequirements)
managedBuffer dev data' usage =
  alloc
    "Buffer"
    (createBuffer dev data' usage)
    (\(ptr, _) -> Vulkan.destroyBuffer dev ptr Nothing)

createBuffer ::
  (MonadIO m, Storable a) =>
  Vulkan.Device ->
  [a] ->
  Vulkan.BufferUsageFlags ->
  m (Vulkan.Buffer, Vulkan.MemoryRequirements)
createBuffer dev data' usage = do
  let bufSize = case data' of
        [] -> 0
        (x : _) -> fromIntegral (length data' * Foreign.sizeOf x)
      createInfo =
        Vulkan.BufferCreateInfo
          { next = (),
            flags = zero,
            size = bufSize,
            usage = usage,
            sharingMode = Vulkan.SHARING_MODE_EXCLUSIVE,
            queueFamilyIndices = Vector.empty
          }
  buffer <- liftIO $ Vulkan.createBuffer dev createInfo Nothing
  memoryRequirements <- liftIO $ Vulkan.getBufferMemoryRequirements dev buffer
  let Vulkan.MemoryRequirements {size = reqSize} = memoryRequirements
  logDebugIO LogBuffer $ "createBuffer size=" <> showT bufSize <> " memReqSize=" <> showT reqSize
  pure (buffer, memoryRequirements)

createBufferMemory ::
  (MonadIO m) =>
  Vulkan.PhysicalDevice ->
  Vulkan.Device ->
  Vulkan.MemoryRequirements ->
  m Vulkan.DeviceMemory
createBufferMemory pdev dev memoryRequirements = do
  let Vulkan.MemoryRequirements {size = reqSize} = memoryRequirements
  logDebugIO LogBuffer $ "createBufferMemory memReqSize=" <> showT reqSize
  Memory.allocateMemoryFor
    pdev
    dev
    memoryRequirements
    [ Vulkan.MEMORY_PROPERTY_HOST_VISIBLE_BIT,
      Vulkan.MEMORY_PROPERTY_HOST_COHERENT_BIT
    ]

managedBufferMemory pdev dev memoryRequirements = do
  let Vulkan.MemoryRequirements {size = reqSize} = memoryRequirements
  logDebugIO LogBuffer $ "managedBufferMemory memReqSize=" <> showT reqSize
  alloc
    "Buffer memory"
    (createBufferMemory pdev dev memoryRequirements)
    (\ptr -> Vulkan.freeMemory dev ptr Nothing)

bindBufferMemory ::
  (MonadIO m, Storable a) =>
  Vulkan.Device ->
  Vulkan.Buffer ->
  Vulkan.DeviceMemory ->
  [a] ->
  m ()
bindBufferMemory dev buffer memory data' = liftIO $ do
  logDebugIO LogBuffer $ "bindBufferMemory binding buffer, data size=" <> showT (length data')
  Vulkan.bindBufferMemory dev buffer memory 0
  logDebugIO LogBuffer "bindBufferMemory buffer bound, copying data"
  copyDataToDeviceMemory dev memory data'
  logDebugIO LogBuffer "bindBufferMemory data copied"

copyDataToDeviceMemory dev memory data' = liftIO $ do
  let size = case data' of
        [] -> 0
        (x : _) -> fromIntegral (length data' * Foreign.sizeOf x)
  logDebugIO LogBuffer $ "copyDataToDeviceMemory size=" <> showT size
  if size == 0
    then logDebugIO LogBuffer "copyDataToDeviceMemory skipping empty data"
    else do
      memPtr <- liftIO $ Vulkan.mapMemory dev memory 0 size zero
      Foreign.Marshal.pokeArray (Foreign.castPtr memPtr) data'
      Vulkan.unmapMemory dev memory
      logDebugIO LogBuffer "copyDataToDeviceMemory done"

managedVertexBuffer :: (MonadManaged m) => Vulkan.PhysicalDevice -> Vulkan.Device -> [Vertex] -> m Vulkan.Buffer
managedVertexBuffer pdev dev vertices = do
  (buffer, memoryRequirements) <- managedBuffer dev vertices Vulkan.BUFFER_USAGE_VERTEX_BUFFER_BIT
  memory <- managedBufferMemory pdev dev memoryRequirements
  bindBufferMemory dev buffer memory vertices
  pure buffer

managedIndexBuffer :: (MonadManaged m) => Vulkan.PhysicalDevice -> Vulkan.Device -> [VertexIndex] -> m Vulkan.Buffer
managedIndexBuffer pdev dev indices = do
  (buffer, memoryRequirements) <- managedBuffer dev indices Vulkan.BUFFER_USAGE_INDEX_BUFFER_BIT
  memory <- managedBufferMemory pdev dev memoryRequirements
  bindBufferMemory dev buffer memory indices
  pure buffer

managedStorageBuffer ::
  (MonadManaged m, Storable a) =>
  Vulkan.PhysicalDevice ->
  Vulkan.Device ->
  [a] ->
  Vulkan.BufferUsageFlags ->
  m (Vulkan.Buffer, Vulkan.DeviceMemory)
managedStorageBuffer pdev dev values extraUsage = do
  (buffer, memoryRequirements) <- managedBuffer dev values (Vulkan.BUFFER_USAGE_STORAGE_BUFFER_BIT .|. extraUsage)
  memory <- managedBufferMemory pdev dev memoryRequirements
  bindBufferMemory dev buffer memory values
  pure (buffer, memory)

updateStorageBuffer :: (MonadIO m, Storable a) => Vulkan.Device -> Vulkan.DeviceMemory -> Int -> [a] -> m ()
updateStorageBuffer = updateUniformBufferRegion

managedUniformBuffer ::
  (MonadManaged m, Storable a) =>
  Vulkan.PhysicalDevice ->
  Vulkan.Device ->
  [a] ->
  m (Vulkan.Buffer, Vulkan.DeviceMemory)
managedUniformBuffer pdev dev values = do
  (buffer, memoryRequirements) <- managedBuffer dev values Vulkan.BUFFER_USAGE_UNIFORM_BUFFER_BIT
  memory <- managedBufferMemory pdev dev memoryRequirements
  bindBufferMemory dev buffer memory values
  pure (buffer, memory)

updateUniformBuffer :: (MonadIO m, Storable a) => Vulkan.Device -> Vulkan.DeviceMemory -> [a] -> m ()
updateUniformBuffer dev memory uniformData = do
  let size = fromIntegral (sum (map Foreign.sizeOf uniformData))
  Control.Monad.unless (size == 0) $ do
    memPtr <- liftIO $ Vulkan.mapMemory dev memory 0 size zero
    liftIO $ do
      Foreign.pokeArray (Foreign.castPtr memPtr) uniformData
      Vulkan.unmapMemory dev memory

updateUniformBufferRegion :: (MonadIO m, Storable a) => Vulkan.Device -> Vulkan.DeviceMemory -> Int -> [a] -> m ()
updateUniformBufferRegion dev memory offset uniformData = do
  let size = fromIntegral (sum (map Foreign.sizeOf uniformData))
  Control.Monad.unless (size == 0) $ do
    memPtr <- liftIO $ Vulkan.mapMemory dev memory (fromIntegral offset) size zero
    liftIO $ do
      Foreign.pokeArray (Foreign.castPtr memPtr) uniformData
      Vulkan.unmapMemory dev memory

-- | Create a buffer resource with embedded cleanup (not registered in any manager).
makeBufferResource ::
  (MonadIO m, Storable a) =>
  Vulkan.PhysicalDevice ->
  Vulkan.Device ->
  [a] ->
  Vulkan.BufferUsageFlags ->
  m BufferResource
makeBufferResource pdev dev data' usage = do
  (buffer, memoryRequirements) <- createBuffer dev data' usage
  memory <- createBufferMemory pdev dev memoryRequirements
  liftIO $ bindBufferMemory dev buffer memory data'

  let bufSize = case data' of
        [] -> 0
        (x : _) -> fromIntegral (length data' * sizeOf x)
      destroy = do
        Vulkan.destroyBuffer dev buffer Nothing
        Vulkan.freeMemory dev memory Nothing

  pure
    BufferResource
      { brVkBuffer = buffer,
        brMemory = memory,
        brSize = bufSize,
        brDestroy = destroy
      }

-- | Create and register a mesh resource (vertex + index buffers).
createMeshResource ::
  (MonadIO m) =>
  ResourceManager ->
  Vulkan.PhysicalDevice ->
  Vulkan.Device ->
  [Vertex] ->
  [VertexIndex] ->
  m MeshHandle
createMeshResource rm pdev dev vertices indices = do
  vertBuf <- makeBufferResource pdev dev vertices Vulkan.BUFFER_USAGE_VERTEX_BUFFER_BIT
  idxBuf <- makeBufferResource pdev dev indices Vulkan.BUFFER_USAGE_INDEX_BUFFER_BIT

  meshH <- MeshHandle <$> allocHandle (rmNextId rm)

  let bounds = fromPoints (map (fmap realToFrac . vPos) vertices)
      mesh =
        MeshResource
          { mrHandle = meshH,
            mrVertexBuffer = vertBuf,
            mrIndexBuffer = idxBuf,
            mrIndexCount = length indices,
            mrFirstIndex = 0,
            mrVertexOffset = 0,
            mrBounds = bounds,
            mrVertices = vertices,
            mrIndices = indices
          }

  registerMesh rm mesh
  pure meshH

-- | Merge multiple mesh resources into single vertex and index buffers.
-- Returns the merged mesh resource (registered in RM) and a map from original MeshHandle to (firstIndex, vertexOffset).
mergeMeshes ::
  (MonadIO m) =>
  ResourceManager ->
  Vulkan.PhysicalDevice ->
  Vulkan.Device ->
  [MeshHandle] ->
  m (MeshResource, HashMap.HashMap MeshHandle (Word32, Int32))
mergeMeshes rm pdev dev meshHandles = do
  meshes <- catMaybes <$> mapM (lookupMesh rm) meshHandles
  let (allVertices, allIndices, offsets) = foldl' accumulate ([], [], HashMap.empty) meshes
        where
          accumulate (verts, idxs, offs) mesh =
            let voff = length verts
                ioff = length idxs
                newIdxs = map (+ fromIntegral voff) (mrIndices mesh)
                newOffs = HashMap.insert (mrHandle mesh) (fromIntegral ioff, fromIntegral voff) offs
             in (verts ++ mrVertices mesh, idxs ++ newIdxs, newOffs)

  vertBuf <- makeBufferResource pdev dev allVertices Vulkan.BUFFER_USAGE_VERTEX_BUFFER_BIT
  idxBuf <- makeBufferResource pdev dev allIndices Vulkan.BUFFER_USAGE_INDEX_BUFFER_BIT

  -- Create shared buffers with no-op destroy (managed by mergedMesh)
  let sharedVertBuf = vertBuf {brDestroy = pure ()}
      sharedIdxBuf = idxBuf {brDestroy = pure ()}

  let mergedHandle = MeshHandle 0 -- dummy handle
      mergedMesh =
        MeshResource
          { mrHandle = mergedHandle,
            mrVertexBuffer = vertBuf,
            mrIndexBuffer = idxBuf,
            mrIndexCount = length allIndices,
            mrFirstIndex = 0,
            mrVertexOffset = 0,
            mrBounds = fromPoints (map (fmap realToFrac . vPos) allVertices),
            mrVertices = allVertices,
            mrIndices = allIndices
          }

  -- Register merged mesh so its buffers get destroyed at shutdown
  _ <- registerMesh rm mergedMesh

  pure (mergedMesh, offsets)

-- | Resolve a mesh handle to its raw Vulkan buffers and index count.
meshBuffers ::
  (MonadIO m) =>
  ResourceManager ->
  MeshHandle ->
  m (Maybe (Vulkan.Buffer, Vulkan.Buffer, Int))
meshBuffers rm handle = do
  mMesh <- lookupMesh rm handle
  pure $ fmap (\mesh -> (brVkBuffer (mrVertexBuffer mesh), brVkBuffer (mrIndexBuffer mesh), mrIndexCount mesh)) mMesh
