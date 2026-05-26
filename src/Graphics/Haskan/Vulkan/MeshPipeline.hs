{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Vulkan.MeshPipeline
  ( createMeshPipeline,
    createMeshPipelineWithBlending,
    managedMeshPipeline,
    managedMeshPipelineWithBlending,
    cmdDrawMeshTasksEXT,
  )
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Bits ((.|.))
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (catMaybes)
import Data.Vector qualified as Vector
import Data.Word (Word32)
import Foreign (FunPtr, Ptr, castFunPtr, nullFunPtr, nullPtr)
import Foreign.C (CInt (..), CUInt (..))
import Foreign.Storable (peek)
import Graphics.Haskan.Render.ShaderProgram (MeshShaderProgram (..))
import Graphics.Haskan.Resources (alloc)
import System.IO.Unsafe (unsafePerformIO)
import Vulkan qualified
import Vulkan.CStruct.Extends (SomeStruct (..))
import Vulkan.Core10 qualified
import Vulkan.Zero (zero)

-- ---------------------------------------------------------------------------
-- Mesh shader stage flag
-- ---------------------------------------------------------------------------

vkShaderStageMeshBitEXT :: Vulkan.ShaderStageFlagBits
vkShaderStageMeshBitEXT =
  Vulkan.SHADER_STAGE_MESH_BIT_EXT

vkShaderStageTaskBitEXT :: Vulkan.ShaderStageFlagBits
vkShaderStageTaskBitEXT =
  Vulkan.SHADER_STAGE_TASK_BIT_EXT

-- ---------------------------------------------------------------------------
-- Mesh pipeline creation
-- ---------------------------------------------------------------------------

managedMeshPipeline ::
  (MonadManaged m) =>
  Vulkan.Device ->
  Vulkan.PipelineLayout ->
  Vulkan.RenderPass ->
  MeshShaderProgram ->
  Vulkan.Extent2D ->
  -- | color attachment count
  Int ->
  m Vulkan.Pipeline
managedMeshPipeline dev layout renderPass program extent colorCount =
  alloc
    "MeshPipeline"
    (createMeshPipeline dev layout renderPass program extent colorCount)
    (\ptr -> Vulkan.destroyPipeline dev ptr Nothing)

createMeshPipeline ::
  (MonadIO m) =>
  Vulkan.Device ->
  Vulkan.PipelineLayout ->
  Vulkan.RenderPass ->
  MeshShaderProgram ->
  Vulkan.Extent2D ->
  -- | color attachment count
  Int ->
  m Vulkan.Pipeline
createMeshPipeline dev layout renderPass MeshShaderProgram {..} swapchainExtent colorAttachmentCount = do
  let mkStage stageBit mod_ =
        Vulkan.PipelineShaderStageCreateInfo
          { next = (),
            flags = zero,
            stage = stageBit,
            module' = mod_,
            name = "main",
            specializationInfo = Nothing
          }

      stages =
        catMaybes
          [ mkStage vkShaderStageTaskBitEXT <$> mspTask,
            Just $ mkStage vkShaderStageMeshBitEXT mspMesh,
            Just $ mkStage Vulkan.SHADER_STAGE_FRAGMENT_BIT mspFragment
          ]

      numStages = length stages

      Vulkan.Extent2D {width = extW, height = extH} = swapchainExtent
      w = fromIntegral extW
      h = fromIntegral extH

      viewport =
        Vulkan.Viewport
          { x = 0,
            y = h,
            width = w,
            height = -h,
            minDepth = 0.0,
            maxDepth = 1.0
          }

      scissor =
        Vulkan.Rect2D
          { offset = Vulkan.Offset2D 0 0,
            extent = swapchainExtent
          }

      viewportState =
        Vulkan.PipelineViewportStateCreateInfo
          { next = (),
            flags = zero,
            viewportCount = 1,
            viewports = Vector.fromList [viewport],
            scissorCount = 1,
            scissors = Vector.fromList [scissor]
          }

      rasterizationState =
        Vulkan.PipelineRasterizationStateCreateInfo
          { next = (),
            flags = zero,
            depthClampEnable = False,
            rasterizerDiscardEnable = False,
            polygonMode = Vulkan.POLYGON_MODE_FILL,
            lineWidth = 1.0,
            cullMode = Vulkan.CULL_MODE_BACK_BIT,
            frontFace = Vulkan.FRONT_FACE_COUNTER_CLOCKWISE,
            depthBiasEnable = False,
            depthBiasConstantFactor = 0.0,
            depthBiasClamp = 0.0,
            depthBiasSlopeFactor = 0.0
          }

      multisampleState =
        Vulkan.PipelineMultisampleStateCreateInfo
          { next = (),
            flags = zero,
            sampleShadingEnable = False,
            rasterizationSamples = Vulkan.SAMPLE_COUNT_1_BIT,
            minSampleShading = 1.0,
            sampleMask = Vector.empty,
            alphaToCoverageEnable = False,
            alphaToOneEnable = False
          }

      nullStencilOp =
        Vulkan.StencilOpState
          { failOp = Vulkan.STENCIL_OP_KEEP,
            passOp = Vulkan.STENCIL_OP_KEEP,
            depthFailOp = Vulkan.STENCIL_OP_KEEP,
            compareOp = Vulkan.COMPARE_OP_ALWAYS,
            compareMask = 0,
            writeMask = 0,
            reference = 0
          }

      depthStencilState =
        Vulkan.PipelineDepthStencilStateCreateInfo
          { flags = zero,
            depthTestEnable = True,
            depthWriteEnable = True,
            depthCompareOp = Vulkan.COMPARE_OP_LESS_OR_EQUAL,
            depthBoundsTestEnable = False,
            stencilTestEnable = False,
            front = nullStencilOp,
            back = nullStencilOp,
            minDepthBounds = 0.0,
            maxDepthBounds = 1.0
          }

      colorBlendAttachment =
        Vulkan.PipelineColorBlendAttachmentState
          { colorWriteMask =
              Vulkan.COLOR_COMPONENT_R_BIT
                .|. Vulkan.COLOR_COMPONENT_G_BIT
                .|. Vulkan.COLOR_COMPONENT_B_BIT
                .|. Vulkan.COLOR_COMPONENT_A_BIT,
            blendEnable = False,
            srcColorBlendFactor = Vulkan.BLEND_FACTOR_ONE,
            dstColorBlendFactor = Vulkan.BLEND_FACTOR_ZERO,
            colorBlendOp = Vulkan.BLEND_OP_ADD,
            srcAlphaBlendFactor = Vulkan.BLEND_FACTOR_ONE,
            dstAlphaBlendFactor = Vulkan.BLEND_FACTOR_ZERO,
            alphaBlendOp = Vulkan.BLEND_OP_ADD
          }

      colorBlendState =
        Vulkan.PipelineColorBlendStateCreateInfo
          { next = (),
            flags = zero,
            logicOpEnable = False,
            logicOp = Vulkan.LOGIC_OP_COPY,
            attachmentCount = fromIntegral colorAttachmentCount,
            attachments = Vector.fromList (replicate colorAttachmentCount colorBlendAttachment),
            blendConstants = (0.0, 0.0, 0.0, 0.0)
          }

      dynamicState =
        Vulkan.PipelineDynamicStateCreateInfo
          { flags = zero,
            dynamicStates = Vector.empty
          }

      pipelineCI =
        Vulkan.GraphicsPipelineCreateInfo
          { next = (),
            flags = zero,
            stageCount = fromIntegral numStages,
            stages = Vector.fromList (map SomeStruct stages),
            vertexInputState = Nothing,
            inputAssemblyState = Nothing,
            tessellationState = Nothing,
            viewportState = Just (SomeStruct viewportState),
            rasterizationState = Just (SomeStruct rasterizationState),
            multisampleState = Just (SomeStruct multisampleState),
            depthStencilState = Just depthStencilState,
            colorBlendState = Just (SomeStruct colorBlendState),
            dynamicState = Just dynamicState,
            layout = layout,
            renderPass = renderPass,
            subpass = 0,
            basePipelineHandle = Vulkan.Pipeline 0,
            basePipelineIndex = -1
          }

  (_, pipelines) <- liftIO $ Vulkan.createGraphicsPipelines dev (Vulkan.PipelineCache 0) (Vector.fromList [SomeStruct pipelineCI]) Nothing
  pure (Vector.head pipelines)

managedMeshPipelineWithBlending ::
  (MonadManaged m) =>
  Vulkan.Device ->
  Vulkan.PipelineLayout ->
  Vulkan.RenderPass ->
  MeshShaderProgram ->
  Vulkan.Extent2D ->
  -- | color attachment count
  Int ->
  m Vulkan.Pipeline
managedMeshPipelineWithBlending dev layout renderPass program extent colorCount =
  alloc
    "MeshPipelineWithBlending"
    (createMeshPipelineWithBlending dev layout renderPass program extent colorCount)
    (\ptr -> Vulkan.destroyPipeline dev ptr Nothing)

createMeshPipelineWithBlending ::
  (MonadIO m) =>
  Vulkan.Device ->
  Vulkan.PipelineLayout ->
  Vulkan.RenderPass ->
  MeshShaderProgram ->
  Vulkan.Extent2D ->
  -- | color attachment count
  Int ->
  m Vulkan.Pipeline
createMeshPipelineWithBlending dev layout renderPass program swapchainExtent colorAttachmentCount = do
  let mkStage stageBit mod_ =
        Vulkan.PipelineShaderStageCreateInfo
          { next = (),
            flags = zero,
            stage = stageBit,
            module' = mod_,
            name = "main",
            specializationInfo = Nothing
          }

      stages =
        catMaybes
          [ mkStage vkShaderStageTaskBitEXT <$> mspTask program,
            Just $ mkStage vkShaderStageMeshBitEXT (mspMesh program),
            Just $ mkStage Vulkan.SHADER_STAGE_FRAGMENT_BIT (mspFragment program)
          ]

      numStages = length stages

      Vulkan.Extent2D {width = extW, height = extH} = swapchainExtent
      w = fromIntegral extW
      h = fromIntegral extH

      viewport =
        Vulkan.Viewport
          { x = 0,
            y = h,
            width = w,
            height = -h,
            minDepth = 0.0,
            maxDepth = 1.0
          }

      scissor =
        Vulkan.Rect2D
          { offset = Vulkan.Offset2D 0 0,
            extent = swapchainExtent
          }

      viewportState =
        Vulkan.PipelineViewportStateCreateInfo
          { next = (),
            flags = zero,
            viewportCount = 1,
            viewports = Vector.fromList [viewport],
            scissorCount = 1,
            scissors = Vector.fromList [scissor]
          }

      rasterizationState =
        Vulkan.PipelineRasterizationStateCreateInfo
          { next = (),
            flags = zero,
            depthClampEnable = False,
            rasterizerDiscardEnable = False,
            polygonMode = Vulkan.POLYGON_MODE_FILL,
            lineWidth = 1.0,
            cullMode = Vulkan.CULL_MODE_BACK_BIT,
            frontFace = Vulkan.FRONT_FACE_COUNTER_CLOCKWISE,
            depthBiasEnable = False,
            depthBiasConstantFactor = 0.0,
            depthBiasClamp = 0.0,
            depthBiasSlopeFactor = 0.0
          }

      multisampleState =
        Vulkan.PipelineMultisampleStateCreateInfo
          { next = (),
            flags = zero,
            sampleShadingEnable = False,
            rasterizationSamples = Vulkan.SAMPLE_COUNT_1_BIT,
            minSampleShading = 1.0,
            sampleMask = Vector.empty,
            alphaToCoverageEnable = False,
            alphaToOneEnable = False
          }

      nullStencilOp =
        Vulkan.StencilOpState
          { failOp = Vulkan.STENCIL_OP_KEEP,
            passOp = Vulkan.STENCIL_OP_KEEP,
            depthFailOp = Vulkan.STENCIL_OP_KEEP,
            compareOp = Vulkan.COMPARE_OP_ALWAYS,
            compareMask = 0,
            writeMask = 0,
            reference = 0
          }

      depthStencilState =
        Vulkan.PipelineDepthStencilStateCreateInfo
          { flags = zero,
            depthTestEnable = True,
            depthWriteEnable = True,
            depthCompareOp = Vulkan.COMPARE_OP_LESS_OR_EQUAL,
            depthBoundsTestEnable = False,
            stencilTestEnable = False,
            front = nullStencilOp,
            back = nullStencilOp,
            minDepthBounds = 0.0,
            maxDepthBounds = 1.0
          }

      colorBlendAttachment =
        Vulkan.PipelineColorBlendAttachmentState
          { colorWriteMask =
              Vulkan.COLOR_COMPONENT_R_BIT
                .|. Vulkan.COLOR_COMPONENT_G_BIT
                .|. Vulkan.COLOR_COMPONENT_B_BIT
                .|. Vulkan.COLOR_COMPONENT_A_BIT,
            blendEnable = True,
            srcColorBlendFactor = Vulkan.BLEND_FACTOR_SRC_ALPHA,
            dstColorBlendFactor = Vulkan.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            colorBlendOp = Vulkan.BLEND_OP_ADD,
            srcAlphaBlendFactor = Vulkan.BLEND_FACTOR_ONE,
            dstAlphaBlendFactor = Vulkan.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            alphaBlendOp = Vulkan.BLEND_OP_ADD
          }

      colorBlendState =
        Vulkan.PipelineColorBlendStateCreateInfo
          { next = (),
            flags = zero,
            logicOpEnable = False,
            logicOp = Vulkan.LOGIC_OP_COPY,
            attachmentCount = fromIntegral colorAttachmentCount,
            attachments = Vector.fromList (replicate colorAttachmentCount colorBlendAttachment),
            blendConstants = (0.0, 0.0, 0.0, 0.0)
          }

      dynamicState =
        Vulkan.PipelineDynamicStateCreateInfo
          { flags = zero,
            dynamicStates = Vector.empty
          }

      pipelineCI =
        Vulkan.GraphicsPipelineCreateInfo
          { next = (),
            flags = zero,
            stageCount = fromIntegral numStages,
            stages = Vector.fromList (map SomeStruct stages),
            vertexInputState = Nothing,
            inputAssemblyState = Nothing,
            tessellationState = Nothing,
            viewportState = Just (SomeStruct viewportState),
            rasterizationState = Just (SomeStruct rasterizationState),
            multisampleState = Just (SomeStruct multisampleState),
            depthStencilState = Just depthStencilState,
            colorBlendState = Just (SomeStruct colorBlendState),
            dynamicState = Just dynamicState,
            layout = layout,
            renderPass = renderPass,
            subpass = 0,
            basePipelineHandle = Vulkan.Pipeline 0,
            basePipelineIndex = -1
          }

  (_, pipelines) <- liftIO $ Vulkan.createGraphicsPipelines dev (Vulkan.PipelineCache 0) (Vector.fromList [SomeStruct pipelineCI]) Nothing
  pure (Vector.head pipelines)

-- ---------------------------------------------------------------------------
-- Dynamic loading of vkCmdDrawMeshTasksEXT
-- ---------------------------------------------------------------------------

type PFN_vkCmdDrawMeshTasksEXT = Ptr Vulkan.CommandBuffer_T -> Word32 -> Word32 -> Word32 -> IO ()

foreign import ccall "dynamic"
  mkCmdDrawMeshTasksEXT :: FunPtr PFN_vkCmdDrawMeshTasksEXT -> PFN_vkCmdDrawMeshTasksEXT

{-# NOINLINE drawMeshTasksEXTPtr #-}
drawMeshTasksEXTPtr :: IORef (Maybe (FunPtr PFN_vkCmdDrawMeshTasksEXT))
drawMeshTasksEXTPtr = unsafePerformIO $ newIORef Nothing

loadCmdDrawMeshTasksEXT :: Vulkan.Device -> IO PFN_vkCmdDrawMeshTasksEXT
loadCmdDrawMeshTasksEXT device = do
  cached <- readIORef drawMeshTasksEXTPtr
  case cached of
    Just fnPtr -> pure (mkCmdDrawMeshTasksEXT fnPtr)
    Nothing -> do
      procAddr <- Vulkan.getDeviceProcAddr device "vkCmdDrawMeshTasksEXT"
      if procAddr == nullFunPtr
        then error "vkCmdDrawMeshTasksEXT not available - VK_EXT_mesh_shader not enabled?"
        else do
          let fnPtr = castFunPtr procAddr
          writeIORef drawMeshTasksEXTPtr (Just fnPtr)
          pure (mkCmdDrawMeshTasksEXT fnPtr)

cmdDrawMeshTasksEXT ::
  (MonadIO m) =>
  Vulkan.Device ->
  Vulkan.CommandBuffer ->
  -- | groupCountX
  Word32 ->
  -- | groupCountY
  Word32 ->
  -- | groupCountZ
  Word32 ->
  m ()
cmdDrawMeshTasksEXT device cmdBuf x y z = liftIO $ do
  fn <- loadCmdDrawMeshTasksEXT device
  fn (Vulkan.commandBufferHandle cmdBuf) x y z
