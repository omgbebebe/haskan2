{-# LANGUAGE LambdaCase #-}

module Graphics.Haskan.Engine.Render.Internal.Screenshot
  ( handleScreenshotSingle,
    handleScreenshotAllStages,
    handleScreenshotSwapchain,
  )
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Word (Word32)
import Graphics.Haskan.Debug.Screenshot qualified as Screenshot
import Graphics.Haskan.Engine.Capabilities.Graphics (MonadGraphics (..))
import Graphics.Haskan.Engine.Capabilities.Log (MonadLog (..), logInfo)
import Graphics.Haskan.Logger (LogCategory (..))
import Graphics.Haskan.Vulkan.DeferredResources (DeferredResources (..))
import Graphics.Haskan.Vulkan.Types (RenderContext (..))
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan

-- | Handle single gbuffer screenshot capture
handleScreenshotSingle ::
  (MonadLog m, MonadGraphics m, MonadIO m) =>
  DeferredResources ->
  Vulkan.VkDevice ->
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkCommandPool ->
  Vulkan.VkQueue ->
  Vulkan.VkExtent2D ->
  Vulkan.Word32 ->
  m ()
handleScreenshotSingle dr device physicalDevice graphicsCommandPool graphicsQueueHandler rcSurfaceExtent imageIndex = do
  deviceWaitIdle
  let gbufferImages = drGBufferImages dr !! fromIntegral imageIndex
  logInfo LogGeneral "capturing screenshot..."
  liftIO $ Screenshot.saveGBufferStage device physicalDevice graphicsCommandPool graphicsQueueHandler (gbufferImages !! 2) rcSurfaceExtent Vulkan.VK_FORMAT_R8G8B8A8_UNORM "albedo"
  logInfo LogGeneral "screenshot saved"

-- | Handle all pipeline stages screenshot capture
handleScreenshotAllStages ::
  (MonadLog m, MonadGraphics m, MonadIO m) =>
  DeferredResources ->
  Vulkan.VkDevice ->
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkCommandPool ->
  Vulkan.VkQueue ->
  Vulkan.VkExtent2D ->
  Vulkan.Word32 ->
  m ()
handleScreenshotAllStages dr device physicalDevice graphicsCommandPool graphicsQueueHandler rcSurfaceExtent imageIndex = do
  deviceWaitIdle
  let gbufferImages = drGBufferImages dr !! fromIntegral imageIndex
  logInfo LogGeneral "capturing all pipeline stages..."
  liftIO $ do
    Screenshot.saveGBufferStage device physicalDevice graphicsCommandPool graphicsQueueHandler (gbufferImages !! 0) rcSurfaceExtent Vulkan.VK_FORMAT_R16G16B16A16_SFLOAT "position"
    Screenshot.saveGBufferStage device physicalDevice graphicsCommandPool graphicsQueueHandler (gbufferImages !! 1) rcSurfaceExtent Vulkan.VK_FORMAT_R8G8B8A8_UNORM "normal"
    Screenshot.saveGBufferStage device physicalDevice graphicsCommandPool graphicsQueueHandler (gbufferImages !! 2) rcSurfaceExtent Vulkan.VK_FORMAT_R8G8B8A8_UNORM "albedo"
    Screenshot.saveGBufferStage device physicalDevice graphicsCommandPool graphicsQueueHandler (gbufferImages !! 3) rcSurfaceExtent Vulkan.VK_FORMAT_R8G8B8A8_UNORM "emissive"
  logInfo LogGeneral "all stages saved"

-- | Handle swapchain screenshot capture
handleScreenshotSwapchain ::
  (MonadLog m, MonadGraphics m, MonadIO m) =>
  RenderContext ->
  Vulkan.VkDevice ->
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkCommandPool ->
  Vulkan.VkQueue ->
  Vulkan.VkExtent2D ->
  Vulkan.Word32 ->
  m ()
handleScreenshotSwapchain ctx device physicalDevice graphicsCommandPool graphicsQueueHandler rcSurfaceExtent imageIndex = do
  deviceWaitIdle
  let swapchainImage = swapchainImages ctx !! fromIntegral imageIndex
  logInfo LogGeneral "capturing swapchain screenshot..."
  liftIO $ Screenshot.saveSwapchainScreenshot device physicalDevice graphicsCommandPool graphicsQueueHandler swapchainImage rcSurfaceExtent
  logInfo LogGeneral "swapchain screenshot saved"
