module Graphics.Haskan.Vulkan.Device where

import Control.Monad (filterM, when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Bits (shiftR, (.&.))
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word32)
import Foreign (castPtr, nullPtr)
import Graphics.Haskan.Logger (logInfoIO, showT, LogCategory(..))
import Graphics.Haskan.Resources (alloc, allocaAndPeek, allocaAndPeek_, peekVkList_)
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Core_1_1 qualified as Vulkan11
import Graphics.Vulkan.Core_1_2 qualified as Vulkan12
import Graphics.Vulkan.Ext qualified as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, setListRef, setStrListRef, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan
import Numeric (showHex)

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
  -- Query physical device properties to check Vulkan version
  props <- liftIO $ allocaAndPeek_ (Vulkan.vkGetPhysicalDeviceProperties dev)
  let apiVersion = Vulkan.getField @"apiVersion" props
      apiVersionWord = fromIntegral apiVersion :: Word32
      majorVersion = fromIntegral ((apiVersionWord `shiftR` 22) .&. (0x7F :: Word32)) :: Int
      minorVersion = fromIntegral ((apiVersionWord `shiftR` 12) .&. (0x3FF :: Word32)) :: Int
      patchVersion = fromIntegral (apiVersionWord .&. (0xFFF :: Word32)) :: Int
  logInfoIO LogVulkan $ "Vulkan API version raw: " <> showT apiVersion <> " hex: 0x" <> Text.pack (showHex apiVersionWord "")
  logInfoIO LogVulkan $ "Vulkan API version: " <> showT majorVersion <> "." <> showT minorVersion <> "." <> showT patchVersion

  -- Query basic features
  availableFeatures <- liftIO $ allocaAndPeek_ (Vulkan.vkGetPhysicalDeviceFeatures dev)
  let geometrySupported = Vulkan.getField @"geometryShader" availableFeatures == Vulkan.VK_TRUE
      cullDistanceSupported = Vulkan.getField @"shaderCullDistance" availableFeatures == Vulkan.VK_TRUE
      vertexStorageSupported = Vulkan.getField @"vertexPipelineStoresAndAtomics" availableFeatures == Vulkan.VK_TRUE
      multiDrawIndirectSupported = Vulkan.getField @"multiDrawIndirect" availableFeatures == Vulkan.VK_TRUE

  -- Check descriptor indexing support (requires Vulkan 1.2+)
  descriptorIndexingSupported <- if majorVersion >= 1 && minorVersion >= 2
    then liftIO $ do
      let diFeaturesQuery :: Vulkan12.VkPhysicalDeviceDescriptorIndexingFeatures
          diFeaturesQuery = Vulkan.createVk
            ( set @"sType" Vulkan12.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES
                &* set @"pNext" Vulkan.VK_NULL
            )
          features2Query :: Vulkan11.VkPhysicalDeviceFeatures2
          features2Query = Vulkan.createVk
            ( set @"sType" Vulkan11.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2
                &* set @"pNext" (castPtr $ Vulkan.unsafePtr diFeaturesQuery)
                &* set @"features" availableFeatures
            )
      withPtr features2Query $ \f2Ptr -> Vulkan11.vkGetPhysicalDeviceFeatures2 dev f2Ptr
      let nonUniform = Vulkan.getField @"shaderSampledImageArrayNonUniformIndexing" diFeaturesQuery == Vulkan.VK_TRUE
          updateAfterBind = Vulkan.getField @"descriptorBindingSampledImageUpdateAfterBind" diFeaturesQuery == Vulkan.VK_TRUE
          partiallyBound = Vulkan.getField @"descriptorBindingPartiallyBound" diFeaturesQuery == Vulkan.VK_TRUE
          runtimeArray = Vulkan.getField @"runtimeDescriptorArray" diFeaturesQuery == Vulkan.VK_TRUE
      logInfoIO LogVulkan $ "Descriptor indexing capabilities: nonUniform=" <> showT nonUniform
        <> " updateAfterBind=" <> showT updateAfterBind
        <> " partiallyBound=" <> showT partiallyBound
        <> " runtimeArray=" <> showT runtimeArray
      pure (nonUniform && updateAfterBind && partiallyBound && runtimeArray)
    else do
      logInfoIO LogVulkan "Descriptor indexing requires Vulkan 1.2+, skipping"
      pure False

  let deviceFlags = Vulkan.VK_ZERO_FLAGS
      queueFlags = Vulkan.VK_ZERO_FLAGS
      enabledExtensions = [Vulkan.VK_KHR_SWAPCHAIN_EXTENSION_NAME]
      enabledBasicFeatures = Vulkan.createVk
        (set @"geometryShader" (if geometrySupported then Vulkan.VK_TRUE else Vulkan.VK_FALSE)
            &* set @"shaderCullDistance" (if cullDistanceSupported then Vulkan.VK_TRUE else Vulkan.VK_FALSE)
            &* set @"vertexPipelineStoresAndAtomics" (if vertexStorageSupported then Vulkan.VK_TRUE else Vulkan.VK_FALSE)
            &* set @"multiDrawIndirect" (if multiDrawIndirectSupported then Vulkan.VK_TRUE else Vulkan.VK_FALSE))
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

  -- Build device create info with feature chain
  liftIO $ do
    case descriptorIndexingSupported of
      False -> do
        -- No descriptor indexing: use legacy pEnabledFeatures path
        withPtr enabledBasicFeatures $ \featPtr -> do
          let createInfo =
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
                      &* set @"pEnabledFeatures" featPtr
                  )
          withPtr createInfo $ \ciPtr ->
            allocaAndPeek (Vulkan.vkCreateDevice dev ciPtr Vulkan.vkNullPtr)
      True -> do
        -- Descriptor indexing: chain VkPhysicalDeviceFeatures2 into VkDeviceCreateInfo
        let diFeatures :: Vulkan12.VkPhysicalDeviceDescriptorIndexingFeatures
            diFeatures = Vulkan.createVk
              ( set @"sType" Vulkan12.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES
                  &* set @"pNext" Vulkan.VK_NULL
                  &* set @"shaderSampledImageArrayNonUniformIndexing" Vulkan.VK_TRUE
                  &* set @"descriptorBindingSampledImageUpdateAfterBind" Vulkan.VK_TRUE
                  &* set @"descriptorBindingPartiallyBound" Vulkan.VK_TRUE
                  &* set @"runtimeDescriptorArray" Vulkan.VK_TRUE
              )
        withPtr diFeatures $ \diPtr -> do
          let features2 :: Vulkan11.VkPhysicalDeviceFeatures2
              features2 = Vulkan.createVk
                ( set @"sType" Vulkan11.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2
                    &* set @"pNext" (castPtr diPtr)
                    &* set @"features" enabledBasicFeatures
                )
          withPtr features2 $ \f2Ptr -> do
            let createInfo =
                  Vulkan.createVk
                    ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
                        &* set @"pNext" (castPtr f2Ptr)
                        &* set @"flags" deviceFlags
                        &* set @"queueCreateInfoCount" (fromIntegral (length queueCreateInfos))
                        &* setListRef @"pQueueCreateInfos" queueCreateInfos
                        &* set @"enabledLayerCount" (fromIntegral (length enabledLayers))
                        &* setStrListRef @"ppEnabledLayerNames" enabledLayers
                        &* set @"enabledExtensionCount" (fromIntegral (length enabledExtensions))
                        &* setListRef @"ppEnabledExtensionNames" enabledExtensions
                        &* set @"pEnabledFeatures" Vulkan.VK_NULL
                    )
            withPtr createInfo $ \ciPtr ->
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
