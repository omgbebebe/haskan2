module Graphics.Haskan.Vulkan.Instance where

-- base
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Foldable (for_)
import Data.List (partition)

-- byetstring
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC

-- managed
import Control.Monad.Managed (MonadManaged)

-- say
import Say

-- text
import Data.Text (Text)
import qualified Data.Text as T

-- vulkan-api
import qualified Graphics.Vulkan as Vulkan
import qualified Graphics.Vulkan.Ext as Vulkan

-- vulkan-api
import qualified Graphics.Vulkan.Core_1_0 as Vulkan
import qualified Graphics.Vulkan.Marshal.Create as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, setStrListRef, setVkRef, (&*))

-- haskan
import Graphics.Haskan.Resources (alloc, allocaAndPeek, peekVkList)

managedInstance :: MonadManaged m => [ByteString] -> m (Vulkan.VkInstance, [String])
managedInstance extraExtensions = alloc "VkInstance"
  (createInstance extraExtensions)
  (\(ptr,_) -> Vulkan.vkDestroyInstance ptr Vulkan.vkNullPtr)

createInstance :: MonadIO m => [ByteString] -> m (Vulkan.VkInstance, [String])
createInstance extraExtensions = do
  let
    partitionOptReq :: (Show a, Eq a, MonadIO m) => Text -> [a] -> [a] -> [a] -> m [a]
    partitionOptReq type' available optional required = do
      let
        (optHave, optMissing) = partition (`elem` available) optional
        (reqHave, reqMissing) = partition (`elem` available) required
        tShow = T.pack . show
      for_ optMissing
        (\n -> sayErr ("Missing optional " <> type' <> ": " <> tShow n))
      for_ reqMissing
        (\n -> sayErr ("Missing required " <> type' <> ": " <> tShow n))
      pure (reqHave <> optHave)

  availableExtensions <-
    fmap (BC.pack . Vulkan.getStringField @"extensionName")
    <$> peekVkList (Vulkan.vkEnumerateInstanceExtensionProperties Vulkan.vkNullPtr)
  availableLayers <-
    fmap (BC.pack . Vulkan.getStringField @"layerName")
    <$> peekVkList (Vulkan.vkEnumerateInstanceLayerProperties)

  reqExtensions <- liftIO $ BC.packCString Vulkan.VK_EXT_DEBUG_UTILS_EXTENSION_NAME

  extensions <- fmap BC.unpack <$>
    partitionOptReq
      "extension"
      availableExtensions
      ["VK_EXT_validation_features"]
      (reqExtensions : extraExtensions)

  layers <- fmap BC.unpack <$>
    partitionOptReq
      "layer"
      availableLayers
      ["VK_LAYER_KHRONOS_validation"]
      []

  let
    appInfo = Vulkan.createVk
      (  set @"sType" Vulkan.VK_STRUCTURE_TYPE_APPLICATION_INFO
      &* set @"pNext" Vulkan.VK_NULL
      &* set @"pApplicationName" (Vulkan.VK_NULL)
      &* set @"pEngineName" (Vulkan.VK_NULL)
      &* set @"applicationVersion" (Vulkan._VK_MAKE_VERSION 1 0 0)
      &* set @"engineVersion" (Vulkan._VK_MAKE_VERSION 1 0 0)
      &* set @"apiVersion" (Vulkan._VK_MAKE_VERSION 1 0 68)
      )

    instanceInfo = Vulkan.createVk
      (  set @"sType" Vulkan.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
      &* set @"pNext" Vulkan.VK_NULL
      &* setVkRef @"pApplicationInfo" appInfo
      &* set @"enabledExtensionCount" (fromIntegral (length extensions) )
      &* setStrListRef @"ppEnabledExtensionNames" extensions
      &* set @"enabledLayerCount" (fromIntegral (length layers))
      &* setStrListRef @"ppEnabledLayerNames" (layers)
      )

  inst <- liftIO $ withPtr instanceInfo (\iiPtr -> allocaAndPeek (Vulkan.vkCreateInstance iiPtr Vulkan.VK_NULL_HANDLE))
  pure (inst, layers)
