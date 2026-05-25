module Graphics.Haskan.Vulkan.RenderPass where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Bits ((.|.))
import Data.Vector qualified as Vector
import Data.Word (Word32)
import Graphics.Haskan.Resources (alloc, allocaAndPeek)
import Vulkan qualified as Vk26
import Vulkan.Zero (zero)

managedRenderPass ::
  (MonadManaged m) =>
  Vk26.Device ->
  Vk26.SurfaceFormatKHR ->
  Vk26.Format ->
  m Vk26.RenderPass
managedRenderPass dev surfaceFormat depthFormat =
  alloc
    "RenderPass"
    (createRenderPass dev surfaceFormat depthFormat)
    (\ptr -> Vk26.destroyRenderPass dev ptr Nothing)

createRenderPass ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.SurfaceFormatKHR ->
  Vk26.Format ->
  m Vk26.RenderPass
createRenderPass dev surfaceFormat depthFormat =
  let Vk26.SurfaceFormatKHR imageFormat _ = surfaceFormat
      colorAttachment =
        Vk26.AttachmentDescription
          zero
          imageFormat
          Vk26.SAMPLE_COUNT_1_BIT
          Vk26.ATTACHMENT_LOAD_OP_CLEAR
          Vk26.ATTACHMENT_STORE_OP_STORE
          Vk26.ATTACHMENT_LOAD_OP_DONT_CARE
          Vk26.ATTACHMENT_STORE_OP_DONT_CARE
          Vk26.IMAGE_LAYOUT_UNDEFINED
          Vk26.IMAGE_LAYOUT_PRESENT_SRC_KHR
      colorAttachmentRef =
        Vk26.AttachmentReference
          0
          Vk26.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
      depthAttachment =
        Vk26.AttachmentDescription
          zero
          depthFormat
          Vk26.SAMPLE_COUNT_1_BIT
          Vk26.ATTACHMENT_LOAD_OP_CLEAR
          Vk26.ATTACHMENT_STORE_OP_DONT_CARE
          Vk26.ATTACHMENT_LOAD_OP_DONT_CARE
          Vk26.ATTACHMENT_STORE_OP_DONT_CARE
          Vk26.IMAGE_LAYOUT_UNDEFINED
          Vk26.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
      depthAttachmentRef =
        Vk26.AttachmentReference
          1
          Vk26.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
      subpass =
        Vk26.SubpassDescription
          zero
          Vk26.PIPELINE_BIND_POINT_GRAPHICS
          Vector.empty
          (Vector.fromList [colorAttachmentRef])
          Vector.empty
          (Just depthAttachmentRef)
          Vector.empty
      dependency =
        Vk26.SubpassDependency
          Vk26.SUBPASS_EXTERNAL
          0
          Vk26.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
          Vk26.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
          zero
          Vk26.ACCESS_COLOR_ATTACHMENT_WRITE_BIT
          zero
      renderPassCI =
        Vk26.RenderPassCreateInfo
          ()
          zero
          (Vector.fromList [colorAttachment, depthAttachment])
          (Vector.fromList [subpass])
          (Vector.fromList [dependency])
   in liftIO $ Vk26.createRenderPass dev renderPassCI Nothing

withRenderPass ::
  (MonadIO m) =>
  Vk26.CommandBuffer ->
  Vk26.RenderPass ->
  Vk26.Framebuffer ->
  Vk26.Extent2D ->
  [Vk26.ClearValue] ->
  m a ->
  m a
withRenderPass commandBuffer renderPass framebuffer extent clearValues action =
  let beginInfo =
        Vk26.RenderPassBeginInfo
          ()
          renderPass
          framebuffer
          (Vk26.Rect2D (Vk26.Offset2D 0 0) extent)
          (Vector.fromList clearValues)
      begin = liftIO $ Vk26.cmdBeginRenderPass commandBuffer beginInfo Vk26.SUBPASS_CONTENTS_INLINE
      end = liftIO $ Vk26.cmdEndRenderPass commandBuffer
   in (begin *> action <* end)

