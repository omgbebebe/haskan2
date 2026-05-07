module Graphics.Haskan.Vulkan.DeviceCapabilities where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Graphics.Haskan.Resources (allocaAndPeek_)
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan

-- | Detected device capabilities relevant to advanced shader stages.
data DeviceCapabilities = DeviceCapabilities
  { dcGeometryShader :: !Bool
  , dcTessellationShader :: !Bool
  , dcMeshShader :: !Bool
  }
  deriving (Show)

-- | Query physical device features.
queryDeviceCapabilities :: MonadIO m => Vulkan.VkPhysicalDevice -> m DeviceCapabilities
queryDeviceCapabilities pdev = liftIO $ do
  features <- allocaAndPeek_ (Vulkan.vkGetPhysicalDeviceFeatures pdev)
  let geometry = Vulkan.getField @"geometryShader" features == Vulkan.VK_TRUE
      tessellation = Vulkan.getField @"tessellationShader" features == Vulkan.VK_TRUE
      -- Mesh shader requires VK_EXT_mesh_shader extension; we'll check that separately
      mesh = False  -- TODO: check VK_EXT_mesh_shader extension
  pure DeviceCapabilities
    { dcGeometryShader = geometry
    , dcTessellationShader = tessellation
    , dcMeshShader = mesh
    }
