module Graphics.Haskan.Vulkan.RenderPass where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Bits ((.|.))
import Graphics.Haskan.Resources (alloc, allocaAndPeek)
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Ext qualified as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, setAt, setListRef, setVkRef, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan

managedRenderPass ::
  (MonadManaged m) =>
  Vulkan.VkDevice ->
  Vulkan.VkSurfaceFormatKHR ->
  Vulkan.VkFormat ->
  m Vulkan.VkRenderPass
managedRenderPass dev surfaceFormat depthFormat =
  alloc
    "RenderPass"
    (createRenderPass dev surfaceFormat depthFormat)
    (\ptr -> Vulkan.vkDestroyRenderPass dev ptr Vulkan.vkNullPtr)

createRenderPass ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkSurfaceFormatKHR ->
  Vulkan.VkFormat ->
  m Vulkan.VkRenderPass
createRenderPass dev surfaceFormat depthFormat =
  let imageFormat = Vulkan.getField @"format" surfaceFormat
      colorAttachment =
        Vulkan.createVk
          ( set @"format" imageFormat
              &* set @"samples" Vulkan.VK_SAMPLE_COUNT_1_BIT
              &* set @"loadOp" Vulkan.VK_ATTACHMENT_LOAD_OP_CLEAR
              &* set @"storeOp" Vulkan.VK_ATTACHMENT_STORE_OP_STORE
              &* set @"stencilLoadOp" Vulkan.VK_ATTACHMENT_LOAD_OP_DONT_CARE
              &* set @"stencilStoreOp" Vulkan.VK_ATTACHMENT_STORE_OP_DONT_CARE
              &* set @"initialLayout" Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
              &* set @"finalLayout" Vulkan.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR
          )
      colorAttachmentRef =
        Vulkan.createVk
          ( set @"attachment" 0
              &* set @"layout" Vulkan.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
          )
      depthAttachment =
        Vulkan.createVk
          ( set @"format" depthFormat
              &* set @"samples" Vulkan.VK_SAMPLE_COUNT_1_BIT
              &* set @"loadOp" Vulkan.VK_ATTACHMENT_LOAD_OP_CLEAR
              &* set @"storeOp" Vulkan.VK_ATTACHMENT_STORE_OP_DONT_CARE
              &* set @"stencilLoadOp" Vulkan.VK_ATTACHMENT_LOAD_OP_DONT_CARE
              &* set @"stencilStoreOp" Vulkan.VK_ATTACHMENT_STORE_OP_DONT_CARE
              &* set @"initialLayout" Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
              &* set @"finalLayout" Vulkan.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
          )
      depthAttachmentRef =
        Vulkan.createVk
          ( set @"attachment" 1
              &* set @"layout" Vulkan.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
          )
      subpass =
        Vulkan.createVk
          ( set @"pipelineBindPoint" Vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS
              &* set @"colorAttachmentCount" 1
              &* setListRef @"pColorAttachments" [colorAttachmentRef]
              &* set @"inputAttachmentCount" 0
              &* setListRef @"pInputAttachments" []
              &* setVkRef @"pDepthStencilAttachment" depthAttachmentRef
              &* set @"preserveAttachmentCount" 0
              &* setListRef @"pPreserveAttachments" []
          )
      dependency =
        Vulkan.createVk
          ( set @"srcSubpass" Vulkan.VK_SUBPASS_EXTERNAL
              &* set @"dstSubpass" 0
              &* set @"srcStageMask" Vulkan.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
              &* set @"srcAccessMask" Vulkan.VK_ZERO_FLAGS
              &* set @"dstStageMask" Vulkan.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
              &* set @"dstAccessMask" Vulkan.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT
          )
      renderPassCI =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"attachmentCount" 2
              &* setListRef @"pAttachments" [colorAttachment, depthAttachment]
              &* set @"subpassCount" 1
              &* setListRef @"pSubpasses" [subpass]
              &* set @"dependencyCount" 1
              &* setListRef @"pDependencies" [dependency]
          )
   in liftIO $ withPtr renderPassCI (\rpciPtr -> allocaAndPeek (Vulkan.vkCreateRenderPass dev rpciPtr Vulkan.VK_NULL))

