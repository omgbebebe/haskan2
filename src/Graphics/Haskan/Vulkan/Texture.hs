{-# LANGUAGE LambdaCase #-}

module Graphics.Haskan.Vulkan.Texture where
import Codec.Picture
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Bits
import Data.Vector.Storable qualified
import Data.Vector.Storable qualified as Vector
import Data.Word (Word8)
import Graphics.Haskan.Resources (alloc, allocaAndPeek, allocaAndPeek_, throwVkResult)
import Graphics.Haskan.Vulkan.Buffer qualified as Haskan
import Graphics.Haskan.Vulkan.CommandBuffer qualified as Haskan
import Graphics.Haskan.Vulkan.ImageView qualified as Haskan
import Graphics.Haskan.Vulkan.Memory qualified as Haskan
import Graphics.Haskan.Vulkan.Resources
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan

readImageFromFile ::
  (MonadFail m, MonadIO m) =>
  FilePath ->
  m ((Data.Vector.Storable.Vector Word8), Int, Int)
readImageFromFile filePath = do
  image <-
    liftIO $
      readImageWithMetadata filePath
        >>= \case
          Right (dynamicImage, imageMetadata) -> pure (convertRGBA8 dynamicImage)
          Left e -> fail e

  let (Image width height imageData) = image
  pure (imageData, width, height)

managedTexture ::
  (MonadFail m, MonadManaged m) =>
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  FilePath -> -- Data.Vector.Storable.Vector Word8
  Vulkan.VkQueue ->
  Vulkan.VkCommandBuffer ->
  m Vulkan.VkImageView
managedTexture pdev dev filePath queue commandBuffer = do
  (imgData, width, height) <- liftIO (readImageFromFile filePath)
  let dataList = Vector.toList imgData

  (stagingBuffer, stagingMemoryRequirement) <-
    Haskan.managedBuffer dev dataList Vulkan.VK_BUFFER_USAGE_TRANSFER_SRC_BIT

  stagingMemory <-
    Haskan.managedBufferMemory pdev dev stagingMemoryRequirement

  liftIO $ do
    Haskan.bindBufferMemory dev stagingBuffer stagingMemory dataList
    Haskan.copyDataToDeviceMemory dev stagingMemory dataList

  let format = Vulkan.VK_FORMAT_R8G8B8A8_SRGB
      imageExtent =
        Vulkan.createVk
          ( set @"width" (fromIntegral width)
              &* set @"height" (fromIntegral height)
              &* set @"depth" 1
          )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
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

  image <-
    alloc
      "texture image"
      (withPtr createInfo (\ciPtr -> allocaAndPeek (Vulkan.vkCreateImage dev ciPtr Vulkan.vkNullPtr)))
      (\ptr -> Vulkan.vkDestroyImage dev ptr Vulkan.vkNullPtr)

  imageMemoryRequirements <-
    allocaAndPeek_
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
      (fromIntegral width)
      (fromIntegral height)

    Haskan.layerTransition
      commandBuffer
      image
      Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
      Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL

  liftIO $ Vulkan.vkQueueWaitIdle queue >>= throwVkResult
  imageView <- Haskan.managedImageView dev format image
  pure imageView

bindImageMemory ::
  (MonadFail m, MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkImage ->
  Vulkan.VkDeviceMemory ->
  Vulkan.VkDeviceSize ->
  m ()
bindImageMemory dev image memory offset =
  liftIO (Vulkan.vkBindImageMemory dev image memory offset) >>= throwVkResult

managedSampler ::
  MonadManaged m =>
  Vulkan.VkDevice ->
  m Vulkan.VkSampler
managedSampler dev =
  alloc
    "Sampler"
    (createSampler dev)
    (\ptr -> Vulkan.vkDestroySampler dev ptr Vulkan.vkNullPtr)

createSampler ::
  MonadIO m =>
  Vulkan.VkDevice ->
  m Vulkan.VkSampler
createSampler dev =
  let createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO
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

-- | Create and register a texture resource. Staging buffer is destroyed immediately after copy.
createTextureResource ::
  (MonadFail m, MonadManaged m, MonadIO m) =>
  ResourceManager ->
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  FilePath ->
  Vulkan.VkQueue ->
  Vulkan.VkCommandBuffer ->
  m TextureHandle
createTextureResource rm pdev dev filePath queue commandBuffer = do
  (imgData, width, height) <- liftIO (readImageFromFile filePath)
  let dataList = Vector.toList imgData

  -- Staging buffer (temporary, not registered)
  (stagingBuffer, stagingMemoryRequirement) <-
    Haskan.managedBuffer dev dataList Vulkan.VK_BUFFER_USAGE_TRANSFER_SRC_BIT

  stagingMemory <-
    Haskan.managedBufferMemory pdev dev stagingMemoryRequirement

  liftIO $ do
    Haskan.bindBufferMemory dev stagingBuffer stagingMemory dataList
    Haskan.copyDataToDeviceMemory dev stagingMemory dataList

  let format = Vulkan.VK_FORMAT_R8G8B8A8_SRGB
      imageExtent =
        Vulkan.createVk
          ( set @"width" (fromIntegral width)
              &* set @"height" (fromIntegral height)
              &* set @"depth" 1
          )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
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

  image <- liftIO $ withPtr createInfo (\ciPtr -> allocaAndPeek (Vulkan.vkCreateImage dev ciPtr Vulkan.vkNullPtr))

  imageMemoryRequirements <-
    allocaAndPeek_
      (Vulkan.vkGetImageMemoryRequirements dev image)

  imageMemory <-
    Haskan.managedMemoryFor pdev dev imageMemoryRequirements [Vulkan.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT]

  liftIO $ bindImageMemory dev image imageMemory 0

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
      (fromIntegral width)
      (fromIntegral height)

    Haskan.layerTransition
      commandBuffer
      image
      Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
      Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL

  liftIO $ Vulkan.vkQueueWaitIdle queue >>= throwVkResult
  imageView <- Haskan.managedImageView dev format image

  -- Destroy staging resources immediately
  liftIO $ do
    Vulkan.vkDestroyBuffer dev stagingBuffer Vulkan.vkNullPtr
    Vulkan.vkFreeMemory dev stagingMemory Vulkan.vkNullPtr

  texH <- TextureHandle <$> allocHandle (rmNextId rm)

  let destroy = do
        Vulkan.vkDestroyImageView dev imageView Vulkan.vkNullPtr
        Vulkan.vkDestroyImage dev image Vulkan.vkNullPtr
        Vulkan.vkFreeMemory dev imageMemory Vulkan.vkNullPtr

      resource =
        TextureResource
          { trHandle = texH,
            trImage = image,
            trImageView = imageView,
            trMemory = imageMemory,
            trDestroy = destroy
          }

  registerTexture rm resource
  pure texH

-- | Resolve a texture handle to its VkImageView.
textureImageView :: MonadIO m => ResourceManager -> TextureHandle -> m (Maybe Vulkan.VkImageView)
textureImageView rm handle = do
  mTex <- lookupTexture rm handle
  pure $ fmap trImageView mTex
