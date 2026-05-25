{-# LANGUAGE DuplicateRecordFields #-}
module Graphics.Haskan.Vulkan.GraphicsPipeline where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Bits ((.|.))
import Data.Vector qualified as Vector
import Graphics.Haskan.Render.ShaderProgram (ShaderProgram (..), stageCount, toPipelineStages)
import Graphics.Haskan.Resources (alloc)
import Graphics.Haskan.Vertex (Vertex)
import Graphics.Haskan.Vulkan.VertexFormat (VertexFormat)
import Graphics.Haskan.Vulkan.VertexFormat qualified as VertexFormat
import Vulkan qualified
import Vulkan.Core10 qualified
import Vulkan.Zero (zero)
import Vulkan.CStruct.Extends (SomeStruct (..))
import Linear (V3 (..))

managedGraphicsPipelineWithCull ::
  (MonadManaged m) =>
  Vulkan.Device ->
  Vulkan.PipelineLayout ->
  Vulkan.RenderPass ->
  ShaderProgram ->
  Vulkan.Extent2D ->
  VertexFormat v ->
  Int ->
  Vulkan.CullModeFlags ->
  m Vulkan.Pipeline
managedGraphicsPipelineWithCull dev layout renderPass shaderProgram swapchainExtent vertexFormat colorAttachmentCount cullMode =
  alloc
    "GraphicsPipeline"
    (createGraphicsPipeline dev layout renderPass shaderProgram swapchainExtent vertexFormat colorAttachmentCount cullMode)
    (\ptr -> Vulkan.destroyPipeline dev ptr Nothing)

managedGraphicsPipeline ::
  (MonadManaged m) =>
  Vulkan.Device ->
  Vulkan.PipelineLayout ->
  Vulkan.RenderPass ->
  ShaderProgram ->
  Vulkan.Extent2D ->
  VertexFormat v ->
  Int ->
  m Vulkan.Pipeline
managedGraphicsPipeline dev layout renderPass shaderProgram swapchainExtent vertexFormat colorAttachmentCount =
  managedGraphicsPipelineWithCull dev layout renderPass shaderProgram swapchainExtent vertexFormat colorAttachmentCount Vulkan.CULL_MODE_BACK_BIT

createGraphicsPipeline ::
  (MonadIO m) =>
  Vulkan.Device ->
  Vulkan.PipelineLayout ->
  Vulkan.RenderPass ->
  ShaderProgram ->
  Vulkan.Extent2D ->
  VertexFormat v ->
  Int ->
  Vulkan.CullModeFlags ->
  m Vulkan.Pipeline
createGraphicsPipeline dev layout renderPass shaderProgram swapchainExtent vertexFormat colorAttachmentCount cullMode = do
  let stages = map SomeStruct (toPipelineStages shaderProgram)
      numStages = stageCount shaderProgram
      positionBindingDescription =
        Vulkan.VertexInputBindingDescription
          { binding = 0
          , stride = fromIntegral (VertexFormat.strideSize vertexFormat)
          , inputRate = Vulkan.VERTEX_INPUT_RATE_VERTEX
          }
      vertexAttributeDescriptions = VertexFormat.attributeDescriptions 0 vertexFormat

      vertexInputStateCI =
        Vulkan.PipelineVertexInputStateCreateInfo
          { next = ()
          , flags = zero
          , vertexBindingDescriptions = Vector.fromList [positionBindingDescription]
          , vertexAttributeDescriptions = Vector.fromList vertexAttributeDescriptions
          }
      assemblyInputStateCI =
        Vulkan.PipelineInputAssemblyStateCreateInfo
          { flags = zero
          , topology = Vulkan.PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
          , primitiveRestartEnable = False
          }

      Vulkan.Extent2D{width = extW, height = extH} = swapchainExtent
      w = fromIntegral extW
      h = fromIntegral extH
      viewport =
        Vulkan.Viewport
          { x = 0
          , y = h
          , width = w
          , height = -h
          , minDepth = 0.0
          , maxDepth = 1.0
          }
      scissor =
        Vulkan.Rect2D
          { offset = Vulkan.Offset2D 0 0
          , extent = swapchainExtent
          }
      viewportState =
        Vulkan.PipelineViewportStateCreateInfo
          { next = ()
          , flags = zero
          , viewportCount = 1
          , viewports = Vector.fromList [viewport]
          , scissorCount = 1
          , scissors = Vector.fromList [scissor]
          }

      rasterizationState =
        Vulkan.PipelineRasterizationStateCreateInfo
          { next = ()
          , flags = zero
          , depthClampEnable = False
          , rasterizerDiscardEnable = False
          , polygonMode = Vulkan.POLYGON_MODE_FILL
          , lineWidth = 1.0
          , cullMode = cullMode
          , frontFace = Vulkan.FRONT_FACE_COUNTER_CLOCKWISE
          , depthBiasEnable = False
          , depthBiasConstantFactor = 0.0
          , depthBiasClamp = 0.0
          , depthBiasSlopeFactor = 0.0
          }
      multisampleState =
        Vulkan.PipelineMultisampleStateCreateInfo
          { next = ()
          , flags = zero
          , sampleShadingEnable = False
          , rasterizationSamples = Vulkan.SAMPLE_COUNT_1_BIT
          , minSampleShading = 1.0
          , sampleMask = Vector.empty
          , alphaToCoverageEnable = False
          , alphaToOneEnable = False
          }
      depthStencilState =
        let nullStencilOp =
              Vulkan.StencilOpState
                { failOp = Vulkan.STENCIL_OP_KEEP
                , passOp = Vulkan.STENCIL_OP_KEEP
                , depthFailOp = Vulkan.STENCIL_OP_KEEP
                , compareOp = Vulkan.COMPARE_OP_ALWAYS
                , compareMask = 0
                , writeMask = 0
                , reference = 0
                }
         in Vulkan.PipelineDepthStencilStateCreateInfo
              { flags = zero
              , depthTestEnable = True
              , depthWriteEnable = True
              , depthCompareOp = Vulkan.COMPARE_OP_LESS_OR_EQUAL
              , depthBoundsTestEnable = False
              , stencilTestEnable = False
              , front = nullStencilOp
              , back = nullStencilOp
              , minDepthBounds = 0
              , maxDepthBounds = 1
              }
      colorBlendState =
        let colorBlendAttachment =
              Vulkan.PipelineColorBlendAttachmentState
                { colorWriteMask =
                    Vulkan.COLOR_COMPONENT_R_BIT
                      .|. Vulkan.COLOR_COMPONENT_G_BIT
                      .|. Vulkan.COLOR_COMPONENT_B_BIT
                      .|. Vulkan.COLOR_COMPONENT_A_BIT
                , blendEnable = False
                , srcColorBlendFactor = Vulkan.BLEND_FACTOR_ONE
                , dstColorBlendFactor = Vulkan.BLEND_FACTOR_ZERO
                , colorBlendOp = Vulkan.BLEND_OP_ADD
                , srcAlphaBlendFactor = Vulkan.BLEND_FACTOR_ONE
                , dstAlphaBlendFactor = Vulkan.BLEND_FACTOR_ZERO
                , alphaBlendOp = Vulkan.BLEND_OP_ADD
                }
         in Vulkan.PipelineColorBlendStateCreateInfo
              { next = ()
              , flags = zero
              , logicOpEnable = False
              , logicOp = Vulkan.LOGIC_OP_COPY
              , attachmentCount = fromIntegral colorAttachmentCount
              , attachments = Vector.fromList (replicate colorAttachmentCount colorBlendAttachment)
              , blendConstants = (0.0, 0.0, 0.0, 0.0)
              }
      dynamicState =
        Vulkan.PipelineDynamicStateCreateInfo
          { flags = zero
          , dynamicStates = Vector.empty
          }
      subpass = 0
      basePipelineHandle = Vulkan.Pipeline 0
      basePipelineIndex = -1
      pipelineCI =
        Vulkan.GraphicsPipelineCreateInfo
          { next = ()
          , flags = zero
          , stageCount = fromIntegral numStages
          , stages = Vector.fromList stages
          , vertexInputState = Just (SomeStruct vertexInputStateCI)
          , inputAssemblyState = Just assemblyInputStateCI
          , tessellationState = Nothing
          , viewportState = Just (SomeStruct viewportState)
          , rasterizationState = Just (SomeStruct rasterizationState)
          , multisampleState = Just (SomeStruct multisampleState)
          , depthStencilState = Just depthStencilState
          , colorBlendState = Just (SomeStruct colorBlendState)
          , dynamicState = Just dynamicState
          , layout = layout
          , renderPass = renderPass
          , subpass = subpass
          , basePipelineHandle = basePipelineHandle
          , basePipelineIndex = basePipelineIndex
          }
  (_, pipelines) <- liftIO $ Vulkan.createGraphicsPipelines dev (Vulkan.PipelineCache 0) (Vector.fromList [SomeStruct pipelineCI]) Nothing
  pure (Vector.head pipelines)

-- ---------------------------------------------------------------------------
-- Fullscreen triangle pipeline (no vertex input)
-- ---------------------------------------------------------------------------

managedFullscreenPipeline ::
  (MonadManaged m) =>
  Vulkan.Device ->
  Vulkan.PipelineLayout ->
  Vulkan.RenderPass ->
  ShaderProgram ->
  Vulkan.Extent2D ->
  m Vulkan.Pipeline
managedFullscreenPipeline dev layout renderPass shaderProgram swapchainExtent =
  alloc
    "FullscreenPipeline"
    (createFullscreenPipeline dev layout renderPass shaderProgram swapchainExtent)
    (\ptr -> Vulkan.destroyPipeline dev ptr Nothing)

createFullscreenPipeline ::
  (MonadIO m) =>
  Vulkan.Device ->
  Vulkan.PipelineLayout ->
  Vulkan.RenderPass ->
  ShaderProgram ->
  Vulkan.Extent2D ->
  m Vulkan.Pipeline
createFullscreenPipeline dev layout renderPass shaderProgram swapchainExtent = do
  let stages = map SomeStruct (toPipelineStages shaderProgram)
      numStages = stageCount shaderProgram
      vertexInputStateCI =
        Vulkan.PipelineVertexInputStateCreateInfo
          { next = ()
          , flags = zero
          , vertexBindingDescriptions = Vector.empty
          , vertexAttributeDescriptions = Vector.empty
          }
      assemblyInputStateCI =
        Vulkan.PipelineInputAssemblyStateCreateInfo
          { flags = zero
          , topology = Vulkan.PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
          , primitiveRestartEnable = False
          }

      Vulkan.Extent2D{width = extW, height = extH} = swapchainExtent
      w = fromIntegral extW
      h = fromIntegral extH
      viewport =
        Vulkan.Viewport
          { x = 0
          , y = h
          , width = w
          , height = -h
          , minDepth = 0.0
          , maxDepth = 1.0
          }
      scissor =
        Vulkan.Rect2D
          { offset = Vulkan.Offset2D 0 0
          , extent = swapchainExtent
          }
      viewportState =
        Vulkan.PipelineViewportStateCreateInfo
          { next = ()
          , flags = zero
          , viewportCount = 1
          , viewports = Vector.fromList [viewport]
          , scissorCount = 1
          , scissors = Vector.fromList [scissor]
          }

      rasterizationState =
        Vulkan.PipelineRasterizationStateCreateInfo
          { next = ()
          , flags = zero
          , depthClampEnable = False
          , rasterizerDiscardEnable = False
          , polygonMode = Vulkan.POLYGON_MODE_FILL
          , lineWidth = 1.0
          , cullMode = Vulkan.CULL_MODE_NONE
          , frontFace = Vulkan.FRONT_FACE_COUNTER_CLOCKWISE
          , depthBiasEnable = False
          , depthBiasConstantFactor = 0.0
          , depthBiasClamp = 0.0
          , depthBiasSlopeFactor = 0.0
          }
      multisampleState =
        Vulkan.PipelineMultisampleStateCreateInfo
          { next = ()
          , flags = zero
          , sampleShadingEnable = False
          , rasterizationSamples = Vulkan.SAMPLE_COUNT_1_BIT
          , minSampleShading = 1.0
          , sampleMask = Vector.empty
          , alphaToCoverageEnable = False
          , alphaToOneEnable = False
          }
      depthStencilState =
        let nullStencilOp =
              Vulkan.StencilOpState
                { failOp = Vulkan.STENCIL_OP_KEEP
                , passOp = Vulkan.STENCIL_OP_KEEP
                , depthFailOp = Vulkan.STENCIL_OP_KEEP
                , compareOp = Vulkan.COMPARE_OP_ALWAYS
                , compareMask = 0
                , writeMask = 0
                , reference = 0
                }
         in Vulkan.PipelineDepthStencilStateCreateInfo
              { flags = zero
              , depthTestEnable = False
              , depthWriteEnable = False
              , depthCompareOp = Vulkan.COMPARE_OP_LESS_OR_EQUAL
              , depthBoundsTestEnable = False
              , stencilTestEnable = False
              , front = nullStencilOp
              , back = nullStencilOp
              , minDepthBounds = 0
              , maxDepthBounds = 1
              }
      colorBlendState =
        let colorBlendAttachment =
              Vulkan.PipelineColorBlendAttachmentState
                { colorWriteMask =
                    Vulkan.COLOR_COMPONENT_R_BIT
                      .|. Vulkan.COLOR_COMPONENT_G_BIT
                      .|. Vulkan.COLOR_COMPONENT_B_BIT
                      .|. Vulkan.COLOR_COMPONENT_A_BIT
                , blendEnable = False
                , srcColorBlendFactor = Vulkan.BLEND_FACTOR_ONE
                , dstColorBlendFactor = Vulkan.BLEND_FACTOR_ZERO
                , colorBlendOp = Vulkan.BLEND_OP_ADD
                , srcAlphaBlendFactor = Vulkan.BLEND_FACTOR_ONE
                , dstAlphaBlendFactor = Vulkan.BLEND_FACTOR_ZERO
                , alphaBlendOp = Vulkan.BLEND_OP_ADD
                }
         in Vulkan.PipelineColorBlendStateCreateInfo
              { next = ()
              , flags = zero
              , logicOpEnable = False
              , logicOp = Vulkan.LOGIC_OP_COPY
              , attachmentCount = 1
              , attachments = Vector.fromList [colorBlendAttachment]
              , blendConstants = (0.0, 0.0, 0.0, 0.0)
              }
      dynamicState =
        Vulkan.PipelineDynamicStateCreateInfo
          { flags = zero
          , dynamicStates = Vector.empty
          }
      subpass = 0
      basePipelineHandle = Vulkan.Pipeline 0
      basePipelineIndex = -1
      pipelineCI =
        Vulkan.GraphicsPipelineCreateInfo
          { next = ()
          , flags = zero
          , stageCount = fromIntegral numStages
          , stages = Vector.fromList stages
          , vertexInputState = Just (SomeStruct vertexInputStateCI)
          , inputAssemblyState = Just assemblyInputStateCI
          , tessellationState = Nothing
          , viewportState = Just (SomeStruct viewportState)
          , rasterizationState = Just (SomeStruct rasterizationState)
          , multisampleState = Just (SomeStruct multisampleState)
          , depthStencilState = Just depthStencilState
          , colorBlendState = Just (SomeStruct colorBlendState)
          , dynamicState = Just dynamicState
          , layout = layout
          , renderPass = renderPass
          , subpass = subpass
          , basePipelineHandle = basePipelineHandle
          , basePipelineIndex = basePipelineIndex
          }
  (_, pipelines) <- liftIO $ Vulkan.createGraphicsPipelines dev (Vulkan.PipelineCache 0) (Vector.fromList [SomeStruct pipelineCI]) Nothing
  pure (Vector.head pipelines)

cmdBindPipeline :: (MonadIO m) => Vulkan.CommandBuffer -> Vulkan.Pipeline -> m ()
cmdBindPipeline commandBuffer pipeline =
  liftIO $
    Vulkan.cmdBindPipeline commandBuffer Vulkan.PIPELINE_BIND_POINT_GRAPHICS pipeline

-- | Fullscreen triangle pipeline with alpha blending enabled.
-- Used for overlay passes that blend with existing framebuffer contents.
managedFullscreenPipelineWithBlending ::
  (MonadManaged m) =>
  Vulkan.Device ->
  Vulkan.PipelineLayout ->
  Vulkan.RenderPass ->
  ShaderProgram ->
  Vulkan.Extent2D ->
  m Vulkan.Pipeline
managedFullscreenPipelineWithBlending dev layout renderPass shaderProgram swapchainExtent =
  alloc
    "FullscreenPipelineWithBlending"
    (createFullscreenPipelineWithBlending dev layout renderPass shaderProgram swapchainExtent)
    (\ptr -> Vulkan.destroyPipeline dev ptr Nothing)

createFullscreenPipelineWithBlending ::
  (MonadIO m) =>
  Vulkan.Device ->
  Vulkan.PipelineLayout ->
  Vulkan.RenderPass ->
  ShaderProgram ->
  Vulkan.Extent2D ->
  m Vulkan.Pipeline
createFullscreenPipelineWithBlending dev layout renderPass shaderProgram swapchainExtent = do
  let stages = map SomeStruct (toPipelineStages shaderProgram)
      numStages = stageCount shaderProgram
      vertexInputStateCI =
        Vulkan.PipelineVertexInputStateCreateInfo
          { next = ()
          , flags = zero
          , vertexBindingDescriptions = Vector.empty
          , vertexAttributeDescriptions = Vector.empty
          }
      assemblyInputStateCI =
        Vulkan.PipelineInputAssemblyStateCreateInfo
          { flags = zero
          , topology = Vulkan.PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
          , primitiveRestartEnable = False
          }

      Vulkan.Extent2D{width = extW, height = extH} = swapchainExtent
      w = fromIntegral extW
      h = fromIntegral extH
      viewport =
        Vulkan.Viewport
          { x = 0
          , y = h
          , width = w
          , height = -h
          , minDepth = 0.0
          , maxDepth = 1.0
          }
      scissor =
        Vulkan.Rect2D
          { offset = Vulkan.Offset2D 0 0
          , extent = swapchainExtent
          }
      viewportState =
        Vulkan.PipelineViewportStateCreateInfo
          { next = ()
          , flags = zero
          , viewportCount = 1
          , viewports = Vector.fromList [viewport]
          , scissorCount = 1
          , scissors = Vector.fromList [scissor]
          }
      rasterizationState =
        Vulkan.PipelineRasterizationStateCreateInfo
          { next = ()
          , flags = zero
          , depthClampEnable = False
          , rasterizerDiscardEnable = False
          , polygonMode = Vulkan.POLYGON_MODE_FILL
          , lineWidth = 1.0
          , cullMode = Vulkan.CULL_MODE_NONE
          , frontFace = Vulkan.FRONT_FACE_COUNTER_CLOCKWISE
          , depthBiasEnable = False
          , depthBiasConstantFactor = 0.0
          , depthBiasClamp = 0.0
          , depthBiasSlopeFactor = 0.0
          }
      multisampleState =
        Vulkan.PipelineMultisampleStateCreateInfo
          { next = ()
          , flags = zero
          , sampleShadingEnable = False
          , rasterizationSamples = Vulkan.SAMPLE_COUNT_1_BIT
          , minSampleShading = 1.0
          , sampleMask = Vector.empty
          , alphaToCoverageEnable = False
          , alphaToOneEnable = False
          }
      depthStencilState =
        let nullStencilOp =
              Vulkan.StencilOpState
                { failOp = Vulkan.STENCIL_OP_KEEP
                , passOp = Vulkan.STENCIL_OP_KEEP
                , depthFailOp = Vulkan.STENCIL_OP_KEEP
                , compareOp = Vulkan.COMPARE_OP_ALWAYS
                , compareMask = 0
                , writeMask = 0
                , reference = 0
                }
         in Vulkan.PipelineDepthStencilStateCreateInfo
              { flags = zero
              , depthTestEnable = False
              , depthWriteEnable = False
              , depthCompareOp = Vulkan.COMPARE_OP_LESS_OR_EQUAL
              , depthBoundsTestEnable = False
              , stencilTestEnable = False
              , front = nullStencilOp
              , back = nullStencilOp
              , minDepthBounds = 0
              , maxDepthBounds = 1
              }
      colorBlendAttachment =
        Vulkan.PipelineColorBlendAttachmentState
          { colorWriteMask =
              Vulkan.COLOR_COMPONENT_R_BIT
                .|. Vulkan.COLOR_COMPONENT_G_BIT
                .|. Vulkan.COLOR_COMPONENT_B_BIT
                .|. Vulkan.COLOR_COMPONENT_A_BIT
          , blendEnable = True
          , srcColorBlendFactor = Vulkan.BLEND_FACTOR_SRC_ALPHA
          , dstColorBlendFactor = Vulkan.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
          , colorBlendOp = Vulkan.BLEND_OP_ADD
          , srcAlphaBlendFactor = Vulkan.BLEND_FACTOR_ONE
          , dstAlphaBlendFactor = Vulkan.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
          , alphaBlendOp = Vulkan.BLEND_OP_ADD
          }
      colorBlendState =
        Vulkan.PipelineColorBlendStateCreateInfo
          { next = ()
          , flags = zero
          , logicOpEnable = False
          , logicOp = Vulkan.LOGIC_OP_COPY
          , attachmentCount = 1
          , attachments = Vector.fromList [colorBlendAttachment]
          , blendConstants = (0.0, 0.0, 0.0, 0.0)
          }
      dynamicState =
        Vulkan.PipelineDynamicStateCreateInfo
          { flags = zero
          , dynamicStates = Vector.empty
          }
      subpass = 0
      basePipelineHandle = Vulkan.Pipeline 0
      basePipelineIndex = -1
      pipelineCI =
        Vulkan.GraphicsPipelineCreateInfo
          { next = ()
          , flags = zero
          , stageCount = fromIntegral numStages
          , stages = Vector.fromList stages
          , vertexInputState = Just (SomeStruct vertexInputStateCI)
          , inputAssemblyState = Just assemblyInputStateCI
          , tessellationState = Nothing
          , viewportState = Just (SomeStruct viewportState)
          , rasterizationState = Just (SomeStruct rasterizationState)
          , multisampleState = Just (SomeStruct multisampleState)
          , depthStencilState = Just depthStencilState
          , colorBlendState = Just (SomeStruct colorBlendState)
          , dynamicState = Just dynamicState
          , layout = layout
          , renderPass = renderPass
          , subpass = subpass
          , basePipelineHandle = basePipelineHandle
          , basePipelineIndex = basePipelineIndex
          }
  (_, pipelines) <- liftIO $ Vulkan.createGraphicsPipelines dev (Vulkan.PipelineCache 0) (Vector.fromList [SomeStruct pipelineCI]) Nothing
  pure (Vector.head pipelines)
