module Graphics.Haskan.Vulkan.Swapchain where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Bits ((.|.))
import Graphics.Haskan.Logger (LogCategory (..), logDebugIO, showT)
import Graphics.Haskan.Resources (alloc, allocaAndPeek, allocaAndPeek_, peekVkList, throwVkResult)
import Graphics.Haskan.Vulkan.Memory (managedMemoryFor)
import Graphics.Haskan.Vulkan.PhysicalDevice (selectPresentMode)
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Ext qualified as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan

managedSwapchain ::
  (MonadManaged m) =>
  Vulkan.VkDevice ->
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkSurfaceKHR ->
  Vulkan.VkExtent2D ->
  m Vulkan.VkSwapchainKHR
managedSwapchain dev pdev surface extent =
  alloc
    "Swapchain"
    (createSwapchain dev pdev surface extent)
    (\ptr -> Vulkan.vkDestroySwapchainKHR dev ptr Vulkan.vkNullPtr)

createSwapchain ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkSurfaceKHR ->
  Vulkan.VkExtent2D ->
  m Vulkan.VkSwapchainKHR
createSwapchain dev pdev surface extent = do
  let imageFormat = Vulkan.VK_FORMAT_B8G8R8A8_SRGB
      imageColorSpace = Vulkan.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR
      imageCount :: Vulkan.Word32
      imageCount = 3 + 1
      preTransform = Vulkan.VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR
  presentMode <- selectPresentMode pdev surface
  let createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"surface" surface
              &* set @"minImageCount" (fromIntegral imageCount)
              &* set @"imageFormat" imageFormat
              &* set @"imageColorSpace" imageColorSpace
              &* set @"imageExtent" extent
              &* set @"imageArrayLayers" 1
              &* set @"imageUsage" (Vulkan.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT .|. Vulkan.VK_IMAGE_USAGE_TRANSFER_SRC_BIT)
              &* set @"imageSharingMode" Vulkan.VK_SHARING_MODE_EXCLUSIVE
              &* set @"queueFamilyIndexCount" 0
              &* set @"pQueueFamilyIndices" Vulkan.VK_NULL
              &* set @"compositeAlpha" Vulkan.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR
              &* set @"presentMode" presentMode
              &* set @"clipped" Vulkan.VK_TRUE
              &* set @"oldSwapchain" Vulkan.VK_NULL
              &* set @"preTransform" preTransform
          )

  swapchain <- liftIO $ withPtr createInfo $ \ptr -> allocaAndPeek (Vulkan.vkCreateSwapchainKHR dev ptr Vulkan.vkNullPtr)
  pure swapchain

getSwapchainImages :: (MonadIO m) => Vulkan.VkDevice -> Vulkan.VkSwapchainKHR -> m [Vulkan.VkImage]
getSwapchainImages dev swapchain = liftIO $ peekVkList (Vulkan.vkGetSwapchainImagesKHR dev swapchain)

-- TODO: get SurfaceFormats from device

surfaceFormat :: Vulkan.VkSurfaceFormatKHR
surfaceFormat =
  let imageFormat = Vulkan.VK_FORMAT_B8G8R8A8_SRGB
      imageColorSpace = Vulkan.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR
   in Vulkan.createVk
        ( set @"format" imageFormat
            &* set @"colorSpace" imageColorSpace
        )

managedDepthImage ::
  (MonadManaged m) =>
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  Vulkan.VkExtent2D ->
  Vulkan.VkFormat ->
  m Vulkan.VkImage
managedDepthImage pdev dev extent depthFormat = do
  image <-
    alloc
      "Depth image"
      (createDepthImage dev extent depthFormat)
      (\ptr -> Vulkan.vkDestroyImage dev ptr Vulkan.vkNullPtr)
  memoryRequirements <- getImageMemoryRequirements dev image
  logDebugIO LogVulkan $ "depth image memory requirements size=" <> showT (Vulkan.getField @"size" memoryRequirements) <> " extent=" <> showT (Vulkan.getField @"width" extent) <> "x" <> showT (Vulkan.getField @"height" extent)
  memory <- managedMemoryFor pdev dev memoryRequirements [Vulkan.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT]
  liftIO $ Vulkan.vkBindImageMemory dev image memory 0 >>= throwVkResult
  pure image

managedGBufferImage ::
  (MonadManaged m) =>
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  Vulkan.VkExtent2D ->
  Vulkan.VkFormat ->
  m Vulkan.VkImage
managedGBufferImage pdev dev extent format = do
  image <-
    alloc
      "GBuffer image"
      (createGBufferImage dev extent format)
      (\ptr -> Vulkan.vkDestroyImage dev ptr Vulkan.vkNullPtr)
  memoryRequirements <- getImageMemoryRequirements dev image
  memory <- managedMemoryFor pdev dev memoryRequirements [Vulkan.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT]
  liftIO $ Vulkan.vkBindImageMemory dev image memory 0 >>= throwVkResult
  pure image