withGBufferRenderPass ::
  (MonadIO m) =>
  Vk26.CommandBuffer ->
  Vk26.RenderPass ->
  Vk26.Framebuffer ->
  Vk26.Extent2D ->
  m a ->
  m a
withGBufferRenderPass commandBuffer renderPass framebuffer extent action =
  let posClear = Vk26.Float32 0.0 0.0 0.0 0.0
      normClear = Vk26.Float32 0.0 0.0 0.0 0.0
      albClear = Vk26.Float32 0.0 0.0 0.0 0.0
      matClear = Vk26.Float32 0.0 0.5 1.0 1.0
      depthClear = Vk26.ClearDepthStencilValue 1.0 0
      clearValues =
        [ Vk26.Color posClear,
          Vk26.Color normClear,
          Vk26.Color albClear,
          Vk26.Color matClear,
          Vk26.DepthStencil depthClear
        ]
   in withRenderPass commandBuffer renderPass framebuffer extent clearValues action

withLightingRenderPass ::
  (MonadIO m) =>
  Vk26.CommandBuffer ->
  Vk26.RenderPass ->
  Vk26.Framebuffer ->
  Vk26.Extent2D ->
  m a ->
  m a
withLightingRenderPass commandBuffer renderPass framebuffer extent action =
  let colorClear = Vk26.Float32 0.0 0.0 1.0 1.0
      clearValues = [Vk26.Color colorClear]
   in withRenderPass commandBuffer renderPass framebuffer extent clearValues action

withCloudRenderPass ::
  (MonadIO m) =>
  Vk26.CommandBuffer ->
  Vk26.RenderPass ->
  Vk26.Framebuffer ->
  Vk26.Extent2D ->
  m a ->
  m a
withCloudRenderPass commandBuffer renderPass framebuffer extent action =
  let colorClear = Vk26.Float32 0.0 0.0 0.0 0.0
      clearValues = [Vk26.Color colorClear]
   in withRenderPass commandBuffer renderPass framebuffer extent clearValues action

withImGuiRenderPass ::
  (MonadIO m) =>
  Vk26.CommandBuffer ->
  Vk26.RenderPass ->
  Vk26.Framebuffer ->
  Vk26.Extent2D ->
  m a ->
  m a
withImGuiRenderPass commandBuffer renderPass framebuffer extent =
  withRenderPass commandBuffer renderPass framebuffer extent []

-- ---------------------------------------------------------------------------
-- G-buffer render pass: 4 color attachments + depth
-- ---------------------------------------------------------------------------

managedGBufferRenderPassEx ::
  (MonadManaged m) =>
  Vk26.Device ->
  Vk26.Format ->
  Vk26.Format ->
  Vk26.Format ->
  m Vk26.RenderPass
managedGBufferRenderPassEx dev posFormat colorFormat depthFormat =
  alloc
    "GBufferRenderPass"
    (createGBufferRenderPassEx dev posFormat colorFormat depthFormat)
    (\ptr -> Vk26.destroyRenderPass dev ptr Nothing)

createGBufferRenderPassEx ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.Format ->
  Vk26.Format ->
  Vk26.Format ->
  m Vk26.RenderPass
