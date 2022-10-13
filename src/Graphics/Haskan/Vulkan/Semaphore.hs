module Graphics.Haskan.Vulkan.Semaphore where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Graphics.Haskan.Resources (alloc, allocaAndPeek)
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan

managedSemaphore :: MonadManaged m => Vulkan.VkDevice -> m Vulkan.VkSemaphore
managedSemaphore dev =
  alloc
    "Vulkan Semaphore"
    (createSemaphore dev)
    (\ptr -> Vulkan.vkDestroySemaphore dev ptr Vulkan.vkNullPtr)

createSemaphore :: MonadIO m => Vulkan.VkDevice -> m Vulkan.VkSemaphore
createSemaphore dev =
  let createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
              &* set @"pNext" Vulkan.vkNullPtr
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateSemaphore dev ciPtr Vulkan.VK_NULL)
          )
