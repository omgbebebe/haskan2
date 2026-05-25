module Graphics.Haskan.Vulkan.PhysicalDevice
  ( selectPhysicalDevice,
    surfaceExtent,
    selectPresentMode,
  )
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.List (maximumBy, sortOn)
import Data.Ord (comparing)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Graphics.Haskan.Logger (LogCategory (..), logInfoIO, showT)
import Vulkan qualified as Vulkan
import Vulkan.Core10 qualified as Vulkan
import Vulkan.Core10.DeviceInitialization (PhysicalDeviceProperties (..))
import Vulkan.Extensions qualified as Vulkan
import Vulkan.Extensions.VK_KHR_surface (SurfaceCapabilitiesKHR (..))

selectPhysicalDevice :: (MonadIO m) => Vulkan.Instance -> m Vulkan.PhysicalDevice
selectPhysicalDevice inst = do
  (_, physicalDevices) <- liftIO $ Vulkan.enumeratePhysicalDevices inst
  case Vector.toList physicalDevices of
    [] -> error "No Vulkan physical devices found"
    [single] -> do
      logInfoIO LogVulkan "Only one physical device available, using it"
      pure single
    multiple -> selectBestPhysicalDevice multiple

selectBestPhysicalDevice :: (MonadIO m) => [Vulkan.PhysicalDevice] -> m Vulkan.PhysicalDevice
selectBestPhysicalDevice devices = do
  scored <- mapM scoreDevice devices
  let best@(bestDev, bestScore, bestName) = maximumBy (comparing (\(_, s, _) -> s)) scored
      scoreStr = concatMap (\(_, score, name) -> "\n  " ++ name ++ " (score=" ++ show score ++ ")") scored
  logInfoIO LogVulkan $ "Selecting physical device:" <> Text.pack scoreStr
  logInfoIO LogVulkan $ "Selected: " <> showT (Text.pack bestName) <> " with score " <> showT bestScore
  pure bestDev
  where
    scoreDevice :: (MonadIO m) => Vulkan.PhysicalDevice -> m (Vulkan.PhysicalDevice, Int, String)
    scoreDevice dev = liftIO $ do
      props <- Vulkan.getPhysicalDeviceProperties dev
      let baseScore = case deviceType props of
            Vulkan.PHYSICAL_DEVICE_TYPE_DISCRETE_GPU -> 100
            Vulkan.PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU -> 50
            Vulkan.PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU -> 30
            Vulkan.PHYSICAL_DEVICE_TYPE_OTHER -> 10
            Vulkan.PHYSICAL_DEVICE_TYPE_CPU -> 0
            _ -> 10
          versionBonus = fromIntegral ((apiVersion props `div` 1000000) `mod` 100) :: Int
          totalScore = baseScore + versionBonus
      pure (dev, totalScore, show (deviceName props))

surfaceExtent :: (MonadIO m) => Vulkan.PhysicalDevice -> Vulkan.SurfaceKHR -> m Vulkan.Extent2D
surfaceExtent pdev surface = do
  caps <- liftIO $ Vulkan.getPhysicalDeviceSurfaceCapabilitiesKHR pdev surface
  pure (currentExtent caps)

-- | Query supported present modes and select the best available.
-- Preference order: MAILBOX > IMMEDIATE > FIFO
selectPresentMode :: (MonadIO m) => Vulkan.PhysicalDevice -> Vulkan.SurfaceKHR -> m Vulkan.PresentModeKHR
selectPresentMode pdev surface = do
  (_, modes) <- liftIO $ Vulkan.getPhysicalDeviceSurfacePresentModesKHR pdev surface
  let preferred = [Vulkan.PRESENT_MODE_MAILBOX_KHR, Vulkan.PRESENT_MODE_IMMEDIATE_KHR, Vulkan.PRESENT_MODE_FIFO_KHR]
      chosen = case filter (`elem` Vector.toList modes) preferred of
        (mode : _) -> mode
        [] -> Vulkan.PRESENT_MODE_FIFO_KHR -- FIFO is guaranteed to be supported
  logInfoIO LogVulkan $ "selected present mode: " <> showT chosen <> " (available: " <> showT (Vector.toList modes) <> ")"
  pure chosen