createGBufferRenderPassEx dev posFormat colorFormat depthFormat =
  let mkColorAttachment fmt =
        Vk26.AttachmentDescription
          zero
          fmt
          Vk26.SAMPLE_COUNT_1_BIT
          Vk26.ATTACHMENT_LOAD_OP_CLEAR
          Vk26.ATTACHMENT_STORE_OP_STORE
          Vk26.ATTACHMENT_LOAD_OP_DONT_CARE
          Vk26.ATTACHMENT_STORE_OP_DONT_CARE
          Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
          Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
      colorAttachments =
        [ mkColorAttachment posFormat,
          mkColorAttachment colorFormat,
          mkColorAttachment colorFormat,
          mkColorAttachment colorFormat
        ]
      colorAttachmentRefs =
        [ Vk26.AttachmentReference i Vk26.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
        | i <- [0 .. 3]
        ]
      depthAttachment =
        Vk26.AttachmentDescription
          zero
          depthFormat
          Vk26.SAMPLE_COUNT_1_BIT
          Vk26.ATTACHMENT_LOAD_OP_CLEAR
          Vk26.ATTACHMENT_STORE_OP_DONT_CARE
          Vk26.ATTACHMENT_LOAD_OP_DONT_CARE
          Vk26.ATTACHMENT_STORE_OP_DONT_CARE
          Vk26.IMAGE_LAYOUT_UNDEFINED
          Vk26.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
      depthAttachmentRef =
        Vk26.AttachmentReference 4 Vk26.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
      subpass =
        Vk26.SubpassDescription
          zero
          Vk26.PIPELINE_BIND_POINT_GRAPHICS
          Vector.empty
          (Vector.fromList colorAttachmentRefs)
          Vector.empty
          (Just depthAttachmentRef)
          Vector.empty
      dependency =
        Vk26.SubpassDependency
          Vk26.SUBPASS_EXTERNAL
          0
          Vk26.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
          (Vk26.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT .|. Vk26.PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT)
          zero
          (Vk26.ACCESS_COLOR_ATTACHMENT_WRITE_BIT .|. Vk26.ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT)
          zero
      dependencyToExternal =
        Vk26.SubpassDependency
          0
          Vk26.SUBPASS_EXTERNAL
          Vk26.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
          Vk26.PIPELINE_STAGE_FRAGMENT_SHADER_BIT
          Vk26.ACCESS_COLOR_ATTACHMENT_WRITE_BIT
          Vk26.ACCESS_SHADER_READ_BIT
          zero
      renderPassCI =
        Vk26.RenderPassCreateInfo
          ()
          zero
          (Vector.fromList (colorAttachments ++ [depthAttachment]))
          (Vector.fromList [subpass])
          (Vector.fromList [dependency, dependencyToExternal])
   in liftIO $ Vk26.createRenderPass dev renderPassCI Nothing

-- ---------------------------------------------------------------------------
-- Bindless render pass: same attachments as g-buffer but with LOAD_OP_LOAD
-- ---------------------------------------------------------------------------

managedBindlessRenderPass ::
  (MonadManaged m) =>
  Vk26.Device ->
  Vk26.Format ->
  Vk26.Format ->
  Vk26.Format ->
  m Vk26.RenderPass
managedBindlessRenderPass dev posFormat colorFormat depthFormat =
  alloc
    "BindlessRenderPass"
    (createBindlessRenderPass dev posFormat colorFormat depthFormat)
    (\ptr -> Vk26.destroyRenderPass dev ptr Nothing)

createBindlessRenderPass ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.Format ->
  Vk26.Format ->
  Vk26.Format ->
  m Vk26.RenderPass