-- ---------------------------------------------------------------------------
-- G-buffer render pass: 3 color attachments + depth
-- ---------------------------------------------------------------------------

managedGBufferRenderPass ::
  (MonadManaged m) =>
  Vulkan.VkDevice ->
  Vulkan.VkFormat ->
  Vulkan.VkFormat ->
  m Vulkan.VkRenderPass
managedGBufferRenderPass dev colorFormat depthFormat =
  alloc
    "GBufferRenderPass"
    (createGBufferRenderPass dev colorFormat depthFormat)
    (\ptr -> Vulkan.vkDestroyRenderPass dev ptr Vulkan.vkNullPtr)

createGBufferRenderPass ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkFormat ->
  Vulkan.VkFormat ->
  m Vulkan.VkRenderPass
createGBufferRenderPass dev colorFormat depthFormat =
  let mkColorAttachment fmt =
        Vulkan.createVk
          ( set @"format" fmt
              &* set @"samples" Vulkan.VK_SAMPLE_COUNT_1_BIT
              &* set @"loadOp" Vulkan.VK_ATTACHMENT_LOAD_OP_CLEAR
              &* set @"storeOp" Vulkan.VK_ATTACHMENT_STORE_OP_STORE
              &* set @"stencilLoadOp" Vulkan.VK_ATTACHMENT_LOAD_OP_DONT_CARE
              &* set @"stencilStoreOp" Vulkan.VK_ATTACHMENT_STORE_OP_DONT_CARE
              &* set @"initialLayout" Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
              &* set @"finalLayout" Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
          )
      colorAttachments =
        [ mkColorAttachment colorFormat, -- position
          mkColorAttachment colorFormat, -- normal
          mkColorAttachment colorFormat, -- albedo
          mkColorAttachment colorFormat -- material (metallic, roughness, AO)
        ]
      colorAttachmentRefs =
        [ Vulkan.createVk
            ( set @"attachment" i
                &* set @"layout" Vulkan.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
            )
        | i <- [0 .. 3]
        ]
      depthAttachment =
        Vulkan.createVk
          ( set @"format" depthFormat
              &* set @"samples" Vulkan.VK_SAMPLE_COUNT_1_BIT
              &* set @"loadOp" Vulkan.VK_ATTACHMENT_LOAD_OP_CLEAR
              &* set @"storeOp" Vulkan.VK_ATTACHMENT_STORE_OP_DONT_CARE
              &* set @"stencilLoadOp" Vulkan.VK_ATTACHMENT_LOAD_OP_DONT_CARE
              &* set @"stencilStoreOp" Vulkan.VK_ATTACHMENT_STORE_OP_DONT_CARE
              &* set @"initialLayout" Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
              &* set @"finalLayout" Vulkan.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
          )
      depthAttachmentRef =
        Vulkan.createVk
          ( set @"attachment" 4
              &* set @"layout" Vulkan.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
          )
      subpass =
        Vulkan.createVk
          ( set @"pipelineBindPoint" Vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS
              &* set @"colorAttachmentCount" 4
              &* setListRef @"pColorAttachments" colorAttachmentRefs
              &* set @"inputAttachmentCount" 0
              &* setListRef @"pInputAttachments" []
              &* setVkRef @"pDepthStencilAttachment" depthAttachmentRef
              &* set @"preserveAttachmentCount" 0
              &* setListRef @"pPreserveAttachments" []
          )
      dependency =
        Vulkan.createVk
          ( set @"srcSubpass" Vulkan.VK_SUBPASS_EXTERNAL
              &* set @"dstSubpass" 0
              &* set @"srcStageMask" Vulkan.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
              &* set @"srcAccessMask" Vulkan.VK_ZERO_FLAGS
              &* set @"dstStageMask" (Vulkan.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT .|. Vulkan.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT)
              &* set @"dstAccessMask" (Vulkan.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT .|. Vulkan.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT)
          )
      dependencyToExternal =
        Vulkan.createVk
          ( set @"srcSubpass" 0
              &* set @"dstSubpass" Vulkan.VK_SUBPASS_EXTERNAL
              &* set @"srcStageMask" Vulkan.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
              &* set @"srcAccessMask" Vulkan.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT
              &* set @"dstStageMask" Vulkan.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT
              &* set @"dstAccessMask" Vulkan.VK_ACCESS_SHADER_READ_BIT
          )
      renderPassCI =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"attachmentCount" 5
              &* setListRef @"pAttachments" (colorAttachments ++ [depthAttachment])
              &* set @"subpassCount" 1
              &* setListRef @"pSubpasses" [subpass]
              &* set @"dependencyCount" 2
              &* setListRef @"pDependencies" [dependency, dependencyToExternal]
          )
   in liftIO $ withPtr renderPassCI (\rpciPtr -> allocaAndPeek (Vulkan.vkCreateRenderPass dev rpciPtr Vulkan.VK_NULL))

