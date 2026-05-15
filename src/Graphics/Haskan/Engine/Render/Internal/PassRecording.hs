{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Engine.Render.Internal.PassRecording
  ( RecordContext (..),
    buildRecordAction,
    buildRecordContext,
  )
where

import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Data.Foldable (for_)
import Data.Text qualified as Text
import Data.Word (Word32)
import qualified DearImGui.Raw
import Foreign.Marshal.Array qualified
import Foreign.Storable (Storable (..))
import Graphics.Haskan.Camera (AnyCamera, Camera (..))
import Graphics.Haskan.Camera qualified as Camera
import Graphics.Haskan.Engine.Render.Internal.FrameState (FrameState (..))
import Graphics.Haskan.Engine.Types (ComputeCullResources (..), DrawIndexedIndirectCommand (..))
import Graphics.Haskan.Logger (LogCategory (..), logInfoIO)
import Graphics.Haskan.Render.Deferred (DeferredPassData (..), buildDeferredGraph)
import Graphics.Haskan.Render.Graph (PassContext (..), PassRecordFunc (..))
import Graphics.Haskan.Render.Graph qualified as Graph
import Graphics.Haskan.Render.RenderSystem (DrawCall (..))
import Graphics.Haskan.UI.Backend qualified as Backend
import Graphics.Haskan.Vulkan.CommandBuffer qualified as CommandBuffer
import Graphics.Haskan.Vulkan.DeferredResources (DeferredResources (..))
import Graphics.Haskan.Vulkan.Types (RenderContext (..))
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Linear (M44, V3 (..))

-- | All values pre-computed before creating the IO callback
data RecordContext = RecordContext
  { rcGraphicsCommandBuffers :: ![Vulkan.VkCommandBuffer],
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
    rcTime :: !Float,
    rcPrevViewProj :: !(M44 Float),
    rcWindDirX :: !Float,
    rcWindDirZ :: !Float,
    rcPrevTime :: !Float,
    rcCloudCoverage :: !Float,
    rcCloudDetail :: !Float,
    rcCloudAbsorption :: !Float,
    rcWireframeEnabled :: !Bool,
    rcDeferred :: !DeferredResources,
    rcCullResources :: !ComputeCullResources,
    rcDevice :: !Vulkan.VkDevice,
    rcPassSurfaceExtent :: !Vulkan.VkExtent2D,
    rcImGuiRenderPass :: !Vulkan.VkRenderPass,
    rcImGuiFramebuffers :: ![Vulkan.VkFramebuffer],
    rcImGuiDrawData :: !(Maybe DearImGui.Raw.DrawData)
  }

buildRecordContext ::
  RenderContext ->
  DeferredResources ->
  ComputeCullResources ->
  [Vulkan.VkDescriptorSet] ->
  Vulkan.VkSampler ->
  Vulkan.VkBuffer ->
  FrameState ->
  AnyCamera ->
  [DrawCall] ->
  Word32 ->
  (V3 Float, V3 Float, V3 Float) ->
  V3 Float ->
  Float ->
  Float ->
  V3 Float ->
  Float ->
  M44 Float ->
  Float ->
  Float ->
  Float ->
  Float ->
  Float ->
  Float ->
  Maybe DearImGui.Raw.DrawData ->
  RecordContext
buildRecordContext ctx dr ccr frameDescriptorSets textureSampler lightSsboBuffer frameState camera drawList lightCount skyboxRays skyTint iblInt sunAzimuth sunDir time prevViewProj windDirX windDirZ prevTime cloudCoverage cloudDetail cloudAbsorption mDrawData =
  RecordContext
    { rcGraphicsCommandBuffers = graphicsCommandBuffers ctx,
      rcFrameDescriptorSets = frameDescriptorSets,
      rcTextureSampler = textureSampler,
      rcLightSsboBuffer = lightSsboBuffer,
      rcDrawList = drawList,
      rcCameraPos = realToFrac <$> Camera.cameraPosition camera,
      rcSkyboxRays = skyboxRays,
      rcDebugMode = fsDebugMode frameState,
      rcAxisOverlay = fsAxisOverlay frameState,
      rcGroundPlane = fsGroundPlane frameState,
      rcLightCount = lightCount,
      rcSkyTint = skyTint,
      rcIBLIntensity = iblInt,
      rcSunAzimuth = sunAzimuth,
      rcSunDir = sunDir,
      rcCloudHeight = fsCloudHeight frameState,
      rcTime = time,
      rcPrevViewProj = prevViewProj,
      rcWindDirX = windDirX,
      rcWindDirZ = windDirZ,
      rcPrevTime = prevTime,
      rcCloudCoverage = cloudCoverage,
      rcCloudDetail = cloudDetail,
      rcCloudAbsorption = cloudAbsorption,
      rcWireframeEnabled = fsWireframe frameState,
      rcDeferred = dr,
      rcCullResources = ccr,
      rcDevice = device ctx,
      rcPassSurfaceExtent = rcSurfaceExtent ctx,
      rcImGuiRenderPass = drImGuiRenderPass dr,
      rcImGuiFramebuffers = drImGuiFramebuffers dr,
      rcImGuiDrawData = mDrawData
    }

buildRecordAction :: RecordContext -> Vulkan.Word32 -> Int -> IO ()
buildRecordAction RecordContext {..} imageIdx frameIdx = do
  let commandBuffer = rcGraphicsCommandBuffers !! fromIntegral imageIdx
      gBufferFramebuffer = drGBufferFramebuffers rcDeferred !! fromIntegral imageIdx
      lightingFramebuffer = drLightingFramebuffers rcDeferred !! fromIntegral imageIdx
      frameDescriptorSet = rcFrameDescriptorSets !! frameIdx
      lightingDescriptorSet = drLightingDescriptorSets rcDeferred !! fromIntegral imageIdx
      gBufferImagesForFrame = drGBufferImages rcDeferred !! fromIntegral imageIdx
      cloudFramebuffer = drCloudFramebuffers rcDeferred !! fromIntegral imageIdx
      cloudDescriptorSet = drCloudDescriptorSets rcDeferred !! fromIntegral imageIdx
      cloudImage = drCloudImages rcDeferred !! fromIntegral imageIdx
      cloudHistoryImage = drCloudHistoryImages rcDeferred !! fromIntegral imageIdx
      gBufferPassCtx =
        PassContext
          { pcCommandBuffer = commandBuffer,
            pcPipeline = drGBufferPipeline rcDeferred,
            pcPipelineLayout = drGBufferPipelineLayout rcDeferred,
            pcDescriptorSet = Vulkan.vkNullPtr,
            pcFramebuffer = gBufferFramebuffer,
            pcRenderPass = drGBufferRenderPass rcDeferred,
            pcExtent = rcPassSurfaceExtent
          }
      cloudPassCtx =
        PassContext
          { pcCommandBuffer = commandBuffer,
            pcPipeline = drCloudPipeline rcDeferred,
            pcPipelineLayout = drCloudPipelineLayout rcDeferred,
            pcDescriptorSet = cloudDescriptorSet,
            pcFramebuffer = cloudFramebuffer,
            pcRenderPass = drCloudRenderPass rcDeferred,
            pcExtent = drCloudExtent rcDeferred
          }
      lightingPassCtx =
        PassContext
          { pcCommandBuffer = commandBuffer,
            pcPipeline = drLightingPipeline rcDeferred,
            pcPipelineLayout = drLightingPipelineLayout rcDeferred,
            pcDescriptorSet = lightingDescriptorSet,
            pcFramebuffer = lightingFramebuffer,
            pcRenderPass = drLightingRenderPass rcDeferred,
            pcExtent = rcPassSurfaceExtent
          }

      (graphRes, graphPasses) =
        Graph.execRenderGraphBuilder $
          buildDeferredGraph
            DeferredPassData
              { dpdExtent = rcPassSurfaceExtent,
                dpdGBufferRenderPass = drGBufferRenderPass rcDeferred,
                dpdGBufferFramebuffer = gBufferFramebuffer,
                dpdGBufferPipeline = drGBufferPipeline rcDeferred,
                dpdGBufferLayout = drGBufferPipelineLayout rcDeferred,
                dpdGBufferDescriptor = frameDescriptorSet,
                dpdGBufferSampler = rcTextureSampler,
                dpdDrawList = rcDrawList,
                dpdDevice = rcDevice,
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
                dpdTime = rcTime,
                dpdPrevViewProj = rcPrevViewProj,
                dpdBlendFactor = 0.92,
                dpdWindDirX = rcWindDirX,
                dpdWindDirZ = rcWindDirZ,
                dpdPrevTime = rcPrevTime,
                dpdCloudCoverage = rcCloudCoverage,
                dpdCloudDetail = rcCloudDetail,
                dpdCloudAbsorption = rcCloudAbsorption,
                dpdCloudFrameDataMemory = drCloudFrameDataMemory rcDeferred,
                dpdCloudRenderPass = drCloudRenderPass rcDeferred,
                dpdCloudFramebuffer = cloudFramebuffer,
                dpdCloudPipeline = drCloudPipeline rcDeferred,
                dpdCloudLayout = drCloudPipelineLayout rcDeferred,
                dpdCloudDescriptor = cloudDescriptorSet,
                dpdCloudExtent = drCloudExtent rcDeferred,
                dpdCloudImage = cloudImage,
                dpdCloudHistoryImage = cloudHistoryImage,
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
              passCtx = case Graph.rpName pass of
                "gbuffer" -> gBufferPassCtx
                "clouds" -> cloudPassCtx
                _ -> lightingPassCtx
          liftIO $ recordFn passCtx

        -- Dear ImGui overlay pass
        for_ rcImGuiDrawData $ \drawData -> liftIO $ do
          let imGuiFramebuffer = rcImGuiFramebuffers !! fromIntegral imageIdx
          Backend.recordImGuiDrawData commandBuffer rcImGuiRenderPass imGuiFramebuffer rcPassSurfaceExtent drawData
