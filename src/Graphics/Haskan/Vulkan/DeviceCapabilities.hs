module Graphics.Haskan.Vulkan.DeviceCapabilities where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.ByteString.Char8 qualified as BS8
import Data.Foldable (find)
import Graphics.Haskan.Resources (allocaAndPeek_)
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan

-- vulkan package
import Vulkan.Core10.ExtensionDiscovery qualified as Vk
import Vulkan.Zero qualified as Vk

import Graphics.Haskan.Vulkan.Interop (toVulkanPhysicalDevice)

-- | Detected device capabilities relevant to advanced shader stages.
data DeviceCapabilities = DeviceCapabilities
  { dcGeometryShader :: !Bool,
    dcTessellationShader :: !Bool,
    dcMeshShader :: !Bool
  }
  deriving (Show)

-- | Query physical device features.
queryDeviceCapabilities :: (MonadIO m) => Vulkan.VkPhysicalDevice -> m DeviceCapabilities
queryDeviceCapabilities pdev = liftIO $ do
  features <- allocaAndPeek_ (Vulkan.vkGetPhysicalDeviceFeatures pdev)
  let geometry = Vulkan.getField @"geometryShader" features == Vulkan.VK_TRUE
      tessellation = Vulkan.getField @"tessellationShader" features == Vulkan.VK_TRUE
  -- Check for VK_EXT_mesh_shader extension using vulkan package
  (_, extensions) <- Vk.enumerateDeviceExtensionProperties (toVulkanPhysicalDevice pdev) Nothing
  let mesh = any (\ext -> Vk.extensionName ext == "VK_EXT_mesh_shader") extensions
  pure
    DeviceCapabilities
      { dcGeometryShader = geometry,
        dcTessellationShader = tessellation,
        dcMeshShader = mesh
      }