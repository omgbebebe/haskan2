module Graphics.Haskan.Vulkan.Device where

-- base
import Control.Monad (filterM)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Bits ((.&.))
-- managed
import Control.Monad.Managed (MonadManaged)

-- vulkan-api
import qualified Graphics.Vulkan as Vulkan
import qualified Graphics.Vulkan.Core_1_0 as Vulkan
import qualified Graphics.Vulkan.Ext as Vulkan
import qualified Graphics.Vulkan.Marshal.Create as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, setListRef, setStrListRef, (&*))

-- haskan
import Graphics.Haskan.Resources (alloc, allocaAndPeek, allocaAndPeek_, peekVkList_)

managedRenderDevice :: MonadManaged m => Vulkan.VkPhysicalDevice -> Vulkan.VkSurfaceKHR -> [String] -> m (Vulkan.VkDevice, (Int,Int))
managedRenderDevice pdev surface layers = alloc "Vulkan Render Device"
  (createRenderDevice pdev surface layers)
  (\(ptr,_) -> Vulkan.vkDestroyDevice ptr Vulkan.vkNullPtr)

createRenderDevice :: MonadIO m => Vulkan.VkPhysicalDevice -> Vulkan.VkSurfaceKHR -> [String] -> m (Vulkan.VkDevice, (Int,Int))
createRenderDevice pdev surface layers = do
  queueFamilies <- liftIO $ zip [0..] <$> peekVkList_ (Vulkan.vkGetPhysicalDeviceQueueFamilyProperties pdev)

  presentQueueFamilies <- filterM (
    \(i,_) -> do
      presentSupported <- liftIO $ allocaAndPeek (Vulkan.vkGetPhysicalDeviceSurfaceSupportKHR pdev (fromIntegral i) surface)
      pure (presentSupported == Vulkan.VK_TRUE)
    ) queueFamilies

  let
    graphicsQueueFamilies =
      filter (\(_,p) -> (Vulkan.getField @"queueFlags" p) .&. Vulkan.VK_QUEUE_GRAPHICS_BIT /= Vulkan.VK_ZERO_FLAGS
             ) queueFamilies

    queueFamilyIndices =
      if null graphicsQueueFamilies
      then fail "Cannot find Graphics queue family"
      else
        if null presentQueueFamilies
        then fail "Cannot find queue family with Presentation support"
        else map fst [head graphicsQueueFamilies, head presentQueueFamilies] -- TODO: more clever selection needed
  device <- createDevice pdev queueFamilyIndices layers
  let (graphicsQueueFamilyIndex:presentQueueFamilyIndex:[]) = queueFamilyIndices
  pure (device, (graphicsQueueFamilyIndex,presentQueueFamilyIndex))

createDevice :: MonadIO m => Vulkan.VkPhysicalDevice -> [Int] -> [String] -> m Vulkan.VkDevice
createDevice dev queueFamilyIndices enabledLayers = do
  let
    deviceFlags = Vulkan.VK_ZERO_FLAGS
    queueFlags = Vulkan.VK_ZERO_FLAGS
    enabledExtensions = [Vulkan.VK_KHR_SWAPCHAIN_EXTENSION_NAME, Vulkan.VK_KHR_SWAPCHAIN_EXTENSION_NAME]
    enabledFeatures = Vulkan.VK_NULL
    queueCreateInfos :: [Vulkan.VkDeviceQueueCreateInfo]
    queueCreateInfos = map (
      \i -> Vulkan.createVk
              (  set @"sType" Vulkan.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" queueFlags
              &* set @"queueFamilyIndex" (fromIntegral i)
              &* set @"queueCount" 1
              &* setListRef @"pQueuePriorities" [1.0]
              )
      ) queueFamilyIndices
    createInfo = Vulkan.createVk
      (  set        @"sType" Vulkan.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
      &* set        @"pNext" Vulkan.VK_NULL
      &* set        @"flags" deviceFlags
      &* set        @"queueCreateInfoCount" (fromIntegral (length queueCreateInfos))
      &* setListRef @"pQueueCreateInfos" queueCreateInfos
      &* set        @"enabledLayerCount" (fromIntegral (length enabledLayers))
      &* setStrListRef @"ppEnabledLayerNames" enabledLayers
      &* set        @"enabledExtensionCount" (fromIntegral (length enabledExtensions))
      &* setListRef @"ppEnabledExtensionNames" enabledExtensions
      &* set        @"pEnabledFeatures" enabledFeatures
      )
    in liftIO $ withPtr createInfo (\ciPtr -> allocaAndPeek ( Vulkan.vkCreateDevice dev ciPtr Vulkan.vkNullPtr ))

getDeviceQueueHandler
  :: MonadIO m
  => Vulkan.VkDevice
  -> Int -- ^| queueFamilyIndex
  -> Int -- ^| queueIndex
  -> m Vulkan.VkQueue
getDeviceQueueHandler dev qfi qi = liftIO $ allocaAndPeek_ (Vulkan.vkGetDeviceQueue dev (fromIntegral qfi) (fromIntegral qi))
