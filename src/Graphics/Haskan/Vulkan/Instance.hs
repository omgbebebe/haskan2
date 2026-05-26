{-# LANGUAGE DuplicateRecordFields #-}

module Graphics.Haskan.Vulkan.Instance where

import Control.Monad (unless, when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Foldable (for_)
import Data.List (partition)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Data.Vector qualified as Vector
import Graphics.Haskan.Logger (LogCategory (..), logInfoIO, logWarnIO)
import Graphics.Haskan.Resources (alloc)
import Vulkan qualified as Vk26
import Vulkan.CStruct.Extends (SomeStruct (..))
import Vulkan.Core10.DeviceInitialization (ApplicationInfo (..), InstanceCreateInfo (..))
import Vulkan.Core10.ExtensionDiscovery (ExtensionProperties (..))
import Vulkan.Core10.LayerDiscovery (LayerProperties (..))
import Vulkan.Zero (zero)

managedInstance :: (MonadManaged m) => [ByteString] -> m (Vk26.Instance, [String])
managedInstance extraExtensions =
  alloc
    "VkInstance"
    (createInstance extraExtensions)
    (\(inst, _) -> Vk26.destroyInstance inst Nothing)

createInstance :: (MonadIO m) => [ByteString] -> m (Vk26.Instance, [String])
createInstance extraExtensions = do
  let partitionOptReq :: (Show a, Eq a, MonadIO m) => Text -> [a] -> [a] -> [a] -> m [a]
      partitionOptReq type' available optional required = do
        let (optHave, optMissing) = partition (`elem` available) optional
            (reqHave, reqMissing) = partition (`elem` available) required
            tShow = T.pack . show
        for_
          optMissing
          (\n -> logWarnIO LogVulkan ("Missing optional " <> type' <> ": " <> tShow n))
        for_
          reqMissing
          (\n -> logWarnIO LogVulkan ("Missing required " <> type' <> ": " <> tShow n))
        pure (reqHave <> optHave)

  (_, extProps) <- liftIO $ Vk26.enumerateInstanceExtensionProperties Nothing
  let availableExtensions = Vector.toList $ fmap extensionName extProps
  (_, layerProps) <- liftIO $ Vk26.enumerateInstanceLayerProperties
  let availableLayers = Vector.toList $ fmap layerName layerProps

  let validationLayerNames =
        [ "VK_LAYER_KHRONOS_validation",
          "VK_LAYER_LUNARG_standard_validation"
        ]
      validationLayersAvailable =
        filter (`elem` availableLayers) validationLayerNames
      anyValidationAvailable = not (null validationLayersAvailable)

  unless anyValidationAvailable $
    logWarnIO LogVulkan "No Vulkan validation layers found (install vulkan-validation-layers for debug builds)"

  let reqExtensions = "VK_EXT_debug_utils"

  let optExtensions =
        (["VK_EXT_validation_features" | anyValidationAvailable])

  extensionsBS <-
    partitionOptReq
      "extension"
      availableExtensions
      optExtensions
      (reqExtensions : extraExtensions)

  layersBS <-
    partitionOptReq
      "layer"
      availableLayers
      validationLayerNames
      []

  let layers = fmap BC.unpack layersBS

      appInfo =
        Vk26.ApplicationInfo
          { applicationName = Nothing,
            applicationVersion = Vk26.MAKE_API_VERSION 1 0 0,
            engineName = Nothing,
            engineVersion = Vk26.MAKE_API_VERSION 1 0 0,
            apiVersion = Vk26.API_VERSION_1_2
          }

      instanceInfo =
        Vk26.InstanceCreateInfo
          { next = (),
            flags = zero,
            applicationInfo = Just appInfo,
            enabledLayerNames = Vector.fromList layersBS,
            enabledExtensionNames = Vector.fromList extensionsBS
          }

  inst <- liftIO $ Vk26.createInstance instanceInfo Nothing
  pure (inst, layers)
