module Graphics.Haskan.Vulkan.Framebuffer where

-- base
import Control.Monad.IO.Class (MonadIO, liftIO)

-- managed
import Control.Monad.Managed (MonadManaged)

-- vulkan-api
import qualified Graphics.Vulkan as Vulkan
import qualified Graphics.Vulkan.Core_1_0 as Vulkan
import qualified Graphics.Vulkan.Marshal.Create as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, setListRef, (&*))

-- haskan
import Graphics.Haskan.Resources (alloc, allocaAndPeek)

managedFramebuffer
  :: MonadManaged m
  => Vulkan.VkDevice
  -> Vulkan.VkRenderPass
  -> Vulkan.VkExtent2D
  -> Vulkan.VkImageView
  -> Vulkan.VkImageView
  -> m Vulkan.VkFramebuffer
managedFramebuffer dev renderPass extent imageView depthView = alloc "Framebuffer"
  (createFramebuffer dev renderPass extent imageView depthView)
  (\ptr -> Vulkan.vkDestroyFramebuffer dev ptr Vulkan.vkNullPtr)

createFramebuffer
  :: MonadIO m
  => Vulkan.VkDevice
  -> Vulkan.VkRenderPass
  -> Vulkan.VkExtent2D
  -> Vulkan.VkImageView
  -> Vulkan.VkImageView
  -> m Vulkan.VkFramebuffer
createFramebuffer dev renderPass extent imageView depthView = do
  let
    framebufferCI = Vulkan.createVk
      (  set @"sType" Vulkan.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO
      &* set @"pNext" Vulkan.VK_NULL
      &* set @"renderPass" renderPass
      &* set @"attachmentCount" 2
      &* setListRef @"pAttachments" [imageView, depthView]
      &* set @"width" (Vulkan.getField @"width" extent)
      &* set @"height" (Vulkan.getField @"height" extent)
      &* set @"layers" 1
      )
  liftIO $ withPtr framebufferCI (\fciPtr -> allocaAndPeek (Vulkan.vkCreateFramebuffer dev fciPtr Vulkan.VK_NULL))
