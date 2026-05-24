{-# LANGUAGE BlockArguments    #-}
{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Graphics.Haskan.Vulkan.MeshPipeline
  ( createMeshPipeline
  , createMeshPipelineWithBlending
  , managedMeshPipeline
  , managedMeshPipelineWithBlending
  , cmdDrawMeshTasksEXT
  ) where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Bits ((.|.))
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (catMaybes)
import Data.Word (Word32)
import Foreign (FunPtr, Ptr, castFunPtr, nullFunPtr, nullPtr)
import Foreign.C (CInt (..), CUInt (..))
import Foreign.C.String (withCString)
import Foreign.Marshal.Array (withArray)
import Foreign.Storable (peek)
import System.IO.Unsafe (unsafePerformIO)

import Graphics.Haskan.Resources (alloc, allocaAndPeek, throwVkResult)
import Graphics.Haskan.Render.ShaderProgram (MeshShaderProgram (..))
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, setAt, setStrRef, setVkRef, setListRef, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan

-- ---------------------------------------------------------------------------
-- Mesh shader stage flag
-- vulkan-api lacks VK_SHADER_STAGE_MESH_BIT_EXT, so we hardcode the value.
-- ---------------------------------------------------------------------------

vkShaderStageMeshBitEXT :: Vulkan.VkShaderStageFlagBits
vkShaderStageMeshBitEXT =
  -- VK_SHADER_STAGE_MESH_BIT_EXT = 0x00000080
  Vulkan.VkShaderStageFlagBits 0x00000080

vkShaderStageTaskBitEXT :: Vulkan.VkShaderStageFlagBits
vkShaderStageTaskBitEXT =
  -- VK_SHADER_STAGE_TASK_BIT_EXT = 0x00000040
  Vulkan.VkShaderStageFlagBits 0x00000040

-- ---------------------------------------------------------------------------
-- Mesh pipeline creation (vulkan-api, no "vulkan" package dependency)
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
    mkStage stageBit mod_ =
      Vulkan.createVk
        ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
            &* set @"pNext" Vulkan.VK_NULL
            &* set @"stage" stageBit
            &* set @"module" mod_
            &* setStrRef @"pName" "main"
            &* set @"pSpecializationInfo" nullPtr
        )

    stages = catMaybes
      [ mkStage vkShaderStageTaskBitEXT <$> mspTask
      , Just $ mkStage vkShaderStageMeshBitEXT mspMesh
      , Just $ mkStage Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT mspFragment
      ]

    numStages = length stages

    -- Viewport (inverted Y for Vulkan)
    viewport =
      Vulkan.createVk
        ( set @"x" 0
            &* set @"y" (fromIntegral $ Vulkan.getField @"height" swapchainExtent)
            &* set @"width" (fromIntegral $ Vulkan.getField @"width" swapchainExtent)
            &* set @"height" (- (fromIntegral $ Vulkan.getField @"height" swapchainExtent))
            &* set @"minDepth" (0.0 :: Float)
            &* set @"maxDepth" (1.0 :: Float)
        )

    scissor =
      Vulkan.createVk
        ( set @"offset"
            (Vulkan.createVk
              ( set @"x" 0
                  &* set @"y" 0
              ))
            &* set @"extent"
            (Vulkan.createVk
              ( set @"width" (fromIntegral $ Vulkan.getField @"width" swapchainExtent)
                  &* set @"height" (fromIntegral $ Vulkan.getField @"height" swapchainExtent)
              ))
        )

    viewportState =
      Vulkan.createVk
        ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO
            &* set @"pNext" Vulkan.VK_NULL
            &* set @"flags" Vulkan.VK_ZERO_FLAGS
            &* set @"viewportCount" 1
            &* setListRef @"pViewports" [viewport]
            &* set @"scissorCount" 1
            &* setListRef @"pScissors" [scissor]
        )

    rasterizationState =
      Vulkan.createVk
        ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
            &* set @"pNext" Vulkan.VK_NULL
            &* set @"flags" Vulkan.VK_ZERO_FLAGS
            &* set @"depthClampEnable" Vulkan.VK_FALSE
            &* set @"rasterizerDiscardEnable" Vulkan.VK_FALSE
            &* set @"polygonMode" Vulkan.VK_POLYGON_MODE_FILL
            &* set @"lineWidth" (1.0 :: Float)
            &* set @"cullMode" Vulkan.VK_CULL_MODE_BACK_BIT
            &* set @"frontFace" Vulkan.VK_FRONT_FACE_COUNTER_CLOCKWISE
            &* set @"depthBiasEnable" Vulkan.VK_FALSE
            &* set @"depthBiasConstantFactor" (0.0 :: Float)
            &* set @"depthBiasClamp" (0.0 :: Float)
            &* set @"depthBiasSlopeFactor" (0.0 :: Float)
        )

    multisampleState =
      Vulkan.createVk
        ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
            &* set @"pNext" Vulkan.VK_NULL
            &* set @"flags" Vulkan.VK_ZERO_FLAGS
            &* set @"sampleShadingEnable" Vulkan.VK_FALSE
            &* set @"rasterizationSamples" Vulkan.VK_SAMPLE_COUNT_1_BIT
            &* set @"minSampleShading" (1.0 :: Float)
            &* setListRef @"pSampleMask" ([] :: [Vulkan.VkSampleMask])
            &* set @"alphaToCoverageEnable" Vulkan.VK_FALSE
            &* set @"alphaToOneEnable" Vulkan.VK_FALSE
        )

    nullStencilOp =
      Vulkan.createVk
        ( set @"failOp" Vulkan.VK_STENCIL_OP_KEEP
            &* set @"passOp" Vulkan.VK_STENCIL_OP_KEEP
            &* set @"depthFailOp" Vulkan.VK_STENCIL_OP_KEEP
            &* set @"compareOp" Vulkan.VK_COMPARE_OP_ALWAYS
            &* set @"compareMask" 0
            &* set @"writeMask" 0
            &* set @"reference" 0
        )

    depthStencilState =
      Vulkan.createVk
        ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO
            &* set @"pNext" Vulkan.VK_NULL
            &* set @"flags" Vulkan.VK_ZERO_FLAGS
            &* set @"depthTestEnable" Vulkan.VK_TRUE
            &* set @"depthWriteEnable" Vulkan.VK_TRUE
            &* set @"depthCompareOp" Vulkan.VK_COMPARE_OP_LESS_OR_EQUAL
            &* set @"depthBoundsTestEnable" Vulkan.VK_FALSE
            &* set @"stencilTestEnable" Vulkan.VK_FALSE
            &* set @"front" nullStencilOp
            &* set @"back" nullStencilOp
            &* set @"minDepthBounds" (0.0 :: Float)
            &* set @"maxDepthBounds" (1.0 :: Float)
        )

    colorBlendAttachment =
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

    colorBlendState =
      Vulkan.createVk
        ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO
            &* set @"pNext" Vulkan.VK_NULL
            &* set @"flags" Vulkan.VK_ZERO_FLAGS
            &* set @"logicOpEnable" Vulkan.VK_FALSE
            &* set @"logicOp" Vulkan.VK_LOGIC_OP_COPY
            &* set @"attachmentCount" (fromIntegral colorAttachmentCount)
            &* setListRef @"pAttachments" (replicate colorAttachmentCount colorBlendAttachment)
            &* setAt @"blendConstants" @0 (0.0 :: Float)
            &* setAt @"blendConstants" @1 (0.0 :: Float)
            &* setAt @"blendConstants" @2 (0.0 :: Float)
            &* setAt @"blendConstants" @3 (0.0 :: Float)
        )

    dynamicState =
      Vulkan.createVk
        ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO
            &* set @"pNext" Vulkan.VK_NULL
            &* set @"flags" Vulkan.VK_ZERO_FLAGS
            &* set @"dynamicStateCount" 0
            &* setListRef @"pDynamicStates" ([] :: [Vulkan.VkDynamicState])
        )

    pipelineCI =
      Vulkan.createVk
        ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
            &* set @"pNext" Vulkan.VK_NULL
            &* set @"flags" Vulkan.VK_ZERO_FLAGS
            &* set @"stageCount" (fromIntegral numStages)
            &* setListRef @"pStages" stages
            &* set @"pVertexInputState" nullPtr
            &* set @"pInputAssemblyState" nullPtr
            &* set @"pTessellationState" nullPtr
            &* setVkRef @"pViewportState" viewportState
            &* setVkRef @"pRasterizationState" rasterizationState
            &* setVkRef @"pMultisampleState" multisampleState
            &* setVkRef @"pDepthStencilState" depthStencilState
            &* setVkRef @"pColorBlendState" colorBlendState
            &* setVkRef @"pDynamicState" dynamicState
            &* set @"layout" layout
            &* set @"renderPass" renderPass
            &* set @"subpass" (0 :: Word32)
            &* set @"basePipelineHandle" Vulkan.VK_NULL_HANDLE
            &* set @"basePipelineIndex" (-1)
        )

  pipeline <- liftIO $
    withPtr pipelineCI $ \pciPtr ->
      allocaAndPeek $ Vulkan.vkCreateGraphicsPipelines dev Vulkan.VK_NULL 1 pciPtr Vulkan.VK_NULL

  pure pipeline

