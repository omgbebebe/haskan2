{-# LANGUAGE DuplicateRecordFields #-}

module Graphics.Haskan.Vulkan.Framebuffer where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Vector qualified as Vector
import Data.Word (Word32)
import Graphics.Haskan.Resources (alloc)
import Vulkan qualified
import Vulkan.Zero (zero)

managedFramebuffer ::
  (MonadManaged m) =>
  Vulkan.Device ->
  Vulkan.RenderPass ->
  Vulkan.Extent2D ->
  Vulkan.ImageView ->
  Vulkan.ImageView ->
  m Vulkan.Framebuffer
managedFramebuffer dev renderPass extent imageView depthView =
  alloc
    "Framebuffer"
    (createFramebuffer dev renderPass extent imageView depthView)
    (\fb -> Vulkan.destroyFramebuffer dev fb Nothing)

createFramebuffer ::
  (MonadIO m) =>
  Vulkan.Device ->
  Vulkan.RenderPass ->
  Vulkan.Extent2D ->
  Vulkan.ImageView ->
  Vulkan.ImageView ->
  m Vulkan.Framebuffer
createFramebuffer dev renderPass extent imageView depthView = do
  let Vulkan.Extent2D {width = w, height = h} = extent
      createInfo =
        Vulkan.FramebufferCreateInfo
          { next = (),
            flags = zero,
            renderPass = renderPass,
            attachments = Vector.fromList [imageView, depthView],
            width = w,
            height = h,
            layers = 1
          }
  liftIO $ Vulkan.createFramebuffer dev createInfo Nothing

managedGBufferFramebuffer ::
  (MonadManaged m) =>
  Vulkan.Device ->
  Vulkan.RenderPass ->
  Vulkan.Extent2D ->
  [Vulkan.ImageView] ->
  Vulkan.ImageView ->
  m Vulkan.Framebuffer
managedGBufferFramebuffer dev renderPass extent colorViews depthView =
  alloc
    "GBufferFramebuffer"
    (createGBufferFramebuffer dev renderPass extent colorViews depthView)
    (\fb -> Vulkan.destroyFramebuffer dev fb Nothing)

createGBufferFramebuffer ::
  (MonadIO m) =>
  Vulkan.Device ->
  Vulkan.RenderPass ->
  Vulkan.Extent2D ->
  [Vulkan.ImageView] ->
  Vulkan.ImageView ->
  m Vulkan.Framebuffer
createGBufferFramebuffer dev renderPass extent colorViews depthView = do
  let Vulkan.Extent2D {width = w, height = h} = extent
      createInfo =
        Vulkan.FramebufferCreateInfo
          { next = (),
            flags = zero,
            renderPass = renderPass,
            attachments = Vector.fromList (colorViews ++ [depthView]),
            width = w,
            height = h,
            layers = 1
          }
  liftIO $ Vulkan.createFramebuffer dev createInfo Nothing

managedLightingFramebuffer ::
  (MonadManaged m) =>
  Vulkan.Device ->
  Vulkan.RenderPass ->
  Vulkan.Extent2D ->
  Vulkan.ImageView ->
  m Vulkan.Framebuffer
managedLightingFramebuffer dev renderPass extent imageView =
  alloc
    "LightingFramebuffer"
    (createLightingFramebuffer dev renderPass extent imageView)
    (\fb -> Vulkan.destroyFramebuffer dev fb Nothing)

createLightingFramebuffer ::
  (MonadIO m) =>
  Vulkan.Device ->
  Vulkan.RenderPass ->
  Vulkan.Extent2D ->
  Vulkan.ImageView ->
  m Vulkan.Framebuffer
createLightingFramebuffer dev renderPass extent imageView = do
  let Vulkan.Extent2D {width = w, height = h} = extent
      createInfo =
        Vulkan.FramebufferCreateInfo
          { next = (),
            flags = zero,
            renderPass = renderPass,
            attachments = Vector.fromList [imageView],
            width = w,
            height = h,
            layers = 1
          }
  liftIO $ Vulkan.createFramebuffer dev createInfo Nothing
