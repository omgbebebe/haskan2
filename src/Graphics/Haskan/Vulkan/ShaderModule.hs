module Graphics.Haskan.Vulkan.ShaderModule where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.ByteString.Char8 qualified as BC
import Foreign.Ptr qualified
import Graphics.Haskan.Resources (alloc, allocaAndPeek)
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan

managedShaderModule :: (MonadManaged m) => Vulkan.VkDevice -> FilePath -> m Vulkan.VkShaderModule
managedShaderModule dev path =
  alloc
    "ShaderModule"
    (createShaderModule dev path)
    (\ptr -> Vulkan.vkDestroyShaderModule dev ptr Vulkan.vkNullPtr)

createShaderModule :: (MonadIO m) => Vulkan.VkDevice -> FilePath -> m Vulkan.VkShaderModule
createShaderModule dev path = liftIO $ do
  bytes <- BC.readFile path
  BC.useAsCStringLen bytes $ \(bytesPtr, len) ->
    let createInfo =
          Vulkan.createVk
            ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
                &* set @"pNext" Vulkan.VK_NULL
                &* set @"flags" Vulkan.VK_ZERO_FLAGS
                &* set @"codeSize" (fromIntegral len)
                &* set @"pCode" (Foreign.Ptr.castPtr bytesPtr)
            )
     in liftIO $ withPtr createInfo (\ciPtr -> allocaAndPeek (Vulkan.vkCreateShaderModule dev ciPtr Vulkan.VK_NULL))
