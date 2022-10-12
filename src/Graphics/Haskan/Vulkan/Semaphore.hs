module Graphics.Haskan.Vulkan.Semaphore where

-- base
import Control.Monad.IO.Class (MonadIO, liftIO)

-- managed
import Control.Monad.Managed (MonadManaged)

-- vulkan-api
import qualified Graphics.Vulkan as Vulkan
import qualified Graphics.Vulkan.Core_1_0 as Vulkan
import qualified Graphics.Vulkan.Marshal.Create as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, (&*))

-- haskan
import Graphics.Haskan.Resources (alloc, allocaAndPeek)

managedSemaphore :: MonadManaged m => Vulkan.VkDevice -> m Vulkan.VkSemaphore
managedSemaphore dev = alloc "Vulkan Semaphore"
  (createSemaphore dev)
  (\ptr -> Vulkan.vkDestroySemaphore dev ptr Vulkan.vkNullPtr)

createSemaphore :: MonadIO m => Vulkan.VkDevice -> m Vulkan.VkSemaphore
createSemaphore dev =
  let
    createInfo = Vulkan.createVk
        (  set @"sType" Vulkan.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
        &* set @"pNext" Vulkan.vkNullPtr
        )
  in liftIO $ withPtr createInfo
     (\ciPtr ->
         allocaAndPeek (Vulkan.vkCreateSemaphore dev ciPtr Vulkan.VK_NULL)
     )
