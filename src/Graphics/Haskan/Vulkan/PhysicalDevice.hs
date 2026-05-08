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
import Graphics.Haskan.Logger (logInfoIO, showT, LogCategory (..))
import Graphics.Haskan.Resources (allocaAndPeek, allocaAndPeek_, peekVkList)
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Ext qualified as Vulkan
import Graphics.Vulkan.Marshal.Internal (getStringField)

selectPhysicalDevice :: MonadIO m => Vulkan.VkInstance -> m Vulkan.VkPhysicalDevice
selectPhysicalDevice inst = do
  physicalDevices <- liftIO $ peekVkList (Vulkan.vkEnumeratePhysicalDevices inst)
  case physicalDevices of
    [] -> error "No Vulkan physical devices found"
    [single] -> do
      logInfoIO LogVulkan "Only one physical device available, using it"
      pure single
    multiple -> selectBestPhysicalDevice multiple

selectBestPhysicalDevice :: MonadIO m => [Vulkan.VkPhysicalDevice] -> m Vulkan.VkPhysicalDevice
selectBestPhysicalDevice devices = do
  scored <- mapM scoreDevice devices
  let best@(bestDev, bestScore, bestName) = maximumBy (comparing (\(_, s, _) -> s)) scored
      scoreStr = concatMap (\(_, score, name) -> "\n  " ++ name ++ " (score=" ++ show score ++ ")") scored
  logInfoIO LogVulkan $ "Selecting physical device:" <> Text.pack scoreStr
  logInfoIO LogVulkan $ "Selected: " <> showT (Text.pack bestName) <> " with score " <> showT bestScore
  pure bestDev
  where
    scoreDevice :: MonadIO m => Vulkan.VkPhysicalDevice -> m (Vulkan.VkPhysicalDevice, Int, String)
    scoreDevice dev = liftIO $ do
      props <- allocaAndPeek_ (Vulkan.vkGetPhysicalDeviceProperties dev)
      let deviceType = Vulkan.getField @"deviceType" props
          deviceName = getStringField @"deviceName" props
          -- Score: discrete (100) > integrated (50) > virtual (30) > other (10) > cpu (0)
          baseScore = case deviceType of
            Vulkan.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU -> 100
            Vulkan.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU -> 50
            Vulkan.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU -> 30
            Vulkan.VK_PHYSICAL_DEVICE_TYPE_OTHER -> 10
            Vulkan.VK_PHYSICAL_DEVICE_TYPE_CPU -> 0
            _ -> 10
          -- Bonus for API version (prefer newer)
          apiVersion = Vulkan.getField @"apiVersion" props
          versionBonus = fromIntegral ((apiVersion `div` 1000000) `mod` 100) :: Int
          totalScore = baseScore + versionBonus
      pure (dev, totalScore, deviceName)

surfaceExtent :: MonadIO m => Vulkan.VkPhysicalDevice -> Vulkan.VkSurfaceKHR -> m Vulkan.VkExtent2D
surfaceExtent pdev surface = do
  caps <- liftIO $ allocaAndPeek (Vulkan.vkGetPhysicalDeviceSurfaceCapabilitiesKHR pdev surface)
  let currentExtent = Vulkan.getField @"currentExtent" caps
  pure currentExtent

-- | Query supported present modes and select the best available.
-- Preference order: MAILBOX > IMMEDIATE > FIFO
selectPresentMode :: MonadIO m => Vulkan.VkPhysicalDevice -> Vulkan.VkSurfaceKHR -> m Vulkan.VkPresentModeKHR
selectPresentMode pdev surface = do
  modes <- liftIO $ peekVkList (Vulkan.vkGetPhysicalDeviceSurfacePresentModesKHR pdev surface)
  let preferred = [Vulkan.VK_PRESENT_MODE_MAILBOX_KHR, Vulkan.VK_PRESENT_MODE_IMMEDIATE_KHR, Vulkan.VK_PRESENT_MODE_FIFO_KHR]
      chosen = case filter (`elem` modes) preferred of
        (mode : _) -> mode
        [] -> Vulkan.VK_PRESENT_MODE_FIFO_KHR -- FIFO is guaranteed to be supported
  logInfoIO LogVulkan $ "selected present mode: " <> showT chosen <> " (available: " <> showT modes <> ")"
  pure chosen
