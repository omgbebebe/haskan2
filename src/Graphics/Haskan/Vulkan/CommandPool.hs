module Graphics.Haskan.Vulkan.CommandPool where

-- base
import Control.Monad.IO.Class (MonadIO, liftIO)

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

managedCommandPool
  :: MonadManaged m
  => Vulkan.VkDevice
  -> Int
  -> m Vulkan.VkCommandPool
managedCommandPool dev qfi = alloc "Command pool"
  (createCommandPool dev qfi)
  (\ptr -> Vulkan.vkDestroyCommandPool dev ptr Vulkan.vkNullPtr)

createCommandPool
  :: MonadIO m
  => Vulkan.VkDevice
  -> Int
  -> m Vulkan.VkCommandPool
createCommandPool dev queueFamilyIndex = do
  let
    commandPoolCI = Vulkan.createVk
      (  set @"sType" Vulkan.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
      &* set @"pNext" Vulkan.VK_NULL
      &* set @"queueFamilyIndex" (fromIntegral queueFamilyIndex)
      &* set @"flags" Vulkan.VK_ZERO_FLAGS
      )
  liftIO $ withPtr commandPoolCI
      (\ciPtr -> allocaAndPeek (Vulkan.vkCreateCommandPool dev ciPtr Vulkan.VK_NULL)
    )
