module Graphics.Haskan.Vulkan.Fence where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Graphics.Haskan.Resources (alloc, allocaAndPeek)
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan

managedFence :: (MonadManaged m) => Vulkan.VkDevice -> m Vulkan.VkFence
managedFence dev =
  alloc
    "Vulkan Fence"
    (createFence dev)
    (\ptr -> Vulkan.vkDestroyFence dev ptr Vulkan.vkNullPtr)

createFence :: (MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkFence
createFence dev =
  let createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
              &* set @"pNext" Vulkan.vkNullPtr
              &* set @"flags" Vulkan.VK_FENCE_CREATE_SIGNALED_BIT
          )
   in liftIO $
        withPtr
          createInfo
          (\ciPtr -> allocaAndPeek (Vulkan.vkCreateFence dev ciPtr Vulkan.VK_NULL))
