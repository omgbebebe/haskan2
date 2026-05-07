module Graphics.Haskan.Vulkan.PhysicalDevice
  ( selectPhysicalDevice,
    surfaceExtent,
    selectPresentMode,
  )
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Graphics.Haskan.Logger (logInfo, showT, LogCategory (..))
import Graphics.Haskan.Resources (allocaAndPeek, peekVkList)
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Ext qualified as Vulkan

selectPhysicalDevice :: MonadIO m => Vulkan.VkInstance -> m Vulkan.VkPhysicalDevice
selectPhysicalDevice inst = do
  physicalDevices <- liftIO $ peekVkList (Vulkan.vkEnumeratePhysicalDevices inst)
  peekPhysicalDevice physicalDevices

peekPhysicalDevice :: MonadIO m => [Vulkan.VkPhysicalDevice] -> m Vulkan.VkPhysicalDevice
peekPhysicalDevice = pure . head

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
  logInfo LogVulkan $ "selected present mode: " <> showT chosen <> " (available: " <> showT modes <> ")"
  pure chosen