managedGBufferRenderPassEx ::
  (MonadManaged m) =>
  Vulkan.VkDevice ->
  -- | position format (e.g. SFLOAT)
  Vulkan.VkFormat ->
  -- | other color formats (e.g. UNORM)
  Vulkan.VkFormat ->
  -- | depth format
  Vulkan.VkFormat ->
  m Vulkan.VkRenderPass
managedGBufferRenderPassEx dev posFormat colorFormat depthFormat =
  alloc
    "GBufferRenderPass"
    (createGBufferRenderPassEx dev posFormat colorFormat depthFormat)
    (\ptr -> Vulkan.vkDestroyRenderPass dev ptr Vulkan.vkNullPtr)

createGBufferRenderPassEx ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkFormat ->
  Vulkan.VkFormat ->
  Vulkan.VkFormat ->
  m Vulkan.VkRenderPass
createGBufferRenderPassEx dev posFormat colorFormat depthFormat =
  let mkColorAttachment fmt =
        Vulkan.createVk
          ( set @"format" fmt
              &* set @"samples" Vulkan.VK_SAMPLE_COUNT_1_BIT
              &* set @"loadOp" Vulkan.VK_ATTACHMENT_LOAD_OP_CLEAR
              &* set @"storeOp" Vulkan.VK_ATTACHMENT_STORE_OP_STORE
              &* set @"stencilLoadOp" Vulkan.VK_ATTACHMENT_LOAD_OP_DONT_CARE
              &* set @"stencilStoreOp" Vulkan.VK_ATTACHMENT_STORE_OP_DONT_CARE
              &* set @"initialLayout" Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
              &* set @"finalLayout" Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
          )
      colorAttachments =
        [ mkColorAttachment posFormat, -- position (needs negative values)
          mkColorAttachment colorFormat, -- normal
          mkColorAttachment colorFormat, -- albedo
          mkColorAttachment colorFormat -- emissive
        ]
      colorAttachmentRefs =
        [ Vulkan.createVk
            ( set @"attachment" i
                &* set @"layout" Vulkan.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
            )
        | i <- [0 .. 3]
        ]
      depthAttachment =
        Vulkan.createVk
          ( set @"format" depthFormat
              &* set @"samples" Vulkan.VK_SAMPLE_COUNT_1_BIT
              &* set @"loadOp" Vulkan.VK_ATTACHMENT_LOAD_OP_CLEAR
              &* set @"storeOp" Vulkan.VK_ATTACHMENT_STORE_OP_DONT_CARE
              &* set @"stencilLoadOp" Vulkan.VK_ATTACHMENT_LOAD_OP_DONT_CARE
              &* set @"stencilStoreOp" Vulkan.VK_ATTACHMENT_STORE_OP_DONT_CARE
              &* set @"initialLayout" Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
              &* set @"finalLayout" Vulkan.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
          )
      depthAttachmentRef =
        Vulkan.createVk
          ( set @"attachment" 4
              &* set @"layout" Vulkan.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
          )
      subpass =
        Vulkan.createVk
          ( set @"pipelineBindPoint" Vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS
              &* set @"colorAttachmentCount" 4
              &* setListRef @"pColorAttachments" colorAttachmentRefs
              &* set @"inputAttachmentCount" 0
              &* setListRef @"pInputAttachments" []
              &* setVkRef @"pDepthStencilAttachment" depthAttachmentRef
              &* set @"preserveAttachmentCount" 0
              &* setListRef @"pPreserveAttachments" []
          )
      dependency =
        Vulkan.createVk
          ( set @"srcSubpass" Vulkan.VK_SUBPASS_EXTERNAL
              &* set @"dstSubpass" 0
              &* set @"srcStageMask" Vulkan.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
              &* set @"srcAccessMask" Vulkan.VK_ZERO_FLAGS
              &* set @"dstStageMask" (Vulkan.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT .|. Vulkan.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT)
              &* set @"dstAccessMask" (Vulkan.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT .|. Vulkan.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT)
          )
      dependencyToExternal =
        Vulkan.createVk
          ( set @"srcSubpass" 0
              &* set @"dstSubpass" Vulkan.VK_SUBPASS_EXTERNAL
              &* set @"srcStageMask" Vulkan.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
              &* set @"srcAccessMask" Vulkan.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT
              &* set @"dstStageMask" Vulkan.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT
              &* set @"dstAccessMask" Vulkan.VK_ACCESS_SHADER_READ_BIT
          )
      renderPassCI =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"attachmentCount" 5
              &* setListRef @"pAttachments" (colorAttachments ++ [depthAttachment])
              &* set @"subpassCount" 1
              &* setListRef @"pSubpasses" [subpass]
              &* set @"dependencyCount" 2
              &* setListRef @"pDependencies" [dependency, dependencyToExternal]
          )
   in liftIO $ withPtr renderPassCI (\rpciPtr -> allocaAndPeek (Vulkan.vkCreateRenderPass dev rpciPtr Vulkan.VK_NULL))

