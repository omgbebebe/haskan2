{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Debug.CloudExport
  ( saveCloudNoiseSlices,
    saveCloudDebugOutput,
    saveCloudOutputImage,
    CloudExportContext (..),
  )
where

import Control.Monad (forM_)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Text qualified as Text
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Data.Word (Word32)
import Graphics.Haskan.Debug.Screenshot (ensureScreenshotDir, saveImage3DSliceToPng, saveImageToPng)
import Graphics.Haskan.Engine.Capabilities.Log (MonadLog (..), logInfo)
import Graphics.Haskan.Logger (LogCategory (..))
import Graphics.Haskan.Vulkan.DeferredResources (DeferredResources (..))
import Graphics.Haskan.Vulkan.Resources (TextureResource (..))
import Graphics.Haskan.Vulkan.Types (VulkanContext (..))
import Vulkan qualified as Vk26
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

-- | Context needed for cloud texture exports.
data CloudExportContext = CloudExportContext
  { cecVulkanContext :: !VulkanContext,
    cecCommandPool :: !Vk26.CommandPool,
    cecResourceManager :: !Vk26.Device,
    cecCloudExtent :: !Vk26.Extent2D
  }

cloudDebugDir :: FilePath
cloudDebugDir = "data/debug/clouds"

-- | Save multiple Z-slices of the 3D cloud noise texture as PNG files.
-- Each slice is saved to data/debug/clouds/cloud_noise_slice_Z_N.png.
saveCloudNoiseSlices ::
  (MonadLog m, MonadIO m) =>
  CloudExportContext ->
  -- | TextureResource for the 3D cloud noise texture
  TextureResource ->
  -- | Slice indices to export
  [Int] ->
  m ()
saveCloudNoiseSlices CloudExportContext {..} texResource slices = do
  liftIO $ ensureScreenshotDir
  liftIO $ createDirectoryIfMissing True cloudDebugDir
  timestamp <- liftIO $ formatTime defaultTimeLocale "%Y%m%d_%H%M%S" <$> getCurrentTime
  let VulkanContext {..} = cecVulkanContext
      image = trImage texResource
      format = Vk26.FORMAT_R8G8B8A8_UNORM
  forM_ slices $ \zSlice -> do
    let path = cloudDebugDir </> (timestamp ++ "_cloud_noise_slice_Z" ++ show zSlice ++ ".png")
    logInfo LogGeneral $ "exporting cloud noise slice Z=" <> Text.pack (show zSlice) <> "..."
    liftIO $
      saveImage3DSliceToPng
        vcDevice
        vcPhysicalDevice
        cecCommandPool
        vcQueue
        image
        (256, 256)
        format
        Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
        zSlice
        path
    logInfo LogGeneral $ "saved: " <> Text.pack path

-- | Save the cloud pass output image (2D) to PNG.
-- This captures whatever the cloud fragment shader wrote for the current debug mode.
saveCloudOutputImage ::
  (MonadLog m, MonadIO m) =>
  CloudExportContext ->
  -- | Cloud output VkImage
  Vk26.Image ->
  -- | Base name for the file
  String ->
  m FilePath
saveCloudOutputImage CloudExportContext {..} cloudImage name = do
  liftIO $ ensureScreenshotDir
  liftIO $ createDirectoryIfMissing True cloudDebugDir
  timestamp <- liftIO $ formatTime defaultTimeLocale "%Y%m%d_%H%M%S" <$> getCurrentTime
  let VulkanContext {..} = cecVulkanContext
      path = cloudDebugDir </> (timestamp ++ "_" ++ name ++ ".png")
  logInfo LogGeneral $ "exporting cloud output (" <> Text.pack name <> ")..."
  liftIO $
    saveImageToPng
      vcDevice
      vcPhysicalDevice
      cecCommandPool
      vcQueue
      cloudImage
      cecCloudExtent
      Vk26.FORMAT_R16G16B16A16_SFLOAT
      Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
      path
  logInfo LogGeneral $ "saved: " <> Text.pack path
  pure path

-- | Save cloud debug output for a specific debug mode.
-- Requires that a frame has already been rendered with the target debugMode set.
saveCloudDebugOutput ::
  (MonadLog m, MonadIO m) =>
  CloudExportContext ->
  DeferredResources ->
  -- | Frame image index
  Word32 ->
  -- | Debug mode name for filename
  String ->
  m FilePath
saveCloudDebugOutput ctx dr imageIdx name = do
  let cloudImage = drCloudImages dr !! fromIntegral imageIdx
  saveCloudOutputImage ctx cloudImage name
