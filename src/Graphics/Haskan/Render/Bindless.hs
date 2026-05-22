module Graphics.Haskan.Render.Bindless
  ( BindlessSet (..),
    createBindlessSet,
    registerTexture,
  )
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Word (Word32)
import Graphics.Haskan.Logger (LogCategory (..), logInfoIO, showT)
import Graphics.Haskan.Resources (allocaAndPeek)
import qualified Graphics.Haskan.Vulkan.DescriptorPool as DescriptorPool
import Graphics.Haskan.Vulkan.DescriptorSet (updateBindlessTexture)
import qualified Graphics.Haskan.Vulkan.DescriptorSetLayout as DescriptorSetLayout
import qualified Graphics.Vulkan as Vulkan
import qualified Graphics.Vulkan.Core_1_0 as VulkanCore
import Graphics.Vulkan.Marshal.Create (createVk, set, setListRef, (&*))

-- | Handle to a bindless texture descriptor set.
data BindlessSet = BindlessSet
  { bsDescriptorSet :: !Vulkan.VkDescriptorSet,
    bsSampler :: !Vulkan.VkSampler,
    bsNextIndex :: !(IORef Word32),
    bsMaxTextures :: !Word32
  }

createBindlessSet ::
  (MonadIO m, MonadManaged m) =>
  Vulkan.VkDevice ->
  Vulkan.VkSampler ->
  m BindlessSet
createBindlessSet dev sampler = do
  layout <- DescriptorSetLayout.managedBindlessDescriptorSetLayout dev
  pool <- DescriptorPool.managedBindlessDescriptorPool dev DescriptorSetLayout.maxBindlessTextures
  ds <- allocateDescriptorSet dev pool [layout]
  idxRef <- liftIO $ newIORef 0
  logInfoIO LogRender $ "Bindless set created with " <> showT DescriptorSetLayout.maxBindlessTextures <> " slots"
  pure
    BindlessSet
      { bsDescriptorSet = ds,
        bsSampler = sampler,
        bsNextIndex = idxRef,
        bsMaxTextures = fromIntegral DescriptorSetLayout.maxBindlessTextures
      }

registerTexture ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  BindlessSet ->
  Vulkan.VkImageView ->
  m (Maybe Word32)
registerTexture dev bindlessSet textureView = do
  nextIdx <- liftIO $ readIORef (bsNextIndex bindlessSet)
  if nextIdx >= bsMaxTextures bindlessSet
    then do
      logInfoIO LogRender "Bindless texture array full, cannot register more textures"
      pure Nothing
    else do
      updateBindlessTexture
        dev
        (bsDescriptorSet bindlessSet)
        (bsSampler bindlessSet)
        textureView
        nextIdx
      liftIO $ modifyIORef' (bsNextIndex bindlessSet) (+ 1)
      logInfoIO LogRender $ "Registered texture at bindless index " <> showT nextIdx
      pure (Just nextIdx)

-- Internal: allocate a descriptor set from pool + layout
allocateDescriptorSet ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkDescriptorPool ->
  [Vulkan.VkDescriptorSetLayout] ->
  m Vulkan.VkDescriptorSet
allocateDescriptorSet dev descriptorPool setLayouts = do
  let allocateInfo =
        createVk
          ( set @"sType" VulkanCore.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"descriptorPool" descriptorPool
              &* set @"descriptorSetCount" (fromIntegral (length setLayouts))
              &* setListRef @"pSetLayouts" setLayouts
          )
   in liftIO $
        Vulkan.withPtr
          allocateInfo
          (allocaAndPeek . VulkanCore.vkAllocateDescriptorSets dev)
