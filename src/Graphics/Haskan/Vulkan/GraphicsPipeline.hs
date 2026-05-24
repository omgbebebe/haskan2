module Graphics.Haskan.Vulkan.GraphicsPipeline where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Bits ((.|.))
import Foreign qualified
import Foreign.C qualified
import Graphics.Haskan.Render.ShaderProgram (ShaderProgram (..), stageCount, toPipelineStages)
import Graphics.Haskan.Resources (alloc, allocaAndPeek)
import Graphics.Haskan.Vertex (Vertex)
import Graphics.Haskan.Vulkan.VertexFormat (VertexFormat)
import Graphics.Haskan.Vulkan.VertexFormat qualified as VertexFormat
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, setAt, setListRef, setStrRef, setVkRef, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan
import Linear (V3 (..))

managedGraphicsPipelineWithCull ::
  (MonadManaged m) =>
  Vulkan.VkDevice ->
  Vulkan.VkPipelineLayout ->
  Vulkan.VkRenderPass ->
  ShaderProgram ->
  Vulkan.VkExtent2D ->
  VertexFormat v ->
  Int ->
  Vulkan.VkCullModeFlags ->
  m Vulkan.VkPipeline
managedGraphicsPipelineWithCull dev layout renderPass shaderProgram swapchainExtent vertexFormat colorAttachmentCount cullMode =
  alloc
    "GraphicsPipeline"
    (createGraphicsPipeline dev layout renderPass shaderProgram swapchainExtent vertexFormat colorAttachmentCount cullMode)
    (\ptr -> Vulkan.vkDestroyPipeline dev ptr Vulkan.vkNullPtr)

managedGraphicsPipeline ::
  (MonadManaged m) =>
  Vulkan.VkDevice ->
  Vulkan.VkPipelineLayout ->
  Vulkan.VkRenderPass ->
  ShaderProgram ->
  Vulkan.VkExtent2D ->
  VertexFormat v ->
  Int ->
  m Vulkan.VkPipeline
managedGraphicsPipeline dev layout renderPass shaderProgram swapchainExtent vertexFormat colorAttachmentCount =
  managedGraphicsPipelineWithCull dev layout renderPass shaderProgram swapchainExtent vertexFormat colorAttachmentCount Vulkan.VK_CULL_MODE_BACK_BIT

createGraphicsPipeline ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkPipelineLayout ->
  Vulkan.VkRenderPass ->
  ShaderProgram ->
  Vulkan.VkExtent2D ->
  VertexFormat v ->
  Int ->
  Vulkan.VkCullModeFlags ->
  m Vulkan.VkPipeline
