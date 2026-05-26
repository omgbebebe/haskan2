{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

module Graphics.Haskan.Vulkan.Swapchain where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Bits ((.|.))
import Data.Vector qualified as Vector
import Data.Word (Word32)
import Graphics.Haskan.Logger (LogCategory (..), logDebugIO, showT)
import Graphics.Haskan.Resources (alloc)
import Graphics.Haskan.Vulkan.Memory (managedMemoryFor)
import Graphics.Haskan.Vulkan.PhysicalDevice (selectPresentMode)
import Vulkan qualified as Vulkan
import Vulkan.Core10 qualified as Vulkan
import Vulkan.Core10.Image (ImageCreateInfo (..))
import Vulkan.Core10.ImageView (ComponentMapping (..), ImageSubresourceRange (..), ImageViewCreateInfo (..))
import Vulkan.Extensions.VK_KHR_surface (ColorSpaceKHR (..), CompositeAlphaFlagBitsKHR (..), PresentModeKHR (..), SurfaceTransformFlagBitsKHR (..))
import Vulkan.Extensions.VK_KHR_swapchain (SwapchainCreateInfoKHR (..))
import Vulkan.Zero (zero)

managedSwapchain :: (MonadManaged m) => Vulkan.Device -> Vulkan.PhysicalDevice -> Vulkan.SurfaceKHR -> Vulkan.Extent2D -> m Vulkan.SwapchainKHR
managedSwapchain dev pdev surface extent =
  alloc
    "Swapchain"
    (createSwapchain dev pdev surface extent)
    (\sc -> Vulkan.destroySwapchainKHR dev sc Nothing)

createSwapchain dev pdev surface extent = do
  let imageFormat = Vulkan.FORMAT_B8G8R8A8_SRGB
      imageColorSpace = Vulkan.COLOR_SPACE_SRGB_NONLINEAR_KHR
      imageCount :: Word32
      imageCount = 3 + 1
      preTransform = Vulkan.SURFACE_TRANSFORM_IDENTITY_BIT_KHR
  presentMode <- selectPresentMode pdev surface
  let createInfo :: Vulkan.SwapchainCreateInfoKHR '[]
      createInfo =
        Vulkan.SwapchainCreateInfoKHR
          { next = (),
            flags = zero,
            surface = surface,
            minImageCount = fromIntegral imageCount,
            imageFormat = imageFormat,
            imageColorSpace = imageColorSpace,
            imageExtent = extent,
            imageArrayLayers = 1,
            imageUsage = Vulkan.IMAGE_USAGE_COLOR_ATTACHMENT_BIT .|. Vulkan.IMAGE_USAGE_TRANSFER_SRC_BIT,
            imageSharingMode = Vulkan.SHARING_MODE_EXCLUSIVE,
            queueFamilyIndices = Vector.empty,
            compositeAlpha = Vulkan.COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            presentMode = presentMode,
            clipped = True,
            oldSwapchain = zero,
            preTransform = preTransform
          }
  liftIO $ Vulkan.createSwapchainKHR dev createInfo Nothing

getSwapchainImages :: (MonadIO m) => Vulkan.Device -> Vulkan.SwapchainKHR -> m [Vulkan.Image]
getSwapchainImages dev swapchain = do
  (_, images) <- liftIO $ Vulkan.getSwapchainImagesKHR dev swapchain
  pure (Vector.toList images)

-- TODO: get SurfaceFormats from device

surfaceFormat :: Vulkan.SurfaceFormatKHR
surfaceFormat =
  Vulkan.SurfaceFormatKHR
    { format = Vulkan.FORMAT_B8G8R8A8_SRGB,
      colorSpace = Vulkan.COLOR_SPACE_SRGB_NONLINEAR_KHR
    }

managedDepthImage ::
  (MonadManaged m) =>
  Vulkan.PhysicalDevice ->
  Vulkan.Device ->
  Vulkan.Extent2D ->
  Vulkan.Format ->
  m Vulkan.Image
managedDepthImage pdev dev extent depthFormat = do
  image <-
    alloc
      "Depth image"
      (createDepthImage dev extent depthFormat)
      (\ptr -> Vulkan.destroyImage dev ptr Nothing)
  memoryRequirements <- getImageMemoryRequirements dev image
  let Vulkan.MemoryRequirements {size = memSize} = memoryRequirements
      Vulkan.Extent2D {width = w, height = h} = extent
  logDebugIO LogVulkan $ "depth image memory requirements size=" <> showT memSize <> " extent=" <> showT w <> "x" <> showT h
  memory <- managedMemoryFor pdev dev memoryRequirements [Vulkan.MEMORY_PROPERTY_DEVICE_LOCAL_BIT]
  liftIO $ Vulkan.bindImageMemory dev image memory 0
  pure image

managedGBufferImage ::
  (MonadManaged m) =>
  Vulkan.PhysicalDevice ->
  Vulkan.Device ->
  Vulkan.Extent2D ->
  Vulkan.Format ->
  m Vulkan.Image
managedGBufferImage pdev dev extent format = do
  image <-
    alloc
      "GBuffer image"
      (createGBufferImage dev extent format)
      (\ptr -> Vulkan.destroyImage dev ptr Nothing)
  memoryRequirements <- getImageMemoryRequirements dev image
  memory <- managedMemoryFor pdev dev memoryRequirements [Vulkan.MEMORY_PROPERTY_DEVICE_LOCAL_BIT]
  liftIO $ Vulkan.bindImageMemory dev image memory 0
  pure image

createGBufferImage ::
  (MonadIO m) =>
  Vulkan.Device ->
  Vulkan.Extent2D ->
  Vulkan.Format ->
  m Vulkan.Image
createGBufferImage dev extent format = do
  let Vulkan.Extent2D {width = w, height = h} = extent
      createInfo :: Vulkan.ImageCreateInfo '[]
      createInfo =
        Vulkan.ImageCreateInfo
          { next = (),
            flags = zero,
            imageType = Vulkan.IMAGE_TYPE_2D,
            format = format,
            extent = Vulkan.Extent3D w h 1,
            mipLevels = 1,
            arrayLayers = 1,
            samples = Vulkan.SAMPLE_COUNT_1_BIT,
            tiling = Vulkan.IMAGE_TILING_OPTIMAL,
            usage = Vulkan.IMAGE_USAGE_COLOR_ATTACHMENT_BIT .|. Vulkan.IMAGE_USAGE_SAMPLED_BIT .|. Vulkan.IMAGE_USAGE_TRANSFER_SRC_BIT .|. Vulkan.IMAGE_USAGE_TRANSFER_DST_BIT,
            sharingMode = Vulkan.SHARING_MODE_EXCLUSIVE,
            queueFamilyIndices = Vector.empty,
            initialLayout = Vulkan.IMAGE_LAYOUT_UNDEFINED
          }
  liftIO $ Vulkan.createImage dev createInfo Nothing

createDepthImage ::
  (MonadIO m) =>
  Vulkan.Device ->
  Vulkan.Extent2D ->
  Vulkan.Format ->
  m Vulkan.Image
createDepthImage dev extent depthFormat = do
  let Vulkan.Extent2D {width = w, height = h} = extent
      createInfo :: Vulkan.ImageCreateInfo '[]
      createInfo =
        Vulkan.ImageCreateInfo
          { next = (),
            flags = zero,
            imageType = Vulkan.IMAGE_TYPE_2D,
            format = depthFormat,
            extent = Vulkan.Extent3D w h 1,
            mipLevels = 1,
            arrayLayers = 1,
            samples = Vulkan.SAMPLE_COUNT_1_BIT,
            tiling = Vulkan.IMAGE_TILING_OPTIMAL,
            usage = Vulkan.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
            sharingMode = Vulkan.SHARING_MODE_EXCLUSIVE,
            queueFamilyIndices = Vector.empty,
            initialLayout = Vulkan.IMAGE_LAYOUT_UNDEFINED
          }
  liftIO $ Vulkan.createImage dev createInfo Nothing

managedDepthView ::
  (MonadManaged m) =>
  Vulkan.Device ->
  Vulkan.Image ->
  Vulkan.Format ->
  m Vulkan.ImageView
managedDepthView dev img depthFormat =
  alloc
    "DepthImageView"
    (createDepthView dev img depthFormat)
    (\ptr -> Vulkan.destroyImageView dev ptr Nothing)

createDepthView ::
  (MonadIO m) =>
  Vulkan.Device ->
  Vulkan.Image ->
  Vulkan.Format ->
  m Vulkan.ImageView
createDepthView dev img depthFormat = do
  let createInfo :: Vulkan.ImageViewCreateInfo '[]
      createInfo =
        Vulkan.ImageViewCreateInfo
          { next = (),
            flags = zero,
            image = img,
            viewType = Vulkan.IMAGE_VIEW_TYPE_2D,
            format = depthFormat,
            components = Vulkan.ComponentMapping Vulkan.COMPONENT_SWIZZLE_IDENTITY Vulkan.COMPONENT_SWIZZLE_IDENTITY Vulkan.COMPONENT_SWIZZLE_IDENTITY Vulkan.COMPONENT_SWIZZLE_IDENTITY,
            subresourceRange = Vulkan.ImageSubresourceRange Vulkan.IMAGE_ASPECT_DEPTH_BIT 0 1 0 1
          }
  liftIO $ Vulkan.createImageView dev createInfo Nothing

getImageMemoryRequirements ::
  (MonadIO m) =>
  Vulkan.Device ->
  Vulkan.Image ->
  m Vulkan.MemoryRequirements
getImageMemoryRequirements dev image =
  liftIO $ Vulkan.getImageMemoryRequirements dev image
