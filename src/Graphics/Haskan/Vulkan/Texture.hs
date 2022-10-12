{-# language LambdaCase #-}
module Graphics.Haskan.Vulkan.Texture where

-- base
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Bits
import Data.Word (Word8)

-- juicypixels
import Codec.Picture

-- managed
import Control.Monad.Managed (MonadManaged)

-- vector
import qualified Data.Vector.Storable
import qualified Data.Vector.Storable as Vector

-- vulkan-api
import qualified Graphics.Vulkan as Vulkan
import qualified Graphics.Vulkan.Core_1_0 as Vulkan
import qualified Graphics.Vulkan.Marshal.Create as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create ((&*), set)

-- haskan
import qualified Graphics.Haskan.Vulkan.Buffer as Haskan
import qualified Graphics.Haskan.Vulkan.CommandBuffer as Haskan
import qualified Graphics.Haskan.Vulkan.ImageView as Haskan
import qualified Graphics.Haskan.Vulkan.Memory as Haskan
import Graphics.Haskan.Resources (alloc, allocaAndPeek, allocaAndPeek_, throwVkResult)

readImageFromFile
  :: (MonadFail m, MonadIO m)
  => FilePath
  -> m ((Data.Vector.Storable.Vector Word8), Int, Int)
readImageFromFile filePath = do
  image <- liftIO $ readImageWithMetadata filePath >>=
    \case
      Right (dynamicImage, imageMetadata) -> pure (convertRGBA8 dynamicImage)
      Left e -> fail e

  let (Image width height imageData) = image
  pure (imageData, width, height)

managedTexture
  :: (MonadFail m, MonadManaged m)
  => Vulkan.VkPhysicalDevice
  -> Vulkan.VkDevice
  -> FilePath -- Data.Vector.Storable.Vector Word8
  -> Vulkan.VkQueue
  -> Vulkan.VkCommandBuffer
  -> m Vulkan.VkImageView
managedTexture pdev dev filePath queue commandBuffer = do
  (imgData, width, height) <- liftIO (readImageFromFile filePath)
  let
    dataList = Vector.toList imgData

  (stagingBuffer, stagingMemoryRequirement) <-
    Haskan.managedBuffer dev dataList Vulkan.VK_BUFFER_USAGE_TRANSFER_SRC_BIT

  stagingMemory <-
    Haskan.managedBufferMemory pdev dev stagingMemoryRequirement

  liftIO $ do
    Haskan.bindBufferMemory dev stagingBuffer stagingMemory dataList
    Haskan.copyDataToDeviceMemory dev stagingMemory dataList

  let
    format = Vulkan.VK_FORMAT_R8G8B8A8_SRGB
    imageExtent = Vulkan.createVk
      (  set @"width" (fromIntegral width)
      &* set @"height" (fromIntegral height)
      &* set @"depth" 1
      )
    createInfo = Vulkan.createVk
      (  set @"sType" Vulkan.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
      &* set @"pNext" Vulkan.VK_NULL
      &* set @"imageType" Vulkan.VK_IMAGE_TYPE_2D
      &* set @"extent" imageExtent
      &* set @"mipLevels" 1
      &* set @"arrayLayers" 1
      &* set @"format" format
      &* set @"tiling" Vulkan.VK_IMAGE_TILING_OPTIMAL
      &* set @"initialLayout" Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
      &* set @"usage" (Vulkan.VK_IMAGE_USAGE_TRANSFER_DST_BIT .|. Vulkan.VK_IMAGE_USAGE_SAMPLED_BIT)
      &* set @"sharingMode" Vulkan.VK_SHARING_MODE_EXCLUSIVE
      &* set @"samples" Vulkan.VK_SAMPLE_COUNT_1_BIT
      &* set @"flags" Vulkan.VK_ZERO_FLAGS
      &* set @"queueFamilyIndexCount" 0
      &* set @"pQueueFamilyIndices" Vulkan.VK_NULL
      )

  image <- alloc "texture image"
    (withPtr createInfo (\ciPtr -> allocaAndPeek (Vulkan.vkCreateImage dev ciPtr Vulkan.vkNullPtr)))
    (\ptr -> Vulkan.vkDestroyImage dev ptr Vulkan.vkNullPtr)

  imageMemoryRequirements <- allocaAndPeek_
    (Vulkan.vkGetImageMemoryRequirements dev image)

  imageMemory <-
    Haskan.managedMemoryFor pdev dev imageMemoryRequirements [Vulkan.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT]

  bindImageMemory dev image imageMemory 0

  Haskan.withCommandBufferOneTime queue commandBuffer $ do
    Haskan.layerTransition
      commandBuffer
      image
      Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
      Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL

    Haskan.copyBufferToImage
      commandBuffer
      stagingBuffer
      image
      (fromIntegral width) (fromIntegral height)

    Haskan.layerTransition
      commandBuffer
      image
      Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
      Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL

  liftIO $ Vulkan.vkQueueWaitIdle queue >>= throwVkResult
  imageView <- Haskan.managedImageView dev format image
  pure imageView

bindImageMemory
  :: (MonadFail m, MonadIO m)
  => Vulkan.VkDevice
  -> Vulkan.VkImage
  -> Vulkan.VkDeviceMemory
  -> Vulkan.VkDeviceSize
  -> m ()
bindImageMemory dev image memory offset =
  liftIO (Vulkan.vkBindImageMemory dev image memory offset) >>= throwVkResult

managedSampler
  :: MonadManaged m
  => Vulkan.VkDevice
  -> m Vulkan.VkSampler
managedSampler dev = alloc "Sampler"
  (createSampler dev)
  (\ptr -> Vulkan.vkDestroySampler dev ptr Vulkan.vkNullPtr)

createSampler
  :: MonadIO m
  => Vulkan.VkDevice
  -> m Vulkan.VkSampler
createSampler dev =
  let
    createInfo = Vulkan.createVk
      (  set @"sType" Vulkan.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO
      &* set @"pNext" Vulkan.VK_NULL
      &* set @"magFilter" Vulkan.VK_FILTER_LINEAR
      &* set @"minFilter" Vulkan.VK_FILTER_LINEAR
      &* set @"addressModeU" Vulkan.VK_SAMPLER_ADDRESS_MODE_REPEAT
      &* set @"addressModeV" Vulkan.VK_SAMPLER_ADDRESS_MODE_REPEAT
      &* set @"addressModeW" Vulkan.VK_SAMPLER_ADDRESS_MODE_REPEAT
--      &* set @"anisotropyEnable" Vulkan.VK_TRUE
--      &* set @"maxAnisotropy" 16.0
      &* set @"anisotropyEnable" Vulkan.VK_FALSE
      &* set @"maxAnisotropy" 1.0
      &* set @"borderColor" Vulkan.VK_BORDER_COLOR_INT_OPAQUE_BLACK
      &* set @"unnormalizedCoordinates" Vulkan.VK_FALSE
      &* set @"compareEnable" Vulkan.VK_FALSE
      &* set @"compareOp" Vulkan.VK_COMPARE_OP_ALWAYS
      &* set @"mipmapMode" Vulkan.VK_SAMPLER_MIPMAP_MODE_LINEAR
      &* set @"mipLodBias" 0.0
      &* set @"minLod" 0.0
      &* set @"maxLod" 0.0
      )
  in liftIO $ withPtr createInfo (\ciPtr -> allocaAndPeek (Vulkan.vkCreateSampler dev ciPtr Vulkan.vkNullPtr))