-- ---------------------------------------------------------------------------
-- Lighting render pass: single color attachment (swapchain)
-- ---------------------------------------------------------------------------

managedLightingRenderPass ::
  (MonadManaged m) =>
  Vulkan.VkDevice ->
  Vulkan.VkSurfaceFormatKHR ->
  m Vulkan.VkRenderPass
managedLightingRenderPass dev surfaceFormat =
  alloc
    "LightingRenderPass"
    (createLightingRenderPass dev surfaceFormat)
    (\ptr -> Vulkan.vkDestroyRenderPass dev ptr Vulkan.vkNullPtr)

createLightingRenderPass ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkSurfaceFormatKHR ->
  m Vulkan.VkRenderPass
createLightingRenderPass dev surfaceFormat =
  let imageFormat = Vulkan.getField @"format" surfaceFormat
      colorAttachment =
        Vulkan.createVk
          ( set @"format" imageFormat
              &* set @"samples" Vulkan.VK_SAMPLE_COUNT_1_BIT
              &* set @"loadOp" Vulkan.VK_ATTACHMENT_LOAD_OP_CLEAR
              &* set @"storeOp" Vulkan.VK_ATTACHMENT_STORE_OP_STORE
              &* set @"stencilLoadOp" Vulkan.VK_ATTACHMENT_LOAD_OP_DONT_CARE
              &* set @"stencilStoreOp" Vulkan.VK_ATTACHMENT_STORE_OP_DONT_CARE
              &* set @"initialLayout" Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
              &* set @"finalLayout" Vulkan.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR
          )
      colorAttachmentRef =
        Vulkan.createVk
          ( set @"attachment" 0
              &* set @"layout" Vulkan.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
          )
      subpass =
        Vulkan.createVk
          ( set @"pipelineBindPoint" Vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS
              &* set @"colorAttachmentCount" 1
              &* setListRef @"pColorAttachments" [colorAttachmentRef]
              &* set @"inputAttachmentCount" 0
              &* setListRef @"pInputAttachments" []
              &* set @"preserveAttachmentCount" 0
              &* setListRef @"pPreserveAttachments" []
          )
      dependency =
        Vulkan.createVk
          ( set @"srcSubpass" Vulkan.VK_SUBPASS_EXTERNAL
              &* set @"dstSubpass" 0
              &* set @"srcStageMask" Vulkan.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
              &* set @"srcAccessMask" Vulkan.VK_ZERO_FLAGS
              &* set @"dstStageMask" Vulkan.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
              &* set @"dstAccessMask" Vulkan.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT
          )
      renderPassCI =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"attachmentCount" 1
              &* setListRef @"pAttachments" [colorAttachment]
              &* set @"subpassCount" 1
              &* setListRef @"pSubpasses" [subpass]
              &* set @"dependencyCount" 1
              &* setListRef @"pDependencies" [dependency]
          )
   in liftIO $ withPtr renderPassCI (\rpciPtr -> allocaAndPeek (Vulkan.vkCreateRenderPass dev rpciPtr Vulkan.VK_NULL))

