{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Engine.Render
  ( renderFrameLoop,
    renderLoop,
    RenderLoopConfig (..),
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
import Control.Monad.Reader (MonadReader, ReaderT, ask, asks, runReaderT)
import Data.Foldable (for_, toList)
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HashMap
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Int (Int32)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.List (nub, sort, sortOn)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector.Storable qualified as Vector
import Data.Word (Word32, Word64, Word8)
import DearImGui.Raw qualified as ImGui.Raw
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
import Graphics.Haskan.Debug.Server (CommandQueue, DebugServerHandle, startDebugServer, stopDebugServer)
import Graphics.Haskan.Engine.Capabilities.Clock (MonadClock (..))
import Graphics.Haskan.Engine.Capabilities.Graphics (MonadGraphics (..))
import Graphics.Haskan.Engine.Capabilities.Log (MonadLog (..), logDebug, logInfo)
import Graphics.Haskan.Engine.Capabilities.StateReader (MonadStateReader (..), consumeTVar, readTVarIO)
import Graphics.Haskan.Engine.Capabilities.Telemetry (MonadTelemetry (..))
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
  ( CloudParams (..),
    FrameParams (..),
    FrameRenderInput (..),
    FrameRenderResources (..),
    SkyParams (..),
    buildRecordAction,
  )
import Graphics.Haskan.Engine.Render.Internal.Screenshot
  ( ScreenshotContext (..),
    ScreenshotFlags (..),
    handleScreenshotAllStages,
    handleScreenshotSingle,
    handleScreenshotSwapchain,
  )
import Graphics.Haskan.Engine.Render.Internal.Setup
  ( Cubemap (..),
    IBLTextures (..),
    NoiseParams (..),
    SceneLoadResult (..),
    ShaderModules (..),
    ShaderPair (..),
    VulkanContext (..),
    WireframeShaders (..),
    compileAllShaders,
    createShaderModules,
    dispatchCloudNoiseGeneration,
    dispatchProceduralSkyGeneration,
    loadIBLTextures,
    loadScene,
  )
import Graphics.Haskan.Engine.Scene (adjustCameraForScene, computeMeshBounds, computeSceneBounds, computeSkyboxRays, computeWorldSpaceBounds, drawCallToSnapshot, makeProjectionMatrix)
import Graphics.Haskan.Engine.Types (ComputeCullData (..), ComputeCullResources (..), ComputeEntityData (..), ControlMessage (..), DrawIndexedIndirectCommand (..), EngineConfig (..), EntityDebugInfo (..), FrameStats (..), FrameTime (..), GameState (..), InputBuffer (..), LightData (..), RenderDebugInfo (..), UVCheckMode (..), WorldState (..), emptyFrameStats, extractFrustumPlanes, filterVisible, flushInputBuffer, forkIOWithHandler, newInputBuffer, toListOfV4, transformAABB, updateFrameStats, writeInputBuffer)
import Graphics.Haskan.Input (Action (..), ActionEvent, payloadToActionEvent)
import Graphics.Haskan.Logger (LogCategory (..), logInfoIO, showT)
import Graphics.Haskan.Mesh qualified as Mesh
import Graphics.Haskan.Model qualified as Model
import Graphics.Haskan.Physics.Jolt.Types (BodyState (..))
import Graphics.Haskan.Render.Deferred (DeferredPassData (..), buildDeferredGraph)
import Graphics.Haskan.Render.Forward (ForwardPassData (..), buildForwardGraph)
import Graphics.Haskan.Render.Graph (PassContext (..), PassRecordFunc (..), RenderPassNode (..))
import Graphics.Haskan.Render.Graph qualified as Graph
import Graphics.Haskan.Render.RenderSystem (DrawCall (..), extractDrawList)
import Graphics.Haskan.Render.ShaderProgram (ShaderProgram (..))
import Graphics.Haskan.Resources (alloc, allocaAndPeekVkResult, throwVkResult)
import Graphics.Haskan.Scene.ECS (EntityId (..))
import Graphics.Haskan.Scene.ECS qualified as ECS
import Graphics.Haskan.Scene.GLTF (GLTFImportResult (..), importGLTF)
import Graphics.Haskan.Scene.Transform (Transform (..), defaultTransform, tPosition)
import Graphics.Haskan.Scene.Transform qualified as Transform
import Graphics.Haskan.UI.Backend qualified as Backend
import Graphics.Haskan.Utils.ObjLoader qualified as ObjLoader
import Graphics.Haskan.Vertex (Vertex (..))
import Graphics.Haskan.Vulkan.BRDF qualified as BRDF
import Graphics.Haskan.Vulkan.Buffer qualified as Buffer
import Graphics.Haskan.Vulkan.CommandBuffer qualified as CommandBuffer
import Graphics.Haskan.Vulkan.CommandPool qualified as CommandPool
import Graphics.Haskan.Vulkan.ComputePipeline qualified as ComputePipeline
import Graphics.Haskan.Vulkan.DeferredResources (DeferredResources (..))
import Graphics.Haskan.Vulkan.DeferredResources qualified as Deferred
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
import Graphics.Haskan.Vulkan.Specialization (SpecEntry (..), SpecializationData (..), mallocSpecializationInfo, packFloat)
import Graphics.Haskan.Vulkan.Swapchain qualified as Swapchain
import Graphics.Haskan.Vulkan.Texture qualified as Texture
import Graphics.Haskan.Vulkan.Types (RenderContext (..), VulkanContext (..))
import Graphics.Haskan.Window (isWindowVisible)
import Graphics.Haskan.Window qualified as Window
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Ext qualified as Vulkan
import Graphics.Vulkan.Marshal.Create qualified as Vulkan
import Linear (M44, V2 (..), V3 (..), V4 (..), normalize, (*^), (^+^), (^-^))
import Linear.Matrix (M44, identity, inv33, inv44, transpose, (!*), (!*!))
import Linear.Projection qualified
import Linear.Quaternion (Quaternion (..))
import Linear.V3 (_x, _y, _z)
import Linear.V4 (_w)
import SDL qualified
import SDL.Input.Mouse qualified as SDL.Mouse
import System.Clock (TimeSpec, toNanoSecs)
import System.Directory (doesFileExist)
import System.IO.Unsafe (unsafePerformIO)

type RenderLoopM m = ReaderT RenderEnv m

-- | Configuration passed to the render loop at startup.
data RenderLoopConfig = RenderLoopConfig
  { rlcWindow :: !SDL.Window,
    rlcPhysicalDevice :: !Vulkan.VkPhysicalDevice,
    rlcSurface :: !Vulkan.VkSurfaceKHR,
    rlcInstance :: !Vulkan.VkInstance,
    rlcLayers :: ![String],
    rlcTargetFPS :: !Integer,
    rlcGameState :: !(GameState AnyCamera),
    rlcFinishedSemaphore :: !(MVar ()),
    rlcReadySemaphore :: !(MVar ()),
    rlcControlChannel :: !(TChan ControlMessage),
    rlcMeshName :: !String,
    rlcUvCheckMode :: !(Maybe UVCheckMode),
    rlcEnvMapDir :: !String,
    rlcCloudTestMode :: !Bool,
    rlcProceduralSkyEnabled :: !Bool,
    rlcSimpleMesh :: !(Maybe Mesh.Mesh)
  }

-- | Mutable game state variables accessed every frame.
data GameStateTVars = GameStateTVars
  { gstCamera :: !(TVar AnyCamera),
    gstInspect :: !(STM.TVar Bool),
    gstInsp :: !(STM.TVar (Maybe FrameInspector)),
    gstRenderDebug :: !(STM.TVar (Maybe RenderDebugInfo)),
    gstWireframe :: !(STM.TVar Bool),
    gstDebugMode :: !(STM.TVar Word32),
    gstAxisOverlay :: !(STM.TVar Float),
    gstGroundPlane :: !(STM.TVar Float),
    gstLights :: !(STM.TVar [LightData]),
    gstTimeOfDay :: !(STM.TVar Float),
    gstTimeSpeed :: !(STM.TVar Float),
    gstDayNightEnabled :: !(STM.TVar Bool)
  }

-- | Mutable cloud and weather state variables.
data CloudStateTVars = CloudStateTVars
  { cstCloudHeight :: !(STM.TVar Float),
    cstWindDirection :: !(STM.TVar Float),
    cstWindSpeed :: !(STM.TVar Float),
    cstCloudCoverage :: !(STM.TVar Float),
    cstCloudDetail :: !(STM.TVar Float),
    cstCloudAbsorption :: !(STM.TVar Float),
    cstWeatherCoverageScale :: !(STM.TVar Float),
    cstWeatherTypeBias :: !(STM.TVar Float),
    cstStormIntensity :: !(STM.TVar Float),
    cstWeatherAnimSpeed :: !(STM.TVar Float)
  }

-- | Mutable physics state variables.
data PhysicsStateTVars = PhysicsStateTVars
  { pstPhysicsBodies :: !(STM.TVar (IntMap BodyState)),
    pstPhysicsBodyToEntity :: !(STM.TVar (IntMap EntityId)),
    pstPhysicsAutoStep :: !(STM.TVar Bool),
    pstPhysicsTimeScale :: !(STM.TVar Float)
  }

-- | Sky and noise generation state.
data SkyNoiseState = SkyNoiseState
  { snsIBLTextures :: !IBLTextures,
    snsSkyNeedsRegeneration :: !(STM.TVar Bool),
    snsNoiseNeedsRegeneration :: !(STM.TVar Bool),
    snsNoiseSeed :: !(STM.TVar Float),
    snsNoiseFrequency :: !(STM.TVar Float),
    snsNoisePersistence :: !(STM.TVar Float)
  }

-- | Temporal reprojection state.
data TemporalState = TemporalState
  { tsPrevViewProj :: ![TVar (Linear.Matrix.M44 Foreign.C.CFloat)],
    tsPrevTime :: ![TVar Float]
  }

data RenderEnv = RenderEnv
  { reWindow :: !SDL.Window,
    reContext :: !RenderContext,
    reDeferred :: DeferredResources,
    reTargetFPS :: !Integer,
    reImageAvailableSemaphores :: ![Vulkan.VkSemaphore],
    reControl :: !(TChan ControlMessage),
    reFrameMvpMemories :: ![Vulkan.VkDeviceMemory],
    reFrameDescriptorSets :: ![Vulkan.VkDescriptorSet],
    reTextureSampler :: !Vulkan.VkSampler,
    reTextureIndexMap :: !(IntMap Word32),
    reFrameStatsRef :: !(IORef FrameStats),
    reCullResources :: ComputeCullResources,
    rePhysicalDevice :: !Vulkan.VkPhysicalDevice,
    reLightSsboBuffer :: Vulkan.VkBuffer,
    reLightSsboMemory :: Vulkan.VkDeviceMemory,
    reECSWorld :: !ECS.World,
    reResourceManager :: !ResourceManager,
    reGameState :: !GameStateTVars,
    reCloudState :: !CloudStateTVars,
    rePhysicsState :: !PhysicsStateTVars,
    reScreenshotFlags :: !ScreenshotFlags,
    reSkyNoiseState :: !SkyNoiseState,
    reTemporalState :: !TemporalState,
    reImGuiBackend :: !(Maybe Backend.ImGuiBackend),
    reSimpleMode :: !Bool
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
  readCamera = asks (gstCamera . reGameState) >>= readTVarIO
  readControl = asks reControl >>= liftIO . STM.atomically . TChan.tryReadTChan
  readWireframe = asks (gstWireframe . reGameState) >>= readTVarIO
  readDebugMode = asks (gstDebugMode . reGameState) >>= readTVarIO
  readAxisOverlay = asks (gstAxisOverlay . reGameState) >>= readTVarIO
  readGroundPlane = asks (gstGroundPlane . reGameState) >>= readTVarIO
  readTimeOfDay = asks (gstTimeOfDay . reGameState) >>= readTVarIO
  readDayNightEnabled = asks (gstDayNightEnabled . reGameState) >>= readTVarIO
  readCloudHeight = asks (cstCloudHeight . reCloudState) >>= readTVarIO
  readInspector = asks (gstInsp . reGameState) >>= readTVarIO
  readLights = asks (gstLights . reGameState) >>= readTVarIO
  consumeInspectFlag = asks (gstInspect . reGameState) >>= consumeTVar
  consumeScreenshotFlag = asks (sfPendingScreenshot . reScreenshotFlags) >>= consumeTVar
  consumeAllStagesFlag = asks (sfPendingAllStages . reScreenshotFlags) >>= consumeTVar
  consumeSwapchainScreenshotFlag = asks (sfPendingSwapchainScreenshot . reScreenshotFlags) >>= consumeTVar

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
terminateFrame :: (MonadLog m) => m (Bool, Bool)
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

  if reSimpleMode
    then do
      drawList <- extractDrawList reECSWorld reResourceManager reTextureIndexMap
      case drawList of
        [] -> pure (False, False)
        _ -> renderAndPresentSimple env frameNumber camera drawList mvpMemory imageAvailableSemaphore
    else do
      -- Sync physics bodies to ECS transforms
      physicsBodies' <- liftIO $ STM.readTVarIO (pstPhysicsBodies rePhysicsState)
      physicsBodyToEntity' <- liftIO $ STM.readTVarIO (pstPhysicsBodyToEntity rePhysicsState)
      liftIO $ forM_ (IntMap.toList physicsBodies') $ \(bid, bstate) ->
        case IntMap.lookup bid physicsBodyToEntity' of
          Just (EntityId eid) -> do
            let t = Transform (bsPosition bstate) (bsRotation bstate) (V3 1 1 1)
            ECS.setTransform reECSWorld (EntityId eid) t
          Nothing -> pure ()

      drawList <- extractDrawList reECSWorld reResourceManager reTextureIndexMap
      logDebug LogRender $ "draw list: " <> showT (length drawList) <> " entities"
      -- Sort: culled entities first, then double-sided (matches pipeline split in gbuffer pass)
      let sortedDrawList = sortOn dcDoubleSided drawList
          camPos = realToFrac <$> Camera.cameraPosition camera
          camTarget = realToFrac <$> Camera.cameraTarget camera
          (w, h) = surfaceExtentWH (rcSurfaceExtent reContext)
          projMat = Linear.Matrix.transpose $ (realToFrac <$>) <$> makeProjectionMatrix w h :: M44 Float
          viewMat = Linear.Matrix.transpose $ (realToFrac <$>) <$> Camera.unViewMatrix (Camera.toMatrix camera) :: M44 Float
          entityDebugInfos = computeEntityDebugInfos sortedDrawList projMat viewMat
          renderDebugInfo = buildRenderDebugInfo frameNumber camPos camTarget projMat entityDebugInfos
      liftIO $ STM.atomically $ STM.writeTVar (gstRenderDebug reGameState) $ Just renderDebugInfo
      let entityData = buildAllEntityData sortedDrawList
          cullData = buildCullData w h camera sortedDrawList
      uploadStorageBuffer (ccrEntityMemory reCullResources) 0 entityData
      uploadUniformBuffer (ccrCullDataMemory reCullResources) 0 [cullData]
      logDebug LogRender $ "compute culling data uploaded: " <> showT (length entityData) <> " entities"

      -- Check if procedural sky needs regeneration (day-night cycle)
      needsSkyRegen <- liftIO $ STM.readTVarIO (snsSkyNeedsRegeneration reSkyNoiseState)
      when needsSkyRegen $ do
        logInfo LogRender "sky regeneration requested (sun angle > 2°)"
        timeOfDay <- readTimeOfDay
        let sunState = DayNight.computeSunState DayNight.defaultDayNightConfig timeOfDay
            sunDir = DayNight.ssDirection sunState
            sunElevation = max 0.0 (sunDir ^. _y) -- elevation from Y component
            sunIntensity = DayNight.ssIntensity sunState * 50.0 -- scale to HW intensity range
            IBLTextures {..} = snsIBLTextures reSkyNoiseState
            ctx = reContext
        -- Create a one-time command buffer and dispatch sky compute shaders
        regenCmdBuf <- CommandBuffer.createCommandBuffer (device ctx) (rcGraphicsCommandPool ctx)
        let vc = VulkanContext (device ctx) rePhysicalDevice (graphicsQueueHandler ctx) regenCmdBuf
        liftIO $
          runManaged $
            dispatchProceduralSkyGeneration
              vc
              reResourceManager
              (cmHandle iblRadiance)
              (cmHandle iblIrradiance)
              sunDir
              sunElevation
              sunIntensity
        liftIO $ STM.atomically $ STM.writeTVar (snsSkyNeedsRegeneration reSkyNoiseState) False

      -- Check if cloud noise needs regeneration (ImGui trigger)
      needsNoiseRegen <- liftIO $ STM.readTVarIO (snsNoiseNeedsRegeneration reSkyNoiseState)
      when needsNoiseRegen $ do
        logInfo LogRender "cloud noise regeneration requested"
        noiseSeedVal <- liftIO $ STM.readTVarIO (snsNoiseSeed reSkyNoiseState)
        noiseFreqVal <- liftIO $ STM.readTVarIO (snsNoiseFrequency reSkyNoiseState)
        noisePersistVal <- liftIO $ STM.readTVarIO (snsNoisePersistence reSkyNoiseState)
        let IBLTextures {..} = snsIBLTextures reSkyNoiseState
            ctx = reContext
        -- Create a one-time command buffer and dispatch noise compute shaders
        regenCmdBuf <- CommandBuffer.createCommandBuffer (device ctx) (rcGraphicsCommandPool ctx)
        liftIO $ Vulkan.vkDeviceWaitIdle (device ctx)
        let vc = VulkanContext (device ctx) rePhysicalDevice (graphicsQueueHandler ctx) regenCmdBuf
        liftIO $
          runManaged $
            dispatchCloudNoiseGeneration
              vc
              reResourceManager
              (cmHandle iblCloudNoise)
              (NoiseParams noiseSeedVal noiseFreqVal noisePersistVal)
        liftIO $ STM.atomically $ STM.writeTVar (snsNoiseNeedsRegeneration reSkyNoiseState) False

      lights' <- readLights
      let lightsToUpload = take 256 lights' ++ replicate (256 - length lights') (LightData (V3 0 0 0) 0.0 (V3 0 0 0) 0 (V3 0 0 0) 0.0)
      uploadStorageBuffer reLightSsboMemory 0 lightsToUpload
      let lightCount = fromIntegral (length lights') :: Word32
      logDebug LogRender $ "lights uploaded: " <> showT (length lights')
      case sortedDrawList of
        [] -> pure (False, False)
        _ -> renderAndPresent env frameNumber camera sortedDrawList lightCount mvpMemory imageAvailableSemaphore

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
      viewProj = projection !*! view
      skyboxRays = computeSkyboxRays ((realToFrac <$>) <$> view) ((realToFrac <$>) <$> projection)
      cloudPrevViewProj = view !*! projection
      invViewProj = (realToFrac <$>) <$> inv44 (view !*! projection) :: M44 Float
      nearPlane = 1.0
      farPlane = 50000.0
  uploadUniformBuffer mvpMemory 0 [view, projection]

  frameState <- readFrameState
  let (sunState, skyTint, iblInt, sunAzimuth, sunDir) = computeSkyParams (fsDayNightEnabled frameState) (fsTimeOfDay frameState)
      sunColor = DayNight.ssColor sunState
      cloudHeight = fsCloudHeight frameState
      cloudBase = cloudHeight - 300.0
      cloudTop = cloudHeight + 300.0

  windDirDeg <- liftIO $ STM.readTVarIO (cstWindDirection reCloudState)
  windSpeedVal <- liftIO $ STM.readTVarIO (cstWindSpeed reCloudState)
  let windDirRad = windDirDeg * pi / 180.0
      windDirXVal = cos windDirRad * windSpeedVal / 10.0
      windDirZVal = sin windDirRad * windSpeedVal / 10.0
  cloudCoverageVal <- liftIO $ STM.readTVarIO (cstCloudCoverage reCloudState)
  cloudDetailVal <- liftIO $ STM.readTVarIO (cstCloudDetail reCloudState)
  cloudAbsorptionVal <- liftIO $ STM.readTVarIO (cstCloudAbsorption reCloudState)
  weatherCoverageScaleVal <- liftIO $ STM.readTVarIO (cstWeatherCoverageScale reCloudState)
  weatherTypeBiasVal <- liftIO $ STM.readTVarIO (cstWeatherTypeBias reCloudState)
  stormIntensityVal <- liftIO $ STM.readTVarIO (cstStormIntensity reCloudState)
  weatherAnimSpeedVal <- liftIO $ STM.readTVarIO (cstWeatherAnimSpeed reCloudState)

  currentTime <- getMonotonicTime
  let elapsedSeconds = fromIntegral (toNanoSecs currentTime) / 1e9

  -- Build Dear ImGui frame
  mDrawData <- liftIO $ case reImGuiBackend of
    Just _ -> do
      let panelEnv =
            Backend.DebugPanelEnv
              { Backend.dpeCloud =
                  Backend.CloudPanel
                    { Backend.cpHeight = cstCloudHeight reCloudState,
                      Backend.cpWindDirection = cstWindDirection reCloudState,
                      Backend.cpWindSpeed = cstWindSpeed reCloudState,
                      Backend.cpDetail = cstCloudDetail reCloudState,
                      Backend.cpAbsorption = cstCloudAbsorption reCloudState,
                      Backend.cpNoiseSeed = snsNoiseSeed reSkyNoiseState,
                      Backend.cpNoiseFrequency = snsNoiseFrequency reSkyNoiseState,
                      Backend.cpNoisePersistence = snsNoisePersistence reSkyNoiseState
                    },
                Backend.dpeWeather =
                  Backend.WeatherPanel
                    { Backend.wpCoverage = cstCloudCoverage reCloudState,
                      Backend.wpCoverageScale = cstWeatherCoverageScale reCloudState,
                      Backend.wpTypeBias = cstWeatherTypeBias reCloudState,
                      Backend.wpStormIntensity = cstStormIntensity reCloudState,
                      Backend.wpAnimSpeed = cstWeatherAnimSpeed reCloudState
                    },
                Backend.dpeTimeOfDay = gstTimeOfDay reGameState,
                Backend.dpeTimeSpeed = gstTimeSpeed reGameState,
                Backend.dpeFrameStatsRef = reFrameStatsRef,
                Backend.dpeCamera = camera,
                Backend.dpeDebugMode = gstDebugMode reGameState,
                Backend.dpeWireframe = gstWireframe reGameState,
                Backend.dpePhysicsAutoStep = pstPhysicsAutoStep rePhysicsState,
                Backend.dpePhysicsTimeScale = pstPhysicsTimeScale rePhysicsState,
                Backend.dpeNoiseNeedsRegeneration = snsNoiseNeedsRegeneration reSkyNoiseState
              }
      Backend.buildImGuiFrame (runReaderT Backend.buildDebugPanel panelEnv)
    Nothing -> pure Nothing

  let skyParams = SkyParams skyTint iblInt sunAzimuth sunDir
      cloudParams = CloudParams windDirXVal windDirZVal cloudCoverageVal cloudDetailVal cloudAbsorptionVal weatherCoverageScaleVal weatherTypeBiasVal stormIntensityVal weatherAnimSpeedVal
      frameParams = FrameParams elapsedSeconds (tsPrevViewProj reTemporalState) (tsPrevTime reTemporalState) cloudPrevViewProj
      resources = FrameRenderResources ctx dr ccr reFrameDescriptorSets reTextureSampler reLightSsboBuffer
      input = FrameRenderInput frameState camera drawList lightCount skyboxRays skyParams cloudParams frameParams invViewProj nearPlane farPlane sunColor cloudBase cloudTop mDrawData
      recordAction = buildRecordAction resources input

  res <- drawFrameGraphics imageAvailableSemaphore frameNumber recordAction
  handleFrameResult env frameNumber camera drawList res

-- | Simple forward rendering for runSimple: single pass directly to swapchain.
renderAndPresentSimple ::
  (MonadFail m, MonadIO m, MonadLog m, MonadClock m, MonadTelemetry m, MonadStateReader m, MonadGraphics m) =>
  RenderEnv ->
  Int ->
  AnyCamera ->
  [DrawCall] ->
  Vulkan.VkDeviceMemory ->
  Vulkan.VkSemaphore ->
  RenderLoopM m (Bool, Bool)
renderAndPresentSimple env@RenderEnv {..} frameNumber camera drawList mvpMemory imageAvailableSemaphore = do
  let ctx = reContext
      (w, h) = surfaceExtentWH (rcSurfaceExtent ctx)
      view = Linear.Matrix.transpose $ Camera.unViewMatrix (Camera.toMatrix camera)
      projection = Linear.Matrix.transpose $ makeProjectionMatrix w h
  uploadUniformBuffer mvpMemory 0 [view, projection]
  res <- drawFrameGraphics imageAvailableSemaphore frameNumber (recordAction ctx)
  handleFrameResult env frameNumber camera drawList res
  where
    recordAction ctx imageIdx frameIdx = do
      let commandBuffer = graphicsCommandBuffers ctx !! fromIntegral imageIdx
          framebuffer = rcFramebuffers ctx !! fromIntegral imageIdx
          renderPass = rcRenderPass ctx
          pipeline = rcGraphicsPipeline ctx
          pipelineLayout = rcPipelineLayout ctx
          descriptorSet = reFrameDescriptorSets !! frameIdx
          extent = rcSurfaceExtent ctx
          colorClear = Vulkan.createVk (Vulkan.setAt @"float32" @0 0.2 Vulkan.&* Vulkan.setAt @"float32" @1 0.2 Vulkan.&* Vulkan.setAt @"float32" @2 0.2 Vulkan.&* Vulkan.setAt @"float32" @3 1.0)
          depthClear = Vulkan.createVk (Vulkan.set @"depth" 1.0 Vulkan.&* Vulkan.set @"stencil" 0)
          clearValues = [Vulkan.createVk (Vulkan.set @"color" colorClear), Vulkan.createVk (Vulkan.set @"depthStencil" depthClear)]
      case drawList of
        [] -> pure ()
        (drawCall : _) -> do
          let vertexBuffer = brVkBuffer (mrVertexBuffer (dcMesh drawCall))
              indexBuffer = brVkBuffer (mrIndexBuffer (dcMesh drawCall))
              indexCount = fromIntegral (mrIndexCount (dcMesh drawCall))
              firstIndex = fromIntegral (mrFirstIndex (dcMesh drawCall))
              vertexOffset = fromIntegral (mrVertexOffset (dcMesh drawCall))
          CommandBuffer.withCommandBuffer commandBuffer $ do
            RenderPass.withRenderPass commandBuffer renderPass framebuffer extent clearValues $ do
              liftIO $ Vulkan.vkCmdBindPipeline commandBuffer Vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS pipeline
              liftIO $ Foreign.Marshal.Array.withArray [descriptorSet] $ \dsPtr ->
                Vulkan.vkCmdBindDescriptorSets commandBuffer Vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS pipelineLayout 0 1 dsPtr 0 Vulkan.vkNullPtr
              liftIO $ Foreign.Marshal.Array.withArray [vertexBuffer] $ \vbPtr ->
                Foreign.Marshal.Array.withArray [0] $ \offsetPtr ->
                  Vulkan.vkCmdBindVertexBuffers commandBuffer 0 1 vbPtr offsetPtr
              liftIO $ Vulkan.vkCmdBindIndexBuffer commandBuffer indexBuffer 0 Vulkan.VK_INDEX_TYPE_UINT32
              liftIO $ Vulkan.vkCmdDrawIndexed commandBuffer indexCount 1 firstIndex vertexOffset 0

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
    delayMicros 100000
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
    unless reSimpleMode $ do
      shouldScreenshot <- consumeScreenshotFlag
      shouldAllStages <- consumeAllStagesFlag
      shouldSwapchain <- consumeSwapchainScreenshotFlag
      let screenshotCtx =
            ScreenshotContext
              { scVulkanContext = VulkanContext (device reContext) rePhysicalDevice (graphicsQueueHandler reContext) undefined,
                scCommandPool = rcGraphicsCommandPool reContext,
                scExtent = rcSurfaceExtent reContext,
                scImageIndex = imageIndex
              }
      when shouldScreenshot $ do
        handleScreenshotSingle reDeferred screenshotCtx
      when shouldAllStages $ do
        handleScreenshotAllStages reDeferred screenshotCtx
      when shouldSwapchain $ do
        handleScreenshotSwapchain reContext screenshotCtx
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

renderFrameLoop' :: (MonadFail m, MonadIO m, MonadLog m, MonadClock m, MonadTelemetry m, MonadStateReader m, MonadGraphics m) => Int -> RenderLoopM m Bool
renderFrameLoop' frameNumber = do
  env@RenderEnv {reWindow = window, reTargetFPS = targetFPS} <- ask
  windowVisible <- liftIO $ isWindowVisible window
  if not windowVisible
    then do
      delayMicros 100000
      renderFrameLoop' frameNumber
    else do
      frameStartTime <- getMonotonicTime
      maybeControlMessage <- readControl

      (needRestart, terminating) <- case maybeControlMessage of
        Just Terminate -> terminateFrame
        Nothing -> runFrame frameNumber

      handleFrameTiming frameStartTime needRestart terminating targetFPS frameNumber

renderLoop ::
  (MonadFail m, MonadManaged m, MonadIO m, MonadLog m, MonadClock m, MonadTelemetry m, MonadStateReader m, MonadGraphics m) =>
  RenderLoopConfig ->
  m ()
renderLoop RenderLoopConfig {..} = do
  control <- liftIO $ STM.atomically $ TChan.dupTChan rlcControlChannel

  rm <- newResourceManager

  (device, (graphicsQueueFamilyIndex, presentQueueFamilyIndex)) <- Device.managedRenderDevice rlcPhysicalDevice rlcSurface rlcLayers

  graphicsQueueHandler <- Device.getDeviceQueueHandler device graphicsQueueFamilyIndex 0
  presentQueueHandler <- Device.getDeviceQueueHandler device presentQueueFamilyIndex 0

  compileAllShaders

  ShaderModules {..} <-
    createShaderModules device

  descriptorSetLayout <- DescriptorSetLayout.managedDescriptorSetLayout device
  pipelineLayout <- PipelineLayout.managedPipelineLayout device [descriptorSetLayout]
  graphicsCommandPool <- CommandPool.managedCommandPool device graphicsQueueFamilyIndex

  computeDescriptorSetLayout <- DescriptorSetLayout.managedComputeDescriptorSetLayout device
  computePipelineLayout <- PipelineLayout.managedPipelineLayout device [computeDescriptorSetLayout]
  computePipeline <- ComputePipeline.managedComputePipeline device computePipelineLayout smCull
  computeDescriptorPool <- DescriptorPool.managedComputeDescriptorPool device
  computeDescriptorSet <- DescriptorSet.allocateDescriptorSet device computeDescriptorPool [computeDescriptorSetLayout]

  imageAvailableSemaphores <- replicateM Render.maxFramesInFlight (Semaphore.managedSemaphore device)
  renderFinishedSemaphores <- replicateM 4 (Semaphore.managedSemaphore device)
  renderFinishedFences <- replicateM Render.maxFramesInFlight (Fence.managedFence device)

  -- Dear ImGui initialization
  let imGuiSurfaceFormat = Swapchain.surfaceFormat
  imGuiRenderPass <- RenderPass.managedImGuiRenderPass device imGuiSurfaceFormat
  imGuiDescriptorPool <- DescriptorPool.managedImGuiDescriptorPool device
  mImGuiBackend <-
    Just
      <$> alloc
        "ImGuiBackend"
        (Backend.initImGuiBackend rlcWindow rlcInstance rlcPhysicalDevice device (fromIntegral graphicsQueueFamilyIndex) graphicsQueueHandler imGuiDescriptorPool imGuiRenderPass 2 3)
        Backend.shutdownImGuiBackend
  logInfo LogGeneral "Dear ImGui initialized"

  textureCommandBuffer <- CommandBuffer.createCommandBuffer device graphicsCommandPool
  logDebug LogTexture "textureCommandBuffer created"

  let vulkanContext = VulkanContext device rlcPhysicalDevice graphicsQueueHandler textureCommandBuffer

  iblTextures <- loadIBLTextures vulkanContext rm rlcEnvMapDir rlcProceduralSkyEnabled
  let IBLTextures {..} = iblTextures

  assetCache <- initCache ".haskan2-cache"

  sceneResult <- loadScene vulkanContext rm assetCache rlcMeshName rlcUvCheckMode rlcSimpleMesh
  let SceneLoadResult {..} = sceneResult
      isStressTest = rlcMeshName == "stress_test"
      ecsWorld = slrECSWorld
      sceneBounds = slrSceneBounds
      texturePixelMap = slrTexturePixelMap

  -- Write physics body specs from scene description
  liftIO $ STM.atomically $ STM.writeTVar (physicsPendingSpecs rlcGameState) slrPhysicsSpecs

  worldState <- liftIO $ STM.readTVarIO (world rlcGameState)
  let tvCamera = activeCamera worldState
  currentCam <- liftIO $ STM.readTVarIO tvCamera
  unless rlcCloudTestMode $ do
    let adjustedCam =
          if isStressTest
            then setDistance (setTarget currentCam (V3 0 0 0 :: V3 Foreign.C.CFloat)) (150.0 :: Foreign.C.CFloat)
            else adjustCameraForScene sceneBounds currentCam
        finalCam = case rlcUvCheckMode of
          Just _ -> setAngles (setDistance (setTarget adjustedCam (V3 0 0 0 :: V3 Foreign.C.CFloat)) 2.0) 0.78 (realToFrac (pi / 6 :: Double))
          Nothing -> setAngles adjustedCam 0 (realToFrac (pi / 6 :: Double))
    liftIO $ STM.atomically $ STM.writeTVar tvCamera finalCam
    logInfo LogGeneral $ "camera adjusted to distance=" <> showT (Camera.cameraDistance finalCam)

  when isStressTest $ liftIO $ STM.atomically $ STM.writeTVar (wireframeEnabled rlcGameState) False

  initialDrawList <- extractDrawList ecsWorld rm IntMap.empty
  let numDrawEntities = length initialDrawList
  logInfo LogRender $ "initial draw list has " <> showT numDrawEntities <> " entities"

  liftIO $ do
    let meshHandles = nub (map (mrHandle . dcMesh) initialDrawList)
    unless (null meshHandles) $ do
      (mergedMesh, offsets) <- Buffer.mergeMeshes rm rlcPhysicalDevice device meshHandles
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
      Buffer.managedUniformBuffer rlcPhysicalDevice device initialViewProjData
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

  (entitySsboBuffer, entitySsboMemory) <- Buffer.managedStorageBuffer rlcPhysicalDevice device (replicate maxEntities dummyEntityData) Vulkan.VK_ZERO_FLAGS
  (drawCommandsBuffer, drawCommandsMemory) <- Buffer.managedStorageBuffer rlcPhysicalDevice device initialDrawCommands Vulkan.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT
  (cullDataBuffer, cullDataMemory) <- Buffer.managedUniformBuffer rlcPhysicalDevice device [dummyCullData]

  let maxLights = 256 :: Int
      dummyLightData = LightData (V3 0 0 0) 0.0 (V3 0 0 0) 0 (V3 0 0 0) 0.0
  (lightSsboBuffer, lightSsboMemory) <- Buffer.managedStorageBuffer rlcPhysicalDevice device (replicate maxLights dummyLightData) Vulkan.VK_ZERO_FLAGS
  logDebug LogBuffer $ "light SSBO created: " <> showT (maxLights * sizeOf (undefined :: LightData)) <> " bytes"

  logDebug LogBuffer $ "compute buffers created: entitySSBO=" <> showT (maxEntities * sizeOf (undefined :: ComputeEntityData)) <> " drawCommands=" <> showT (maxEntities * sizeOf (undefined :: DrawIndexedIndirectCommand)) <> " cullData=" <> showT (sizeOf (undefined :: ComputeCullData))

  DescriptorSet.updateComputeDescriptorSets $
    DescriptorSet.ComputeDescriptorUpdate
      { cpduDevice = device,
        cpduDescriptorSet = computeDescriptorSet,
        cpduEntitiesBuffer = entitySsboBuffer,
        cpduDrawCommandsBuffer = drawCommandsBuffer,
        cpduCullDataBuffer = cullDataBuffer
      }
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
        whiteHandle <- Texture.createTextureFromData rm (VulkanContext device rlcPhysicalDevice graphicsQueueHandler textureCommandBuffer) 2 2 whiteTexData
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
          texHandle' <- Texture.createTextureFromDataSRGB rm (VulkanContext device rlcPhysicalDevice graphicsQueueHandler textureCommandBuffer) tw th pixelData
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
    DescriptorSet.updateDescriptorSetsBindless $
      DescriptorSet.BindlessDescriptorUpdate
        { bduDevice = device,
          bduDescriptorSet = ds,
          bduBuffer = buf,
          bduRange = fromIntegral viewProjUniformSize,
          bduSampler = textureSampler,
          bduImageViews = bindlessTextureViews,
          bduEntityBuffer = entitySsboBuffer
        }
  logInfo LogVulkan "frame descriptor sets updated"

  logInfo LogRender "all resources created, entering render loop"
  liftIO $ putMVar rlcReadySemaphore ()

  let mkRenderContext =
        Render.createRenderContext
          Render.RenderContextConfig
            { Render.rccPhysicalDevice = rlcPhysicalDevice,
              Render.rccDevice = device,
              Render.rccSurface = rlcSurface,
              Render.rccPipelineLayout = pipelineLayout,
              Render.rccVertexShader = shpVertex smForward,
              Render.rccFragmentShader = shpFragment smForward,
              Render.rccDescriptorSets = [],
              Render.rccCommandPool = graphicsCommandPool,
              Render.rccGraphicsQueue = graphicsQueueHandler,
              Render.rccPresentQueue = presentQueueHandler,
              Render.rccRenderFinishedFences = renderFinishedFences,
              Render.rccRenderFinishedSemaphores = renderFinishedSemaphores
            }
      mkSimpleRenderContext =
        Render.createRenderContext
          Render.RenderContextConfig
            { Render.rccPhysicalDevice = rlcPhysicalDevice,
              Render.rccDevice = device,
              Render.rccSurface = rlcSurface,
              Render.rccPipelineLayout = pipelineLayout,
              Render.rccVertexShader = shpVertex smSimpleForward,
              Render.rccFragmentShader = shpFragment smSimpleForward,
              Render.rccDescriptorSets = [],
              Render.rccCommandPool = graphicsCommandPool,
              Render.rccGraphicsQueue = graphicsQueueHandler,
              Render.rccPresentQueue = presentQueueHandler,
              Render.rccRenderFinishedFences = renderFinishedFences,
              Render.rccRenderFinishedSemaphores = renderFinishedSemaphores
            }
      isSimple = isJust rlcSimpleMesh

  worldState <- liftIO $ STM.readTVarIO (world rlcGameState)
  frameStatsRef <- liftIO $ newIORef emptyFrameStats
  let tvCamera = activeCamera worldState
      tvInspect = inspectFrame rlcGameState
      tvInsp = inspector rlcGameState
      tvRenderDebug = renderDebugState rlcGameState
      tvWireframe = wireframeEnabled rlcGameState
      tvDebugMode = debugMode rlcGameState
      tvAxisOverlay = axisOverlayEnabled rlcGameState
      tvGroundPlane = groundPlaneEnabled rlcGameState
      tvPendingScreenshot = pendingScreenshot rlcGameState
      tvPendingAllStages = pendingAllStages rlcGameState
      tvPendingSwapchainScreenshot = pendingSwapchainScreenshot rlcGameState
      tvLights = lights rlcGameState
      tvTimeOfDay = gameTimeOfDay rlcGameState
      tvTimeSpeed = gameTimeSpeed rlcGameState
      tvDayNightEnabled = gameDayNightEnabled rlcGameState
      tvCloudHeight = cloudHeight rlcGameState
      tvWindDirection = windDirection rlcGameState
      tvWindSpeed = windSpeed rlcGameState
      tvCloudCoverage = cloudCoverage rlcGameState
      tvCloudDetail = cloudDetail rlcGameState
      tvCloudAbsorption = cloudAbsorption rlcGameState
      tvWeatherCoverageScale = weatherCoverageScale rlcGameState
      tvWeatherTypeBias = weatherTypeBias rlcGameState
      tvStormIntensity = stormIntensity rlcGameState
      tvWeatherAnimSpeed = weatherAnimSpeed rlcGameState
      frameMvpMemories = map snd frameMvpBuffers
      outerLoop :: (MonadFail m, MonadIO m) => Bool -> m ()
      outerLoop exit = do
        unless exit $ do
          renderFrameLoopFinished <-
            liftIO $
              if isSimple
                then with mkSimpleRenderContext $ \context -> do
                  let renderEnv =
                        RenderEnv
                          { reWindow = rlcWindow,
                            reContext = context,
                            reDeferred = undefined,
                            reTargetFPS = rlcTargetFPS,
                            reImageAvailableSemaphores = imageAvailableSemaphores,
                            reControl = control,
                            reFrameMvpMemories = frameMvpMemories,
                            reGameState =
                              GameStateTVars
                                { gstCamera = tvCamera,
                                  gstInspect = tvInspect,
                                  gstInsp = tvInsp,
                                  gstRenderDebug = tvRenderDebug,
                                  gstWireframe = tvWireframe,
                                  gstDebugMode = tvDebugMode,
                                  gstAxisOverlay = tvAxisOverlay,
                                  gstGroundPlane = tvGroundPlane,
                                  gstLights = tvLights,
                                  gstTimeOfDay = tvTimeOfDay,
                                  gstTimeSpeed = tvTimeSpeed,
                                  gstDayNightEnabled = tvDayNightEnabled
                                },
                            reECSWorld = ecsWorld,
                            reResourceManager = rm,
                            reTextureSampler = textureSampler,
                            reFrameDescriptorSets = frameDescriptorSets,
                            reTextureIndexMap = textureIndexMap,
                            reFrameStatsRef = frameStatsRef,
                            reCullResources = undefined,
                            rePhysicalDevice = rlcPhysicalDevice,
                            reLightSsboBuffer = undefined,
                            reLightSsboMemory = undefined,
                            reCloudState =
                              CloudStateTVars
                                { cstCloudHeight = tvCloudHeight,
                                  cstWindDirection = tvWindDirection,
                                  cstWindSpeed = tvWindSpeed,
                                  cstCloudCoverage = tvCloudCoverage,
                                  cstCloudDetail = tvCloudDetail,
                                  cstCloudAbsorption = tvCloudAbsorption,
                                  cstWeatherCoverageScale = tvWeatherCoverageScale,
                                  cstWeatherTypeBias = tvWeatherTypeBias,
                                  cstStormIntensity = tvStormIntensity,
                                  cstWeatherAnimSpeed = tvWeatherAnimSpeed
                                },
                            reScreenshotFlags =
                              ScreenshotFlags
                                { sfPendingScreenshot = tvPendingScreenshot,
                                  sfPendingAllStages = tvPendingAllStages,
                                  sfPendingSwapchainScreenshot = tvPendingSwapchainScreenshot
                                },
                            reSkyNoiseState =
                              SkyNoiseState
                                { snsIBLTextures = iblTextures,
                                  snsSkyNeedsRegeneration = skyNeedsRegeneration rlcGameState,
                                  snsNoiseNeedsRegeneration = noiseNeedsRegeneration rlcGameState,
                                  snsNoiseSeed = noiseSeed rlcGameState,
                                  snsNoiseFrequency = noiseFrequency rlcGameState,
                                  snsNoisePersistence = noisePersistence rlcGameState
                                },
                            rePhysicsState =
                              PhysicsStateTVars
                                { pstPhysicsBodies = physicsBodies rlcGameState,
                                  pstPhysicsBodyToEntity = physicsBodyToEntity rlcGameState,
                                  pstPhysicsAutoStep = physicsAutoStep rlcGameState,
                                  pstPhysicsTimeScale = physicsTimeScale rlcGameState
                                },
                            reTemporalState = TemporalState {tsPrevViewProj = [], tsPrevTime = []},
                            reImGuiBackend = Nothing,
                            reSimpleMode = True
                          }
                  renderFrameLoop renderEnv 0
                else with mkRenderContext $ \context -> do
                  cloudSpecInfo <- liftIO $ mallocSpecializationInfo $
                    SpecializationData [SpecEntry 0 (packFloat 96.0)]
                  apVolumeSpecInfo <- liftIO $ mallocSpecializationInfo $
                    SpecializationData
                      [ SpecEntry 0 (packFloat 0.0003)
                      , SpecEntry 1 (packFloat 0.76)
                      ]
                  lightingSpecInfo <- liftIO $ mallocSpecializationInfo $
                    SpecializationData
                      [ SpecEntry 0 (packFloat 0.1)
                      , SpecEntry 1 (packFloat 10000.0)
                      ]
                  let dcfg =
                        Deferred.DeferredConfig
                          { Deferred.dcPhysicalDevice = rlcPhysicalDevice,
                            Deferred.dcDevice = device,
                            Deferred.dcRenderContext = context,
                            Deferred.dcBindlessDescSetLayout = descriptorSetLayout,
                            Deferred.dcShaders =
                              Deferred.DeferredShaders
                                { Deferred.dsGBuffer = ShaderProgram (shpVertex smGBuffer) Nothing Nothing Nothing (shpFragment smGBuffer) Nothing,
                                  Deferred.dsLighting = ShaderProgram (shpVertex smLighting) Nothing Nothing Nothing (if rlcProceduralSkyEnabled then smLightingProcedural else shpFragment smLighting) (Just lightingSpecInfo),
                                  Deferred.dsWireframe = ShaderProgram (wsVertex smWireframe) Nothing Nothing (wsGeometry smWireframe) (wsFragment smWireframe) Nothing,
                                  Deferred.dsCloud = ShaderProgram (shpVertex smCloud) Nothing Nothing Nothing (shpFragment smCloud) (Just cloudSpecInfo),
                                  Deferred.dsGodRay = ShaderProgram (shpVertex smGodRay) Nothing Nothing Nothing (shpFragment smGodRay) Nothing,
                                  Deferred.dsAPVolume = smAPVolume,
                                  Deferred.dsAPVolumeSpecInfo = Just apVolumeSpecInfo,
                                  Deferred.dsBindless = ShaderProgram (shpVertex smBindless) Nothing Nothing Nothing (shpFragment smBindless) Nothing
                                },
                            Deferred.dcIBL =
                              Deferred.IBLResources
                                { Deferred.irRadianceView = cmView iblRadiance,
                                  Deferred.irIrradianceView = cmView iblIrradiance,
                                  Deferred.irBrdfView = iblBrdfView,
                                  Deferred.irSampler = iblSampler
                                },
                            Deferred.dcCloudTextures =
                              Deferred.CloudTextures
                                { Deferred.ctNoiseView = cmView iblCloudNoise,
                                  Deferred.ctBlueNoiseView = iblBlueNoiseView,
                                  Deferred.ctWeatherMapView = iblWeatherMapView,
                                  Deferred.ctBlueNoiseSampler = iblBlueNoiseSampler,
                                  Deferred.ctNoiseSampler = iblNoiseSampler
                                },
                            Deferred.dcLightBuffer = Just lightSsboBuffer,
                            Deferred.dcImGuiRenderPass = imGuiRenderPass,
                            Deferred.dcProceduralSky = rlcProceduralSkyEnabled
                          }
                  with (Deferred.createDeferredResources dcfg) $ \dr -> do
                    let numSwapchainImages = length (drCloudImages dr)
                    prevViewProjTVars <- replicateM numSwapchainImages (STM.newTVarIO (identity :: M44 Foreign.C.CFloat))
                    prevTimeTVars <- replicateM numSwapchainImages (STM.newTVarIO 0.0)
                    let renderEnv =
                          RenderEnv
                            { reWindow = rlcWindow,
                              reContext = context,
                              reDeferred = dr,
                              reTargetFPS = rlcTargetFPS,
                              reImageAvailableSemaphores = imageAvailableSemaphores,
                              reControl = control,
                              reFrameMvpMemories = frameMvpMemories,
                              reGameState =
                                GameStateTVars
                                  { gstCamera = tvCamera,
                                    gstInspect = tvInspect,
                                    gstInsp = tvInsp,
                                    gstRenderDebug = tvRenderDebug,
                                    gstWireframe = tvWireframe,
                                    gstDebugMode = tvDebugMode,
                                    gstAxisOverlay = tvAxisOverlay,
                                    gstGroundPlane = tvGroundPlane,
                                    gstLights = tvLights,
                                    gstTimeOfDay = tvTimeOfDay,
                                    gstTimeSpeed = tvTimeSpeed,
                                    gstDayNightEnabled = tvDayNightEnabled
                                  },
                              reECSWorld = ecsWorld,
                              reResourceManager = rm,
                              reTextureSampler = textureSampler,
                              reFrameDescriptorSets = frameDescriptorSets,
                              reTextureIndexMap = textureIndexMap,
                              reFrameStatsRef = frameStatsRef,
                              reCullResources = computeCullResources,
                              rePhysicalDevice = rlcPhysicalDevice,
                              reLightSsboBuffer = lightSsboBuffer,
                              reLightSsboMemory = lightSsboMemory,
                              reCloudState =
                                CloudStateTVars
                                  { cstCloudHeight = tvCloudHeight,
                                    cstWindDirection = tvWindDirection,
                                    cstWindSpeed = tvWindSpeed,
                                    cstCloudCoverage = tvCloudCoverage,
                                    cstCloudDetail = tvCloudDetail,
                                    cstCloudAbsorption = tvCloudAbsorption,
                                    cstWeatherCoverageScale = tvWeatherCoverageScale,
                                    cstWeatherTypeBias = tvWeatherTypeBias,
                                    cstStormIntensity = tvStormIntensity,
                                    cstWeatherAnimSpeed = tvWeatherAnimSpeed
                                  },
                              reScreenshotFlags =
                                ScreenshotFlags
                                  { sfPendingScreenshot = tvPendingScreenshot,
                                    sfPendingAllStages = tvPendingAllStages,
                                    sfPendingSwapchainScreenshot = tvPendingSwapchainScreenshot
                                  },
                              reSkyNoiseState =
                                SkyNoiseState
                                  { snsIBLTextures = iblTextures,
                                    snsSkyNeedsRegeneration = skyNeedsRegeneration rlcGameState,
                                    snsNoiseNeedsRegeneration = noiseNeedsRegeneration rlcGameState,
                                    snsNoiseSeed = noiseSeed rlcGameState,
                                    snsNoiseFrequency = noiseFrequency rlcGameState,
                                    snsNoisePersistence = noisePersistence rlcGameState
                                  },
                              rePhysicsState =
                                PhysicsStateTVars
                                  { pstPhysicsBodies = physicsBodies rlcGameState,
                                    pstPhysicsBodyToEntity = physicsBodyToEntity rlcGameState,
                                    pstPhysicsAutoStep = physicsAutoStep rlcGameState,
                                    pstPhysicsTimeScale = physicsTimeScale rlcGameState
                                  },
                              reTemporalState = TemporalState {tsPrevViewProj = prevViewProjTVars, tsPrevTime = prevTimeTVars},
                              reImGuiBackend = mImGuiBackend,
                              reSimpleMode = False
                            }
                    renderFrameLoop renderEnv 0
          outerLoop renderFrameLoopFinished

  logInfo LogGeneral "Starting render loop"
  outerLoop False

  logInfo LogGeneral "renderLoop finished"
  destroyAllResources rm
