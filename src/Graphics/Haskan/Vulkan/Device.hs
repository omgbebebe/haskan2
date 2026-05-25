{-# LANGUAGE DataKinds, DuplicateRecordFields #-}
module Graphics.Haskan.Vulkan.Device where

import Control.Monad (filterM)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Bits (shiftR, (.&.))
import Data.ByteString.Char8 qualified as BS8
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Data.Word (Word32)
import Graphics.Haskan.Logger (LogCategory (..), logInfoIO, showT)
import Graphics.Haskan.Resources (alloc)
import Numeric (showHex)
import System.IO.Unsafe (unsafePerformIO)
import Vulkan qualified as Vk26
import Vulkan.CStruct.Extends (SomeStruct(..))
import Vulkan.Core10.DeviceInitialization (PhysicalDeviceProperties(..), PhysicalDeviceFeatures(..), QueueFamilyProperties(..))
import Vulkan.Core12.Promoted_From_VK_EXT_descriptor_indexing (PhysicalDeviceDescriptorIndexingFeatures(..))
import Vulkan.Zero (zero)

vkExtMeshShaderExtensionName :: BS8.ByteString
vkExtMeshShaderExtensionName = BS8.pack "VK_EXT_mesh_shader"

managedRenderDevice :: (MonadManaged m) => Vk26.PhysicalDevice -> Vk26.SurfaceKHR -> [String] -> Bool -> m (Vk26.Device, (Int, Int))
managedRenderDevice pdev surface layers enableMeshShader =
  alloc
    "Vulkan Render Device"
    (createRenderDevice pdev surface layers enableMeshShader)
    (\(ptr, _) -> Vk26.destroyDevice ptr Nothing)

createRenderDevice :: (MonadIO m) => Vk26.PhysicalDevice -> Vk26.SurfaceKHR -> [String] -> Bool -> m (Vk26.Device, (Int, Int))
createRenderDevice pdev surface layers enableMeshShader = do
  queueFamilies <- liftIO $ zip [0 ..] . Vector.toList <$> Vk26.getPhysicalDeviceQueueFamilyProperties pdev

  presentQueueFamilies <-
    filterM
      ( \(i, _) -> do
          presentSupported <- liftIO $ Vk26.getPhysicalDeviceSurfaceSupportKHR pdev (fromIntegral i) surface
          pure presentSupported
      )
      queueFamilies

  let graphicsQueueFamilies =
        filter
          (\(_, p) -> queueFlags p .&. Vk26.QUEUE_GRAPHICS_BIT /= zero)
          queueFamilies

      queueFamilyIndices = case (graphicsQueueFamilies, presentQueueFamilies) of
        ([], _) -> fail "Cannot find Graphics queue family"
        (_, []) -> fail "Cannot find queue family with Presentation support"
        (g : _, p : _) -> nub [fst g, fst p]
  device <- createDevice pdev queueFamilyIndices layers enableMeshShader
  let (graphicsQueueFamilyIndex, presentQueueFamilyIndex) = case queueFamilyIndices of
        [g] -> (g, g)
        [g, p] -> (g, p)
        (g : p : _) -> (g, p)
        [] -> error "unreachable: queueFamilyIndices is non-empty"
  pure (device, (graphicsQueueFamilyIndex, presentQueueFamilyIndex))

createDevice :: (MonadIO m) => Vk26.PhysicalDevice -> [Int] -> [String] -> Bool -> m Vk26.Device
createDevice dev queueFamilyIndices enabledLayers enableMeshShader = do
  props <- liftIO $ Vk26.getPhysicalDeviceProperties dev
  let apiVersionWord = fromIntegral (apiVersion props) :: Word32
      majorVersion = fromIntegral ((apiVersionWord `shiftR` 22) .&. (0x7F :: Word32)) :: Int
      minorVersion = fromIntegral ((apiVersionWord `shiftR` 12) .&. (0x3FF :: Word32)) :: Int
      patchVersion = fromIntegral (apiVersionWord .&. (0xFFF :: Word32)) :: Int
  logInfoIO LogVulkan $ "Vulkan API version raw: " <> showT (apiVersion props) <> " hex: 0x" <> Text.pack (showHex apiVersionWord "")
  logInfoIO LogVulkan $ "Vulkan API version: " <> showT majorVersion <> "." <> showT minorVersion <> "." <> showT patchVersion

  availableFeatures <- liftIO $ Vk26.getPhysicalDeviceFeatures dev
  let geometrySupported = geometryShader availableFeatures
      cullDistanceSupported = shaderCullDistance availableFeatures
      vertexStorageSupported = vertexPipelineStoresAndAtomics availableFeatures
      fragmentStorageSupported = fragmentStoresAndAtomics availableFeatures
      multiDrawIndirectSupported = multiDrawIndirect availableFeatures

  descriptorIndexingSupported <-
    if majorVersion >= 1 && minorVersion >= 2
      then liftIO $ do
        features2 <- Vk26.getPhysicalDeviceFeatures2 dev :: IO (Vk26.PhysicalDeviceFeatures2 '[Vk26.PhysicalDeviceDescriptorIndexingFeatures])
        let Vk26.PhysicalDeviceFeatures2 (diFeaturesQuery, ()) _ = features2
            nonUniform = shaderSampledImageArrayNonUniformIndexing diFeaturesQuery
            updateAfterBind = descriptorBindingSampledImageUpdateAfterBind diFeaturesQuery
            partiallyBound = descriptorBindingPartiallyBound diFeaturesQuery
            runtimeArray = runtimeDescriptorArray diFeaturesQuery
        logInfoIO LogVulkan $
          "Descriptor indexing capabilities: nonUniform="
            <> showT nonUniform
            <> " updateAfterBind="
            <> showT updateAfterBind
            <> " partiallyBound="
            <> showT partiallyBound
            <> " runtimeArray="
            <> showT runtimeArray
        pure (nonUniform && updateAfterBind && partiallyBound && runtimeArray)
      else do
        logInfoIO LogVulkan "Descriptor indexing requires Vulkan 1.2+, skipping"
        pure False

  let deviceFlags = zero
      queueFlags = zero
      meshShaderExtension = if enableMeshShader then [vkExtMeshShaderExtensionName] else []
      enabledExtensions = Vector.fromList $ Vk26.KHR_SWAPCHAIN_EXTENSION_NAME : meshShaderExtension
      enabledBasicFeatures =
        (zero :: Vk26.PhysicalDeviceFeatures)
          { geometryShader = geometrySupported
          , shaderCullDistance = cullDistanceSupported
          , vertexPipelineStoresAndAtomics = vertexStorageSupported
          , fragmentStoresAndAtomics = fragmentStorageSupported
          , multiDrawIndirect = multiDrawIndirectSupported
          }
      queueCreateInfos =
        map
          ( \i ->
              SomeStruct
                ( Vk26.DeviceQueueCreateInfo
                    { next = ()
                    , flags = queueFlags
                    , queueFamilyIndex = fromIntegral i
                    , queuePriorities = Vector.fromList [1.0]
                    }
                )
          )
          queueFamilyIndices

  liftIO $ do
    case descriptorIndexingSupported of
      False -> do
        let createInfo =
              Vk26.DeviceCreateInfo
                { next = ()
                , flags = deviceFlags
                , queueCreateInfos = Vector.fromList queueCreateInfos
                , enabledLayerNames = Vector.fromList $ map BS8.pack enabledLayers
                , enabledExtensionNames = enabledExtensions
                , enabledFeatures = Just enabledBasicFeatures
                }
        Vk26.createDevice dev createInfo Nothing
      True -> do
        let diFeatures =
              (zero :: Vk26.PhysicalDeviceDescriptorIndexingFeatures)
                { shaderSampledImageArrayNonUniformIndexing = True
                , descriptorBindingSampledImageUpdateAfterBind = True
                , descriptorBindingPartiallyBound = True
                , runtimeDescriptorArray = True
                }
            createInfo =
              Vk26.DeviceCreateInfo
                { next = (diFeatures, ())
                , flags = deviceFlags
                , queueCreateInfos = Vector.fromList queueCreateInfos
                , enabledLayerNames = Vector.fromList $ map BS8.pack enabledLayers
                , enabledExtensionNames = enabledExtensions
                , enabledFeatures = Just enabledBasicFeatures
                }
        Vk26.createDevice dev createInfo Nothing

getDeviceQueueHandler ::
  (MonadIO m) =>
  Vk26.Device ->
  -- | queueFamilyIndex
  Int ->
  -- | queueIndex
  Int ->
  m Vk26.Queue
getDeviceQueueHandler dev qfi qi = liftIO $ Vk26.getDeviceQueue dev (fromIntegral qfi) (fromIntegral qi)
