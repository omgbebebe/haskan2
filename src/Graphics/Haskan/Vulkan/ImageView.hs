{-# LANGUAGE DuplicateRecordFields #-}

module Graphics.Haskan.Vulkan.ImageView where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Word (Word32)
import Graphics.Haskan.Resources (alloc)
import Vulkan qualified as Vk26
import Vulkan.Zero (zero)

managedImageView ::
  (MonadManaged m) =>
  Vk26.Device ->
  Vk26.Format ->
  Vk26.Image ->
  m Vk26.ImageView
managedImageView dev format img =
  alloc
    "ImageView"
    (createImageView dev format img)
    (\ptr -> Vk26.destroyImageView dev ptr Nothing)

createImageView ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.Format ->
  Vk26.Image ->
  m Vk26.ImageView
createImageView dev format img = do
  let cmapping =
        Vk26.ComponentMapping
          Vk26.COMPONENT_SWIZZLE_IDENTITY
          Vk26.COMPONENT_SWIZZLE_IDENTITY
          Vk26.COMPONENT_SWIZZLE_IDENTITY
          Vk26.COMPONENT_SWIZZLE_IDENTITY
      subresourceRange =
        Vk26.ImageSubresourceRange
          Vk26.IMAGE_ASPECT_COLOR_BIT
          0
          1
          0
          1
      createInfo =
        Vk26.ImageViewCreateInfo
          ()
          zero
          img
          Vk26.IMAGE_VIEW_TYPE_2D
          format
          cmapping
          subresourceRange
  liftIO $ Vk26.createImageView dev createInfo Nothing

managedImageView3D ::
  (MonadManaged m) =>
  Vk26.Device ->
  Vk26.Format ->
  Vk26.Image ->
  m Vk26.ImageView
managedImageView3D dev format img =
  alloc
    "ImageView3D"
    (createImageView3D dev format img)
    (\ptr -> Vk26.destroyImageView dev ptr Nothing)

createImageView3D ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.Format ->
  Vk26.Image ->
  m Vk26.ImageView
createImageView3D dev format img = do
  let cmapping =
        Vk26.ComponentMapping
          Vk26.COMPONENT_SWIZZLE_IDENTITY
          Vk26.COMPONENT_SWIZZLE_IDENTITY
          Vk26.COMPONENT_SWIZZLE_IDENTITY
          Vk26.COMPONENT_SWIZZLE_IDENTITY
      subresourceRange =
        Vk26.ImageSubresourceRange
          Vk26.IMAGE_ASPECT_COLOR_BIT
          0
          1
          0
          1
      createInfo =
        Vk26.ImageViewCreateInfo
          ()
          zero
          img
          Vk26.IMAGE_VIEW_TYPE_3D
          format
          cmapping
          subresourceRange
  liftIO $ Vk26.createImageView dev createInfo Nothing

managedImageView3DMips ::
  (MonadManaged m) =>
  Vk26.Device ->
  Vk26.Format ->
  Vk26.Image ->
  -- | mip level count
  Word32 ->
  m Vk26.ImageView
managedImageView3DMips dev format img mipLevels =
  alloc
    "ImageView3DMips"
    (createImageView3DMips dev format img mipLevels)
    (\ptr -> Vk26.destroyImageView dev ptr Nothing)

createImageView3DMips ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.Format ->
  Vk26.Image ->
  -- | mip level count
  Word32 ->
  m Vk26.ImageView
createImageView3DMips dev format img mipLevels = do
  let cmapping =
        Vk26.ComponentMapping
          Vk26.COMPONENT_SWIZZLE_IDENTITY
          Vk26.COMPONENT_SWIZZLE_IDENTITY
          Vk26.COMPONENT_SWIZZLE_IDENTITY
          Vk26.COMPONENT_SWIZZLE_IDENTITY
      subresourceRange =
        Vk26.ImageSubresourceRange
          Vk26.IMAGE_ASPECT_COLOR_BIT
          0
          mipLevels
          0
          1
      createInfo =
        Vk26.ImageViewCreateInfo
          ()
          zero
          img
          Vk26.IMAGE_VIEW_TYPE_3D
          format
          cmapping
          subresourceRange
  liftIO $ Vk26.createImageView dev createInfo Nothing

createImageView3DSingleMip ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.Format ->
  Vk26.Image ->
  -- | base mip level
  Word32 ->
  m Vk26.ImageView
createImageView3DSingleMip dev format img baseMip = do
  let cmapping =
        Vk26.ComponentMapping
          Vk26.COMPONENT_SWIZZLE_IDENTITY
          Vk26.COMPONENT_SWIZZLE_IDENTITY
          Vk26.COMPONENT_SWIZZLE_IDENTITY
          Vk26.COMPONENT_SWIZZLE_IDENTITY
      subresourceRange =
        Vk26.ImageSubresourceRange
          Vk26.IMAGE_ASPECT_COLOR_BIT
          baseMip
          1
          0
          1
      createInfo =
        Vk26.ImageViewCreateInfo
          ()
          zero
          img
          Vk26.IMAGE_VIEW_TYPE_3D
          format
          cmapping
          subresourceRange
  liftIO $ Vk26.createImageView dev createInfo Nothing

managedImageView2DArray ::
  (MonadManaged m) =>
  Vk26.Device ->
  Vk26.Format ->
  Vk26.Image ->
  -- | layer count
  Word32 ->
  m Vk26.ImageView
managedImageView2DArray dev format img layerCount =
  alloc
    "ImageView2DArray"
    (createImageView2DArray dev format img layerCount)
    (\ptr -> Vk26.destroyImageView dev ptr Nothing)

createImageView2DArray ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.Format ->
  Vk26.Image ->
  -- | layer count
  Word32 ->
  m Vk26.ImageView
createImageView2DArray dev format img layerCount = do
  let cmapping =
        Vk26.ComponentMapping
          Vk26.COMPONENT_SWIZZLE_IDENTITY
          Vk26.COMPONENT_SWIZZLE_IDENTITY
          Vk26.COMPONENT_SWIZZLE_IDENTITY
          Vk26.COMPONENT_SWIZZLE_IDENTITY
      subresourceRange =
        Vk26.ImageSubresourceRange
          Vk26.IMAGE_ASPECT_COLOR_BIT
          0
          1
          0
          layerCount
      createInfo =
        Vk26.ImageViewCreateInfo
          ()
          zero
          img
          Vk26.IMAGE_VIEW_TYPE_2D_ARRAY
          format
          cmapping
          subresourceRange
  liftIO $ Vk26.createImageView dev createInfo Nothing

managedImageViewCube ::
  (MonadManaged m) =>
  Vk26.Device ->
  Vk26.Format ->
  Vk26.Image ->
  m Vk26.ImageView
managedImageViewCube dev format img =
  alloc
    "ImageViewCube"
    (createImageViewCube dev format img)
    (\ptr -> Vk26.destroyImageView dev ptr Nothing)

createImageViewCube ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.Format ->
  Vk26.Image ->
  m Vk26.ImageView
createImageViewCube dev format img = do
  let cmapping =
        Vk26.ComponentMapping
          Vk26.COMPONENT_SWIZZLE_IDENTITY
          Vk26.COMPONENT_SWIZZLE_IDENTITY
          Vk26.COMPONENT_SWIZZLE_IDENTITY
          Vk26.COMPONENT_SWIZZLE_IDENTITY
      subresourceRange =
        Vk26.ImageSubresourceRange
          Vk26.IMAGE_ASPECT_COLOR_BIT
          0
          1
          0
          6
      createInfo =
        Vk26.ImageViewCreateInfo
          ()
          zero
          img
          Vk26.IMAGE_VIEW_TYPE_CUBE
          format
          cmapping
          subresourceRange
  liftIO $ Vk26.createImageView dev createInfo Nothing

managedImageViewCubeMips ::
  (MonadManaged m) =>
  Vk26.Device ->
  Vk26.Format ->
  Vk26.Image ->
  -- | mip level count
  Word32 ->
  m Vk26.ImageView
managedImageViewCubeMips dev format img mipLevels =
  alloc
    "ImageViewCubeMips"
    (createImageViewCubeMips dev format img mipLevels)
    (\ptr -> Vk26.destroyImageView dev ptr Nothing)

createImageViewCubeMips ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.Format ->
  Vk26.Image ->
  -- | mip level count
  Word32 ->
  m Vk26.ImageView
createImageViewCubeMips dev format img mipLevels = do
  let cmapping =
        Vk26.ComponentMapping
          Vk26.COMPONENT_SWIZZLE_IDENTITY
          Vk26.COMPONENT_SWIZZLE_IDENTITY
          Vk26.COMPONENT_SWIZZLE_IDENTITY
          Vk26.COMPONENT_SWIZZLE_IDENTITY
      subresourceRange =
        Vk26.ImageSubresourceRange
          Vk26.IMAGE_ASPECT_COLOR_BIT
          0
          mipLevels
          0
          6
      createInfo =
        Vk26.ImageViewCreateInfo
          ()
          zero
          img
          Vk26.IMAGE_VIEW_TYPE_CUBE
          format
          cmapping
          subresourceRange
  liftIO $ Vk26.createImageView dev createInfo Nothing