createGraphicsPipeline dev layout renderPass shaderProgram swapchainExtent vertexFormat colorAttachmentCount cullMode = do
  let stages = toPipelineStages shaderProgram
      numStages = stageCount shaderProgram
      positionBindingDescription =
        Vulkan.createVk
          ( set @"binding" 0
              &* set @"stride" (fromIntegral (VertexFormat.strideSize vertexFormat))
              &* set @"inputRate" Vulkan.VK_VERTEX_INPUT_RATE_VERTEX
          )
      vertexAttributeDescriptions = VertexFormat.attributeDescriptions 0 vertexFormat

      vertexInputStateCI =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"vertexBindingDescriptionCount" 1
              &* setListRef @"pVertexBindingDescriptions"
                [ positionBindingDescription
                ]
              &* set @"vertexAttributeDescriptionCount" (fromIntegral (length vertexAttributeDescriptions))
              &* setListRef @"pVertexAttributeDescriptions" vertexAttributeDescriptions
          )
      assemblyInputStateCI =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"topology" Vulkan.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
              &* set @"primitiveRestartEnable" Vulkan.VK_FALSE
          )
      tessellationState = Vulkan.VK_NULL

      viewport =
        let w = fromIntegral (Vulkan.getField @"width" swapchainExtent)
            h = fromIntegral (Vulkan.getField @"height" swapchainExtent)
         in Vulkan.createVk
              ( set @"x" 0
                  &* set @"y" h
                  &* set @"width" w
                  &* set @"height" (-h)
                  &* set @"minDepth" 0.0
                  &* set @"maxDepth" 1.0
              )
      scissor =
        let offset =
              Vulkan.createVk
                ( set @"x" 0
                    &* set @"y" 0
                )
         in Vulkan.createVk
              ( set @"offset" offset
                  &* set @"extent" swapchainExtent
              )
      viewportState =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"viewportCount" 1
              &* setListRef @"pViewports" [viewport]
              &* set @"scissorCount" 1
              &* setListRef @"pScissors" [scissor]
          )

      rasterizationState =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"depthClampEnable" Vulkan.VK_FALSE
              &* set @"rasterizerDiscardEnable" Vulkan.VK_FALSE
              &* set @"polygonMode" Vulkan.VK_POLYGON_MODE_FILL
              &* set @"lineWidth" 1.0
              &* set @"cullMode" cullMode
              &* set @"frontFace" Vulkan.VK_FRONT_FACE_COUNTER_CLOCKWISE
              &* set @"depthBiasEnable" Vulkan.VK_FALSE
              &* set @"depthBiasConstantFactor" 0.0
              &* set @"depthBiasClamp" 0.0
              &* set @"depthBiasSlopeFactor" 0.0
          )
      multisampleState =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"sampleShadingEnable" Vulkan.VK_FALSE
              &* set @"rasterizationSamples" Vulkan.VK_SAMPLE_COUNT_1_BIT
              &* set @"minSampleShading" 1.0
              &* set @"pSampleMask" Vulkan.VK_NULL
              &* set @"alphaToCoverageEnable" Vulkan.VK_FALSE
              &* set @"alphaToOneEnable" Vulkan.VK_FALSE
          )
      depthStencilState =
        let nullStencilOp =
              Vulkan.createVk
                ( set @"failOp" Vulkan.VK_STENCIL_OP_KEEP
                    &* set @"passOp" Vulkan.VK_STENCIL_OP_KEEP
                    &* set @"depthFailOp" Vulkan.VK_STENCIL_OP_KEEP
                    &* set @"compareOp" Vulkan.VK_COMPARE_OP_ALWAYS
                    &* set @"compareMask" 0
                    &* set @"writeMask" 0
                    &* set @"reference" 0
                )
         in Vulkan.createVk
              ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO
                  &* set @"pNext" Vulkan.VK_NULL
                  &* set @"flags" Vulkan.VK_ZERO_FLAGS
                  &* set @"depthTestEnable" Vulkan.VK_TRUE
                  &* set @"depthWriteEnable" Vulkan.VK_TRUE
                  &* set @"depthCompareOp" Vulkan.VK_COMPARE_OP_LESS_OR_EQUAL
                  --         &* set @"depthCompareOp" Vulkan.VK_COMPARE_OP_GREATER_OR_EQUAL
                  &* set @"depthBoundsTestEnable" Vulkan.VK_FALSE
                  &* set @"stencilTestEnable" Vulkan.VK_FALSE
                  &* set @"front" nullStencilOp
                  &* set @"back" nullStencilOp
                  &* set @"minDepthBounds" 0
                  &* set @"maxDepthBounds" 1
              )
      colorBlendState =
        let colorBlendAttachment =
              Vulkan.createVk
                ( set @"colorWriteMask"
                    ( Vulkan.VK_COLOR_COMPONENT_R_BIT
                        .|. Vulkan.VK_COLOR_COMPONENT_G_BIT
                        .|. Vulkan.VK_COLOR_COMPONENT_B_BIT
                        .|. Vulkan.VK_COLOR_COMPONENT_A_BIT
                    )
                    &* set @"blendEnable" Vulkan.VK_FALSE
                    &* set @"srcColorBlendFactor" Vulkan.VK_BLEND_FACTOR_ONE
                    &* set @"dstColorBlendFactor" Vulkan.VK_BLEND_FACTOR_ZERO
                    &* set @"colorBlendOp" Vulkan.VK_BLEND_OP_ADD
                    &* set @"srcAlphaBlendFactor" Vulkan.VK_BLEND_FACTOR_ONE
                    &* set @"dstAlphaBlendFactor" Vulkan.VK_BLEND_FACTOR_ZERO
                    &* set @"alphaBlendOp" Vulkan.VK_BLEND_OP_ADD
                )
         in Vulkan.createVk
              ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO
                  &* set @"pNext" Vulkan.VK_NULL
                  &* set @"logicOpEnable" Vulkan.VK_FALSE
                  &* set @"logicOp" Vulkan.VK_LOGIC_OP_COPY
                  &* set @"attachmentCount" (fromIntegral colorAttachmentCount)
                  &* setListRef @"pAttachments" (replicate colorAttachmentCount colorBlendAttachment)
                  &* setAt @"blendConstants" @0 0.0
                  &* setAt @"blendConstants" @1 0.0
                  &* setAt @"blendConstants" @2 0.0
                  &* setAt @"blendConstants" @3 0.0
              )
      {- TODO
          dynamicState = Vulkan.createVk
            (  set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO
            &* set @"pNext" Vulkan.VK_NULL
            &* set @"dynamicStateCount" 1
            &* setListRef @"pDynamicStates" [Vulkan.VK_DYNAMIC_STATE_VIEWPORT]
            )
      -}
      dynamicState =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dynamicStateCount" 0
              &* setListRef @"pDynamicStates" []
          )
      subpass = 0
      basePipelineHandle = Vulkan.VK_NULL_HANDLE
      basePipelineIndex = (-1)
      pipelineCI =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"stageCount" (fromIntegral numStages)
              &* setListRef @"pStages" stages
              &* setVkRef @"pVertexInputState" vertexInputStateCI
              &* setVkRef @"pInputAssemblyState" assemblyInputStateCI
              &* set @"pTessellationState" tessellationState
              &* setVkRef @"pViewportState" viewportState
              &* setVkRef @"pRasterizationState" rasterizationState
              &* setVkRef @"pMultisampleState" multisampleState
              &* setVkRef @"pDepthStencilState" depthStencilState
              &* setVkRef @"pColorBlendState" colorBlendState
              &* setVkRef @"pDynamicState" dynamicState
              &* set @"layout" layout
              &* set @"renderPass" renderPass
              &* set @"subpass" subpass
              &* set @"basePipelineHandle" basePipelineHandle
              &* set @"basePipelineIndex" basePipelineIndex
          )
   in liftIO $
        withPtr
          pipelineCI
          ( \pciPtr ->
              allocaAndPeek $ Vulkan.vkCreateGraphicsPipelines dev Vulkan.VK_NULL 1 pciPtr Vulkan.VK_NULL
          )

