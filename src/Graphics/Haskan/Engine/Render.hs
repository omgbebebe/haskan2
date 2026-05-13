{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Engine.Render
  ( renderFrameLoop,
    renderLoop,
  )
where

import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (STM)
import Control.Concurrent.STM qualified as STM
import Control.Concurrent.STM.TChan (TChan)
import Control.Concurrent.STM.TChan qualified as TChan
import Control.Concurrent.STM.TQueue (TQueue)
import Control.Concurrent.STM.TQueue qualified as TQueue
import Control.Concurrent.STM.TVar (TVar)
import Control.Exception (SomeException, try)
import Control.Lens ((^.))
import Control.Monad (forM, forM_, replicateM, unless, when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged, runManaged, with)
import Data.Foldable (for_, toList)
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HashMap
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Int (Int32)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector.Storable qualified as Vector
import Data.Word (Word32, Word64, Word8)
import FIR qualified
import Foreign.C qualified
import Foreign.Marshal.Array qualified
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (Storable (..), peekByteOff, pokeByteOff)
import GHC.Generics
import Graphics.Haskan.Assets.Cache (initCache)
import Graphics.Haskan.BoundingBox (BBox (..), bboxCenter, bboxDiagonal, emptyBBox, fromPoints, mergeBBox, mergePoint)
import Graphics.Haskan.Camera (AnyCamera, Camera (..))
import Graphics.Haskan.Camera qualified as Camera
import Graphics.Haskan.DayNight (computeSunState, defaultDayNightConfig)
import Graphics.Haskan.DayNight qualified as DayNight
import Graphics.Haskan.Debug.FrameInspector (FrameInspector, RenderableSnapshot (..), buildFrameSnapshot, defaultInspector)
import Graphics.Haskan.Debug.Interface (DebugCameraSnapshot (..), DebugCommand (..), DebugMessage (..), DebugResponse (..), GameStateSnapshot (..), debugMessageToActionEvent, encodeDebugResponse, parseDebugMessage)
import Graphics.Haskan.Debug.Screenshot qualified as Screenshot
import Graphics.Haskan.Engine.Render.Internal.Screenshot
  ( handleScreenshotAllStages,
    handleScreenshotSingle,
    handleScreenshotSwapchain,
  )
import Graphics.Haskan.Debug.Server (CommandQueue, DebugServerHandle, startDebugServer, stopDebugServer)
import Graphics.Haskan.Engine.Render.Internal.FramePrepare
  ( buildAllEntityData,
    buildCullData,
    buildRenderDebugInfo,
    computeEntityDebugInfos,
    computeSkyParams,
    surfaceExtentWH,
  )
import Graphics.Haskan.Engine.Render.Internal.FrameState
  ( FrameState (..),
    readFrameState,
  )
import Graphics.Haskan.Engine.Render.Internal.PassRecording
  ( RecordContext (..),
    buildRecordAction,
    buildRecordContext,
  )
import Graphics.Haskan.Engine.Scene (adjustCameraForScene, computeMeshBounds, computeSceneBounds, computeSkyboxRays, computeWorldSpaceBounds, drawCallToSnapshot, makeProjectionMatrix)
import Graphics.Haskan.Engine.Types (ComputeCullData (..), ComputeCullResources (..), ComputeEntityData (..), ControlMessage (..), DrawIndexedIndirectCommand (..), EngineConfig (..), EntityDebugInfo (..), FrameStats (..), FrameTime (..), GameState (..), InputBuffer (..), LightData (..), RenderDebugInfo (..), WorldState (..), emptyFrameStats, extractFrustumPlanes, filterVisible, flushInputBuffer, forkIOWithHandler, newInputBuffer, toListOfV4, transformAABB, updateFrameStats, writeInputBuffer)
import Graphics.Haskan.Input (Action (..), ActionEvent, payloadToActionEvent)
import Graphics.Haskan.Engine.Capabilities.Graphics (MonadGraphics (..))
import Graphics.Haskan.Engine.Capabilities.Clock (MonadClock (..))
import Graphics.Haskan.Engine.Capabilities.Log (MonadLog (..), logDebug, logInfo)
import Graphics.Haskan.Engine.Capabilities.StateReader (MonadStateReader (..), consumeTVar, readTVarIO)
import Graphics.Haskan.Engine.Capabilities.Telemetry (MonadTelemetry (..))
import Graphics.Haskan.Logger (LogCategory (..), logInfoIO, showT)
import Graphics.Haskan.Mesh qualified as Mesh
import Graphics.Haskan.Model qualified as Model
import Graphics.Haskan.Render.Deferred (DeferredPassData (..), buildDeferredGraph)
import Graphics.Haskan.Render.Forward (ForwardPassData (..), buildForwardGraph)
import Graphics.Haskan.Render.Graph (PassContext (..), PassRecordFunc (..), RenderPassNode (..))
import Graphics.Haskan.Render.Graph qualified as Graph
import Graphics.Haskan.Render.RenderSystem (DrawCall (..), extractDrawList)
import Graphics.Haskan.Resources (allocaAndPeek, throwVkResult)
import Graphics.Haskan.Scene.ECS qualified as ECS
import Graphics.Haskan.Scene.GLTF (GLTFImportResult (..), importGLTF)
import Graphics.Haskan.Scene.Transform (Transform (..), defaultTransform, tPosition)
import Graphics.Haskan.Scene.Transform qualified as Transform
import Graphics.Haskan.Utils.ObjLoader qualified as ObjLoader
import Graphics.Haskan.Vertex (Vertex (..))
import Graphics.Haskan.Vulkan.BRDF qualified as BRDF
import Graphics.Haskan.Vulkan.Buffer qualified as Buffer
import Graphics.Haskan.Vulkan.CommandBuffer qualified as CommandBuffer
import Graphics.Haskan.Vulkan.CommandPool qualified as CommandPool
import Graphics.Haskan.Vulkan.ComputePipeline qualified as ComputePipeline
import Graphics.Haskan.Vulkan.DeferredResources (DeferredResources (..), createDeferredResources)
import Graphics.Haskan.Vulkan.DescriptorPool qualified as DescriptorPool
import Graphics.Haskan.Vulkan.DescriptorSet qualified as DescriptorSet
import Graphics.Haskan.Vulkan.DescriptorSetLayout qualified as DescriptorSetLayout
import Graphics.Haskan.Vulkan.Device qualified as Device
import Graphics.Haskan.Vulkan.DeviceCapabilities (DeviceCapabilities (..), queryDeviceCapabilities)
import Graphics.Haskan.Vulkan.Fence qualified as Fence
import Graphics.Haskan.Vulkan.GraphicsPipeline qualified as GraphicsPipeline
import Graphics.Haskan.Vulkan.Instance qualified as Instance
import Graphics.Haskan.Vulkan.PhysicalDevice qualified as PhysicalDevice
import Graphics.Haskan.Vulkan.PipelineLayout qualified as PipelineLayout
import Graphics.Haskan.Vulkan.Render (drawFrame, presentFrame, runRenderM)
import Graphics.Haskan.Vulkan.Render qualified as Render
import Graphics.Haskan.Vulkan.RenderPass qualified as RenderPass
import Graphics.Haskan.Vulkan.Resources
import Graphics.Haskan.Vulkan.Semaphore qualified as Semaphore
import Graphics.Haskan.Vulkan.ShaderModule qualified as ShaderModule
import Graphics.Haskan.Vulkan.Shaders.Compute.Cull qualified as CullShaders
import Graphics.Haskan.Vulkan.Shaders.Deferred.GBuffer qualified as GBufferShaders
import Graphics.Haskan.Vulkan.Shaders.Deferred.Lighting qualified as LightingShaders
import Graphics.Haskan.Vulkan.Shaders.Texture qualified as Shaders
import Graphics.Haskan.Vulkan.Shaders.Wireframe qualified as WireframeShaders
import Graphics.Haskan.Vulkan.Texture qualified as Texture
import Graphics.Haskan.Vulkan.Types (RenderContext (..))
import Graphics.Haskan.Window qualified as Window
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Ext qualified as Vulkan
import Graphics.Vulkan.Marshal.Create qualified as Vulkan
import Linear (M44, V2 (..), V3 (..), V4 (..), normalize, (*^), (^+^), (^-^))
import Linear.Matrix (identity, inv33, inv44, transpose, (!*), (!*!))
import Linear.Projection qualified
import Linear.Quaternion (Quaternion (..))
import Linear.V3 (_x, _y, _z)
import Linear.V4 (_w)
import SDL qualified
import SDL.Input.Mouse qualified as SDL.Mouse
import System.Clock (TimeSpec, toNanoSecs)
import System.Directory (doesFileExist)
import System.IO.Unsafe (unsafePerformIO)
import Control.Monad.Reader (MonadReader, ReaderT, ask, asks, runReaderT)

type RenderLoopM m = ReaderT RenderEnv m

data RenderEnv = RenderEnv
  { reContext :: !RenderContext,
    reDeferred :: !DeferredResources,
    reTargetFPS :: !Integer,
    reImageAvailableSemaphores :: ![Vulkan.VkSemaphore],
    reControl :: !(TChan ControlMessage),
    reFrameMvpMemories :: ![Vulkan.VkDeviceMemory],
    reTvCamera :: !(TVar AnyCamera),
    reTvInspect :: !(STM.TVar Bool),
    reTvInsp :: !(STM.TVar (Maybe FrameInspector)),
    reTvRenderDebug :: !(STM.TVar (Maybe RenderDebugInfo)),
    reECSWorld :: !ECS.World,
    reResourceManager :: !ResourceManager,
    reTextureSampler :: !Vulkan.VkSampler,
    reFrameDescriptorSets :: ![Vulkan.VkDescriptorSet],
    reTextureIndexMap :: !(IntMap Word32),
    reTvWireframe :: !(STM.TVar Bool),
    reFrameStatsRef :: !(IORef FrameStats),
    reCullResources :: !ComputeCullResources,
    reTvDebugMode :: !(STM.TVar Word32),
    reTvAxisOverlay :: !(STM.TVar Float),
    reTvGroundPlane :: !(STM.TVar Float),
    reTvPendingScreenshot :: !(STM.TVar Bool),
    reTvPendingAllStages :: !(STM.TVar Bool),
    reTvPendingSwapchainScreenshot :: !(STM.TVar Bool),
    rePhysicalDevice :: !Vulkan.VkPhysicalDevice,
    reLightSsboBuffer :: !Vulkan.VkBuffer,
    reLightSsboMemory :: !Vulkan.VkDeviceMemory,
    reTvLights :: !(STM.TVar [LightData]),
    reTvTimeOfDay :: !(STM.TVar Float),
    reTvTimeSpeed :: !(STM.TVar Float),
    reTvDayNightEnabled :: !(STM.TVar Bool),
    reTvCloudHeight :: !(STM.TVar Float)
  }

instance (MonadIO m) => MonadTelemetry (ReaderT RenderEnv m) where
  recordFrameTime rt = do
    ref <- asks reFrameStatsRef
    liftIO $ do
      stats <- readIORef ref
      let (newStats, _) = updateFrameStats stats rt
      writeIORef ref newStats
  getTelemetryMessage = do
    ref <- asks reFrameStatsRef
    liftIO $ do
      stats <- readIORef ref
      let (_, mMsg) = updateFrameStats stats 0
      pure mMsg

instance (MonadIO m) => MonadStateReader (ReaderT RenderEnv m) where
  readCamera = asks reTvCamera >>= readTVarIO
  readControl = asks reControl >>= liftIO . STM.atomically . TChan.tryReadTChan
  readWireframe = asks reTvWireframe >>= readTVarIO
  readDebugMode = asks reTvDebugMode >>= readTVarIO
  readAxisOverlay = asks reTvAxisOverlay >>= readTVarIO
  readGroundPlane = asks reTvGroundPlane >>= readTVarIO
  readTimeOfDay = asks reTvTimeOfDay >>= readTVarIO
  readDayNightEnabled = asks reTvDayNightEnabled >>= readTVarIO
  readCloudHeight = asks reTvCloudHeight >>= readTVarIO
  readInspector = asks reTvInsp >>= readTVarIO
  readLights = asks reTvLights >>= readTVarIO
  consumeInspectFlag = asks reTvInspect >>= consumeTVar
  consumeScreenshotFlag = asks reTvPendingScreenshot >>= consumeTVar
  consumeAllStagesFlag = asks reTvPendingAllStages >>= consumeTVar
  consumeSwapchainScreenshotFlag = asks reTvPendingSwapchainScreenshot >>= consumeTVar

instance (MonadIO m) => MonadGraphics (ReaderT RenderEnv m) where
  uploadStorageBuffer mem offset dat = do
    device <- asks (device . reContext)
    liftIO $ Buffer.updateStorageBuffer device mem offset dat
  uploadUniformBuffer mem offset dat = do
    device <- asks (device . reContext)
    liftIO $ Buffer.updateUniformBufferRegion device mem offset dat
  deviceWaitIdle = do
    device <- asks (device . reContext)
    liftIO $ Vulkan.vkDeviceWaitIdle device >>= throwVkResult
  drawFrameGraphics sem idx action = do
    ctx <- asks reContext
    liftIO $ Render.runRenderM ctx $ Render.drawFrame sem idx action
  presentFrameGraphics idx sem = do
    ctx <- asks reContext
    liftIO $ Render.runRenderM ctx $ Render.presentFrame idx sem

-- | Handle frame inspector snapshot capture
handleInspector ::
  (MonadClock m, MonadIO m, MonadStateReader m) =>
  Int ->
  [DrawCall] ->
  RenderContext ->
  AnyCamera ->
  Vulkan.VkExtent2D ->
  m ()
handleInspector frameNumber drawList ctx camera rcSurfaceExtent = do
  mInsp <- readInspector
  for_ mInsp $ \insp -> do
    startTime <- getMonotonicTime
    let snapshots = map drawCallToSnapshot drawList
        (w, h) = surfaceExtentWH rcSurfaceExtent
    snap <- buildFrameSnapshot (fromIntegral frameNumber) startTime ctx camera ((realToFrac <$>) <$> makeProjectionMatrix w h) snapshots
    liftIO $ insp snap

-- | Handle termination control message
terminateFrame :: MonadLog m => m (Bool, Bool)
terminateFrame = do
  logInfo LogGeneral "terminating render loop by signal"
  pure (True, True)

-- | Main frame body: read state, compute, upload, render
runFrame ::
  (MonadFail m, MonadIO m, MonadLog m, MonadClock m, MonadTelemetry m, MonadStateReader m, MonadGraphics m) =>
  Int ->
  RenderLoopM m (Bool, Bool)
runFrame frameNumber = do
  env@RenderEnv {..} <- ask
  let imageAvailableSemaphore = reImageAvailableSemaphores !! frameNumber
      mvpMemory = reFrameMvpMemories !! frameNumber
  camera <- readCamera
  drawList <- extractDrawList reECSWorld reResourceManager reTextureIndexMap
  logDebug LogRender $ "draw list: " <> showT (length drawList) <> " entities"
  let camPos = realToFrac <$> Camera.cameraPosition camera
      camTarget = realToFrac <$> Camera.cameraTarget camera
      (w, h) = surfaceExtentWH (rcSurfaceExtent reContext)
      projMat = Linear.Matrix.transpose $ (realToFrac <$>) <$> makeProjectionMatrix w h :: M44 Float
      viewMat = Linear.Matrix.transpose $ (realToFrac <$>) <$> Camera.unViewMatrix (Camera.toMatrix camera) :: M44 Float
      entityDebugInfos = computeEntityDebugInfos drawList projMat viewMat
      renderDebugInfo = buildRenderDebugInfo frameNumber camPos camTarget projMat entityDebugInfos
  liftIO $ STM.atomically $ STM.writeTVar reTvRenderDebug $ Just renderDebugInfo
  let entityData = buildAllEntityData drawList
      cullData = buildCullData w h camera drawList
  uploadStorageBuffer (ccrEntityMemory reCullResources) 0 entityData
  uploadUniformBuffer (ccrCullDataMemory reCullResources) 0 [cullData]
  logDebug LogRender $ "compute culling data uploaded: " <> showT (length entityData) <> " entities"

  lights' <- readLights
  let lightsToUpload = take 256 lights' ++ replicate (256 - length lights') (LightData (V3 0 0 0) 0.0 (V3 0 0 0) 0 (V3 0 0 0) 0.0)
  uploadStorageBuffer reLightSsboMemory 0 lightsToUpload
  let lightCount = fromIntegral (length lights') :: Word32
  logDebug LogRender $ "lights uploaded: " <> showT (length lights')
  case drawList of
    [] -> pure (False, False)
    _ -> renderAndPresent env frameNumber camera drawList lightCount mvpMemory imageAvailableSemaphore

-- | Render and present a non-empty frame
renderAndPresent ::
  (MonadFail m, MonadIO m, MonadLog m, MonadClock m, MonadTelemetry m, MonadStateReader m, MonadGraphics m) =>
  RenderEnv ->
  Int ->
  AnyCamera ->
  [DrawCall] ->
  Word32 ->
  Vulkan.VkDeviceMemory ->
  Vulkan.VkSemaphore ->
  RenderLoopM m (Bool, Bool)
renderAndPresent env@RenderEnv {..} frameNumber camera drawList lightCount mvpMemory imageAvailableSemaphore = do
  let ctx = reContext
      dr = reDeferred
      ccr = reCullResources
      (w, h) = surfaceExtentWH (rcSurfaceExtent ctx)
      view = Linear.Matrix.transpose $ Camera.unViewMatrix (Camera.toMatrix camera)
      projection = Linear.Matrix.transpose $ makeProjectionMatrix w h
      skyboxRays = computeSkyboxRays ((realToFrac <$>) <$> view) ((realToFrac <$>) <$> projection)
  uploadUniformBuffer mvpMemory 0 [view, projection]

  frameState <- readFrameState
  let (sunState, skyTint, iblInt, sunAzimuth, sunDir) = computeSkyParams (fsDayNightEnabled frameState) (fsTimeOfDay frameState)

  let recordCtx = buildRecordContext ctx dr ccr reFrameDescriptorSets reTextureSampler reLightSsboBuffer frameState camera drawList lightCount skyboxRays skyTint iblInt sunAzimuth sunDir
      recordAction = buildRecordAction recordCtx

  res <- drawFrameGraphics imageAvailableSemaphore frameNumber recordAction
  handleFrameResult env frameNumber camera drawList res

-- | Handle frame draw result
handleFrameResult ::
  (MonadFail m, MonadIO m, MonadLog m, MonadClock m, MonadTelemetry m, MonadStateReader m, MonadGraphics m) =>
  RenderEnv ->
  Int ->
  AnyCamera ->
  [DrawCall] ->
  Render.RenderResult ->
  RenderLoopM m (Bool, Bool)
handleFrameResult env@RenderEnv {reContext = ctx, ..} frameNumber camera drawList = \case
  Render.FrameOk imageIndex -> do
    presentResult <- presentFrameGraphics imageIndex (renderFinishedSemaphores ctx !! fromIntegral imageIndex)
    handlePresentResult env frameNumber camera drawList imageIndex presentResult
  Render.FrameSuboptimal _ ->
    fail "suboptimal"
  Render.FrameOutOfDate -> do
    logInfo LogGeneral "resizing swapchain"
    pure (True, False)
  Render.FrameTimeout -> do
    delayMicros 16000
    pure (False, False)
  Render.FrameFailed err ->
    fail err

-- | Handle present result
handlePresentResult ::
  (MonadFail m, MonadIO m, MonadLog m, MonadClock m, MonadTelemetry m, MonadStateReader m, MonadGraphics m) =>
  RenderEnv ->
  Int ->
  AnyCamera ->
  [DrawCall] ->
  Vulkan.Word32 ->
  Vulkan.VkResult ->
  RenderLoopM m (Bool, Bool)
handlePresentResult env@RenderEnv {..} frameNumber camera drawList imageIndex = \case
  Vulkan.VK_SUCCESS -> do
    shouldInspect <- consumeInspectFlag
    when shouldInspect $ do
      handleInspector frameNumber drawList reContext camera (rcSurfaceExtent reContext)
    shouldScreenshot <- consumeScreenshotFlag
    shouldAllStages <- consumeAllStagesFlag
    shouldSwapchain <- consumeSwapchainScreenshotFlag
    when shouldScreenshot $ do
      handleScreenshotSingle reDeferred (device reContext) rePhysicalDevice (rcGraphicsCommandPool reContext) (graphicsQueueHandler reContext) (rcSurfaceExtent reContext) imageIndex
    when shouldAllStages $ do
      handleScreenshotAllStages reDeferred (device reContext) rePhysicalDevice (rcGraphicsCommandPool reContext) (graphicsQueueHandler reContext) (rcSurfaceExtent reContext) imageIndex
    when shouldSwapchain $ do
      handleScreenshotSwapchain reContext (device reContext) rePhysicalDevice (rcGraphicsCommandPool reContext) (graphicsQueueHandler reContext) (rcSurfaceExtent reContext) imageIndex
    pure (False, False)
  Vulkan.VK_SUBOPTIMAL_KHR ->
    pure (True, False)
  Vulkan.VK_ERROR_OUT_OF_DATE_KHR ->
    pure (True, False)
  _ ->
    fail "presentFrame failed"

-- | Handle frame timing and loop continuation
handleFrameTiming ::
  (MonadFail m, MonadIO m, MonadLog m, MonadClock m, MonadTelemetry m, MonadGraphics m, MonadStateReader m) =>
  TimeSpec ->
  Bool ->
  Bool ->
  Integer ->
  Int ->
  RenderLoopM m Bool
handleFrameTiming frameStartTime needRestart terminating targetFPS frameNumber
  | needRestart = do
      deviceWaitIdle
      logInfo LogGeneral "waiting IDLE state for device"
      logInfo LogGeneral "terminating renderFrameLoop"
      pure terminating
  | otherwise = do
      frameEndTime <- getMonotonicTime
      let renderTime = toNanoSecs frameEndTime - toNanoSecs frameStartTime
          delay = ((1000000000 `div` targetFPS) - renderTime) `div` 1000
      recordFrameTime renderTime
      mMsg <- getTelemetryMessage
      for_ mMsg $ logInfo LogRender
      delayMicros (fromIntegral delay)
      renderFrameLoop' ((frameNumber + 1) `mod` Render.maxFramesInFlight)

renderFrameLoop ::
  (MonadFail m, MonadIO m, MonadLog m, MonadClock m, MonadTelemetry m, MonadStateReader m, MonadGraphics m) =>
  RenderEnv ->
  Int ->
  m Bool
renderFrameLoop env frameNumber = runReaderT (renderFrameLoop' frameNumber) env

renderFrameLoop' ::
  (MonadFail m, MonadIO m, MonadLog m, MonadClock m, MonadTelemetry m, MonadStateReader m, MonadGraphics m) =>
  Int ->
  RenderLoopM m Bool
renderFrameLoop' frameNumber = do
  env@RenderEnv {reTargetFPS = targetFPS} <- ask
  frameStartTime <- getMonotonicTime
  maybeControlMessage <- readControl

  (needRestart, terminating) <- case maybeControlMessage of
    Just Terminate -> terminateFrame
    Nothing -> runFrame frameNumber

  handleFrameTiming frameStartTime needRestart terminating targetFPS frameNumber

renderLoop ::
  (MonadFail m, MonadManaged m, MonadIO m, MonadLog m, MonadClock m, MonadTelemetry m, MonadStateReader m, MonadGraphics m) =>
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkSurfaceKHR ->
  [String] ->
  Integer ->
  GameState AnyCamera ->
  MVar () ->
  MVar () ->
  TChan ControlMessage ->
  String ->
  Maybe String ->
  String ->
  m ()
renderLoop physicalDevice surface layers targetFPS gameState finishedSemaphore readySemaphore controlChannel meshName uvCheckMode envMapDir = do
  control <- liftIO $ STM.atomically $ TChan.dupTChan controlChannel

  rm <- newResourceManager

  (device, (graphicsQueueFamilyIndex, presentQueueFamilyIndex)) <- Device.managedRenderDevice physicalDevice surface layers

  graphicsQueueHandler <- Device.getDeviceQueueHandler device graphicsQueueFamilyIndex 0
  presentQueueHandler <- Device.getDeviceQueueHandler device presentQueueFamilyIndex 0

  logInfo LogGeneral "compiling shaders..."
  liftIO $ FIR.compileTo "data/shaders/fir/vert.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] Shaders.vertex
  logInfo LogGeneral "  vert.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/frag.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] Shaders.fragment
  logInfo LogGeneral "  frag.spv done"

  liftIO $ FIR.compileTo "data/shaders/fir/gbuf_vert.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] GBufferShaders.vertex
  logInfo LogGeneral "  gbuf_vert.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/gbuf_frag.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] GBufferShaders.fragment
  logInfo LogGeneral "  gbuf_frag.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/light_vert.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] LightingShaders.vertex
  logInfo LogGeneral "  light_vert.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/light_frag.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] LightingShaders.fragment
  logInfo LogGeneral "  light_frag.spv done"

  liftIO $ FIR.compileTo "data/shaders/fir/wire_vert.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] WireframeShaders.vertex
  logInfo LogGeneral "  wire_vert.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/wire_geom.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] WireframeShaders.geometry
  logInfo LogGeneral "  wire_geom.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/wire_frag.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] WireframeShaders.fragment
  logInfo LogGeneral "  wire_frag.spv done"

  liftIO $ FIR.compileTo "data/shaders/fir/cull_comp.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] CullShaders.program
  logInfo LogGeneral "  cull_comp.spv done"

  vertShader <- ShaderModule.managedShaderModule device "data/shaders/fir/vert.spv"
  fragShader <- ShaderModule.managedShaderModule device "data/shaders/fir/frag.spv"

  gbufVertShader <- ShaderModule.managedShaderModule device "data/shaders/fir/gbuf_vert.spv"
  gbufFragShader <- ShaderModule.managedShaderModule device "data/shaders/fir/gbuf_frag.spv"
  lightVertShader <- ShaderModule.managedShaderModule device "data/shaders/fir/light_vert.spv"
  lightFragShader <- ShaderModule.managedShaderModule device "data/shaders/fir/light_frag.spv"

  wireVertShader <- ShaderModule.managedShaderModule device "data/shaders/fir/wire_vert.spv"
  wireGeomShader <- ShaderModule.managedShaderModule device "data/shaders/fir/wire_geom.spv"
  wireFragShader <- ShaderModule.managedShaderModule device "data/shaders/fir/wire_frag.spv"

  cullShader <- ShaderModule.managedShaderModule device "data/shaders/fir/cull_comp.spv"

  descriptorSetLayout <- DescriptorSetLayout.managedDescriptorSetLayout device
  pipelineLayout <- PipelineLayout.managedPipelineLayout device [descriptorSetLayout]
  graphicsCommandPool <- CommandPool.managedCommandPool device graphicsQueueFamilyIndex

  computeDescriptorSetLayout <- DescriptorSetLayout.managedComputeDescriptorSetLayout device
  computePipelineLayout <- PipelineLayout.managedPipelineLayout device [computeDescriptorSetLayout]
  computePipeline <- ComputePipeline.managedComputePipeline device computePipelineLayout cullShader
  computeDescriptorPool <- DescriptorPool.managedComputeDescriptorPool device
  computeDescriptorSet <- DescriptorSet.allocateDescriptorSet device computeDescriptorPool [computeDescriptorSetLayout]

  imageAvailableSemaphores <- replicateM Render.maxFramesInFlight (Semaphore.managedSemaphore device)
  renderFinishedSemaphores <- replicateM 4 (Semaphore.managedSemaphore device)
  renderFinishedFences <- replicateM Render.maxFramesInFlight (Fence.managedFence device)

  textureCommandBuffer <- CommandBuffer.createCommandBuffer device graphicsCommandPool
  logDebug LogTexture "textureCommandBuffer created"

  let envDir = "data/textures/cubemaps/" ++ envMapDir ++ "/"
      radianceFacePaths = map (envDir ++) ["posx.png", "negx.png", "posy.png", "negy.png", "posz.png", "negz.png"]
      irradianceFacePaths = map (envDir ++) ["posx.png", "negx.png", "posy.png", "negy.png", "posz.png", "negz.png"]
  logInfo LogGeneral "loading IBL cubemaps..."
  radianceFaceDatas <- liftIO $ mapM Texture.readImageFromFile radianceFacePaths
  irradianceFaceDatas <- liftIO $ mapM Texture.readImageFromFile irradianceFacePaths
  let (radDatas, radWidths, _) = unzip3 radianceFaceDatas
      (irrDatas, irrWidths, _) = unzip3 irradianceFaceDatas
      radSize = head radWidths
      irrSize = head irrWidths
      radMipLevels = floor (logBase 2 (fromIntegral radSize :: Double)) + 1
  radianceCubemap <- Texture.createCubemapMips rm physicalDevice device radSize radDatas graphicsQueueHandler textureCommandBuffer
  irradianceCubemap <- Texture.createCubemap rm physicalDevice device irrSize irrDatas graphicsQueueHandler textureCommandBuffer
  mRadianceView <- Texture.textureImageView rm radianceCubemap
  mIrradianceView <- Texture.textureImageView rm irradianceCubemap
  logInfo LogGeneral $ "IBL cubemaps loaded: radiance=" <> showT radSize <> "px irradiance=" <> showT irrSize <> "px mipLevels=" <> showT radMipLevels

  lightingSampler <- Texture.createSamplerWithLod device (fromIntegral radMipLevels - 1)
  logInfo LogGeneral "lighting sampler created with mip support"

  let brdfPixels = BRDF.generateBRDFLUT 256 256
  brdfTexHandle <- Texture.createTextureFromData rm physicalDevice device 256 256 brdfPixels graphicsQueueHandler textureCommandBuffer
  mBrdfView <- Texture.textureImageView rm brdfTexHandle
  logInfo LogGeneral "BRDF LUT generated"

  -- Load 3D cloud noise texture
  logInfo LogGeneral "loading 3D cloud noise texture..."
  cloudNoiseView <- Texture.managedTexture3D physicalDevice device "data/textures/cloud_noise/cloud_noise_128.raw" 128 128 128 graphicsQueueHandler textureCommandBuffer
  logInfo LogGeneral "3D cloud noise texture loaded"

  assetCache <- initCache ".haskan2-cache"

  let isGLTF = ".gltf" `Text.isSuffixOf` Text.pack meshName || ".glb" `Text.isSuffixOf` Text.pack meshName
      isStressTest = meshName == "stress_test"

  (ecsWorld, numEntities, sceneBounds, texturePixelMap) <- case uvCheckMode of
    Just mode -> do
      world <- ECS.createWorld
      let uvCheckerPath = "data/textures/uv_checker.png"
      uvTexHandle <-
        liftIO (doesFileExist uvCheckerPath) >>= \exists ->
          if exists
            then do
              (pixelData, tw, th) <- Texture.readImageFromFile uvCheckerPath
              Texture.createTextureFromData rm physicalDevice device tw th pixelData graphicsQueueHandler textureCommandBuffer
            else do
              let checkerTexData = Texture.generateCheckerboardTexture 256 256 32
              Texture.createTextureFromData rm physicalDevice device 256 256 checkerTexData graphicsQueueHandler textureCommandBuffer

      let testMesh = case mode of
            "cube" -> Mesh.unitCube
            "sphere" -> Mesh.uvSphere 32 16 1.0
            _ -> Mesh.uvPlane 1.0
      testMeshHandle <- Buffer.createMeshResource rm physicalDevice device (Mesh.vertices testMesh) (Mesh.indices testMesh)
      testEntity <- ECS.spawnEntity world
      ECS.setTransform world testEntity (Transform (V3 0 0 0) (Quaternion 1 (V3 0 0 0)) (V3 1 1 1))
      ECS.setMesh world testEntity testMeshHandle
      ECS.setMaterial world testEntity uvTexHandle
      ECS.setMetallicFactor world testEntity 0.0
      ECS.setRoughnessFactor world testEntity 0.5

      let sceneBbox = BBox (V3 (-1) (-1) (-1)) (V3 1 1 1)
      pure (world, 1, sceneBbox, IntMap.empty)
    Nothing ->
      if isStressTest
        then do
          world <- ECS.createWorld
          let cubeMesh = Mesh.unitCube
          meshHandle <- Buffer.createMeshResource rm physicalDevice device (Mesh.vertices cubeMesh) (Mesh.indices cubeMesh)

          let whiteTexData = Texture.generateGridTexture 2 2 1
          whiteTexHandle <- Texture.createTextureFromData rm physicalDevice device 2 2 whiteTexData graphicsQueueHandler textureCommandBuffer

          logInfo LogGeneral "spawning 10000 stress test entities"
          forM_ [0 .. 9999] $ \i -> do
            let x = fromIntegral (i `mod` 100) * 1.0 - 50.0
                z = fromIntegral (i `div` 100) * 1.0 - 50.0
                y = sin (fromIntegral i * 0.1) * 1.0
            entity <- ECS.spawnEntity world
            ECS.setTransform world entity (Transform (V3 x y z) (Quaternion 1 (V3 0 0 0)) (V3 0.5 0.5 0.5))
            ECS.setMesh world entity meshHandle
            ECS.setMaterial world entity whiteTexHandle
            ECS.setMetallicFactor world entity 0.0
            ECS.setRoughnessFactor world entity 0.5

          let sceneBbox = BBox (V3 (-50) (-2) (-50)) (V3 50 2 50)
          logInfo LogGeneral $ "stress test scene bounds: " <> showT sceneBbox
          pure (world, 10000, sceneBbox, IntMap.empty)
        else
          if isGLTF
            then do
              result <- importGLTF rm physicalDevice device graphicsQueueHandler textureCommandBuffer assetCache meshName
              let world = girWorld result
                  meshes = girMeshes result
                  textures = girTextures result
                  textureData = girTextureData result
                  pixelMap =
                    IntMap.fromList $
                      zip (map (fromIntegral . unTextureHandle) textures) textureData

              sceneBbox <- liftIO $ computeWorldSpaceBounds world rm
              logInfo LogGeneral $ "scene bounds: " <> showT sceneBbox

              pure (world, length meshes, sceneBbox, pixelMap)
            else do
              world <- ECS.createWorld
              (mesh, _) <- Model.fromObj <$> ObjLoader.parseObj meshName
              meshHandle <- Buffer.createMeshResource rm physicalDevice device (Mesh.vertices mesh) (Mesh.indices mesh)

              let objBounds = computeMeshBounds mesh
              logInfo LogGeneral $ "OBJ mesh bounds: " <> showT objBounds

              entity1 <- ECS.spawnEntity world
              ECS.setTransform world entity1 (Transform (V3 0 0 0) (Quaternion 1 (V3 0 0 0)) (V3 1 1 1))
              ECS.setMesh world entity1 meshHandle
              ECS.setMetallicFactor world entity1 0.0
              ECS.setRoughnessFactor world entity1 0.5

              entity2 <- ECS.spawnEntity world
              ECS.setTransform world entity2 (Transform (V3 2 0 0) (Quaternion 1 (V3 0 0 0)) (V3 1 1 1))
              ECS.setMesh world entity2 meshHandle
              ECS.setMetallicFactor world entity2 0.0
              ECS.setRoughnessFactor world entity2 0.5

              entity3 <- ECS.spawnEntity world
              ECS.setTransform world entity3 (Transform (V3 (-2) 0 0) (Quaternion 1 (V3 0 0 0)) (V3 1 1 1))
              ECS.setMesh world entity3 meshHandle
              ECS.setMetallicFactor world entity3 0.0
              ECS.setRoughnessFactor world entity3 0.5

              let groundMesh = Mesh.groundPlaneMesh 50.0
              groundMeshHandle <- Buffer.createMeshResource rm physicalDevice device (Mesh.vertices groundMesh) (Mesh.indices groundMesh)
              let checkerTexData = Texture.generateCheckerboardTexture 256 256 32
              checkerTexHandle <- Texture.createTextureFromData rm physicalDevice device 256 256 checkerTexData graphicsQueueHandler textureCommandBuffer
              groundEntity <- ECS.spawnEntity world
              ECS.setTransform world groundEntity (Transform (V3 0 (-0.5) 0) (Quaternion 1 (V3 0 0 0)) (V3 1 1 1))
              ECS.setMesh world groundEntity groundMeshHandle
              ECS.setMaterial world groundEntity checkerTexHandle
              ECS.setMetallicFactor world groundEntity 0.0
              ECS.setRoughnessFactor world groundEntity 1.0

              sceneBbox <- liftIO $ computeWorldSpaceBounds world rm
              logInfo LogGeneral $ "scene bounds: " <> showT sceneBbox

              pure (world, 1, sceneBbox, IntMap.empty)

  worldState <- liftIO $ STM.readTVarIO (world gameState)
  let tvCamera = activeCamera worldState
  currentCam <- liftIO $ STM.readTVarIO tvCamera
  let adjustedCam =
        if isStressTest
          then setDistance (setTarget currentCam (V3 0 0 0 :: V3 Foreign.C.CFloat)) (150.0 :: Foreign.C.CFloat)
          else adjustCameraForScene sceneBounds currentCam
      finalCam = case uvCheckMode of
        Just _ -> setAngles (setDistance (setTarget adjustedCam (V3 0 0 0 :: V3 Foreign.C.CFloat)) 2.0) 0.78 (realToFrac (pi / 6 :: Double))
        Nothing -> setAngles adjustedCam 0 (realToFrac (pi / 6 :: Double))
  liftIO $ STM.atomically $ STM.writeTVar tvCamera finalCam
  logInfo LogGeneral $ "camera adjusted to distance=" <> showT (Camera.cameraDistance finalCam)

  when isStressTest $ liftIO $ STM.atomically $ STM.writeTVar (wireframeEnabled gameState) False

  initialDrawList <- extractDrawList ecsWorld rm IntMap.empty
  let numDrawEntities = length initialDrawList
  logInfo LogRender $ "initial draw list has " <> showT numDrawEntities <> " entities"

  liftIO $ do
    let meshHandles = nub (map (mrHandle . dcMesh) initialDrawList)
    unless (null meshHandles) $ do
      (mergedMesh, offsets) <- Buffer.mergeMeshes rm physicalDevice device meshHandles
      let sharedVertBuf = (mrVertexBuffer mergedMesh) {brDestroy = pure ()}
          sharedIdxBuf = (mrIndexBuffer mergedMesh) {brDestroy = pure ()}
      forM_ (HashMap.toList offsets) $ \(mh, (fi, vo)) -> do
        mMesh <- lookupMesh rm mh
        forM_ mMesh $ \mesh -> do
          updateMesh rm mh $
            mesh
              { mrVertexBuffer = sharedVertBuf,
                mrIndexBuffer = sharedIdxBuf,
                mrFirstIndex = fi,
                mrVertexOffset = 0
              }
      logInfo LogRender $ "merged " <> showT (length meshHandles) <> " meshes into single buffers"

  let viewProjUniformSize = 128 :: Int
      initialViewProjData = [identity, makeProjectionMatrix 16 9] :: [M44 Foreign.C.CFloat]

  logDebug LogBuffer $ "initialViewProjData length=" <> showT (length initialViewProjData) <> " size=" <> showT (length initialViewProjData * sizeOf (undefined :: M44 Foreign.C.CFloat))
  frameMvpBuffers <-
    replicateM Render.maxFramesInFlight $
      Buffer.managedUniformBuffer physicalDevice device initialViewProjData
  logDebug LogBuffer $ "frameMvpBuffers created, count=" <> showT (length frameMvpBuffers)

  let maxEntities = 16384 :: Int
      dummyEntityData =
        ComputeEntityData
          { ceTransform = identity,
            ceNormalMatrix = identity,
            ceAabbMin = V4 (-1000) (-1000) (-1000) 1,
            ceAabbMax = V4 1000 1000 1000 1,
            ceMaterialIndex = 0,
            ceFirstIndex = 0,
            ceVertexOffset = 0,
            ceIndexCount = 0,
            ceMetallicRoughnessIndex = 0,
            ceMetallicFactor = 0.0,
            ceRoughnessFactor = 0.5,
            ceNormalIndex = 0,
            ceOcclusionIndex = 0,
            ceOcclusionStrength = 1.0,
            ceEmissiveIndex = 0
          }
      dummyCullData =
        ComputeCullData
          { ccFrustumPlanes = replicate 6 (V4 0 0 0 0),
            ccCameraPosition = V4 0 0 0 1,
            ccEntityCount = fromIntegral numDrawEntities,
            ccLodDistance1 = 1000.0,
            ccLodDistance2 = 5000.0,
            ccPad3 = 0
          }
      initialDrawCommands = replicate maxEntities (DrawIndexedIndirectCommand 0 0 0 0 0)

  (entitySsboBuffer, entitySsboMemory) <- Buffer.managedStorageBuffer physicalDevice device (replicate maxEntities dummyEntityData) Vulkan.VK_ZERO_FLAGS
  (drawCommandsBuffer, drawCommandsMemory) <- Buffer.managedStorageBuffer physicalDevice device initialDrawCommands Vulkan.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT
  (cullDataBuffer, cullDataMemory) <- Buffer.managedUniformBuffer physicalDevice device [dummyCullData]

  let maxLights = 256 :: Int
      dummyLightData = LightData (V3 0 0 0) 0.0 (V3 0 0 0) 0 (V3 0 0 0) 0.0
  (lightSsboBuffer, lightSsboMemory) <- Buffer.managedStorageBuffer physicalDevice device (replicate maxLights dummyLightData) Vulkan.VK_ZERO_FLAGS
  logDebug LogBuffer $ "light SSBO created: " <> showT (maxLights * sizeOf (undefined :: LightData)) <> " bytes"

  logDebug LogBuffer $ "compute buffers created: entitySSBO=" <> showT (maxEntities * sizeOf (undefined :: ComputeEntityData)) <> " drawCommands=" <> showT (maxEntities * sizeOf (undefined :: DrawIndexedIndirectCommand)) <> " cullData=" <> showT (sizeOf (undefined :: ComputeCullData))

  DescriptorSet.updateComputeDescriptorSets device computeDescriptorSet entitySsboBuffer drawCommandsBuffer cullDataBuffer
  logDebug LogRender "compute descriptor set updated"

  let computeCullResources =
        ComputeCullResources
          { ccrPipeline = computePipeline,
            ccrPipelineLayout = computePipelineLayout,
            ccrDescriptorSet = computeDescriptorSet,
            ccrEntityBuffer = entitySsboBuffer,
            ccrEntityMemory = entitySsboMemory,
            ccrDrawCommandsBuffer = drawCommandsBuffer,
            ccrDrawCommandsMemory = drawCommandsMemory,
            ccrCullDataBuffer = cullDataBuffer,
            ccrCullDataMemory = cullDataMemory,
            ccrMaxEntities = maxEntities
          }

  logInfo LogTexture "creating sampler"
  textureSampler <- Texture.managedSampler device
  logInfo LogTexture "sampler created"

  let resizeImageBilinear src sw sh dw dh =
        let srcIdx x y = (y * sw + x) * 4
            sample x y =
              let x0 = clamp 0 (sw - 1) (floor x)
                  y0 = clamp 0 (sh - 1) (floor y)
                  x1 = clamp 0 (sw - 1) (x0 + 1)
                  y1 = clamp 0 (sh - 1) (y0 + 1)
                  fx = x - fromIntegral x0
                  fy = y - fromIntegral y0
                  ixf = 1 - fx
                  iyf = 1 - fy
                  lerpPixel a b t = round (fromIntegral a * (1 - t) + fromIntegral b * t)
                  blendChannel i =
                    let c00 = src Vector.! (srcIdx x0 y0 + i)
                        c10 = src Vector.! (srcIdx x1 y0 + i)
                        c01 = src Vector.! (srcIdx x0 y1 + i)
                        c11 = src Vector.! (srcIdx x1 y1 + i)
                        c0 = lerpPixel c00 c10 fx
                        c1 = lerpPixel c01 c11 fx
                     in lerpPixel c0 c1 fy
               in [blendChannel 0, blendChannel 1, blendChannel 2, blendChannel 3]
            dstPixel dx dy =
              let sx = fromIntegral dx * fromIntegral sw / fromIntegral dw
                  sy = fromIntegral dy * fromIntegral sh / fromIntegral dh
               in sample sx sy
            clamp lo hi v = max lo (min hi v)
         in Vector.fromList [dstPixel dx dy !! c | dy <- [0 .. dh - 1], dx <- [0 .. dw - 1], c <- [0 .. 3]]

  ecsMaterials <- liftIO $ STM.readTVarIO (ECS.wMaterials ecsWorld)
  let uniqueTextures = nub $ IntMap.elems ecsMaterials
      numUniqueTextures = length uniqueTextures

  logInfo LogTexture $ "unique textures: " <> showT numUniqueTextures

  let textureIndexMap = IntMap.fromList $ zip (map (fromIntegral . unTextureHandle) uniqueTextures) [0 ..]
      unTextureHandle (TextureHandle h) = h

  bindlessTextureViews <-
    if numUniqueTextures == 0
      then do
        let whiteTexData = Texture.generateGridTexture 2 2 1
        whiteHandle <- Texture.createTextureFromData rm physicalDevice device 2 2 whiteTexData graphicsQueueHandler textureCommandBuffer
        mView <- Texture.textureImageView rm whiteHandle
        case mView of
          Just view -> pure [view]
          Nothing -> fail "failed to create white texture"
      else do
        forM uniqueTextures $ \texHandle -> do
          let hId = fromIntegral (unTextureHandle texHandle)
          (tw, th, pixelData) <- case IntMap.lookup hId texturePixelMap of
            Just (tw, th, pixelData) -> pure (tw, th, pixelData)
            Nothing -> do
              mTexRes <- lookupTexture rm texHandle
              case mTexRes of
                Nothing -> pure (256, 256, Texture.generateCheckerboardTexture 256 256 32)
                Just texRes -> case trPixelData texRes of
                  Nothing -> pure (256, 256, Texture.generateCheckerboardTexture 256 256 32)
                  Just pixelData -> pure (trWidth texRes, trHeight texRes, pixelData)
          texHandle' <- Texture.createTextureFromData rm physicalDevice device tw th pixelData graphicsQueueHandler textureCommandBuffer
          mView <- Texture.textureImageView rm texHandle'
          case mView of
            Just view -> pure view
            Nothing -> fail "failed to create texture view"

  logInfo LogTexture $ "bindless textures created: " <> showT (length bindlessTextureViews)

  let totalDescriptorSets = Render.maxFramesInFlight
  descriptorPool <- DescriptorPool.managedDescriptorPool device totalDescriptorSets
  logDebug LogRender $ "descriptor pool created for " <> showT totalDescriptorSets <> " sets"

  frameDescriptorSets <-
    replicateM totalDescriptorSets $
      DescriptorSet.allocateDescriptorSet device descriptorPool [descriptorSetLayout]
  logDebug LogRender $ "allocated " <> showT (length frameDescriptorSets) <> " frame descriptor sets"

  logInfo LogVulkan "updating frame descriptor sets"
  for_ (zip [0 ..] frameMvpBuffers) $ \(frameIdx, (buf, _)) -> do
    let ds = frameDescriptorSets !! frameIdx
    DescriptorSet.updateDescriptorSetsBindless
      device
      ds
      buf
      (fromIntegral viewProjUniformSize)
      textureSampler
      bindlessTextureViews
      entitySsboBuffer
  logInfo LogVulkan "frame descriptor sets updated"

  logInfo LogRender "all resources created, entering render loop"
  liftIO $ putMVar readySemaphore ()

  let mkRenderContext =
        Render.createRenderContext
          physicalDevice
          device
          surface
          pipelineLayout
          vertShader
          fragShader
          []
          graphicsCommandPool
          graphicsQueueHandler
          presentQueueHandler
          renderFinishedFences
          renderFinishedSemaphores

  worldState <- liftIO $ STM.readTVarIO (world gameState)
  frameStatsRef <- liftIO $ newIORef emptyFrameStats
  let tvCamera = activeCamera worldState
      tvInspect = inspectFrame gameState
      tvInsp = inspector gameState
      tvRenderDebug = renderDebugState gameState
      tvWireframe = wireframeEnabled gameState
      tvDebugMode = debugMode gameState
      tvAxisOverlay = axisOverlayEnabled gameState
      tvGroundPlane = groundPlaneEnabled gameState
      tvPendingScreenshot = pendingScreenshot gameState
      tvPendingAllStages = pendingAllStages gameState
      tvPendingSwapchainScreenshot = pendingSwapchainScreenshot gameState
      tvLights = lights gameState
      tvTimeOfDay = gameTimeOfDay gameState
      tvTimeSpeed = gameTimeSpeed gameState
      tvDayNightEnabled = gameDayNightEnabled gameState
      tvCloudHeight = cloudHeight gameState
      frameMvpMemories = map snd frameMvpBuffers
      outerLoop :: (MonadFail m, MonadIO m) => Bool -> m ()
      outerLoop exit = do
        unless exit $ do
            renderFrameLoopFinished <- liftIO $ with mkRenderContext $ \context ->
              with (createDeferredResources physicalDevice device context descriptorSetLayout [] gbufVertShader gbufFragShader lightVertShader lightFragShader wireVertShader wireGeomShader wireFragShader mRadianceView mIrradianceView mBrdfView lightingSampler cloudNoiseView) $ \dr -> do
                -- Update lighting descriptor sets with light SSBO
                for_ (drLightingDescriptorSets dr) $ \ds ->
                  DescriptorSet.updateLightingLightBuffer device ds lightSsboBuffer
                let renderEnv =
                      RenderEnv
                        { reContext = context,
                          reDeferred = dr,
                          reTargetFPS = targetFPS,
                          reImageAvailableSemaphores = imageAvailableSemaphores,
                          reControl = control,
                          reFrameMvpMemories = frameMvpMemories,
                          reTvCamera = tvCamera,
                          reTvInspect = tvInspect,
                          reTvInsp = tvInsp,
                          reTvRenderDebug = tvRenderDebug,
                          reECSWorld = ecsWorld,
                          reResourceManager = rm,
                          reTextureSampler = textureSampler,
                          reFrameDescriptorSets = frameDescriptorSets,
                          reTextureIndexMap = textureIndexMap,
                          reTvWireframe = tvWireframe,
                          reFrameStatsRef = frameStatsRef,
                          reCullResources = computeCullResources,
                          reTvDebugMode = tvDebugMode,
                          reTvAxisOverlay = tvAxisOverlay,
                          reTvGroundPlane = tvGroundPlane,
                          reTvPendingScreenshot = tvPendingScreenshot,
                          reTvPendingAllStages = tvPendingAllStages,
                          reTvPendingSwapchainScreenshot = tvPendingSwapchainScreenshot,
                          rePhysicalDevice = physicalDevice,
                          reLightSsboBuffer = lightSsboBuffer,
                          reLightSsboMemory = lightSsboMemory,
                          reTvLights = tvLights,
                          reTvTimeOfDay = tvTimeOfDay,
                          reTvTimeSpeed = tvTimeSpeed,
                          reTvDayNightEnabled = tvDayNightEnabled,
                          reTvCloudHeight = tvCloudHeight
                        }
                renderFrameLoop renderEnv 0
            outerLoop renderFrameLoopFinished

  logInfo LogGeneral "Starting render loop"
  outerLoop False

  logInfo LogGeneral "renderLoop finished"
  destroyAllResources rm
