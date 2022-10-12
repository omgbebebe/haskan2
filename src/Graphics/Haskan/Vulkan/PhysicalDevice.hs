module Graphics.Haskan.Vulkan.PhysicalDevice
  (selectPhysicalDevice
  ,surfaceExtent
  ) where

-- base
import Control.Monad.IO.Class (MonadIO, liftIO)

-- vulkan-api
import qualified Graphics.Vulkan as Vulkan
import qualified Graphics.Vulkan.Core_1_0 as Vulkan
import qualified Graphics.Vulkan.Ext as Vulkan

-- haskan
import Graphics.Haskan.Resources (allocaAndPeek, peekVkList)

selectPhysicalDevice :: MonadIO m => Vulkan.VkInstance -> m Vulkan.VkPhysicalDevice
selectPhysicalDevice inst = do
  physicalDevices <- liftIO $ peekVkList (Vulkan.vkEnumeratePhysicalDevices inst)
  peekPhysicalDevice physicalDevices

peekPhysicalDevice :: MonadIO m => [Vulkan.VkPhysicalDevice] -> m Vulkan.VkPhysicalDevice
peekPhysicalDevice = pure . head

surfaceExtent :: MonadIO m => Vulkan.VkPhysicalDevice -> Vulkan.VkSurfaceKHR -> m Vulkan.VkExtent2D
surfaceExtent pdev surface = do
  caps <- liftIO $ allocaAndPeek (Vulkan.vkGetPhysicalDeviceSurfaceCapabilitiesKHR pdev surface)
  let
    currentExtent = Vulkan.getField @"currentExtent" caps
  pure currentExtent
