module Graphics.Haskan.Vulkan.Framebuffer where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Graphics.Haskan.Resources (alloc, allocaAndPeek)
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, setListRef, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan

managedFramebuffer ::
  MonadManaged m =>
  Vulkan.VkDevice ->
  Vulkan.VkRenderPass ->
  Vulkan.VkExtent2D ->
  Vulkan.VkImageView ->
  Vulkan.VkImageView ->
  m Vulkan.VkFramebuffer
managedFramebuffer dev renderPass extent imageView depthView =
  alloc
    "Framebuffer"
    (createFramebuffer dev renderPass extent imageView depthView)
    (\ptr -> Vulkan.vkDestroyFramebuffer dev ptr Vulkan.vkNullPtr)

createFramebuffer ::
  MonadIO m =>
  Vulkan.VkDevice ->
  Vulkan.VkRenderPass ->
  Vulkan.VkExtent2D ->
  Vulkan.VkImageView ->
  Vulkan.VkImageView ->
  m Vulkan.VkFramebuffer
createFramebuffer dev renderPass extent imageView depthView = do
  let framebufferCI =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"renderPass" renderPass
              &* set @"attachmentCount" 2
              &* setListRef @"pAttachments" [imageView, depthView]
              &* set @"width" (Vulkan.getField @"width" extent)
              &* set @"height" (Vulkan.getField @"height" extent)
              &* set @"layers" 1
          )
  liftIO $ withPtr framebufferCI (\fciPtr -> allocaAndPeek (Vulkan.vkCreateFramebuffer dev fciPtr Vulkan.VK_NULL))

managedGBufferFramebuffer ::
  MonadManaged m =>
  Vulkan.VkDevice ->
  Vulkan.VkRenderPass ->
  Vulkan.VkExtent2D ->
  [Vulkan.VkImageView] ->
  Vulkan.VkImageView ->
  m Vulkan.VkFramebuffer
managedGBufferFramebuffer dev renderPass extent colorViews depthView =
  alloc
    "GBufferFramebuffer"
    (createGBufferFramebuffer dev renderPass extent colorViews depthView)
    (\ptr -> Vulkan.vkDestroyFramebuffer dev ptr Vulkan.vkNullPtr)

createGBufferFramebuffer ::
  MonadIO m =>
  Vulkan.VkDevice ->
  Vulkan.VkRenderPass ->
  Vulkan.VkExtent2D ->
  [Vulkan.VkImageView] ->
  Vulkan.VkImageView ->
  m Vulkan.VkFramebuffer
createGBufferFramebuffer dev renderPass extent colorViews depthView = do
  let framebufferCI =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"renderPass" renderPass
              &* set @"attachmentCount" (fromIntegral (length colorViews + 1))
              &* setListRef @"pAttachments" (colorViews ++ [depthView])
              &* set @"width" (Vulkan.getField @"width" extent)
              &* set @"height" (Vulkan.getField @"height" extent)
              &* set @"layers" 1
          )
  liftIO $ withPtr framebufferCI (\fciPtr -> allocaAndPeek (Vulkan.vkCreateFramebuffer dev fciPtr Vulkan.VK_NULL))

managedLightingFramebuffer ::
  MonadManaged m =>
  Vulkan.VkDevice ->
  Vulkan.VkRenderPass ->
  Vulkan.VkExtent2D ->
  Vulkan.VkImageView ->
  m Vulkan.VkFramebuffer
managedLightingFramebuffer dev renderPass extent imageView =
  alloc
    "LightingFramebuffer"
    (createLightingFramebuffer dev renderPass extent imageView)
    (\ptr -> Vulkan.vkDestroyFramebuffer dev ptr Vulkan.vkNullPtr)

createLightingFramebuffer ::
  MonadIO m =>
  Vulkan.VkDevice ->
  Vulkan.VkRenderPass ->
  Vulkan.VkExtent2D ->
  Vulkan.VkImageView ->
  m Vulkan.VkFramebuffer
createLightingFramebuffer dev renderPass extent imageView = do
  let framebufferCI =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"renderPass" renderPass
              &* set @"attachmentCount" 1
              &* setListRef @"pAttachments" [imageView]
              &* set @"width" (Vulkan.getField @"width" extent)
              &* set @"height" (Vulkan.getField @"height" extent)
              &* set @"layers" 1
          )
  liftIO $ withPtr framebufferCI (\fciPtr -> allocaAndPeek (Vulkan.vkCreateFramebuffer dev fciPtr Vulkan.VK_NULL))
