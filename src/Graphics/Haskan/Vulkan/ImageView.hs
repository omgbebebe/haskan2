module Graphics.Haskan.Vulkan.ImageView where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Graphics.Haskan.Resources (alloc, allocaAndPeek)
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Ext qualified as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan

managedImageView ::
  MonadManaged m =>
  Vulkan.VkDevice ->
  Vulkan.VkFormat ->
  Vulkan.VkImage ->
  m Vulkan.VkImageView
managedImageView dev format img =
  alloc
    "ImageView"
    (createImageView dev format img)
    (\ptr -> Vulkan.vkDestroyImageView dev ptr Vulkan.vkNullPtr)

createImageView ::
  MonadIO m =>
  Vulkan.VkDevice ->
  Vulkan.VkFormat ->
  Vulkan.VkImage ->
  m Vulkan.VkImageView
createImageView dev format img = do
  let createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"image" img
              &* set @"viewType" Vulkan.VK_IMAGE_VIEW_TYPE_2D
              &* set @"format" format
              &* set @"components" cmapping
              &* set @"subresourceRange" subresourceRange
          )
      cmapping =
        Vulkan.createVk
          ( set @"r" Vulkan.VK_COMPONENT_SWIZZLE_IDENTITY
              &* set @"g" Vulkan.VK_COMPONENT_SWIZZLE_IDENTITY
              &* set @"b" Vulkan.VK_COMPONENT_SWIZZLE_IDENTITY
              &* set @"a" Vulkan.VK_COMPONENT_SWIZZLE_IDENTITY
          )
      subresourceRange =
        Vulkan.createVk
          ( set @"aspectMask" Vulkan.VK_IMAGE_ASPECT_COLOR_BIT
              &* set @"baseMipLevel" 0
              &* set @"levelCount" 1
              &* set @"baseArrayLayer" 0
              &* set @"layerCount" 1
          )
   in
      liftIO $ withPtr createInfo $ \ptr -> allocaAndPeek (Vulkan.vkCreateImageView dev ptr Vulkan.VK_NULL)

managedImageView2DArray ::
  MonadManaged m =>
  Vulkan.VkDevice ->
  Vulkan.VkFormat ->
  Vulkan.VkImage ->
  Vulkan.Word32 -> -- ^ layer count
  m Vulkan.VkImageView
managedImageView2DArray dev format img layerCount =
  alloc
    "ImageView2DArray"
    (createImageView2DArray dev format img layerCount)
    (\ptr -> Vulkan.vkDestroyImageView dev ptr Vulkan.vkNullPtr)

createImageView2DArray ::
  MonadIO m =>
  Vulkan.VkDevice ->
  Vulkan.VkFormat ->
  Vulkan.VkImage ->
  Vulkan.Word32 -> -- ^ layer count
  m Vulkan.VkImageView
createImageView2DArray dev format img layerCount = do
  let createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"image" img
              &* set @"viewType" Vulkan.VK_IMAGE_VIEW_TYPE_2D_ARRAY
              &* set @"format" format
              &* set @"components" cmapping
              &* set @"subresourceRange" subresourceRange
          )
      cmapping =
        Vulkan.createVk
          ( set @"r" Vulkan.VK_COMPONENT_SWIZZLE_IDENTITY
              &* set @"g" Vulkan.VK_COMPONENT_SWIZZLE_IDENTITY
              &* set @"b" Vulkan.VK_COMPONENT_SWIZZLE_IDENTITY
              &* set @"a" Vulkan.VK_COMPONENT_SWIZZLE_IDENTITY
          )
      subresourceRange =
        Vulkan.createVk
          ( set @"aspectMask" Vulkan.VK_IMAGE_ASPECT_COLOR_BIT
              &* set @"baseMipLevel" 0
              &* set @"levelCount" 1
              &* set @"baseArrayLayer" 0
              &* set @"layerCount" layerCount
          )
   in
      liftIO $ withPtr createInfo $ \ptr -> allocaAndPeek (Vulkan.vkCreateImageView dev ptr Vulkan.VK_NULL)