-- ---------------------------------------------------------------------------
-- Fullscreen triangle pipeline (no vertex input)
-- ---------------------------------------------------------------------------

managedFullscreenPipeline ::
  (MonadManaged m) =>
  Vulkan.VkDevice ->
  Vulkan.VkPipelineLayout ->
  Vulkan.VkRenderPass ->
  ShaderProgram ->
  Vulkan.VkExtent2D ->
  m Vulkan.VkPipeline
managedFullscreenPipeline dev layout renderPass shaderProgram swapchainExtent =
  alloc
    "FullscreenPipeline"
    (createFullscreenPipeline dev layout renderPass shaderProgram swapchainExtent)
    (\ptr -> Vulkan.vkDestroyPipeline dev ptr Vulkan.vkNullPtr)

createFullscreenPipeline ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkPipelineLayout ->
  Vulkan.VkRenderPass ->
  ShaderProgram ->
  Vulkan.VkExtent2D ->
  m Vulkan.VkPipeline
createFullscreenPipeline dev layout renderPass shaderProgram swapchainExtent = do
  let stages = toPipelineStages shaderProgram
      numStages = stageCount shaderProgram
      vertexInputStateCI =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"vertexBindingDescriptionCount" 0
              &* setListRef @"pVertexBindingDescriptions" []
              &* set @"vertexAttributeDescriptionCount" 0
              &* setListRef @"pVertexAttributeDescriptions" []
          )
      assemblyInputStateCI =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"topology" Vulkan.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
              &* set @"primitiveRestartEnable" Vulkan.VK_FALSE
          )
      tessellationState = Vulkan.VK_NULL

      viewport =
        let w = fromIntegral (Vulkan.getField @"width" swapchainExtent)
            h = fromIntegral (Vulkan.getField @"height" swapchainExtent)
         in Vulkan.createVk
              ( set @"x" 0
                  &* set @"y" h
                  &* set @"width" w
                  &* set @"height" (-h)
                  &* set @"minDepth" 0.0
                  &* set @"maxDepth" 1.0
              )
      scissor =
        let offset =
              Vulkan.createVk
                ( set @"x" 0
                    &* set @"y" 0
                )
         in Vulkan.createVk
              ( set @"offset" offset
                  &* set @"extent" swapchainExtent
              )
      viewportState =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"viewportCount" 1
              &* setListRef @"pViewports" [viewport]
              &* set @"scissorCount" 1
              &* setListRef @"pScissors" [scissor]
          )

      rasterizationState =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"depthClampEnable" Vulkan.VK_FALSE
              &* set @"rasterizerDiscardEnable" Vulkan.VK_FALSE
              &* set @"polygonMode" Vulkan.VK_POLYGON_MODE_FILL
              &* set @"lineWidth" 1.0
              &* set @"cullMode" Vulkan.VK_CULL_MODE_NONE
              &* set @"frontFace" Vulkan.VK_FRONT_FACE_COUNTER_CLOCKWISE
              &* set @"depthBiasEnable" Vulkan.VK_FALSE
              &* set @"depthBiasConstantFactor" 0.0
              &* set @"depthBiasClamp" 0.0
              &* set @"depthBiasSlopeFactor" 0.0
          )
      multisampleState =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"sampleShadingEnable" Vulkan.VK_FALSE
              &* set @"rasterizationSamples" Vulkan.VK_SAMPLE_COUNT_1_BIT
              &* set @"minSampleShading" 1.0
              &* set @"pSampleMask" Vulkan.VK_NULL
              &* set @"alphaToCoverageEnable" Vulkan.VK_FALSE
              &* set @"alphaToOneEnable" Vulkan.VK_FALSE
          )
      depthStencilState =
        let nullStencilOp =
              Vulkan.createVk
                ( set @"failOp" Vulkan.VK_STENCIL_OP_KEEP
                    &* set @"passOp" Vulkan.VK_STENCIL_OP_KEEP
                    &* set @"depthFailOp" Vulkan.VK_STENCIL_OP_KEEP
                    &* set @"compareOp" Vulkan.VK_COMPARE_OP_ALWAYS
                    &* set @"compareMask" 0
                    &* set @"writeMask" 0
                    &* set @"reference" 0
                )
         in Vulkan.createVk
              ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO
                  &* set @"pNext" Vulkan.VK_NULL
                  &* set @"flags" Vulkan.VK_ZERO_FLAGS
                  &* set @"depthTestEnable" Vulkan.VK_FALSE
                  &* set @"depthWriteEnable" Vulkan.VK_FALSE
                  &* set @"depthCompareOp" Vulkan.VK_COMPARE_OP_LESS_OR_EQUAL
                  &* set @"depthBoundsTestEnable" Vulkan.VK_FALSE
                  &* set @"stencilTestEnable" Vulkan.VK_FALSE
                  &* set @"front" nullStencilOp
                  &* set @"back" nullStencilOp
                  &* set @"minDepthBounds" 0
                  &* set @"maxDepthBounds" 1
              )
      colorBlendState =
        let colorBlendAttachment =
              Vulkan.createVk
                ( set @"colorWriteMask"
                    ( Vulkan.VK_COLOR_COMPONENT_R_BIT
                        .|. Vulkan.VK_COLOR_COMPONENT_G_BIT
                        .|. Vulkan.VK_COLOR_COMPONENT_B_BIT
                        .|. Vulkan.VK_COLOR_COMPONENT_A_BIT
                    )
                    &* set @"blendEnable" Vulkan.VK_FALSE
                    &* set @"srcColorBlendFactor" Vulkan.VK_BLEND_FACTOR_ONE
                    &* set @"dstColorBlendFactor" Vulkan.VK_BLEND_FACTOR_ZERO
                    &* set @"colorBlendOp" Vulkan.VK_BLEND_OP_ADD
                    &* set @"srcAlphaBlendFactor" Vulkan.VK_BLEND_FACTOR_ONE
                    &* set @"dstAlphaBlendFactor" Vulkan.VK_BLEND_FACTOR_ZERO
                    &* set @"alphaBlendOp" Vulkan.VK_BLEND_OP_ADD
                )
         in Vulkan.createVk
              ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO
                  &* set @"pNext" Vulkan.VK_NULL
                  &* set @"logicOpEnable" Vulkan.VK_FALSE
                  &* set @"logicOp" Vulkan.VK_LOGIC_OP_COPY
                  &* set @"attachmentCount" 1
                  &* setListRef @"pAttachments" [colorBlendAttachment]
                  &* setAt @"blendConstants" @0 0.0
                  &* setAt @"blendConstants" @1 0.0
                  &* setAt @"blendConstants" @2 0.0
                  &* setAt @"blendConstants" @3 0.0
              )
      dynamicState =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dynamicStateCount" 0
              &* setListRef @"pDynamicStates" []
          )
      subpass = 0
      basePipelineHandle = Vulkan.VK_NULL_HANDLE
      basePipelineIndex = (-1)
      pipelineCI =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"stageCount" (fromIntegral numStages)
              &* setListRef @"pStages" stages
              &* setVkRef @"pVertexInputState" vertexInputStateCI
              &* setVkRef @"pInputAssemblyState" assemblyInputStateCI
              &* set @"pTessellationState" tessellationState
              &* setVkRef @"pViewportState" viewportState
              &* setVkRef @"pRasterizationState" rasterizationState
              &* setVkRef @"pMultisampleState" multisampleState
              &* setVkRef @"pDepthStencilState" depthStencilState
              &* setVkRef @"pColorBlendState" colorBlendState
              &* setVkRef @"pDynamicState" dynamicState
              &* set @"layout" layout
              &* set @"renderPass" renderPass
              &* set @"subpass" subpass
              &* set @"basePipelineHandle" basePipelineHandle
              &* set @"basePipelineIndex" basePipelineIndex
          )
   in liftIO $
        withPtr
          pipelineCI
          ( \pciPtr ->
              allocaAndPeek $ Vulkan.vkCreateGraphicsPipelines dev Vulkan.VK_NULL 1 pciPtr Vulkan.VK_NULL
          )

