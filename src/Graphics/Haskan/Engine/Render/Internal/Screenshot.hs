{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Engine.Render.Internal.Screenshot
  ( ScreenshotContext (..),
    ScreenshotFlags (..),
    handleScreenshotSingle,
    handleScreenshotAllStages,
    handleScreenshotSwapchain,
  )
where

import Control.Concurrent.STM qualified as STM
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Word (Word32)
import Graphics.Haskan.Debug.Screenshot qualified as Screenshot
import Graphics.Haskan.Engine.Capabilities.Graphics (MonadGraphics (..))
import Graphics.Haskan.Engine.Capabilities.Log (MonadLog (..), logInfo)
import Graphics.Haskan.Logger (LogCategory (..))
import Graphics.Haskan.Vulkan.DeferredResources (DeferredResources (..))
import Graphics.Haskan.Vulkan.Types (RenderContext (..), VulkanContext (..))
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan

-- | Mutable screenshot trigger flags.
data ScreenshotFlags = ScreenshotFlags
  { sfPendingScreenshot :: !(STM.TVar Bool),
    sfPendingAllStages :: !(STM.TVar Bool),
    sfPendingSwapchainScreenshot :: !(STM.TVar Bool)
  }

-- | Common Vulkan handles needed by all screenshot operations.
data ScreenshotContext = ScreenshotContext
  { scVulkanContext :: !VulkanContext,
    scCommandPool :: !Vulkan.VkCommandPool,
    scExtent :: !Vulkan.VkExtent2D,
    scImageIndex :: !Vulkan.Word32
  }

-- | Handle single gbuffer screenshot capture
handleScreenshotSingle ::
  (MonadLog m, MonadGraphics m, MonadIO m) =>
  DeferredResources ->
  ScreenshotContext ->
  m ()
handleScreenshotSingle dr ScreenshotContext {scVulkanContext = VulkanContext {..}, ..} = do
  deviceWaitIdle
  let gbufferImages = drGBufferImages dr !! fromIntegral scImageIndex
  logInfo LogGeneral "capturing screenshot..."
  liftIO $ Screenshot.saveGBufferStage vcDevice vcPhysicalDevice scCommandPool vcQueue (gbufferImages !! 2) scExtent Vulkan.VK_FORMAT_R8G8B8A8_UNORM "albedo"
  logInfo LogGeneral "screenshot saved"

-- | Handle all pipeline stages screenshot capture
handleScreenshotAllStages ::
  (MonadLog m, MonadGraphics m, MonadIO m) =>
  DeferredResources ->
  ScreenshotContext ->
  m ()
handleScreenshotAllStages dr ScreenshotContext {scVulkanContext = VulkanContext {..}, ..} = do
  deviceWaitIdle
  let gbufferImages = drGBufferImages dr !! fromIntegral scImageIndex
  logInfo LogGeneral "capturing all pipeline stages..."
  liftIO $ do
    Screenshot.saveGBufferStage vcDevice vcPhysicalDevice scCommandPool vcQueue (gbufferImages !! 0) scExtent Vulkan.VK_FORMAT_R16G16B16A16_SFLOAT "position"
    Screenshot.saveGBufferStage vcDevice vcPhysicalDevice scCommandPool vcQueue (gbufferImages !! 1) scExtent Vulkan.VK_FORMAT_R8G8B8A8_UNORM "normal"
    Screenshot.saveGBufferStage vcDevice vcPhysicalDevice scCommandPool vcQueue (gbufferImages !! 2) scExtent Vulkan.VK_FORMAT_R8G8B8A8_UNORM "albedo"
    Screenshot.saveGBufferStage vcDevice vcPhysicalDevice scCommandPool vcQueue (gbufferImages !! 3) scExtent Vulkan.VK_FORMAT_R8G8B8A8_UNORM "emissive"
  logInfo LogGeneral "all stages saved"

-- | Handle swapchain screenshot capture
handleScreenshotSwapchain ::
  (MonadLog m, MonadGraphics m, MonadIO m) =>
  RenderContext ->
  ScreenshotContext ->
  m ()
handleScreenshotSwapchain ctx ScreenshotContext {scVulkanContext = VulkanContext {..}, ..} = do
  deviceWaitIdle
  let swapchainImage = swapchainImages ctx !! fromIntegral scImageIndex
  logInfo LogGeneral "capturing swapchain screenshot..."
  liftIO $ Screenshot.saveSwapchainScreenshot vcDevice vcPhysicalDevice scCommandPool vcQueue swapchainImage scExtent
  logInfo LogGeneral "swapchain screenshot saved"
