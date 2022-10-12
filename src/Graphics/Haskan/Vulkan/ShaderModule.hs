module Graphics.Haskan.Vulkan.ShaderModule where

-- base
import Control.Monad.IO.Class (MonadIO, liftIO)
import qualified Data.ByteString.Char8 as BC
import qualified Foreign.Ptr
 
-- managed
import Control.Monad.Managed (MonadManaged)

-- vulkan-api
import qualified Graphics.Vulkan as Vulkan
import qualified Graphics.Vulkan.Core_1_0 as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import qualified Graphics.Vulkan.Marshal.Create as Vulkan
import Graphics.Vulkan.Marshal.Create (set, (&*))

-- haskan
import Graphics.Haskan.Resources (alloc, allocaAndPeek)

managedShaderModule :: MonadManaged m => Vulkan.VkDevice -> FilePath -> m Vulkan.VkShaderModule
managedShaderModule dev path = alloc "ShaderModule"
  (createShaderModule dev path)
  (\ptr -> Vulkan.vkDestroyShaderModule dev ptr Vulkan.vkNullPtr)
 
createShaderModule :: MonadIO m => Vulkan.VkDevice -> FilePath -> m Vulkan.VkShaderModule
createShaderModule dev path = liftIO $ do
  bytes <- BC.readFile path
  BC.useAsCStringLen bytes $ \(bytesPtr, len) ->
    let
      createInfo = Vulkan.createVk
        (  set @"sType" Vulkan.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
        &* set @"pNext" Vulkan.VK_NULL
        &* set @"flags" Vulkan.VK_ZERO_FLAGS
        &* set @"codeSize" (fromIntegral len)
        &* set @"pCode" (Foreign.Ptr.castPtr bytesPtr)
        )
    in liftIO $ withPtr createInfo (\ciPtr -> allocaAndPeek (Vulkan.vkCreateShaderModule dev ciPtr Vulkan.VK_NULL))