createBindlessRenderPass dev posFormat colorFormat depthFormat =
  let mkColorAttachment fmt =
        Vk26.AttachmentDescription
          zero
          fmt
          Vk26.SAMPLE_COUNT_1_BIT
          Vk26.ATTACHMENT_LOAD_OP_LOAD
          Vk26.ATTACHMENT_STORE_OP_STORE
          Vk26.ATTACHMENT_LOAD_OP_DONT_CARE
          Vk26.ATTACHMENT_STORE_OP_DONT_CARE
          Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
          Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
      colorAttachments =
        [ mkColorAttachment posFormat,
          mkColorAttachment colorFormat,
          mkColorAttachment colorFormat,
          mkColorAttachment colorFormat
        ]
      colorAttachmentRefs =
        [ Vk26.AttachmentReference i Vk26.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
        | i <- [0 .. 3]
        ]
      depthAttachment =
        Vk26.AttachmentDescription
          zero
          depthFormat
          Vk26.SAMPLE_COUNT_1_BIT
          Vk26.ATTACHMENT_LOAD_OP_CLEAR
          Vk26.ATTACHMENT_STORE_OP_STORE
          Vk26.ATTACHMENT_LOAD_OP_DONT_CARE
          Vk26.ATTACHMENT_STORE_OP_DONT_CARE
          Vk26.IMAGE_LAYOUT_UNDEFINED
          Vk26.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
      depthAttachmentRef =
        Vk26.AttachmentReference 4 Vk26.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
      subpass =
        Vk26.SubpassDescription
          zero
          Vk26.PIPELINE_BIND_POINT_GRAPHICS
          Vector.empty
          (Vector.fromList colorAttachmentRefs)
          Vector.empty
          (Just depthAttachmentRef)
          Vector.empty
      dependency =
        Vk26.SubpassDependency
          Vk26.SUBPASS_EXTERNAL
          0
          Vk26.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
          (Vk26.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT .|. Vk26.PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT)
          zero
          (Vk26.ACCESS_COLOR_ATTACHMENT_WRITE_BIT .|. Vk26.ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT)
          zero
      dependencyToExternal =
        Vk26.SubpassDependency
          0
          Vk26.SUBPASS_EXTERNAL
          Vk26.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
          Vk26.PIPELINE_STAGE_FRAGMENT_SHADER_BIT
          Vk26.ACCESS_COLOR_ATTACHMENT_WRITE_BIT
          Vk26.ACCESS_SHADER_READ_BIT
          zero
      renderPassCI =
        Vk26.RenderPassCreateInfo
          ()
          zero
          (Vector.fromList (colorAttachments ++ [depthAttachment]))
          (Vector.fromList [subpass])
          (Vector.fromList [dependency, dependencyToExternal])
   in liftIO $ Vk26.createRenderPass dev renderPassCI Nothing

-- ---------------------------------------------------------------------------
-- Lighting render pass: single color attachment (swapchain)
-- ---------------------------------------------------------------------------

managedLightingRenderPass ::
  (MonadManaged m) =>
  Vk26.Device ->
  Vk26.SurfaceFormatKHR ->
  m Vk26.RenderPass
managedLightingRenderPass dev surfaceFormat =
  alloc
    "LightingRenderPass"
    (createLightingRenderPass dev surfaceFormat)
    (\ptr -> Vk26.destroyRenderPass dev ptr Nothing)

createLightingRenderPass ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.SurfaceFormatKHR ->
  m Vk26.RenderPass
createLightingRenderPass dev surfaceFormat =
  let Vk26.SurfaceFormatKHR imageFormat _ = surfaceFormat
      colorAttachment =
        Vk26.AttachmentDescription
          zero
          imageFormat
          Vk26.SAMPLE_COUNT_1_BIT
          Vk26.ATTACHMENT_LOAD_OP_CLEAR
          Vk26.ATTACHMENT_STORE_OP_STORE
          Vk26.ATTACHMENT_LOAD_OP_DONT_CARE
          Vk26.ATTACHMENT_STORE_OP_DONT_CARE
          Vk26.IMAGE_LAYOUT_UNDEFINED
          Vk26.IMAGE_LAYOUT_PRESENT_SRC_KHR
      colorAttachmentRef =
        Vk26.AttachmentReference 0 Vk26.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
      subpass =
        Vk26.SubpassDescription
          zero
          Vk26.PIPELINE_BIND_POINT_GRAPHICS
          Vector.empty
          (Vector.fromList [colorAttachmentRef])
          Vector.empty
          Nothing
          Vector.empty
      dependency =
        Vk26.SubpassDependency
          Vk26.SUBPASS_EXTERNAL
          0
          Vk26.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
          Vk26.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
          zero
          Vk26.ACCESS_COLOR_ATTACHMENT_WRITE_BIT
          zero
      renderPassCI =
        Vk26.RenderPassCreateInfo
          ()
          zero
          (Vector.fromList [colorAttachment])
          (Vector.fromList [subpass])
          (Vector.fromList [dependency])
   in liftIO $ Vk26.createRenderPass dev renderPassCI Nothing