managedImageViewCube ::
  MonadManaged m =>
  Vulkan.VkDevice ->
  Vulkan.VkFormat ->
  Vulkan.VkImage ->
  m Vulkan.VkImageView
managedImageViewCube dev format img =
  alloc
    "ImageViewCube"
    (createImageViewCube dev format img)
    (\ptr -> Vulkan.vkDestroyImageView dev ptr Vulkan.vkNullPtr)

createImageViewCube ::
  MonadIO m =>
  Vulkan.VkDevice ->
  Vulkan.VkFormat ->
  Vulkan.VkImage ->
  m Vulkan.VkImageView
createImageViewCube dev format img = do
  let createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"image" img
              &* set @"viewType" Vulkan.VK_IMAGE_VIEW_TYPE_CUBE
              &* set @"format" format
              &* set @"components" cmapping
              &* set @"subresourceRange" subresourceRange
          )
      cmapping =
        Vulkan.createVk
          ( set @"r" Vulkan.VK_COMPONENT_SWIZZLE_IDENTITY
              &* set @"g" Vulkan.VK_COMPONENT_SWIZZLE_IDENTITY
              &* set @"b" Vulkan.VK_COMPONENT_SWIZZLE_IDENTITY
              &* set @"a" Vulkan.VK_COMPONENT_SWIZZLE_IDENTITY
          )
      subresourceRange =
        Vulkan.createVk
          ( set @"aspectMask" Vulkan.VK_IMAGE_ASPECT_COLOR_BIT
              &* set @"baseMipLevel" 0
              &* set @"levelCount" 1
              &* set @"baseArrayLayer" 0
              &* set @"layerCount" 6
          )
   in
      liftIO $ withPtr createInfo $ \ptr -> allocaAndPeek (Vulkan.vkCreateImageView dev ptr Vulkan.VK_NULL)

managedImageViewCubeMips ::
  MonadManaged m =>
  Vulkan.VkDevice ->
  Vulkan.VkFormat ->
  Vulkan.VkImage ->
  Vulkan.Word32 -> -- ^ mip level count
  m Vulkan.VkImageView
managedImageViewCubeMips dev format img mipLevels =
  alloc
    "ImageViewCubeMips"
    (createImageViewCubeMips dev format img mipLevels)
    (\ptr -> Vulkan.vkDestroyImageView dev ptr Vulkan.vkNullPtr)

createImageViewCubeMips ::
  MonadIO m =>
  Vulkan.VkDevice ->
  Vulkan.VkFormat ->
  Vulkan.VkImage ->
  Vulkan.Word32 -> -- ^ mip level count
  m Vulkan.VkImageView
createImageViewCubeMips dev format img mipLevels = do
  let createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"image" img
              &* set @"viewType" Vulkan.VK_IMAGE_VIEW_TYPE_CUBE
              &* set @"format" format
              &* set @"components" cmapping
              &* set @"subresourceRange" subresourceRange
          )
      cmapping =
        Vulkan.createVk
          ( set @"r" Vulkan.VK_COMPONENT_SWIZZLE_IDENTITY
              &* set @"g" Vulkan.VK_COMPONENT_SWIZZLE_IDENTITY
              &* set @"b" Vulkan.VK_COMPONENT_SWIZZLE_IDENTITY
              &* set @"a" Vulkan.VK_COMPONENT_SWIZZLE_IDENTITY
          )
      subresourceRange =
        Vulkan.createVk
          ( set @"aspectMask" Vulkan.VK_IMAGE_ASPECT_COLOR_BIT
              &* set @"baseMipLevel" 0
              &* set @"levelCount" mipLevels
              &* set @"baseArrayLayer" 0
              &* set @"layerCount" 6
          )
   in
      liftIO $ withPtr createInfo $ \ptr -> allocaAndPeek (Vulkan.vkCreateImageView dev ptr Vulkan.VK_NULL)
