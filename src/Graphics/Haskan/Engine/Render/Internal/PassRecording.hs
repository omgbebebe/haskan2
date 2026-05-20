{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Engine.Render.Internal.PassRecording
  ( RecordContext (..),
    buildRecordAction,
    buildRecordContext,
  )
where

import Control.Concurrent.STM qualified as STM
import Control.Lens ((^.))
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Data.Foldable (for_)
import Data.Text qualified as Text
import Data.Word (Word32)
import DearImGui.Raw qualified
import Foreign.C (CFloat)
import Foreign.Marshal.Array qualified
import Foreign.Storable (Storable (..))
import Graphics.Haskan.Camera (AnyCamera, Camera (..))
import Graphics.Haskan.Camera qualified as Camera
import Graphics.Haskan.Camera.Types (ViewMatrix (..))
import Graphics.Haskan.Engine.Render.Internal.FrameState (FrameState (..))
import Graphics.Haskan.Engine.Types (ComputeCullResources (..), DrawIndexedIndirectCommand (..))
import Graphics.Haskan.Logger (LogCategory (..), logInfoIO)
import Graphics.Haskan.Render.Deferred (DeferredPassData (..), buildDeferredGraph)
import Graphics.Haskan.Render.Graph (PassContext (..), PassRecordFunc (..))
import Graphics.Haskan.Render.Graph qualified as Graph
import Graphics.Haskan.Render.RenderSystem (DrawCall (..))
import Graphics.Haskan.UI.Backend qualified as Backend
import Graphics.Haskan.Vulkan.Buffer qualified as Buffer
import Graphics.Haskan.Vulkan.CommandBuffer qualified as CommandBuffer
import Graphics.Haskan.Vulkan.DeferredResources (DeferredResources (..))
import Graphics.Haskan.Vulkan.Types (RenderContext (..))
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan
import Linear (M44, V3 (..), V4 (..), (^*))
import Linear.Matrix ((!*), (!*!))
import Linear.Projection (perspective)
import Linear.V3 (_x, _y, _z)
import Linear.V4 (_w)

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
    rcSunScreenX :: !Float,
    rcSunScreenY :: !Float,
    rcSunDir :: !(V3 Float),
    rcCloudHeight :: !Float,
    rcTime :: !Float,
    rcPrevViewProjTVars :: ![STM.TVar (M44 CFloat)],
    rcPrevTimeTVars :: ![STM.TVar Float],
    rcCurrentCloudViewProj :: !(M44 CFloat),
    rcWindDirX :: !Float,
    rcWindDirZ :: !Float,
    rcCloudCoverage :: !Float,
    rcCloudDetail :: !Float,
    rcCloudAbsorption :: !Float,
    rcWeatherCoverageScale :: !Float,
    rcWeatherTypeBias :: !Float,
    rcStormIntensity :: !Float,
    rcWeatherAnimSpeed :: !Float,
    rcWireframeEnabled :: !Bool,
    rcDeferred :: !DeferredResources,
    rcCullResources :: !ComputeCullResources,
    rcDevice :: !Vulkan.VkDevice,
    rcPassSurfaceExtent :: !Vulkan.VkExtent2D,
    rcImGuiRenderPass :: !Vulkan.VkRenderPass,
    rcImGuiFramebuffers :: ![Vulkan.VkFramebuffer],
    rcImGuiDrawData :: !(Maybe DearImGui.Raw.DrawData),
    -- AP volume uniform data
    rcInvViewProj :: !(M44 Float),
    rcNearPlane :: !Float,
    rcFarPlane :: !Float,
    rcSunColor :: !(V3 Float),
    rcCloudBase :: !Float,
    rcCloudTop :: !Float
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
  [STM.TVar (M44 CFloat)] ->
  [STM.TVar Float] ->
  M44 CFloat ->
  Float ->
  Float ->
  Float ->
  Float ->
  Float ->
  Float ->
  Float ->
  Float ->
  Float ->
  M44 Float ->
  Float ->
  Float ->
  V3 Float ->
  Float ->
  Float ->
  Maybe DearImGui.Raw.DrawData ->
  RecordContext
buildRecordContext ctx dr ccr frameDescriptorSets textureSampler lightSsboBuffer frameState camera drawList lightCount skyboxRays skyTint iblInt sunAzimuth sunDir time prevViewProjTVars prevTimeTVars currentCloudViewProj windDirX windDirZ cloudCoverage cloudDetail cloudAbsorption weatherCoverageScale weatherTypeBias stormIntensity weatherAnimSpeed invViewProj nearPlane farPlane sunColor cloudBase cloudTop mDrawData =
  let viewMat = fmap (fmap realToFrac) (unViewMatrix (Camera.toMatrix camera)) :: M44 Float
      extent = rcSurfaceExtent ctx
      width = realToFrac (Vulkan.getField @"width" extent) :: Float
      height = realToFrac (Vulkan.getField @"height" extent) :: Float
      projMat = perspective (pi / 3) (width / height) 1.0 50000.0
      viewProj = projMat !*! viewMat
      sunWorld = sunDir ^* 10000.0
      V4 cx cy cz cw = viewProj !* V4 (sunWorld ^. _x) (sunWorld ^. _y) (sunWorld ^. _z) 1.0
      sunScreenX = if cw > 0 then cx / cw * 0.5 + 0.5 else (-1.0)
      sunScreenY = if cw > 0 then -cy / cw * 0.5 + 0.5 else (-1.0)
   in RecordContext
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
          rcSunScreenX = sunScreenX,
          rcSunScreenY = sunScreenY,
          rcSunDir = sunDir,
          rcCloudHeight = fsCloudHeight frameState,
          rcTime = time,
          rcPrevViewProjTVars = prevViewProjTVars,
          rcPrevTimeTVars = prevTimeTVars,
          rcCurrentCloudViewProj = currentCloudViewProj,
          rcWindDirX = windDirX,
          rcWindDirZ = windDirZ,
          rcCloudCoverage = cloudCoverage,
          rcCloudDetail = cloudDetail,
          rcCloudAbsorption = cloudAbsorption,
          rcWeatherCoverageScale = weatherCoverageScale,
          rcWeatherTypeBias = weatherTypeBias,
          rcStormIntensity = stormIntensity,
          rcWeatherAnimSpeed = weatherAnimSpeed,
           rcWireframeEnabled = fsWireframe frameState,
           rcDeferred = dr,
           rcCullResources = ccr,
           rcDevice = device ctx,
           rcPassSurfaceExtent = rcSurfaceExtent ctx,
           rcImGuiRenderPass = drImGuiRenderPass dr,
           rcImGuiFramebuffers = drImGuiFramebuffers dr,
           rcImGuiDrawData = mDrawData,
           rcInvViewProj = invViewProj,
           rcNearPlane = nearPlane,
           rcFarPlane = farPlane,
           rcSunColor = sunColor,
           rcCloudBase = cloudBase,
           rcCloudTop = cloudTop
         }