-- ---------------------------------------------------------------------------
-- Cloud render pass: single RGBA16F color attachment (intermediate texture)
-- ---------------------------------------------------------------------------

managedCloudRenderPass ::
  (MonadManaged m) =>
  Vk26.Device ->
  m Vk26.RenderPass
managedCloudRenderPass dev =
  alloc
    "CloudRenderPass"
    (createCloudRenderPass dev)
    (\ptr -> Vk26.destroyRenderPass dev ptr Nothing)

createCloudRenderPass ::
  (MonadIO m) =>
  Vk26.Device ->
  m Vk26.RenderPass
createCloudRenderPass dev =
  let cloudFormat = Vk26.FORMAT_R16G16B16A16_SFLOAT
      colorAttachment =
        Vk26.AttachmentDescription
          zero
          cloudFormat
          Vk26.SAMPLE_COUNT_1_BIT
          Vk26.ATTACHMENT_LOAD_OP_CLEAR
          Vk26.ATTACHMENT_STORE_OP_STORE
          Vk26.ATTACHMENT_LOAD_OP_DONT_CARE
          Vk26.ATTACHMENT_STORE_OP_DONT_CARE
          Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
          Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
      colorAttachmentRef =
        Vk26.AttachmentReference 0 Vk26.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
      subpass =
        Vk26.SubpassDescription
          zero
          Vk26.PIPELINE_BIND_POINT_GRAPHICS
          Vector.empty
          (Vector.fromList [colorAttachmentRef])
          Vector.empty
          Nothing
          Vector.empty
      dependency =
        Vk26.SubpassDependency
          Vk26.SUBPASS_EXTERNAL
          0
          Vk26.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
          Vk26.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
          zero
          Vk26.ACCESS_COLOR_ATTACHMENT_WRITE_BIT
          zero
      dependencyToExternal =
        Vk26.SubpassDependency
          0
          Vk26.SUBPASS_EXTERNAL
          Vk26.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
          Vk26.PIPELINE_STAGE_FRAGMENT_SHADER_BIT
          Vk26.ACCESS_COLOR_ATTACHMENT_WRITE_BIT
          Vk26.ACCESS_SHADER_READ_BIT
          zero
      renderPassCI =
        Vk26.RenderPassCreateInfo
          ()
          zero
          (Vector.fromList [colorAttachment])
          (Vector.fromList [subpass])
          (Vector.fromList [dependency, dependencyToExternal])
   in liftIO $ Vk26.createRenderPass dev renderPassCI Nothing

-- ---------------------------------------------------------------------------
-- Terrain overlay render pass: single color attachment (swapchain), load existing
-- ---------------------------------------------------------------------------

managedTerrainOverlayRenderPass ::
  (MonadManaged m) =>
  Vk26.Device ->
  Vk26.SurfaceFormatKHR ->
  m Vk26.RenderPass
managedTerrainOverlayRenderPass dev surfaceFormat =
  alloc
    "TerrainOverlayRenderPass"
    (createTerrainOverlayRenderPass dev surfaceFormat)
    (\ptr -> Vk26.destroyRenderPass dev ptr Nothing)

createTerrainOverlayRenderPass ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.SurfaceFormatKHR ->
  m Vk26.RenderPass
