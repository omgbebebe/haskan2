{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Engine.Render.Internal.PassRecording
  ( CloudParams (..),
    SkyParams (..),
    FrameParams (..),
    FrameRenderResources (..),
    FrameRenderInput (..),
    buildRecordAction,
  )
where

import Control.Concurrent.STM qualified as STM
import Control.Lens ((^.))
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Data.Foldable (for_)
import Data.Maybe (isJust, isNothing)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Data.Vector.Storable qualified as VS
import Data.Word (Word32)
import DearImGui.Raw qualified
import Foreign.C (CFloat)
import Foreign.Storable (Storable (..))
import Graphics.Haskan.Camera (AnyCamera, Camera (..))
import Graphics.Haskan.Camera qualified as Camera
import Graphics.Haskan.Camera.Types (ViewMatrix (..))
import Graphics.Haskan.Engine.Render.Internal.FrameState (FrameState (..))
import Graphics.Haskan.Engine.Types (ComputeCullResources (..), DrawIndexedIndirectCommand (..), extractFrustumPlanes)
import Graphics.Haskan.Logger (LogCategory (..), logInfoIO)
import Graphics.Haskan.Render.Deferred (BindlessPassData (..), CloudPassData (..), DeferredPassData (..), GBufferPassData (..), GodRayPassData (..), LightingPassData (..), buildDeferredGraph)
import Graphics.Haskan.Render.Graph (PassContext (..), PassRecordFunc (..))
import Graphics.Haskan.Render.Graph qualified as Graph
import Graphics.Haskan.Render.RenderSystem (DrawCall (..))
import Graphics.Haskan.Terrain.CDLOD (NodeSelection (..), buildCDLODTree, defaultCDLODConfig, selectVisibleNodes)
import Graphics.Haskan.Terrain.NodeSSBO (packNodesToSSBO)
import Graphics.Haskan.UI.Backend qualified as Backend
import Graphics.Haskan.Vulkan.Buffer qualified as Buffer
import Graphics.Haskan.Vulkan.CommandBuffer qualified as CommandBuffer
import Graphics.Haskan.Vulkan.DeferredResources (DeferredResources (..))
import Graphics.Haskan.Vulkan.DescriptorSet qualified as DescriptorSet
import Graphics.Haskan.Vulkan.MeshPipeline qualified as MeshPipeline
import Graphics.Haskan.Vulkan.RenderPass qualified as RenderPass
import Graphics.Haskan.Vulkan.Types (RenderContext (..))
import Linear (M44, V3 (..), V4 (..), (^*))
import Linear.Matrix ((!*), (!*!))
import Linear.Projection (perspective)
import Linear.V3 (_x, _y, _z)
import Linear.V4 (_w)
import Vulkan qualified as Vk26
import Vulkan.CStruct.Extends (SomeStruct(..))
import Vulkan.Zero (zero)

-- | All values pre-computed before creating the IO callback
-- | Cloud/weather parameters grouped together.
data CloudParams = CloudParams
  { clWindDirX :: !Float,
    clWindDirZ :: !Float,
    clCloudCoverage :: !Float,
    clCloudDetail :: !Float,
    clCloudAbsorption :: !Float,
    clWeatherCoverageScale :: !Float,
    clWeatherTypeBias :: !Float,
    clStormIntensity :: !Float,
    clWeatherAnimSpeed :: !Float
  }

-- | Sky/lighting parameters grouped together.
data SkyParams = SkyParams
  { spSkyTint :: !(V3 Float),
    spIBLIntensity :: !Float,
    spSunAzimuth :: !Float,
    spSunDir :: !(V3 Float)
  }

-- | Per-frame time and matrix parameters.
data FrameParams = FrameParams
  { fpTime :: !Float,
    fpPrevViewProjTVars :: ![STM.TVar (M44 CFloat)],
    fpPrevTimeTVars :: ![STM.TVar Float],
    fpCurrentCloudViewProj :: !(M44 CFloat)
  }

-- | Static resources passed to every frame render.
data FrameRenderResources = FrameRenderResources
  { frrContext :: !RenderContext,
    frrDeferred :: !DeferredResources,
    frrCullResources :: !ComputeCullResources,
    frrFrameDescriptorSets :: ![Vk26.DescriptorSet],
    frrTextureSampler :: !Vk26.Sampler,
    frrLightSsboBuffer :: !Vk26.Buffer
  }

-- | Per-frame varying inputs to buildRecordContext.
data FrameRenderInput = FrameRenderInput
  { friFrameState :: !FrameState,
    friCamera :: !AnyCamera,
    friDrawList :: ![DrawCall],
    friLightCount :: !Word32,
    friSkyboxRays :: !(V3 Float, V3 Float, V3 Float),
    friSkyParams :: !SkyParams,
    friCloudParams :: !CloudParams,
    friFrameParams :: !FrameParams,
    friInvViewProj :: !(M44 Float),
    friViewProj :: !(M44 Float),
    friNearPlane :: !Float,
    friFarPlane :: !Float,
    friSunColor :: !(V3 Float),
    friCloudBase :: !Float,
    friCloudTop :: !Float,
    friDrawData :: !(Maybe DearImGui.Raw.DrawData)
  }

buildRecordAction :: FrameRenderResources -> FrameRenderInput -> Word32 -> Int -> IO ()
buildRecordAction FrameRenderResources {..} FrameRenderInput {..} imageIdx frameIdx = do
  let rcGraphicsCommandBuffers = graphicsCommandBuffers frrContext
      rcFrameDescriptorSets = frrFrameDescriptorSets
      rcTextureSampler = frrTextureSampler
      rcLightSsboBuffer = frrLightSsboBuffer
      rcDrawList = friDrawList
      rcCameraPos = realToFrac <$> Camera.cameraPosition friCamera
      rcSkyboxRays = friSkyboxRays
      rcDebugMode = fsDebugMode friFrameState
      rcAxisOverlay = fsAxisOverlay friFrameState
      rcGroundPlane = fsGroundPlane friFrameState
      rcLightCount = friLightCount
      rcSkyTint = spSkyTint friSkyParams
      rcIBLIntensity = spIBLIntensity friSkyParams
      rcSunDir = spSunDir friSkyParams
      rcCloudHeight = fsCloudHeight friFrameState
      rcTime = fpTime friFrameParams
      rcPrevViewProjTVars = fpPrevViewProjTVars friFrameParams
      rcPrevTimeTVars = fpPrevTimeTVars friFrameParams
      rcCurrentCloudViewProj = fpCurrentCloudViewProj friFrameParams
      rcWindDirX = clWindDirX friCloudParams
      rcWindDirZ = clWindDirZ friCloudParams
      rcCloudCoverage = clCloudCoverage friCloudParams
      rcCloudDetail = clCloudDetail friCloudParams
      rcCloudAbsorption = clCloudAbsorption friCloudParams
      rcWeatherCoverageScale = clWeatherCoverageScale friCloudParams
      rcWeatherTypeBias = clWeatherTypeBias friCloudParams
      rcStormIntensity = clStormIntensity friCloudParams
      rcWeatherAnimSpeed = clWeatherAnimSpeed friCloudParams
      rcWireframeEnabled = fsWireframe friFrameState
      rcDeferred = frrDeferred
      rcCullResources = frrCullResources
      rcDevice = device frrContext
      rcPassSurfaceExtent = rcSurfaceExtent frrContext
      rcImGuiRenderPass = drImGuiRenderPass frrDeferred
      rcImGuiFramebuffers = drImGuiFramebuffers frrDeferred
      rcImGuiDrawData = friDrawData
      rcInvViewProj = friInvViewProj
      rcNearPlane = friNearPlane
      rcFarPlane = friFarPlane
      rcSunColor = friSunColor
      rcCloudBase = friCloudBase
      rcCloudTop = friCloudTop
      viewMat = fmap (fmap realToFrac) (unViewMatrix (Camera.toMatrix friCamera)) :: M44 Float
      Vk26.Extent2D w h = rcPassSurfaceExtent
      width = realToFrac w :: Float
      height = realToFrac h :: Float
      projMat = perspective (pi / 3) (width / height) 1.0 50000.0
      viewProj = projMat !*! viewMat
      sunWorld = rcSunDir ^* 10000.0
      V4 cx cy cz cw = viewProj !* V4 (sunWorld ^. _x) (sunWorld ^. _y) (sunWorld ^. _z) 1.0
      rcSunScreenX = if cw > 0 then cx / cw * 0.5 + 0.5 else (-1.0)
      rcSunScreenY = if cw > 0 then -cy / cw * 0.5 + 0.5 else (-1.0)
      rcSunAzimuth = rcSunScreenX
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
      bindlessDescriptorSet = drBindlessDescriptorSets rcDeferred !! frameIdx
      gBufferPassCtx =
        PassContext
          { pcCommandBuffer = commandBuffer,
            pcPipeline = drGBufferPipeline rcDeferred,
            pcPipelineLayout = drGBufferPipelineLayout rcDeferred,
            pcDescriptorSet = zero,
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

      gbufferDraws = filter (isNothing . dcMaterial) rcDrawList
      bindlessDraws = filter (isJust . dcMaterial) rcDrawList
      (graphRes, graphPasses) =
        Graph.execRenderGraphBuilder $
          buildDeferredGraph
            DeferredPassData
              { dpdExtent = rcPassSurfaceExtent,
                dpdDrawList = gbufferDraws,
                dpdDevice = rcDevice,
                dpdGBuffer =
                  GBufferPassData
                    { gbpRenderPass = drGBufferRenderPass rcDeferred,
                      gbpFramebuffer = gBufferFramebuffer,
                      gbpPipeline = drGBufferPipeline rcDeferred,
                      gbpDoubleSidedPipeline = drGBufferDoubleSidedPipeline rcDeferred,
                      gbpLayout = drGBufferPipelineLayout rcDeferred,
                      gbpDescriptor = frameDescriptorSet,
                      gbpSampler = rcTextureSampler,
                      gbpDrawCommandsBuffer = ccrDrawCommandsBuffer rcCullResources,
                      gbpEntityCount = fromIntegral (length gbufferDraws),
                      gbpGBufferImages = gBufferImagesForFrame,
                      gbpWireframePipeline = drWireframePipeline rcDeferred,
                      gbpWireframeLayout = drWireframePipelineLayout rcDeferred,
                      gbpWireframeEnabled = rcWireframeEnabled
                    },
                dpdBindless =
                  Just
                    BindlessPassData
                      { blpPipeline = drBindlessPipeline rcDeferred,
                        blpLayout = drBindlessPipelineLayout rcDeferred,
                        blpDescriptor = bindlessDescriptorSet,
                        blpRenderPass = drBindlessRenderPass rcDeferred,
                        blpFramebuffer = gBufferFramebuffer,
                        blpDrawList = bindlessDraws,
                        blpTextureArrayView = Nothing,
                        blpSampler = rcTextureSampler
                      },
                dpdCloud =
                  CloudPassData
                    { cpRenderPass = drCloudRenderPass rcDeferred,
                      cpFramebuffer = cloudFramebuffer,
                      cpPipeline = drCloudPipeline rcDeferred,
                      cpLayout = drCloudPipelineLayout rcDeferred,
                      cpDescriptor = cloudDescriptorSet,
                      cpExtent = drCloudExtent rcDeferred,
                      cpImage = cloudImage,
                      cpHistoryImage = cloudHistoryImage,
                      cpFrameDataMemory = drCloudFrameDataMemory rcDeferred,
                      cpCameraPos = rcCameraPos,
                      cpSkyboxRays = rcSkyboxRays,
                      cpSunDir = rcSunDir,
                      cpCloudHeight = rcCloudHeight,
                      cpTime = rcTime,
                      cpBlendFactor = 0.3,
                      cpWindDirX = rcWindDirX,
                      cpWindDirZ = rcWindDirZ,
                      cpPrevTime = prevTimeVal,
                      cpCloudCoverage = rcCloudCoverage,
                      cpCloudDetail = rcCloudDetail,
                      cpCloudAbsorption = rcCloudAbsorption,
                      cpWeatherCoverageScale = rcWeatherCoverageScale,
                      cpWeatherTypeBias = rcWeatherTypeBias,
                      cpStormIntensity = rcStormIntensity,
                      cpWeatherAnimSpeed = rcWeatherAnimSpeed,
                      cpFrameIndex = frameIdx,
                      cpDebugMode = rcDebugMode,
                      cpPrevViewProj = prevViewProjF
                    },
                dpdGodRay =
                  GodRayPassData
                    { grpRenderPass = drGodRayRenderPass rcDeferred,
                      grpFramebuffer = drGodRayFramebuffers rcDeferred !! fromIntegral imageIdx,
                      grpPipeline = drGodRayPipeline rcDeferred,
                      grpLayout = drGodRayPipelineLayout rcDeferred,
                      grpDescriptor = drGodRayDescriptorSets rcDeferred !! fromIntegral imageIdx,
                      grpExtent = drCloudExtent rcDeferred,
                      grpSunScreenX = rcSunScreenX,
                      grpSunScreenY = rcSunScreenY
                    },
                dpdLighting =
                  LightingPassData
                    { lpRenderPass = drLightingRenderPass rcDeferred,
                      lpFramebuffer = lightingFramebuffer,
                      lpPipeline = drLightingPipeline rcDeferred,
                      lpLayout = drLightingPipelineLayout rcDeferred,
                      lpDescriptor = lightingDescriptorSet,
                      lpCameraPos = rcCameraPos,
                      lpSkyboxRays = rcSkyboxRays,
                      lpSkyTint = rcSkyTint,
                      lpIBLIntensity = rcIBLIntensity,
                      lpSunAzimuth = rcSunAzimuth,
                      lpSunScreenX = rcSunScreenX,
                      lpSunScreenY = rcSunScreenY,
                      lpSunDir = rcSunDir,
                      lpCloudHeight = rcCloudHeight,
                      lpTime = rcTime,
                      lpDebugMode = rcDebugMode,
                      lpAxisOverlay = rcAxisOverlay,
                      lpGroundPlane = rcGroundPlane,
                      lpLightCount = rcLightCount,
                      lpLightBuffer = rcLightSsboBuffer
                    }
              }
  case Graph.compileGraph graphRes graphPasses of
    Left err -> logInfoIO LogRender $ "graph compilation failed: " <> Text.pack (show err)
    Right compiled -> do
      CommandBuffer.withCommandBuffer commandBuffer $ do
        let numWorkgroups = (length rcDrawList + 63) `div` 64
        when (numWorkgroups > 0) $ do
          liftIO $ Vk26.cmdBindPipeline commandBuffer Vk26.PIPELINE_BIND_POINT_COMPUTE (ccrPipeline rcCullResources)
          liftIO $ Vk26.cmdBindDescriptorSets
            commandBuffer
            Vk26.PIPELINE_BIND_POINT_COMPUTE
            (ccrPipelineLayout rcCullResources)
            0
            (Vector.fromList [ccrDescriptorSet rcCullResources])
            (Vector.empty)
          liftIO $ CommandBuffer.cmdDispatch commandBuffer (fromIntegral numWorkgroups) 1 1
          liftIO $
            CommandBuffer.cmdBufferBarrier
              commandBuffer
              (ccrDrawCommandsBuffer rcCullResources)
              (fromIntegral (ccrMaxEntities rcCullResources * sizeOf (undefined :: DrawIndexedIndirectCommand)))
              Vk26.PIPELINE_STAGE_COMPUTE_SHADER_BIT
              Vk26.ACCESS_SHADER_WRITE_BIT
              Vk26.PIPELINE_STAGE_DRAW_INDIRECT_BIT
              Vk26.ACCESS_INDIRECT_COMMAND_READ_BIT

        let passes = Graph.cgPasses compiled
        for_ passes $ \cp -> do
          let pass = Graph.cpPass cp
              recordFn = unPassRecordFunc (Graph.rpRecord pass)
              passCtx = case Graph.rpName pass of
                "gbuffer" -> gBufferPassCtx
                "bindless" -> gBufferPassCtx
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
                  [ realToFrac camX,
                    realToFrac camY,
                    realToFrac camZ,
                    0,
                    realToFrac r0x,
                    realToFrac r0y,
                    realToFrac r0z,
                    realToFrac r0w,
                    realToFrac r1x,
                    realToFrac r1y,
                    realToFrac r1z,
                    realToFrac r1w,
                    realToFrac r2x,
                    realToFrac r2y,
                    realToFrac r2z,
                    realToFrac r2w,
                    realToFrac r3x,
                    realToFrac r3y,
                    realToFrac r3z,
                    realToFrac r3w,
                    realToFrac sunDirX,
                    realToFrac sunDirY,
                    realToFrac sunDirZ,
                    0,
                    realToFrac sunColorR,
                    realToFrac sunColorG,
                    realToFrac sunColorB,
                    0,
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
                    0,
                    0 -- pad to 256 bytes
                  ] ::
                    [CFloat]
            liftIO $ Buffer.copyDataToDeviceMemory rcDevice (drAPVolumeUniformMemory rcDeferred) apVolumeData
            let apVolumePipeline = drAPVolumePipeline rcDeferred
                apVolumeLayout = drAPVolumePipelineLayout rcDeferred
                apVolumeDescriptorSet = drAPVolumeDescriptorSets rcDeferred !! fromIntegral imageIdx
            liftIO $ Vk26.cmdBindPipeline commandBuffer Vk26.PIPELINE_BIND_POINT_COMPUTE apVolumePipeline
            liftIO $ Vk26.cmdBindDescriptorSets
              commandBuffer
              Vk26.PIPELINE_BIND_POINT_COMPUTE
              apVolumeLayout
              0
              (Vector.fromList [apVolumeDescriptorSet])
              (Vector.empty)
            -- Dispatch: 64x32x64 voxels with 4x4x4 local size = 16x8x16 workgroups
            liftIO $ CommandBuffer.cmdDispatch commandBuffer 16 8 16
            -- Barrier: ensure compute writes are visible to fragment shader reads
            liftIO $ Vk26.cmdPipelineBarrier
              commandBuffer
              Vk26.PIPELINE_STAGE_COMPUTE_SHADER_BIT
              Vk26.PIPELINE_STAGE_FRAGMENT_SHADER_BIT
              zero
              (Vector.fromList [Vk26.MemoryBarrier Vk26.ACCESS_SHADER_WRITE_BIT Vk26.ACCESS_SHADER_READ_BIT])
              Vector.empty
              Vector.empty

        -- Terrain pass (mesh terrain or legacy overlay)
        let terrainFramebuffer = drTerrainFramebuffers rcDeferred !! fromIntegral imageIdx
            terrainRenderPass = drTerrainRenderPass rcDeferred
            swapchainImage = drSwapchainImages rcDeferred !! fromIntegral imageIdx
        -- Transition swapchain image from PRESENT_SRC_KHR to COLOR_ATTACHMENT_OPTIMAL
        let imageBarrier =
              Vk26.ImageMemoryBarrier
                ()
                Vk26.ACCESS_COLOR_ATTACHMENT_WRITE_BIT
                Vk26.ACCESS_COLOR_ATTACHMENT_WRITE_BIT
                Vk26.IMAGE_LAYOUT_PRESENT_SRC_KHR
                Vk26.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
                Vk26.QUEUE_FAMILY_IGNORED
                Vk26.QUEUE_FAMILY_IGNORED
                swapchainImage
                (Vk26.ImageSubresourceRange Vk26.IMAGE_ASPECT_COLOR_BIT 0 1 0 1)
        liftIO $ Vk26.cmdPipelineBarrier
          commandBuffer
          Vk26.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
          Vk26.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
          zero
          Vector.empty
          Vector.empty
          (Vector.fromList [SomeStruct imageBarrier])

        -- Mesh terrain pass (when enabled)
        let terrainMeshDescriptorSet = drTerrainMeshDescriptorSets rcDeferred !! fromIntegral imageIdx
            terrainMeshPipeline = drTerrainMeshPipeline rcDeferred
            terrainMeshPipelineLayout = drTerrainMeshPipelineLayout rcDeferred
            cdlodTree = buildCDLODTree defaultCDLODConfig
            frustumPlanes = extractFrustumPlanes friViewProj
            visibleNodes = selectVisibleNodes cdlodTree rcCameraPos frustumPlanes
            nodeList = nsNodes visibleNodes
            nodeCount = length nodeList
        when (nodeCount > 0) $ do
          let nodeGPUData = packNodesToSSBO nodeList
          liftIO $ Buffer.copyDataToDeviceMemory rcDevice (drTerrainMeshNodeMemory rcDeferred) (VS.toList nodeGPUData)
          liftIO $ RenderPass.withRenderPass commandBuffer terrainRenderPass terrainFramebuffer rcPassSurfaceExtent [] $ do
            liftIO $ Vk26.cmdBindPipeline commandBuffer Vk26.PIPELINE_BIND_POINT_GRAPHICS terrainMeshPipeline
            liftIO $ Vk26.cmdBindDescriptorSets
              commandBuffer
              Vk26.PIPELINE_BIND_POINT_GRAPHICS
              terrainMeshPipelineLayout
              0
              (Vector.fromList [terrainMeshDescriptorSet])
              (Vector.empty)
            MeshPipeline.cmdDrawMeshTasksEXT rcDevice commandBuffer (fromIntegral nodeCount) 1 1

        -- Dear ImGui overlay pass
        for_ rcImGuiDrawData $ \drawData -> liftIO $ do
          let imGuiFramebuffer = rcImGuiFramebuffers !! fromIntegral imageIdx
          Backend.recordImGuiDrawData commandBuffer rcImGuiRenderPass imGuiFramebuffer rcPassSurfaceExtent drawData