cmdBindPipeline :: (MonadIO m) => Vulkan.VkCommandBuffer -> Vulkan.VkPipeline -> m ()
cmdBindPipeline commandBuffer pipeline =
  liftIO $
    Vulkan.vkCmdBindPipeline commandBuffer Vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS pipeline -- >>= throwVkResult

-- | Fullscreen triangle pipeline with alpha blending enabled.
-- Used for overlay passes that blend with existing framebuffer contents.
managedFullscreenPipelineWithBlending ::
  (MonadManaged m) =>
  Vulkan.VkDevice ->
  Vulkan.VkPipelineLayout ->
  Vulkan.VkRenderPass ->
  ShaderProgram ->
  Vulkan.VkExtent2D ->
  m Vulkan.VkPipeline
managedFullscreenPipelineWithBlending dev layout renderPass shaderProgram swapchainExtent =
  alloc
    "FullscreenPipelineWithBlending"
    (createFullscreenPipelineWithBlending dev layout renderPass shaderProgram swapchainExtent)
    (\ptr -> Vulkan.vkDestroyPipeline dev ptr Vulkan.vkNullPtr)

createFullscreenPipelineWithBlending ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkPipelineLayout ->
  Vulkan.VkRenderPass ->
  ShaderProgram ->
  Vulkan.VkExtent2D ->
  m Vulkan.VkPipeline