createGBufferImage ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkExtent2D ->
  Vulkan.VkFormat ->
  m Vulkan.VkImage
createGBufferImage dev extent format = do
  let imageExtent =
        Vulkan.createVk
          ( set @"width" (Vulkan.getField @"width" extent)
              &* set @"height" (Vulkan.getField @"height" extent)
              &* set @"depth" 1
          )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"initialLayout" Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
              &* set @"sharingMode" Vulkan.VK_SHARING_MODE_EXCLUSIVE
              &* set @"queueFamilyIndexCount" 0
              &* set @"pQueueFamilyIndices" Vulkan.VK_NULL
              &* set @"usage" (Vulkan.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT .|. Vulkan.VK_IMAGE_USAGE_SAMPLED_BIT .|. Vulkan.VK_IMAGE_USAGE_TRANSFER_SRC_BIT)
              &* set @"tiling" Vulkan.VK_IMAGE_TILING_OPTIMAL
              &* set @"format" format
              &* set @"samples" Vulkan.VK_SAMPLE_COUNT_1_BIT
              &* set @"arrayLayers" 1
              &* set @"mipLevels" 1
              &* set @"imageType" Vulkan.VK_IMAGE_TYPE_2D
              &* set @"extent" imageExtent
          )
  liftIO $ withPtr createInfo (\ciPtr -> allocaAndPeek (Vulkan.vkCreateImage dev ciPtr Vulkan.vkNullPtr))

createDepthImage ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkExtent2D ->
  Vulkan.VkFormat ->
  m Vulkan.VkImage
createDepthImage dev extent depthFormat = do
  let depthExtent =
        Vulkan.createVk
          ( set @"width" (Vulkan.getField @"width" extent)
              &* set @"height" (Vulkan.getField @"height" extent)
              &* set @"depth" 1
          )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"initialLayout" Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
              &* set @"sharingMode" Vulkan.VK_SHARING_MODE_EXCLUSIVE
              &* set @"queueFamilyIndexCount" 0
              &* set @"pQueueFamilyIndices" Vulkan.VK_NULL
              &* set @"usage" Vulkan.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT
              &* set @"tiling" Vulkan.VK_IMAGE_TILING_OPTIMAL
              &* set @"format" depthFormat
              &* set @"samples" Vulkan.VK_SAMPLE_COUNT_1_BIT
              &* set @"arrayLayers" 1
              &* set @"mipLevels" 1
              &* set @"imageType" Vulkan.VK_IMAGE_TYPE_2D
              &* set @"extent" depthExtent
          )
  liftIO $ withPtr createInfo (\ciPtr -> allocaAndPeek (Vulkan.vkCreateImage dev ciPtr Vulkan.vkNullPtr))

managedDepthView ::
  (MonadManaged m) =>
  Vulkan.VkDevice ->
  Vulkan.VkImage ->
  Vulkan.VkFormat ->
  m Vulkan.VkImageView
managedDepthView dev img depthFormat =
  alloc
    "DepthImageView"
    (createDepthView dev img depthFormat)
    (\ptr -> Vulkan.vkDestroyImageView dev ptr Vulkan.vkNullPtr)

createDepthView ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkImage ->
  Vulkan.VkFormat ->
  m Vulkan.VkImageView
createDepthView dev img depthFormat = do
  let createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"image" img
              &* set @"viewType" Vulkan.VK_IMAGE_VIEW_TYPE_2D
              &* set @"format" format
              &* set @"components" cmapping
              &* set @"subresourceRange" subresourceRange
          )
      cmapping =
        Vulkan.createVk
          ( set @"r" Vulkan.VK_COMPONENT_SWIZZLE_IDENTITY
              &* set @"g" Vulkan.VK_COMPONENT_SWIZZLE_IDENTITY
              &* set @"b" Vulkan.VK_COMPONENT_SWIZZLE_IDENTITY
              &* set @"a" Vulkan.VK_COMPONENT_SWIZZLE_IDENTITY
          )
      subresourceRange =
        Vulkan.createVk
          ( set @"aspectMask" Vulkan.VK_IMAGE_ASPECT_DEPTH_BIT
              &* set @"baseMipLevel" 0
              &* set @"levelCount" 1
              &* set @"baseArrayLayer" 0
              &* set @"layerCount" 1
          )
      format = depthFormat
   in liftIO $ withPtr createInfo $ \ptr -> allocaAndPeek (Vulkan.vkCreateImageView dev ptr Vulkan.VK_NULL)

getImageMemoryRequirements ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkImage ->
  m Vulkan.VkMemoryRequirements
getImageMemoryRequirements dev image =
  liftIO $ allocaAndPeek_ (Vulkan.vkGetImageMemoryRequirements dev image)