withRenderPass ::
  (MonadIO m) =>
  Vulkan.VkCommandBuffer ->
  Vulkan.VkRenderPass ->
  Vulkan.VkFramebuffer ->
  Vulkan.VkExtent2D ->
  [Vulkan.VkClearValue] ->
  m a ->
  m a
withRenderPass commandBuffer renderPass framebuffer extent clearValues action =
  let offset =
        Vulkan.createVk
          ( set @"x" 0
              &* set @"y" 0
          )
      renderArea =
        Vulkan.createVk
          ( set @"offset" offset
              &* set @"extent" extent
          )
      beginInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
              &* set @"pNext" Vulkan.vkNullPtr
              &* set @"renderPass" renderPass
              &* set @"framebuffer" framebuffer
              &* set @"renderArea" renderArea
              &* set @"clearValueCount" (fromIntegral (length clearValues))
              &* setListRef @"pClearValues" clearValues
          )
      begin = liftIO $ withPtr beginInfo (\biPtr -> Vulkan.vkCmdBeginRenderPass commandBuffer biPtr Vulkan.VK_SUBPASS_CONTENTS_INLINE)
      end = liftIO $ Vulkan.vkCmdEndRenderPass commandBuffer
   in (begin *> action <* end)

withGBufferRenderPass ::
  (MonadIO m) =>
  Vulkan.VkCommandBuffer ->
  Vulkan.VkRenderPass ->
  Vulkan.VkFramebuffer ->
  Vulkan.VkExtent2D ->
  m a ->
  m a
withGBufferRenderPass commandBuffer renderPass framebuffer extent action =
  let posClear = Vulkan.createVk (setAt @"float32" @0 0.0 &* setAt @"float32" @1 0.0 &* setAt @"float32" @2 0.0 &* setAt @"float32" @3 0.0)
      normClear = Vulkan.createVk (setAt @"float32" @0 0.0 &* setAt @"float32" @1 0.0 &* setAt @"float32" @2 0.0 &* setAt @"float32" @3 0.0)
      albClear = Vulkan.createVk (setAt @"float32" @0 0.0 &* setAt @"float32" @1 0.0 &* setAt @"float32" @2 0.0 &* setAt @"float32" @3 0.0)
      matClear = Vulkan.createVk (setAt @"float32" @0 0.0 &* setAt @"float32" @1 0.5 &* setAt @"float32" @2 1.0 &* setAt @"float32" @3 1.0)
      depthClear = Vulkan.createVk (set @"depth" 1 &* set @"stencil" 0)
      clearValues =
        [ Vulkan.createVk (set @"color" posClear),
          Vulkan.createVk (set @"color" normClear),
          Vulkan.createVk (set @"color" albClear),
          Vulkan.createVk (set @"color" matClear),
          Vulkan.createVk (set @"depthStencil" depthClear)
        ]
   in withRenderPass commandBuffer renderPass framebuffer extent clearValues action

withLightingRenderPass ::
  (MonadIO m) =>
  Vulkan.VkCommandBuffer ->
  Vulkan.VkRenderPass ->
  Vulkan.VkFramebuffer ->
  Vulkan.VkExtent2D ->
  m a ->
  m a
withLightingRenderPass commandBuffer renderPass framebuffer extent action =
  let colorClear = Vulkan.createVk (setAt @"float32" @0 0.0 &* setAt @"float32" @1 0.0 &* setAt @"float32" @2 1.0 &* setAt @"float32" @3 1.0)
      clearValues = [Vulkan.createVk (set @"color" colorClear)]
   in withRenderPass commandBuffer renderPass framebuffer extent clearValues action