createFullscreenPipelineWithBlending dev layout renderPass shaderProgram swapchainExtent = do
  let stages = toPipelineStages shaderProgram
      numStages = stageCount shaderProgram
      vertexInputStateCI =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"vertexBindingDescriptionCount" 0
              &* setListRef @"pVertexBindingDescriptions" []
              &* set @"vertexAttributeDescriptionCount" 0
              &* setListRef @"pVertexAttributeDescriptions" []
          )
      assemblyInputStateCI =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"topology" Vulkan.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
              &* set @"primitiveRestartEnable" Vulkan.VK_FALSE
          )
      tessellationState = Vulkan.VK_NULL
      viewport =
        let w = fromIntegral (Vulkan.getField @"width" swapchainExtent)
            h = fromIntegral (Vulkan.getField @"height" swapchainExtent)
         in Vulkan.createVk
              ( set @"x" 0
                  &* set @"y" h
                  &* set @"width" w
                  &* set @"height" (-h)
                  &* set @"minDepth" 0.0
                  &* set @"maxDepth" 1.0
              )
      scissor =
        let offset =
              Vulkan.createVk
                ( set @"x" 0
                    &* set @"y" 0
                )
         in Vulkan.createVk
              ( set @"offset" offset
                  &* set @"extent" swapchainExtent
              )
      viewportState =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"viewportCount" 1
              &* setListRef @"pViewports" [viewport]
              &* set @"scissorCount" 1
              &* setListRef @"pScissors" [scissor]
          )
      rasterizationState =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"depthClampEnable" Vulkan.VK_FALSE
              &* set @"rasterizerDiscardEnable" Vulkan.VK_FALSE
              &* set @"polygonMode" Vulkan.VK_POLYGON_MODE_FILL
              &* set @"lineWidth" 1.0
              &* set @"cullMode" Vulkan.VK_CULL_MODE_NONE
              &* set @"frontFace" Vulkan.VK_FRONT_FACE_COUNTER_CLOCKWISE
              &* set @"depthBiasEnable" Vulkan.VK_FALSE
              &* set @"depthBiasConstantFactor" 0.0
              &* set @"depthBiasClamp" 0.0
              &* set @"depthBiasSlopeFactor" 0.0
          )
      multisampleState =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"sampleShadingEnable" Vulkan.VK_FALSE
              &* set @"rasterizationSamples" Vulkan.VK_SAMPLE_COUNT_1_BIT
              &* set @"minSampleShading" 1.0
              &* set @"pSampleMask" Vulkan.VK_NULL
              &* set @"alphaToCoverageEnable" Vulkan.VK_FALSE
              &* set @"alphaToOneEnable" Vulkan.VK_FALSE
          )
      depthStencilState =
        let nullStencilOp =
              Vulkan.createVk
                ( set @"failOp" Vulkan.VK_STENCIL_OP_KEEP
                    &* set @"passOp" Vulkan.VK_STENCIL_OP_KEEP
                    &* set @"depthFailOp" Vulkan.VK_STENCIL_OP_KEEP
                    &* set @"compareOp" Vulkan.VK_COMPARE_OP_ALWAYS
                    &* set @"compareMask" 0
                    &* set @"writeMask" 0
                    &* set @"reference" 0
                )
         in Vulkan.createVk
              ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO
                  &* set @"pNext" Vulkan.VK_NULL
                  &* set @"flags" Vulkan.VK_ZERO_FLAGS
                  &* set @"depthTestEnable" Vulkan.VK_FALSE
                  &* set @"depthWriteEnable" Vulkan.VK_FALSE
                  &* set @"depthCompareOp" Vulkan.VK_COMPARE_OP_LESS_OR_EQUAL
                  &* set @"depthBoundsTestEnable" Vulkan.VK_FALSE
                  &* set @"stencilTestEnable" Vulkan.VK_FALSE
                  &* set @"front" nullStencilOp
                  &* set @"back" nullStencilOp
                  &* set @"minDepthBounds" 0
                  &* set @"maxDepthBounds" 1
              )
      colorBlendAttachment =
        Vulkan.createVk
          ( set @"colorWriteMask"
              ( Vulkan.VK_COLOR_COMPONENT_R_BIT
                  .|. Vulkan.VK_COLOR_COMPONENT_G_BIT
                  .|. Vulkan.VK_COLOR_COMPONENT_B_BIT
                  .|. Vulkan.VK_COLOR_COMPONENT_A_BIT
              )
              &* set @"blendEnable" Vulkan.VK_TRUE
              &* set @"srcColorBlendFactor" Vulkan.VK_BLEND_FACTOR_SRC_ALPHA
              &* set @"dstColorBlendFactor" Vulkan.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
              &* set @"colorBlendOp" Vulkan.VK_BLEND_OP_ADD
              &* set @"srcAlphaBlendFactor" Vulkan.VK_BLEND_FACTOR_ONE
              &* set @"dstAlphaBlendFactor" Vulkan.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
              &* set @"alphaBlendOp" Vulkan.VK_BLEND_OP_ADD
          )
      colorBlendState =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"logicOpEnable" Vulkan.VK_FALSE
              &* set @"logicOp" Vulkan.VK_LOGIC_OP_COPY
              &* set @"attachmentCount" 1
              &* setListRef @"pAttachments" [colorBlendAttachment]
              &* setAt @"blendConstants" @0 0.0
              &* setAt @"blendConstants" @1 0.0
              &* setAt @"blendConstants" @2 0.0
              &* setAt @"blendConstants" @3 0.0
          )
      dynamicState =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dynamicStateCount" 0
              &* setListRef @"pDynamicStates" []
          )
      subpass = 0
      basePipelineHandle = Vulkan.VK_NULL_HANDLE
      basePipelineIndex = (-1)
      pipelineCI =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"stageCount" (fromIntegral numStages)
              &* setListRef @"pStages" stages
              &* setVkRef @"pVertexInputState" vertexInputStateCI
              &* setVkRef @"pInputAssemblyState" assemblyInputStateCI
              &* set @"pTessellationState" tessellationState
              &* setVkRef @"pViewportState" viewportState
              &* setVkRef @"pRasterizationState" rasterizationState
              &* setVkRef @"pMultisampleState" multisampleState
              &* setVkRef @"pDepthStencilState" depthStencilState
              &* setVkRef @"pColorBlendState" colorBlendState
              &* setVkRef @"pDynamicState" dynamicState
              &* set @"layout" layout
              &* set @"renderPass" renderPass
              &* set @"subpass" subpass
              &* set @"basePipelineHandle" basePipelineHandle
              &* set @"basePipelineIndex" basePipelineIndex
          )
   in liftIO $
        withPtr
          pipelineCI
          ( \pciPtr ->
              allocaAndPeek $ Vulkan.vkCreateGraphicsPipelines dev Vulkan.VK_NULL 1 pciPtr Vulkan.VK_NULL
          )
