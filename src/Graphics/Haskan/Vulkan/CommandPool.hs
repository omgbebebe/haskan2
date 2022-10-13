module Graphics.Haskan.Vulkan.CommandPool where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Graphics.Haskan.Resources (alloc, allocaAndPeek)
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan

managedCommandPool ::
  MonadManaged m =>
  Vulkan.VkDevice ->
  Int ->
  m Vulkan.VkCommandPool
managedCommandPool dev qfi =
  alloc
    "Command pool"
    (createCommandPool dev qfi)
    (\ptr -> Vulkan.vkDestroyCommandPool dev ptr Vulkan.vkNullPtr)

createCommandPool ::
  MonadIO m =>
  Vulkan.VkDevice ->
  Int ->
  m Vulkan.VkCommandPool
createCommandPool dev queueFamilyIndex = do
  let commandPoolCI =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"queueFamilyIndex" (fromIntegral queueFamilyIndex)
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
          )
  liftIO $
    withPtr
      commandPoolCI
      ( \ciPtr -> allocaAndPeek (Vulkan.vkCreateCommandPool dev ciPtr Vulkan.VK_NULL)
      )
