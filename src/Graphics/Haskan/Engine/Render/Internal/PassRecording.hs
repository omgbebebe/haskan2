{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Engine.Render.Internal.PassRecording
  ( RecordContext (..),
    buildRecordAction,
  )
where

import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Data.Foldable (for_)
import Data.Text qualified as Text
import Data.Word (Word32)
import Foreign.Marshal.Array qualified
import Foreign.Storable (Storable (..))
import Graphics.Haskan.Engine.Types (ComputeCullResources (..), DrawIndexedIndirectCommand (..))
import Graphics.Haskan.Logger (LogCategory (..), logInfoIO)
import Graphics.Haskan.Render.Deferred (DeferredPassData (..), buildDeferredGraph)
import Graphics.Haskan.Render.Graph (PassContext (..), PassRecordFunc (..))
import Graphics.Haskan.Render.Graph qualified as Graph
import Graphics.Haskan.Render.RenderSystem (DrawCall (..))
import Graphics.Haskan.Vulkan.CommandBuffer qualified as CommandBuffer
import Graphics.Haskan.Vulkan.DeferredResources (DeferredResources (..))
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Linear (V3 (..))

-- | All values pre-computed before creating the IO callback
data RecordContext = RecordContext
  {     prcGraphicsCommandBuffers :: ![Vulkan.VkCommandBuffer],
    rcFrameDescriptorSets :: ![Vulkan.VkDescriptorSet],
    rcTextureSampler :: !Vulkan.VkSampler,
    rcLightSsboBuffer :: !Vulkan.VkBuffer,
    rcDrawList :: ![DrawCall],
    rcCameraPos :: !(V3 Float),
    rcSkyboxRays :: !(V3 Float, V3 Float, V3 Float),
    rcDebugMode :: !Word32,
    rcAxisOverlay :: !Float,
    rcGroundPlane :: !Float,
    rcLightCount :: !Word32,
    rcSkyTint :: !(V3 Float),
    rcIBLIntensity :: !Float,
    rcSunAzimuth :: !Float,
    rcSunDir :: !(V3 Float),
    rcCloudHeight :: !Float,
    rcWireframeEnabled :: !Bool,
    rcDeferred :: !DeferredResources,
    rcCullResources :: !ComputeCullResources,
    prcDevice :: !Vulkan.VkDevice,
    prcSurfaceExtent :: !Vulkan.VkExtent2D
  }

buildRecordAction :: RecordContext -> Vulkan.Word32 -> Int -> IO ()
buildRecordAction RecordContext {..} imageIdx frameIdx = do
  let commandBuffer = prcGraphicsCommandBuffers !! fromIntegral imageIdx
      gBufferFramebuffer = drGBufferFramebuffers rcDeferred !! fromIntegral imageIdx
      lightingFramebuffer = drLightingFramebuffers rcDeferred !! fromIntegral imageIdx
      frameDescriptorSet = rcFrameDescriptorSets !! frameIdx
      lightingDescriptorSet = drLightingDescriptorSets rcDeferred !! fromIntegral imageIdx
      gBufferImagesForFrame = drGBufferImages rcDeferred !! fromIntegral imageIdx
      gBufferPassCtx =
        PassContext
          { pcCommandBuffer = commandBuffer,
            pcPipeline = drGBufferPipeline rcDeferred,
            pcPipelineLayout = drGBufferPipelineLayout rcDeferred,
            pcDescriptorSet = Vulkan.vkNullPtr,
            pcFramebuffer = gBufferFramebuffer,
            pcRenderPass = drGBufferRenderPass rcDeferred,
            pcExtent = prcSurfaceExtent
          }
      lightingPassCtx =
        PassContext
          { pcCommandBuffer = commandBuffer,
            pcPipeline = drLightingPipeline rcDeferred,
            pcPipelineLayout = drLightingPipelineLayout rcDeferred,
            pcDescriptorSet = lightingDescriptorSet,
            pcFramebuffer = lightingFramebuffer,
            pcRenderPass = drLightingRenderPass rcDeferred,
            pcExtent = prcSurfaceExtent
          }

      (graphRes, graphPasses) =
        Graph.execRenderGraphBuilder $
          buildDeferredGraph
            DeferredPassData
              { dpdExtent = prcSurfaceExtent,
                dpdGBufferRenderPass = drGBufferRenderPass rcDeferred,
                dpdGBufferFramebuffer = gBufferFramebuffer,
                dpdGBufferPipeline = drGBufferPipeline rcDeferred,
                dpdGBufferLayout = drGBufferPipelineLayout rcDeferred,
                dpdGBufferDescriptor = frameDescriptorSet,
                dpdGBufferSampler = rcTextureSampler,
                dpdDrawList = rcDrawList,
                dpdDevice = prcDevice,
                dpdDrawCommandsBuffer = ccrDrawCommandsBuffer rcCullResources,
                dpdEntityCount = fromIntegral (length rcDrawList),
                dpdLightingRenderPass = drLightingRenderPass rcDeferred,
                dpdLightingFramebuffer = lightingFramebuffer,
                dpdLightingPipeline = drLightingPipeline rcDeferred,
                dpdLightingLayout = drLightingPipelineLayout rcDeferred,
                dpdLightingDescriptor = lightingDescriptorSet,
                dpdCameraPos = rcCameraPos,
                dpdSkyboxRays = rcSkyboxRays,
                dpdDebugMode = rcDebugMode,
                dpdAxisOverlay = rcAxisOverlay,
                dpdGroundPlane = rcGroundPlane,
                dpdLightCount = rcLightCount,
                dpdLightBuffer = rcLightSsboBuffer,
                dpdSkyTint = rcSkyTint,
                dpdIBLIntensity = rcIBLIntensity,
                dpdSunAzimuth = rcSunAzimuth,
                dpdSunDir = rcSunDir,
                dpdCloudHeight = rcCloudHeight,
                dpdGBufferImages = gBufferImagesForFrame,
                dpdWireframePipeline = drWireframePipeline rcDeferred,
                dpdWireframeLayout = drWireframePipelineLayout rcDeferred,
                dpdWireframeEnabled = rcWireframeEnabled
              }
  case Graph.compileGraph graphRes graphPasses of
    Left err -> logInfoIO LogRender $ "graph compilation failed: " <> Text.pack (show err)
    Right compiled -> do
      CommandBuffer.withCommandBuffer commandBuffer $ do
        let numWorkgroups = (length rcDrawList + 63) `div` 64
        when (numWorkgroups > 0) $ do
          liftIO $ Vulkan.vkCmdBindPipeline commandBuffer Vulkan.VK_PIPELINE_BIND_POINT_COMPUTE (ccrPipeline rcCullResources)
          liftIO $ Foreign.Marshal.Array.withArray [ccrDescriptorSet rcCullResources] $ \dsPtr ->
            Vulkan.vkCmdBindDescriptorSets
              commandBuffer
              Vulkan.VK_PIPELINE_BIND_POINT_COMPUTE
              (ccrPipelineLayout rcCullResources)
              0
              1
              dsPtr
              0
              Vulkan.vkNullPtr
          liftIO $ CommandBuffer.cmdDispatch commandBuffer (fromIntegral numWorkgroups) 1 1
          liftIO $
            CommandBuffer.cmdBufferBarrier
              commandBuffer
              (ccrDrawCommandsBuffer rcCullResources)
              (fromIntegral (ccrMaxEntities rcCullResources * sizeOf (undefined :: DrawIndexedIndirectCommand)))
              Vulkan.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT
              Vulkan.VK_ACCESS_SHADER_WRITE_BIT
              Vulkan.VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT
              Vulkan.VK_ACCESS_INDIRECT_COMMAND_READ_BIT

        let passes = Graph.cgPasses compiled
        for_ passes $ \cp -> do
          let pass = Graph.cpPass cp
              recordFn = unPassRecordFunc (Graph.rpRecord pass)
              passCtx = if Graph.rpName pass == "gbuffer" then gBufferPassCtx else lightingPassCtx
          liftIO $ recordFn passCtx