buildRecordAction :: RecordContext -> Vulkan.Word32 -> Int -> IO ()
buildRecordAction RecordContext {..} imageIdx frameIdx = do
  prevViewProj <- STM.readTVarIO (rcPrevViewProjTVars !! fromIntegral imageIdx)
  prevTimeVal <- STM.readTVarIO (rcPrevTimeTVars !! fromIntegral imageIdx)
  STM.atomically $ do
    STM.writeTVar (rcPrevViewProjTVars !! fromIntegral imageIdx) rcCurrentCloudViewProj
    STM.writeTVar (rcPrevTimeTVars !! fromIntegral imageIdx) rcTime
  let prevViewProjF = (realToFrac <$>) <$> prevViewProj
      commandBuffer = rcGraphicsCommandBuffers !! fromIntegral imageIdx
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
                 dpdGBufferDoubleSidedPipeline = drGBufferDoubleSidedPipeline rcDeferred,
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
                dpdSunScreenX = rcSunScreenX,
                dpdSunScreenY = rcSunScreenY,
                dpdSunDir = rcSunDir,
                dpdCloudHeight = rcCloudHeight,
                dpdTime = rcTime,
                dpdPrevViewProj = prevViewProjF,
                dpdBlendFactor = 0.3,
                dpdWindDirX = rcWindDirX,
                dpdWindDirZ = rcWindDirZ,
                dpdPrevTime = prevTimeVal,
                dpdCloudCoverage = rcCloudCoverage,
                dpdCloudDetail = rcCloudDetail,
                dpdCloudAbsorption = rcCloudAbsorption,
                dpdWeatherCoverageScale = rcWeatherCoverageScale,
                dpdWeatherTypeBias = rcWeatherTypeBias,
                dpdStormIntensity = rcStormIntensity,
                dpdWeatherAnimSpeed = rcWeatherAnimSpeed,
                dpdFrameIndex = frameIdx,
                dpdCloudFrameDataMemory = drCloudFrameDataMemory rcDeferred,
                dpdCloudRenderPass = drCloudRenderPass rcDeferred,
                dpdCloudFramebuffer = cloudFramebuffer,
                dpdCloudPipeline = drCloudPipeline rcDeferred,
                dpdCloudLayout = drCloudPipelineLayout rcDeferred,
                dpdCloudDescriptor = cloudDescriptorSet,
                dpdCloudExtent = drCloudExtent rcDeferred,
                dpdCloudImage = cloudImage,
                dpdCloudHistoryImage = cloudHistoryImage,
                dpdGodRayRenderPass = drGodRayRenderPass rcDeferred,
                dpdGodRayFramebuffer = drGodRayFramebuffers rcDeferred !! fromIntegral imageIdx,
                dpdGodRayPipeline = drGodRayPipeline rcDeferred,
                dpdGodRayLayout = drGodRayPipelineLayout rcDeferred,
                dpdGodRayDescriptor = drGodRayDescriptorSets rcDeferred !! fromIntegral imageIdx,
                dpdGodRayExtent = drCloudExtent rcDeferred,
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

          -- After g-buffer, run AP volume compute
          when (Graph.rpName pass == "gbuffer") $ do
            -- Write AP volume uniform data (std140 layout, 256 byte buffer)
            let (V3 camX camY camZ) = rcCameraPos
                (V4 r0x r0y r0z r0w) = rcInvViewProj ^. _x
                (V4 r1x r1y r1z r1w) = rcInvViewProj ^. _y
                (V4 r2x r2y r2z r2w) = rcInvViewProj ^. _z
                (V4 r3x r3y r3z r3w) = rcInvViewProj ^. _w
                (V3 sunDirX sunDirY sunDirZ) = rcSunDir
                (V3 sunColorR sunColorG sunColorB) = rcSunColor
                apVolumeData =
                  [ realToFrac camX, realToFrac camY, realToFrac camZ, 0,
                    realToFrac r0x, realToFrac r0y, realToFrac r0z, realToFrac r0w,
                    realToFrac r1x, realToFrac r1y, realToFrac r1z, realToFrac r1w,
                    realToFrac r2x, realToFrac r2y, realToFrac r2z, realToFrac r2w,
                    realToFrac r3x, realToFrac r3y, realToFrac r3z, realToFrac r3w,
                    realToFrac sunDirX, realToFrac sunDirY, realToFrac sunDirZ, 0,
                    realToFrac sunColorR, realToFrac sunColorG, realToFrac sunColorB, 0,
                    realToFrac rcCloudBase,
                    realToFrac rcCloudTop,
                    realToFrac rcTime,
                    realToFrac rcNearPlane,
                    realToFrac rcFarPlane,
                    64.0, -- volumeDepth
                    realToFrac rcWindDirX,
                    realToFrac rcWindDirZ,
                    realToFrac rcCloudAbsorption,
                    realToFrac rcWeatherCoverageScale,
                    realToFrac rcWeatherTypeBias,
                    realToFrac rcStormIntensity,
                    realToFrac rcWeatherAnimSpeed,
                    realToFrac rcCloudDetail,
                    0, 0 -- pad to 256 bytes
                  ] :: [CFloat]
            liftIO $ Buffer.copyDataToDeviceMemory rcDevice (drAPVolumeUniformMemory rcDeferred) apVolumeData
            let apVolumePipeline = drAPVolumePipeline rcDeferred
                apVolumeLayout = drAPVolumePipelineLayout rcDeferred
                apVolumeDescriptorSet = drAPVolumeDescriptorSets rcDeferred !! fromIntegral imageIdx
            liftIO $ Vulkan.vkCmdBindPipeline commandBuffer Vulkan.VK_PIPELINE_BIND_POINT_COMPUTE apVolumePipeline
            liftIO $ Foreign.Marshal.Array.withArray [apVolumeDescriptorSet] $ \dsPtr ->
              Vulkan.vkCmdBindDescriptorSets
                commandBuffer
                Vulkan.VK_PIPELINE_BIND_POINT_COMPUTE
                apVolumeLayout
                0
                1
                dsPtr
                0
                Vulkan.vkNullPtr
            -- Dispatch: 64x32x64 voxels with 4x4x4 local size = 16x8x16 workgroups
            liftIO $ CommandBuffer.cmdDispatch commandBuffer 16 8 16
            -- Barrier: ensure compute writes are visible to fragment shader reads
            let memoryBarrier =
                  Vulkan.createVk
                    ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_MEMORY_BARRIER
                        &* set @"pNext" Vulkan.VK_NULL
                        &* set @"srcAccessMask" Vulkan.VK_ACCESS_SHADER_WRITE_BIT
                        &* set @"dstAccessMask" Vulkan.VK_ACCESS_SHADER_READ_BIT
                    )
            liftIO $ withPtr memoryBarrier $ \bPtr ->
              Vulkan.vkCmdPipelineBarrier
                commandBuffer
                Vulkan.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT
                Vulkan.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT
                Vulkan.VK_ZERO_FLAGS
                1
                bPtr
                0
                Vulkan.vkNullPtr
                0
                Vulkan.vkNullPtr

        -- Dear ImGui overlay pass
        for_ rcImGuiDrawData $ \drawData -> liftIO $ do
          let imGuiFramebuffer = rcImGuiFramebuffers !! fromIntegral imageIdx
          Backend.recordImGuiDrawData commandBuffer rcImGuiRenderPass imGuiFramebuffer rcPassSurfaceExtent drawData
