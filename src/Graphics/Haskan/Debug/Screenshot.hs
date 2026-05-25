{-# LANGUAGE BlockArguments #-}

module Graphics.Haskan.Debug.Screenshot
  ( saveSwapchainScreenshot,
    saveGBufferStage,
    saveImageToPng,
    saveImage3DSliceToPng,
    ensureScreenshotDir,
  )
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Text qualified as Text
import Graphics.Haskan.Logger (LogCategory (..), logInfoIO)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import Vulkan qualified as Vulkan

screenshotDir :: FilePath
screenshotDir = "data/debug/screenshots"

ensureScreenshotDir :: IO ()
ensureScreenshotDir = createDirectoryIfMissing True screenshotDir

saveImageToPng ::
  Vulkan.Device ->
  Vulkan.PhysicalDevice ->
  Vulkan.CommandPool ->
  Vulkan.Queue ->
  Vulkan.Image ->
  Vulkan.Extent2D ->
  Vulkan.Format ->
  Vulkan.ImageLayout ->
  FilePath ->
  IO ()
saveImageToPng _ _ _ _ _ _ _ _ _ =
  logInfoIO LogGeneral "saveImageToPng: stubbed during vulkan migration"

saveImage3DSliceToPng ::
  Vulkan.Device ->
  Vulkan.PhysicalDevice ->
  Vulkan.CommandPool ->
  Vulkan.Queue ->
  Vulkan.Image ->
  (Int, Int) ->
  Vulkan.Format ->
  Vulkan.ImageLayout ->
  Int ->
  FilePath ->
  IO ()
saveImage3DSliceToPng _ _ _ _ _ _ _ _ _ _ =
  logInfoIO LogGeneral "saveImage3DSliceToPng: stubbed during vulkan migration"

saveSwapchainScreenshot ::
  Vulkan.Device ->
  Vulkan.PhysicalDevice ->
  Vulkan.CommandPool ->
  Vulkan.Queue ->
  Vulkan.Image ->
  Vulkan.Extent2D ->
  IO FilePath
saveSwapchainScreenshot _ _ _ _ _ _ = do
  ensureScreenshotDir
  let path = screenshotDir </> "stubbed_screenshot.png"
  logInfoIO LogGeneral $ "saveSwapchainScreenshot: stubbed during vulkan migration, path=" <> Text.pack path
  pure path

saveGBufferStage ::
  Vulkan.Device ->
  Vulkan.PhysicalDevice ->
  Vulkan.CommandPool ->
  Vulkan.Queue ->
  Vulkan.Image ->
  Vulkan.Extent2D ->
  Vulkan.Format ->
  FilePath ->
  IO FilePath
saveGBufferStage _ _ _ _ _ _ _ name = do
  ensureScreenshotDir
  let path = screenshotDir </> ("stubbed_" ++ name ++ ".png")
  logInfoIO LogGeneral $ "saveGBufferStage: stubbed during vulkan migration, path=" <> Text.pack path
  pure path
