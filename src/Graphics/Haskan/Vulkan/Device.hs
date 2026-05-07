module Graphics.Haskan.Vulkan.Device where

import Control.Monad (filterM)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Bits ((.&.))
import Data.List (nub)
import Graphics.Haskan.Resources (alloc, allocaAndPeek, allocaAndPeek_, peekVkList_)
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Ext qualified as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, setListRef, setStrListRef, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan

managedRenderDevice :: MonadManaged m => Vulkan.VkPhysicalDevice -> Vulkan.VkSurfaceKHR -> [String] -> m (Vulkan.VkDevice, (Int, Int))
managedRenderDevice pdev surface layers =
  alloc
    "Vulkan Render Device"
    (createRenderDevice pdev surface layers)
    (\(ptr, _) -> Vulkan.vkDestroyDevice ptr Vulkan.vkNullPtr)

createRenderDevice :: MonadIO m => Vulkan.VkPhysicalDevice -> Vulkan.VkSurfaceKHR -> [String] -> m (Vulkan.VkDevice, (Int, Int))
createRenderDevice pdev surface layers = do
  queueFamilies <- liftIO $ zip [0 ..] <$> peekVkList_ (Vulkan.vkGetPhysicalDeviceQueueFamilyProperties pdev)

  presentQueueFamilies <-
    filterM
      ( \(i, _) -> do
          presentSupported <- liftIO $ allocaAndPeek (Vulkan.vkGetPhysicalDeviceSurfaceSupportKHR pdev (fromIntegral i) surface)
          pure (presentSupported == Vulkan.VK_TRUE)
      )
      queueFamilies

  let graphicsQueueFamilies =
        filter
          ( \(_, p) -> (Vulkan.getField @"queueFlags" p) .&. Vulkan.VK_QUEUE_GRAPHICS_BIT /= Vulkan.VK_ZERO_FLAGS
          )
          queueFamilies

      queueFamilyIndices = case (graphicsQueueFamilies, presentQueueFamilies) of
        ([], _) -> fail "Cannot find Graphics queue family"
        (_, []) -> fail "Cannot find queue family with Presentation support"
        (g:_, p:_) -> nub [fst g, fst p]
  device <- createDevice pdev queueFamilyIndices layers
  let (graphicsQueueFamilyIndex, presentQueueFamilyIndex) = case queueFamilyIndices of
        [g] -> (g, g)
        [g, p] -> (g, p)
        (g:p:_) -> (g, p)
        [] -> error "unreachable: queueFamilyIndices is non-empty"
  pure (device, (graphicsQueueFamilyIndex, presentQueueFamilyIndex))

createDevice :: MonadIO m => Vulkan.VkPhysicalDevice -> [Int] -> [String] -> m Vulkan.VkDevice
createDevice dev queueFamilyIndices enabledLayers = do
  availableFeatures <- liftIO $ allocaAndPeek_ (Vulkan.vkGetPhysicalDeviceFeatures dev)
  let geometrySupported = Vulkan.getField @"geometryShader" availableFeatures == Vulkan.VK_TRUE
      deviceFlags = Vulkan.VK_ZERO_FLAGS
      queueFlags = Vulkan.VK_ZERO_FLAGS
      enabledExtensions = [Vulkan.VK_KHR_SWAPCHAIN_EXTENSION_NAME]
      enabledFeatures = Vulkan.createVk (set @"geometryShader" (if geometrySupported then Vulkan.VK_TRUE else Vulkan.VK_FALSE))
      queueCreateInfos :: [Vulkan.VkDeviceQueueCreateInfo]
      queueCreateInfos =
        map
          ( \i ->
              Vulkan.createVk
                ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
                    &* set @"pNext" Vulkan.VK_NULL
                    &* set @"flags" queueFlags
                    &* set @"queueFamilyIndex" (fromIntegral i)
                    &* set @"queueCount" 1
                    &* setListRef @"pQueuePriorities" [1.0]
                )
          )
          queueFamilyIndices
      createInfo featuresPtr =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" deviceFlags
              &* set @"queueCreateInfoCount" (fromIntegral (length queueCreateInfos))
              &* setListRef @"pQueueCreateInfos" queueCreateInfos
              &* set @"enabledLayerCount" (fromIntegral (length enabledLayers))
              &* setStrListRef @"ppEnabledLayerNames" enabledLayers
              &* set @"enabledExtensionCount" (fromIntegral (length enabledExtensions))
              &* setListRef @"ppEnabledExtensionNames" enabledExtensions
              &* set @"pEnabledFeatures" featuresPtr
          )
  liftIO $ withPtr enabledFeatures $ \featPtr ->
    withPtr (createInfo featPtr) $ \ciPtr ->
      allocaAndPeek (Vulkan.vkCreateDevice dev ciPtr Vulkan.vkNullPtr)

getDeviceQueueHandler ::
  MonadIO m =>
  Vulkan.VkDevice ->
  -- | | queueFamilyIndex
  Int ->
  -- | | queueIndex
  Int ->
  m Vulkan.VkQueue
getDeviceQueueHandler dev qfi qi = liftIO $ allocaAndPeek_ (Vulkan.vkGetDeviceQueue dev (fromIntegral qfi) (fromIntegral qi))
