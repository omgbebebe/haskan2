{-# LANGUAGE BlockArguments    #-}
{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Graphics.Haskan.Vulkan.MeshPipeline
  ( createMeshPipeline
  , managedMeshPipeline
  , cmdDrawMeshTasksEXT
  ) where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Bits ((.|.))
import Data.Maybe (catMaybes)
import Data.Vector qualified as Vector
import Data.Word (Word32)

-- vulkan-api (existing project style)
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan

-- vulkan package (for mesh shader API)
import Vulkan.Core10.APIConstants qualified as Vk
import Vulkan.Core10.Enums.BlendFactor qualified as Vk
import Vulkan.Core10.Enums.BlendOp qualified as Vk
import Vulkan.Core10.Enums.ColorComponentFlagBits qualified as Vk
import Vulkan.Core10.Enums.CompareOp qualified as Vk
import Vulkan.Core10.Enums.CullModeFlagBits qualified as Vk
import Vulkan.Core10.Enums.FrontFace qualified as Vk
import Vulkan.Core10.Enums.LogicOp qualified as Vk
import Vulkan.Core10.Enums.PolygonMode qualified as Vk
import Vulkan.Core10.Enums.SampleCountFlagBits qualified as Vk
import Vulkan.Core10.Enums.ShaderStageFlagBits qualified as Vk
import Vulkan.Core10.Enums.StencilOp qualified as Vk
import Vulkan.Core10.FundamentalTypes qualified as Vk
import Vulkan.Core10.Pipeline qualified as Vk
import Vulkan.Core10.Handles qualified as Vk
import Vulkan.CStruct.Extends qualified as Vk
import Vulkan.Extensions.VK_EXT_mesh_shader qualified as Vk
import Vulkan.Zero qualified as Vk

import Graphics.Haskan.Resources (alloc)
import Graphics.Haskan.Vulkan.Interop
import Graphics.Haskan.Render.ShaderProgram (MeshShaderProgram(..))

-- ---------------------------------------------------------------------------
-- Mesh pipeline creation
-- ---------------------------------------------------------------------------

managedMeshPipeline
  :: (MonadManaged m)
  => Vulkan.VkDevice
  -> Vulkan.VkPipelineLayout
  -> Vulkan.VkRenderPass
  -> MeshShaderProgram
  -> Vulkan.VkExtent2D
  -> Int  -- ^ color attachment count
  -> m Vulkan.VkPipeline
managedMeshPipeline dev layout renderPass program extent colorCount =
  alloc
    "MeshPipeline"
    (createMeshPipeline dev layout renderPass program extent colorCount)
    (\ptr -> Vulkan.vkDestroyPipeline dev ptr Vulkan.vkNullPtr)

createMeshPipeline
  :: (MonadIO m)
  => Vulkan.VkDevice
  -> Vulkan.VkPipelineLayout
  -> Vulkan.VkRenderPass
  -> MeshShaderProgram
  -> Vulkan.VkExtent2D
  -> Int  -- ^ color attachment count
  -> m Vulkan.VkPipeline
createMeshPipeline dev layout renderPass MeshShaderProgram{..} swapchainExtent colorAttachmentCount = do
  let
    device = toVulkanDevice dev
    pipelineLayout = toVulkanPipelineLayout layout
    renderPass_ = toVulkanRenderPass renderPass

    -- Build shader stages: [task?] + mesh + fragment
    stages = Vector.fromList $ catMaybes
      [ mkStage Vk.SHADER_STAGE_TASK_BIT_EXT <$> mspTask
      , Just $ mkStage Vk.SHADER_STAGE_MESH_BIT_EXT mspMesh
      , Just $ mkStage Vk.SHADER_STAGE_FRAGMENT_BIT mspFragment
      ]

    mkStage stageBit mod_ =
      Vk.SomeStruct $ Vk.zero
        { Vk.stage = stageBit
        , Vk.module' = toVulkanShaderModule mod_
        , Vk.name = "main"
        }

    -- Viewport (inverted Y for Vulkan)
    viewport = Vk.Viewport
      { Vk.x = 0
      , Vk.y = fromIntegral (Vulkan.getField @"height" swapchainExtent)
      , Vk.width = fromIntegral (Vulkan.getField @"width" swapchainExtent)
      , Vk.height = - (fromIntegral (Vulkan.getField @"height" swapchainExtent))
      , Vk.minDepth = 0.0
      , Vk.maxDepth = 1.0
      }

    scissor = Vk.Rect2D
      { Vk.offset = Vk.Offset2D 0 0
      , Vk.extent = Vk.Extent2D
          (fromIntegral $ Vulkan.getField @"width" swapchainExtent)
          (fromIntegral $ Vulkan.getField @"height" swapchainExtent)
      }

    viewportState = Vk.PipelineViewportStateCreateInfo
      { Vk.next = ()
      , Vk.flags = Vk.zero
      , Vk.viewportCount = 1
      , Vk.viewports = Vector.fromList [viewport]
      , Vk.scissorCount = 1
      , Vk.scissors = Vector.fromList [scissor]
      }

    rasterizationState = Vk.PipelineRasterizationStateCreateInfo
      { Vk.next = ()
      , Vk.flags = Vk.zero
      , Vk.depthClampEnable = False
      , Vk.rasterizerDiscardEnable = False
      , Vk.polygonMode = Vk.POLYGON_MODE_FILL
      , Vk.lineWidth = 1.0
      , Vk.cullMode = Vk.CULL_MODE_BACK_BIT
      , Vk.frontFace = Vk.FRONT_FACE_COUNTER_CLOCKWISE
      , Vk.depthBiasEnable = False
      , Vk.depthBiasConstantFactor = 0.0
      , Vk.depthBiasClamp = 0.0
      , Vk.depthBiasSlopeFactor = 0.0
      }

    multisampleState = Vk.PipelineMultisampleStateCreateInfo
      { Vk.next = ()
      , Vk.flags = Vk.zero
      , Vk.sampleShadingEnable = False
      , Vk.rasterizationSamples = Vk.SAMPLE_COUNT_1_BIT
      , Vk.minSampleShading = 1.0
      , Vk.sampleMask = Vector.fromList []
      , Vk.alphaToCoverageEnable = False
      , Vk.alphaToOneEnable = False
      }

    nullStencilOp = Vk.StencilOpState
      { Vk.failOp = Vk.STENCIL_OP_KEEP
      , Vk.passOp = Vk.STENCIL_OP_KEEP
      , Vk.depthFailOp = Vk.STENCIL_OP_KEEP
      , Vk.compareOp = Vk.COMPARE_OP_ALWAYS
      , Vk.compareMask = 0
      , Vk.writeMask = 0
      , Vk.reference = 0
      }

    depthStencilState = Vk.PipelineDepthStencilStateCreateInfo
      { Vk.flags = Vk.zero
      , Vk.depthTestEnable = True
      , Vk.depthWriteEnable = True
      , Vk.depthCompareOp = Vk.COMPARE_OP_LESS_OR_EQUAL
      , Vk.depthBoundsTestEnable = False
      , Vk.stencilTestEnable = False
      , Vk.front = nullStencilOp
      , Vk.back = nullStencilOp
      , Vk.minDepthBounds = 0
      , Vk.maxDepthBounds = 1
      }

    colorBlendAttachment = Vk.PipelineColorBlendAttachmentState
      { Vk.colorWriteMask =
          Vk.COLOR_COMPONENT_R_BIT
            .|. Vk.COLOR_COMPONENT_G_BIT
            .|. Vk.COLOR_COMPONENT_B_BIT
            .|. Vk.COLOR_COMPONENT_A_BIT
      , Vk.blendEnable = False
      , Vk.srcColorBlendFactor = Vk.BLEND_FACTOR_ONE
      , Vk.dstColorBlendFactor = Vk.BLEND_FACTOR_ZERO
      , Vk.colorBlendOp = Vk.BLEND_OP_ADD
      , Vk.srcAlphaBlendFactor = Vk.BLEND_FACTOR_ONE
      , Vk.dstAlphaBlendFactor = Vk.BLEND_FACTOR_ZERO
      , Vk.alphaBlendOp = Vk.BLEND_OP_ADD
      }

    colorBlendState = Vk.PipelineColorBlendStateCreateInfo
      { Vk.next = ()
      , Vk.flags = Vk.zero
      , Vk.logicOpEnable = False
      , Vk.logicOp = Vk.LOGIC_OP_COPY
      , Vk.attachmentCount = fromIntegral colorAttachmentCount
      , Vk.attachments = Vector.fromList $ replicate colorAttachmentCount colorBlendAttachment
      , Vk.blendConstants = (0, 0, 0, 0)
      }

    dynamicState = Vk.PipelineDynamicStateCreateInfo
      { Vk.flags = Vk.zero
      , Vk.dynamicStates = Vector.fromList []
      }

    -- Mesh pipeline: no vertex input, no input assembly, no tessellation
    createInfo = Vk.GraphicsPipelineCreateInfo
      { Vk.next = ()
      , Vk.flags = Vk.zero
      , Vk.stageCount = fromIntegral (Vector.length stages)
      , Vk.stages = stages
      , Vk.vertexInputState = Nothing
      , Vk.inputAssemblyState = Nothing
      , Vk.tessellationState = Nothing
      , Vk.viewportState = Just $ Vk.SomeStruct viewportState
      , Vk.rasterizationState = Just $ Vk.SomeStruct rasterizationState
      , Vk.multisampleState = Just $ Vk.SomeStruct multisampleState
      , Vk.depthStencilState = Just depthStencilState
      , Vk.colorBlendState = Just $ Vk.SomeStruct colorBlendState
      , Vk.dynamicState = Just dynamicState
      , Vk.layout = pipelineLayout
      , Vk.renderPass = renderPass_
      , Vk.subpass = 0
      , Vk.basePipelineHandle = Vk.zero
      , Vk.basePipelineIndex = -1
      }

  (result, pipelines) <- liftIO $ Vk.createGraphicsPipelines
    device
    Vk.NULL_HANDLE
    (Vector.fromList [Vk.SomeStruct createInfo])
    Nothing

  case pipelines Vector.!? 0 of
    Nothing -> error "createMeshPipeline: no pipeline returned"
    Just pipeline -> pure $ fromVulkanPipeline pipeline

-- ---------------------------------------------------------------------------
-- Mesh shader draw command wrapper
-- ---------------------------------------------------------------------------

cmdDrawMeshTasksEXT
  :: (MonadIO m)
  => Vulkan.VkCommandBuffer
  -> Word32  -- ^ groupCountX
  -> Word32  -- ^ groupCountY
  -> Word32  -- ^ groupCountZ
  -> m ()
cmdDrawMeshTasksEXT cmdBuf x y z =
  liftIO $ Vk.cmdDrawMeshTasksEXT (toVulkanCommandBuffer cmdBuf) x y z