managedMeshPipelineWithBlending
  :: (MonadManaged m)
  => Vulkan.VkDevice
  -> Vulkan.VkPipelineLayout
  -> Vulkan.VkRenderPass
  -> MeshShaderProgram
  -> Vulkan.VkExtent2D
  -> Int  -- ^ color attachment count
  -> m Vulkan.VkPipeline
managedMeshPipelineWithBlending dev layout renderPass program extent colorCount =
  alloc
    "MeshPipelineWithBlending"
    (createMeshPipelineWithBlending dev layout renderPass program extent colorCount)
    (\ptr -> Vulkan.vkDestroyPipeline dev ptr Vulkan.vkNullPtr)

createMeshPipelineWithBlending
  :: (MonadIO m)
  => Vulkan.VkDevice
  -> Vulkan.VkPipelineLayout
  -> Vulkan.VkRenderPass
  -> MeshShaderProgram
  -> Vulkan.VkExtent2D
  -> Int  -- ^ color attachment count
  -> m Vulkan.VkPipeline
createMeshPipelineWithBlending dev layout renderPass program swapchainExtent colorAttachmentCount = do
  let
    mkStage stageBit mod_ =
      Vulkan.createVk
        ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
            &* set @"pNext" Vulkan.VK_NULL
            &* set @"stage" stageBit
            &* set @"module" mod_
            &* setStrRef @"pName" "main"
            &* set @"pSpecializationInfo" nullPtr
        )

    stages = catMaybes
      [ mkStage vkShaderStageTaskBitEXT <$> mspTask program
      , Just $ mkStage vkShaderStageMeshBitEXT (mspMesh program)
      , Just $ mkStage Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT (mspFragment program)
      ]

    numStages = length stages

    viewport =
      Vulkan.createVk
        ( set @"x" 0
            &* set @"y" (fromIntegral $ Vulkan.getField @"height" swapchainExtent)
            &* set @"width" (fromIntegral $ Vulkan.getField @"width" swapchainExtent)
            &* set @"height" (- (fromIntegral $ Vulkan.getField @"height" swapchainExtent))
            &* set @"minDepth" (0.0 :: Float)
            &* set @"maxDepth" (1.0 :: Float)
        )

    scissor =
      Vulkan.createVk
        ( set @"offset"
            (Vulkan.createVk
              ( set @"x" 0
                  &* set @"y" 0
              ))
            &* set @"extent"
            (Vulkan.createVk
              ( set @"width" (fromIntegral $ Vulkan.getField @"width" swapchainExtent)
                  &* set @"height" (fromIntegral $ Vulkan.getField @"height" swapchainExtent)
              ))
        )

    viewportState =
      Vulkan.createVk
        ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO
            &* set @"pNext" Vulkan.VK_NULL
            &* set @"flags" Vulkan.VK_ZERO_FLAGS
            &* set @"viewportCount" 1
            &* setListRef @"pViewports" [viewport]
            &* set @"scissorCount" 1
            &* setListRef @"pScissors" [scissor]
        )

    rasterizationState =
      Vulkan.createVk
        ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
            &* set @"pNext" Vulkan.VK_NULL
            &* set @"flags" Vulkan.VK_ZERO_FLAGS
            &* set @"depthClampEnable" Vulkan.VK_FALSE
            &* set @"rasterizerDiscardEnable" Vulkan.VK_FALSE
            &* set @"polygonMode" Vulkan.VK_POLYGON_MODE_FILL
            &* set @"lineWidth" (1.0 :: Float)
            &* set @"cullMode" Vulkan.VK_CULL_MODE_BACK_BIT
            &* set @"frontFace" Vulkan.VK_FRONT_FACE_COUNTER_CLOCKWISE
            &* set @"depthBiasEnable" Vulkan.VK_FALSE
            &* set @"depthBiasConstantFactor" (0.0 :: Float)
            &* set @"depthBiasClamp" (0.0 :: Float)
            &* set @"depthBiasSlopeFactor" (0.0 :: Float)
        )

    multisampleState =
      Vulkan.createVk
        ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
            &* set @"pNext" Vulkan.VK_NULL
            &* set @"flags" Vulkan.VK_ZERO_FLAGS
            &* set @"sampleShadingEnable" Vulkan.VK_FALSE
            &* set @"rasterizationSamples" Vulkan.VK_SAMPLE_COUNT_1_BIT
            &* set @"minSampleShading" (1.0 :: Float)
            &* setListRef @"pSampleMask" ([] :: [Vulkan.VkSampleMask])
            &* set @"alphaToCoverageEnable" Vulkan.VK_FALSE
            &* set @"alphaToOneEnable" Vulkan.VK_FALSE
        )

    nullStencilOp =
      Vulkan.createVk
        ( set @"failOp" Vulkan.VK_STENCIL_OP_KEEP
            &* set @"passOp" Vulkan.VK_STENCIL_OP_KEEP
            &* set @"depthFailOp" Vulkan.VK_STENCIL_OP_KEEP
            &* set @"compareOp" Vulkan.VK_COMPARE_OP_ALWAYS
            &* set @"compareMask" 0
            &* set @"writeMask" 0
            &* set @"reference" 0
        )

    depthStencilState =
      Vulkan.createVk
        ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO
            &* set @"pNext" Vulkan.VK_NULL
            &* set @"flags" Vulkan.VK_ZERO_FLAGS
            &* set @"depthTestEnable" Vulkan.VK_TRUE
            &* set @"depthWriteEnable" Vulkan.VK_TRUE
            &* set @"depthCompareOp" Vulkan.VK_COMPARE_OP_LESS_OR_EQUAL
            &* set @"depthBoundsTestEnable" Vulkan.VK_FALSE
            &* set @"stencilTestEnable" Vulkan.VK_FALSE
            &* set @"front" nullStencilOp
            &* set @"back" nullStencilOp
            &* set @"minDepthBounds" (0.0 :: Float)
            &* set @"maxDepthBounds" (1.0 :: Float)
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
            &* set @"dstAlphaBlendFactor" Vulkan.VK_BLEND_FACTOR_ZERO
            &* set @"alphaBlendOp" Vulkan.VK_BLEND_OP_ADD
        )

    colorBlendState =
      Vulkan.createVk
        ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO
            &* set @"pNext" Vulkan.VK_NULL
            &* set @"flags" Vulkan.VK_ZERO_FLAGS
            &* set @"logicOpEnable" Vulkan.VK_FALSE
            &* set @"logicOp" Vulkan.VK_LOGIC_OP_COPY
            &* set @"attachmentCount" (fromIntegral colorAttachmentCount)
            &* setListRef @"pAttachments" (replicate colorAttachmentCount colorBlendAttachment)
            &* setAt @"blendConstants" @0 (0.0 :: Float)
            &* setAt @"blendConstants" @1 (0.0 :: Float)
            &* setAt @"blendConstants" @2 (0.0 :: Float)
            &* setAt @"blendConstants" @3 (0.0 :: Float)
        )

    dynamicState =
      Vulkan.createVk
        ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO
            &* set @"pNext" Vulkan.VK_NULL
            &* set @"flags" Vulkan.VK_ZERO_FLAGS
            &* set @"dynamicStateCount" 0
            &* setListRef @"pDynamicStates" ([] :: [Vulkan.VkDynamicState])
        )

    pipelineCI =
      Vulkan.createVk
        ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
            &* set @"pNext" Vulkan.VK_NULL
            &* set @"flags" Vulkan.VK_ZERO_FLAGS
            &* set @"stageCount" (fromIntegral numStages)
            &* setListRef @"pStages" stages
            &* set @"pVertexInputState" nullPtr
            &* set @"pInputAssemblyState" nullPtr
            &* set @"pTessellationState" nullPtr
            &* setVkRef @"pViewportState" viewportState
            &* setVkRef @"pRasterizationState" rasterizationState
            &* setVkRef @"pMultisampleState" multisampleState
            &* setVkRef @"pDepthStencilState" depthStencilState
            &* setVkRef @"pColorBlendState" colorBlendState
            &* setVkRef @"pDynamicState" dynamicState
            &* set @"layout" layout
            &* set @"renderPass" renderPass
            &* set @"subpass" (0 :: Word32)
            &* set @"basePipelineHandle" Vulkan.VK_NULL_HANDLE
            &* set @"basePipelineIndex" (-1)
        )

  pipeline <- liftIO $
    withPtr pipelineCI $ \pciPtr ->
      allocaAndPeek $ Vulkan.vkCreateGraphicsPipelines dev Vulkan.VK_NULL 1 pciPtr Vulkan.VK_NULL

  pure pipeline

