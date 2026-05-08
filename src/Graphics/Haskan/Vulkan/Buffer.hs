module Graphics.Haskan.Vulkan.Buffer where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Bits ((.|.))
import Foreign qualified
import Foreign.Marshal qualified
import Foreign.Storable (Storable, sizeOf)
import Graphics.Haskan.Logger (logDebugIO, showT, LogCategory (..))
import Graphics.Haskan.Resources (alloc, allocaAndPeek, allocaAndPeek_, throwVkResult)
import Graphics.Haskan.BoundingBox (BBox, fromPoints)
import Graphics.Haskan.Vertex (Vertex (..), VertexIndex)
import Graphics.Haskan.Vulkan.Memory qualified as Memory
import Graphics.Haskan.Vulkan.Resources
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan

managedBuffer ::
  (MonadManaged m, Storable a) =>
  Vulkan.VkDevice ->
  [a] ->
  (Vulkan.VkBufferUsageBitmask Vulkan.FlagMask) ->
  m (Vulkan.VkBuffer, Vulkan.VkMemoryRequirements)
managedBuffer dev data' usage =
  alloc
    "Buffer"
    (createBuffer dev data' usage)
    (\(ptr, _) -> Vulkan.vkDestroyBuffer dev ptr Vulkan.vkNullPtr)

createBuffer ::
  (MonadIO m, Storable a) =>
  Vulkan.VkDevice ->
  [a] ->
  (Vulkan.VkBufferUsageBitmask Vulkan.FlagMask) ->
  m (Vulkan.VkBuffer, Vulkan.VkMemoryRequirements)
createBuffer dev data' usage = do
  let size = case data' of
               [] -> 0
               (x:_) -> fromIntegral (length data' * Foreign.sizeOf x)
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"usage" usage
              &* set @"size" size
              &* set @"sharingMode" Vulkan.VK_SHARING_MODE_EXCLUSIVE
              &* set @"queueFamilyIndexCount" 0
              &* set @"pQueueFamilyIndices" Vulkan.VK_NULL
          )
  buffer <- liftIO $ withPtr createInfo (\ciPtr -> allocaAndPeek (Vulkan.vkCreateBuffer dev ciPtr Vulkan.vkNullPtr))
  memoryRequirements <- allocaAndPeek_ (Vulkan.vkGetBufferMemoryRequirements dev buffer)
  logDebugIO LogBuffer $ "createBuffer size=" <> showT size <> " memReqSize=" <> showT (Vulkan.getField @"size" memoryRequirements)
  pure (buffer, memoryRequirements)

createBufferMemory ::
  (MonadIO m) =>
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  Vulkan.VkMemoryRequirements ->
  m Vulkan.VkDeviceMemory
createBufferMemory pdev dev memoryRequirements = do
  logDebugIO LogBuffer $ "createBufferMemory memReqSize=" <> showT (Vulkan.getField @"size" memoryRequirements)
  Memory.allocateMemoryFor
    pdev
    dev
    memoryRequirements
    [ Vulkan.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT,
      Vulkan.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT
    ]

managedBufferMemory pdev dev memoryRequirements = do
  logDebugIO LogBuffer $ "managedBufferMemory memReqSize=" <> showT (Vulkan.getField @"size" memoryRequirements)
  alloc
    "Buffer memory"
    (createBufferMemory pdev dev memoryRequirements)
    (\ptr -> Vulkan.vkFreeMemory dev ptr Vulkan.vkNullPtr)

bindBufferMemory ::
  (MonadIO m, Storable a) =>
  Vulkan.VkDevice ->
  Vulkan.VkBuffer ->
  Vulkan.VkDeviceMemory ->
  [a] ->
  m ()
bindBufferMemory dev buffer memory data' = liftIO $ do
  logDebugIO LogBuffer $ "bindBufferMemory binding buffer, data size=" <> showT (length data')
  Vulkan.vkBindBufferMemory dev buffer memory 0 {- offset-} >>= throwVkResult
  logDebugIO LogBuffer "bindBufferMemory buffer bound, copying data"
  copyDataToDeviceMemory dev memory data'
  logDebugIO LogBuffer "bindBufferMemory data copied"

copyDataToDeviceMemory dev memory data' = liftIO $ do
  let size = case data' of
               [] -> 0
               (x:_) -> fromIntegral (length data' * Foreign.sizeOf x)
  logDebugIO LogBuffer $ "copyDataToDeviceMemory size=" <> showT size
  memPtr <-
    allocaAndPeek (Vulkan.vkMapMemory dev memory 0 size Vulkan.VK_ZERO_FLAGS)
  Foreign.Marshal.pokeArray (Foreign.castPtr memPtr) data'
  Vulkan.vkUnmapMemory dev memory
  logDebugIO LogBuffer "copyDataToDeviceMemory done"

managedVertexBuffer :: (MonadManaged m) => Vulkan.VkPhysicalDevice -> Vulkan.VkDevice -> [Vertex] -> m Vulkan.VkBuffer
managedVertexBuffer pdev dev vertices = do
  (buffer, memoryRequirements) <- managedBuffer dev vertices Vulkan.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT
  memory <- managedBufferMemory pdev dev memoryRequirements
  bindBufferMemory dev buffer memory vertices
  pure buffer

managedIndexBuffer :: (MonadManaged m) => Vulkan.VkPhysicalDevice -> Vulkan.VkDevice -> [VertexIndex] -> m Vulkan.VkBuffer
managedIndexBuffer pdev dev indices = do
  (buffer, memoryRequirements) <- managedBuffer dev indices Vulkan.VK_BUFFER_USAGE_INDEX_BUFFER_BIT
  memory <- managedBufferMemory pdev dev memoryRequirements
  bindBufferMemory dev buffer memory indices
  pure buffer

managedStorageBuffer ::
  (MonadManaged m, Storable a) =>
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  [a] ->
  Vulkan.VkBufferUsageBitmask Vulkan.FlagMask ->
  m (Vulkan.VkBuffer, Vulkan.VkDeviceMemory)
managedStorageBuffer pdev dev values extraUsage = do
  (buffer, memoryRequirements) <- managedBuffer dev values (Vulkan.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT .|. extraUsage)
  memory <- managedBufferMemory pdev dev memoryRequirements
  bindBufferMemory dev buffer memory values
  pure (buffer, memory)

updateStorageBuffer :: (MonadIO m, Storable a) => Vulkan.VkDevice -> Vulkan.VkDeviceMemory -> Int -> [a] -> m ()
updateStorageBuffer = updateUniformBufferRegion

managedUniformBuffer ::
  (MonadManaged m, Storable a) =>
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  [a] ->
  m (Vulkan.VkBuffer, Vulkan.VkDeviceMemory)
managedUniformBuffer pdev dev values = do
  (buffer, memoryRequirements) <- managedBuffer dev values Vulkan.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT
  memory <- managedBufferMemory pdev dev memoryRequirements
  bindBufferMemory dev buffer memory values
  pure (buffer, memory)

updateUniformBuffer :: (MonadIO m, Storable a) => Vulkan.VkDevice -> Vulkan.VkDeviceMemory -> [a] -> m ()
updateUniformBuffer dev memory uniformData = do
  let size = fromIntegral (sum (map Foreign.sizeOf uniformData))
  memPtr <-
    allocaAndPeek (Vulkan.vkMapMemory dev memory 0 size Vulkan.VK_ZERO_FLAGS)
  liftIO $ do
    Foreign.pokeArray (Foreign.castPtr memPtr) uniformData
    Vulkan.vkUnmapMemory dev memory

updateUniformBufferRegion :: (MonadIO m, Storable a) => Vulkan.VkDevice -> Vulkan.VkDeviceMemory -> Int -> [a] -> m ()
updateUniformBufferRegion dev memory offset uniformData = do
  let size = fromIntegral (sum (map Foreign.sizeOf uniformData))
  memPtr <-
    allocaAndPeek (Vulkan.vkMapMemory dev memory (fromIntegral offset) size Vulkan.VK_ZERO_FLAGS)
  liftIO $ do
    Foreign.pokeArray (Foreign.castPtr memPtr) uniformData
    Vulkan.vkUnmapMemory dev memory

-- | Create a buffer resource with embedded cleanup (not registered in any manager).
makeBufferResource ::
  (MonadIO m, Storable a) =>
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  [a] ->
  Vulkan.VkBufferUsageBitmask Vulkan.FlagMask ->
  m BufferResource
makeBufferResource pdev dev data' usage = do
  (buffer, memoryRequirements) <- createBuffer dev data' usage
  memory <- createBufferMemory pdev dev memoryRequirements
  liftIO $ bindBufferMemory dev buffer memory data'

  let bufSize = case data' of
                  [] -> 0
                  (x:_) -> fromIntegral (length data' * sizeOf x)
      destroy = do
        Vulkan.vkDestroyBuffer dev buffer Vulkan.vkNullPtr
        Vulkan.vkFreeMemory dev memory Vulkan.vkNullPtr

  pure
    BufferResource
      { brVkBuffer = buffer
      , brMemory = memory
      , brSize = bufSize
      , brDestroy = destroy
      }

-- | Create and register a mesh resource (vertex + index buffers).
createMeshResource ::
  (MonadIO m) =>
  ResourceManager ->
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  [Vertex] ->
  [VertexIndex] ->
  m MeshHandle
createMeshResource rm pdev dev vertices indices = do
  vertBuf <- makeBufferResource pdev dev vertices Vulkan.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT
  idxBuf <- makeBufferResource pdev dev indices Vulkan.VK_BUFFER_USAGE_INDEX_BUFFER_BIT

  meshH <- MeshHandle <$> allocHandle (rmNextId rm)

  let bounds = fromPoints (map (fmap realToFrac . vPos) vertices)
      mesh =
        MeshResource
          { mrHandle = meshH
          , mrVertexBuffer = vertBuf
          , mrIndexBuffer = idxBuf
          , mrIndexCount = length indices
          , mrBounds = bounds
          }

  registerMesh rm mesh
  pure meshH

-- | Resolve a mesh handle to its raw Vulkan buffers and index count.
meshBuffers ::
  MonadIO m =>
  ResourceManager ->
  MeshHandle ->
  m (Maybe (Vulkan.VkBuffer, Vulkan.VkBuffer, Int))
meshBuffers rm handle = do
  mMesh <- lookupMesh rm handle
  pure $ fmap (\mesh -> (brVkBuffer (mrVertexBuffer mesh), brVkBuffer (mrIndexBuffer mesh), mrIndexCount mesh)) mMesh
