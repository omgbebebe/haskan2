module Graphics.Haskan.Vulkan.ImageView where

-- base
import Control.Monad.IO.Class (MonadIO, liftIO)

-- managed
import Control.Monad.Managed (MonadManaged)

-- vulkan-api
import qualified Graphics.Vulkan as Vulkan
import qualified Graphics.Vulkan.Core_1_0 as Vulkan
import qualified Graphics.Vulkan.Ext as Vulkan
import qualified Graphics.Vulkan.Marshal.Create as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, (&*))

-- haskan
import Graphics.Haskan.Resources (alloc, allocaAndPeek)

managedImageView
  :: MonadManaged m
  => Vulkan.VkDevice
  -> Vulkan.VkFormat
  -> Vulkan.VkImage
  -> m Vulkan.VkImageView
managedImageView dev format img = alloc "ImageView"
  (createImageView dev format img)
  (\ptr -> Vulkan.vkDestroyImageView dev ptr Vulkan.vkNullPtr)

createImageView
  :: MonadIO m
  => Vulkan.VkDevice
  -> Vulkan.VkFormat
  -> Vulkan.VkImage
  -> m Vulkan.VkImageView
createImageView dev format img = do
  let
    createInfo = Vulkan.createVk
      (  set @"sType" Vulkan.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
      &* set @"pNext" Vulkan.VK_NULL
      &* set @"image" img
      &* set @"viewType" Vulkan.VK_IMAGE_VIEW_TYPE_2D
      &* set @"format" format
      &* set @"components" cmapping
      &* set @"subresourceRange" subresourceRange
      )
    cmapping = Vulkan.createVk
      (  set @"r" Vulkan.VK_COMPONENT_SWIZZLE_IDENTITY
      &* set @"g" Vulkan.VK_COMPONENT_SWIZZLE_IDENTITY
      &* set @"b" Vulkan.VK_COMPONENT_SWIZZLE_IDENTITY
      &* set @"a" Vulkan.VK_COMPONENT_SWIZZLE_IDENTITY
      )
    subresourceRange = Vulkan.createVk
      (  set @"aspectMask" Vulkan.VK_IMAGE_ASPECT_COLOR_BIT
      &* set @"baseMipLevel" 0
      &* set @"levelCount" 1
      &* set @"baseArrayLayer" 0
      &* set @"layerCount" 1
      )
--    format = Vulkan.getField @"format" surfFormat
    in liftIO $ withPtr createInfo $ \ptr -> allocaAndPeek (Vulkan.vkCreateImageView dev ptr Vulkan.VK_NULL)