createTerrainOverlayRenderPass dev surfaceFormat =
  let Vk26.SurfaceFormatKHR imageFormat _ = surfaceFormat
      colorAttachment =
        Vk26.AttachmentDescription
          zero
          imageFormat
          Vk26.SAMPLE_COUNT_1_BIT
          Vk26.ATTACHMENT_LOAD_OP_LOAD
          Vk26.ATTACHMENT_STORE_OP_STORE
          Vk26.ATTACHMENT_LOAD_OP_DONT_CARE
          Vk26.ATTACHMENT_STORE_OP_DONT_CARE
          Vk26.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
          Vk26.IMAGE_LAYOUT_PRESENT_SRC_KHR
      colorAttachmentRef =
        Vk26.AttachmentReference 0 Vk26.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
      subpass =
        Vk26.SubpassDescription
          zero
          Vk26.PIPELINE_BIND_POINT_GRAPHICS
          Vector.empty
          (Vector.fromList [colorAttachmentRef])
          Vector.empty
          Nothing
          Vector.empty
      dependency =
        Vk26.SubpassDependency
          Vk26.SUBPASS_EXTERNAL
          0
          Vk26.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
          Vk26.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
          Vk26.ACCESS_COLOR_ATTACHMENT_WRITE_BIT
          Vk26.ACCESS_COLOR_ATTACHMENT_WRITE_BIT
          zero
      renderPassCI =
        Vk26.RenderPassCreateInfo
          ()
          zero
          (Vector.fromList [colorAttachment])
          (Vector.fromList [subpass])
          (Vector.fromList [dependency])
   in liftIO $ Vk26.createRenderPass dev renderPassCI Nothing

-- ---------------------------------------------------------------------------
-- ImGui overlay render pass: single color attachment (swapchain), load existing
-- ---------------------------------------------------------------------------

managedImGuiRenderPass ::
  (MonadManaged m) =>
  Vk26.Device ->
  Vk26.SurfaceFormatKHR ->
  m Vk26.RenderPass
managedImGuiRenderPass dev surfaceFormat =
  alloc
    "ImGuiRenderPass"
    (createImGuiRenderPass dev surfaceFormat)
    (\ptr -> Vk26.destroyRenderPass dev ptr Nothing)

createImGuiRenderPass ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.SurfaceFormatKHR ->
  m Vk26.RenderPass
createImGuiRenderPass dev surfaceFormat =
  let Vk26.SurfaceFormatKHR imageFormat _ = surfaceFormat
      colorAttachment =
        Vk26.AttachmentDescription
          zero
          imageFormat
          Vk26.SAMPLE_COUNT_1_BIT
          Vk26.ATTACHMENT_LOAD_OP_LOAD
          Vk26.ATTACHMENT_STORE_OP_STORE
          Vk26.ATTACHMENT_LOAD_OP_DONT_CARE
          Vk26.ATTACHMENT_STORE_OP_DONT_CARE
          Vk26.IMAGE_LAYOUT_PRESENT_SRC_KHR
          Vk26.IMAGE_LAYOUT_PRESENT_SRC_KHR
      colorAttachmentRef =
        Vk26.AttachmentReference 0 Vk26.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
      subpass =
        Vk26.SubpassDescription
          zero
          Vk26.PIPELINE_BIND_POINT_GRAPHICS
          Vector.empty
          (Vector.fromList [colorAttachmentRef])
          Vector.empty
          Nothing
          Vector.empty
      dependency =
        Vk26.SubpassDependency
          Vk26.SUBPASS_EXTERNAL
          0
          Vk26.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
          Vk26.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
          Vk26.ACCESS_COLOR_ATTACHMENT_WRITE_BIT
          Vk26.ACCESS_COLOR_ATTACHMENT_WRITE_BIT
          zero
      renderPassCI =
        Vk26.RenderPassCreateInfo
          ()
          zero
          (Vector.fromList [colorAttachment])
          (Vector.fromList [subpass])
          (Vector.fromList [dependency])
   in liftIO $ Vk26.createRenderPass dev renderPassCI Nothing