-- ---------------------------------------------------------------------------
-- Cloud render pass: single RGBA16F color attachment (intermediate texture)
-- ---------------------------------------------------------------------------

managedCloudRenderPass ::
  (MonadManaged m) =>
  Vulkan.VkDevice ->
  m Vulkan.VkRenderPass
managedCloudRenderPass dev =
  alloc
    "CloudRenderPass"
    (createCloudRenderPass dev)
    (\ptr -> Vulkan.vkDestroyRenderPass dev ptr Vulkan.vkNullPtr)

createCloudRenderPass ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  m Vulkan.VkRenderPass
createCloudRenderPass dev =
  let cloudFormat = Vulkan.VK_FORMAT_R16G16B16A16_SFLOAT
      colorAttachment =
        Vulkan.createVk
          ( set @"format" cloudFormat
              &* set @"samples" Vulkan.VK_SAMPLE_COUNT_1_BIT
              &* set @"loadOp" Vulkan.VK_ATTACHMENT_LOAD_OP_CLEAR
              &* set @"storeOp" Vulkan.VK_ATTACHMENT_STORE_OP_STORE
              &* set @"stencilLoadOp" Vulkan.VK_ATTACHMENT_LOAD_OP_DONT_CARE
              &* set @"stencilStoreOp" Vulkan.VK_ATTACHMENT_STORE_OP_DONT_CARE
              &* set @"initialLayout" Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
              &* set @"finalLayout" Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
          )
      colorAttachmentRef =
        Vulkan.createVk
          ( set @"attachment" 0
              &* set @"layout" Vulkan.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
          )
      subpass =
        Vulkan.createVk
          ( set @"pipelineBindPoint" Vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS
              &* set @"colorAttachmentCount" 1
              &* setListRef @"pColorAttachments" [colorAttachmentRef]
              &* set @"inputAttachmentCount" 0
              &* setListRef @"pInputAttachments" []
              &* set @"preserveAttachmentCount" 0
              &* setListRef @"pPreserveAttachments" []
          )
      dependency =
        Vulkan.createVk
          ( set @"srcSubpass" Vulkan.VK_SUBPASS_EXTERNAL
              &* set @"dstSubpass" 0
              &* set @"srcStageMask" Vulkan.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
              &* set @"srcAccessMask" Vulkan.VK_ZERO_FLAGS
              &* set @"dstStageMask" Vulkan.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
              &* set @"dstAccessMask" Vulkan.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT
          )
      dependencyToExternal =
        Vulkan.createVk
          ( set @"srcSubpass" 0
              &* set @"dstSubpass" Vulkan.VK_SUBPASS_EXTERNAL
              &* set @"srcStageMask" Vulkan.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
              &* set @"srcAccessMask" Vulkan.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT
              &* set @"dstStageMask" Vulkan.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT
              &* set @"dstAccessMask" Vulkan.VK_ACCESS_SHADER_READ_BIT
          )
      renderPassCI =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"attachmentCount" 1
              &* setListRef @"pAttachments" [colorAttachment]
              &* set @"subpassCount" 1
              &* setListRef @"pSubpasses" [subpass]
              &* set @"dependencyCount" 2
              &* setListRef @"pDependencies" [dependency, dependencyToExternal]
          )
   in liftIO $ withPtr renderPassCI (\rpciPtr -> allocaAndPeek (Vulkan.vkCreateRenderPass dev rpciPtr Vulkan.VK_NULL))

withCloudRenderPass ::
  (MonadIO m) =>
  Vulkan.VkCommandBuffer ->
  Vulkan.VkRenderPass ->
  Vulkan.VkFramebuffer ->
  Vulkan.VkExtent2D ->
  m a ->
  m a
withCloudRenderPass commandBuffer renderPass framebuffer extent action =
  let colorClear = Vulkan.createVk (setAt @"float32" @0 0.0 &* setAt @"float32" @1 0.0 &* setAt @"float32" @2 0.0 &* setAt @"float32" @3 0.0)
      clearValues = [Vulkan.createVk (set @"color" colorClear)]
   in withRenderPass commandBuffer renderPass framebuffer extent clearValues action