-- ---------------------------------------------------------------------------
-- Dynamic loading of vkCmdDrawMeshTasksEXT (vulkan-api lacks this extension)
-- ---------------------------------------------------------------------------

type PFN_vkCmdDrawMeshTasksEXT = Ptr Vulkan.VkCommandBuffer_T -> Word32 -> Word32 -> Word32 -> IO ()

foreign import ccall "dynamic"
  mkCmdDrawMeshTasksEXT :: FunPtr PFN_vkCmdDrawMeshTasksEXT -> PFN_vkCmdDrawMeshTasksEXT

{-# NOINLINE drawMeshTasksEXTPtr #-}
drawMeshTasksEXTPtr :: IORef (Maybe (FunPtr PFN_vkCmdDrawMeshTasksEXT))
drawMeshTasksEXTPtr = unsafePerformIO $ newIORef Nothing

loadCmdDrawMeshTasksEXT :: Vulkan.VkDevice -> IO PFN_vkCmdDrawMeshTasksEXT
loadCmdDrawMeshTasksEXT device = do
  cached <- readIORef drawMeshTasksEXTPtr
  case cached of
    Just fnPtr -> pure (mkCmdDrawMeshTasksEXT fnPtr)
    Nothing -> do
      withCString "vkCmdDrawMeshTasksEXT" $ \namePtr -> do
        procAddr <- Vulkan.vkGetDeviceProcAddr device namePtr
        if procAddr == nullFunPtr
          then error "vkCmdDrawMeshTasksEXT not available - VK_EXT_mesh_shader not enabled?"
          else do
            let fnPtr = castFunPtr procAddr
            writeIORef drawMeshTasksEXTPtr (Just fnPtr)
            pure (mkCmdDrawMeshTasksEXT fnPtr)

cmdDrawMeshTasksEXT
  :: (MonadIO m)
  => Vulkan.VkDevice
  -> Vulkan.VkCommandBuffer
  -> Word32  -- ^ groupCountX
  -> Word32  -- ^ groupCountY
  -> Word32  -- ^ groupCountZ
  -> m ()
cmdDrawMeshTasksEXT device cmdBuf x y z = liftIO $ do
  fn <- loadCmdDrawMeshTasksEXT device
  fn cmdBuf x y z
