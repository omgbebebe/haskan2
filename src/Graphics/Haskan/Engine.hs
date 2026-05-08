{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Engine where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (STM)
import Control.Concurrent.STM qualified as STM
import Control.Concurrent.STM.TChan (TChan)
import Control.Concurrent.STM.TChan qualified as TChan
import Control.Concurrent.STM.TQueue (TQueue)
import Control.Concurrent.STM.TQueue qualified as TQueue
import Control.Concurrent.STM.TVar (TVar)
import Control.Monad (forM, forM_, replicateM, unless, when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged, runManaged, with)
import Data.Aeson (ToJSON (..), object, (.=))
import Data.Foldable (for_)
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HashMap
import Data.Hashable (Hashable (..))
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (nub, sort)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector.Storable qualified as Vector
import Data.Word (Word32)

import FIR qualified
import Foreign.C qualified
import Foreign.Marshal.Array qualified
import Foreign.Storable (Storable (..), peekByteOff, pokeByteOff)
import GHC.Generics
import Graphics.Haskan.Camera (Camera (..))
import Graphics.Haskan.Camera qualified as Camera
import Graphics.Haskan.Debug.FrameInspector (FrameInspector, RenderableSnapshot (..), defaultInspector, buildFrameSnapshot)
import Graphics.Haskan.Debug.Interface (DebugCommand (..), DebugMessage (..), DebugResponse (..), GameStateSnapshot (..), DebugCameraSnapshot (..), debugMessageToActionEvent, parseDebugMessage, encodeDebugResponse)
import Graphics.Haskan.Debug.Server (DebugServerHandle, CommandQueue, startDebugServer, stopDebugServer)
import Graphics.Haskan.Input (Action (..), ActionEvent, payloadToActionEvent)
import Graphics.Haskan.Logger (logInfoIO, logDebugIO, showT, LogCategory(..))
import Graphics.Haskan.Mesh qualified as Mesh
import Graphics.Haskan.Model qualified as Model
import Graphics.Haskan.Render.RenderSystem (DrawCall (..), extractDrawList)
import Graphics.Haskan.Render.Graph qualified as Graph
import Graphics.Haskan.Render.Graph (PassContext (..), PassRecordFunc (..), RenderPassNode (..))
import Graphics.Haskan.Render.Deferred (DeferredPassData (..), buildDeferredGraph)
import Graphics.Haskan.Render.Forward (ForwardPassData (..), buildForwardGraph)
import Graphics.Haskan.Scene.ECS qualified as ECS
import Graphics.Haskan.Scene.GLTF (GLTFImportResult (..), importGLTF)
import Graphics.Haskan.Scene.Transform (Transform (..), defaultTransform, tPosition)
import Graphics.Haskan.Assets.Cache (initCache)
import Graphics.Haskan.BoundingBox (BBox (..), bboxDiagonal, emptyBBox, fromPoints, mergeBBox, mergePoint)
import Graphics.Haskan.Resources (throwVkResult)
import Graphics.Haskan.Utils.ObjLoader qualified as ObjLoader
import Graphics.Haskan.Vertex (Vertex (..))
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
import Graphics.Haskan.Vulkan.Instance qualified as Instance
import Graphics.Haskan.Vulkan.PhysicalDevice qualified as PhysicalDevice
import Graphics.Haskan.Vulkan.PipelineLayout qualified as PipelineLayout
import Graphics.Haskan.Vulkan.Render (drawFrame, presentFrame)
import Graphics.Haskan.Vulkan.Render qualified as Render
import Graphics.Haskan.Vulkan.RenderPass qualified as RenderPass
import Graphics.Haskan.Vulkan.GraphicsPipeline qualified as GraphicsPipeline
import Graphics.Haskan.Vulkan.Resources
import Graphics.Haskan.Vulkan.Semaphore qualified as Semaphore
import Graphics.Haskan.Vulkan.ShaderModule qualified as ShaderModule
import Graphics.Haskan.Vulkan.Shaders.Deferred.GBuffer qualified as GBufferShaders
import Graphics.Haskan.Vulkan.Shaders.Deferred.Lighting qualified as LightingShaders
import Graphics.Haskan.Vulkan.Shaders.Wireframe qualified as WireframeShaders
import Graphics.Haskan.Vulkan.Shaders.Texture qualified as Shaders
import Graphics.Haskan.Vulkan.Shaders.Compute.Cull qualified as CullShaders
import Graphics.Haskan.Vulkan.Texture qualified as Texture
import Graphics.Haskan.Vulkan.Types (RenderContext (..))
import Graphics.Haskan.Window qualified as Window
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Ext qualified as Vulkan
import Graphics.Vulkan.Marshal.Create qualified as Vulkan
import Linear (M44, V2 (..), V3 (..), V4 (..))
import Linear.Matrix (identity, transpose, (!*), (!*!))
import Linear.Projection qualified
import Linear.Quaternion (Quaternion (..))
import SDL qualified
import System.IO.Unsafe (unsafePerformIO)
import System.Clock (Clock (..), getTime, toNanoSecs)

toListOfV4 :: V4 (V4 a) -> [[a]]
toListOfV4 (V4 r1 r2 r3 r4) = [toList r1, toList r2, toList r3, toList r4]
  where
    toList (V4 a b c d) = [a, b, c, d]

-- | Compute culling entity data (matches shader EntityData, Base/std430 layout).
-- Array stride is 128 bytes (124-byte struct + 4 bytes padding).
data ComputeEntityData = ComputeEntityData
  { ceTransform :: M44 Foreign.C.CFloat
  , ceAabbMin :: V4 Foreign.C.CFloat
  , ceAabbMax :: V4 Foreign.C.CFloat
  , ceMaterialIndex :: Word32
  , cePad :: V3 Word32
  } deriving (Show)

instance Storable ComputeEntityData where
  sizeOf _ = 128
  alignment _ = 16
  peek ptr = ComputeEntityData
    <$> peekByteOff ptr 0
    <*> peekByteOff ptr 64
    <*> peekByteOff ptr 80
    <*> peekByteOff ptr 96
    <*> peekByteOff ptr 112
  poke ptr (ComputeEntityData t amin amax mat pad) = do
    pokeByteOff ptr 0 t
    pokeByteOff ptr 64 amin
    pokeByteOff ptr 80 amax
    pokeByteOff ptr 96 mat
    pokeByteOff ptr 112 pad

-- | Compute culling uniform data (matches shader CullData, Extended/std140 layout).
data ComputeCullData = ComputeCullData
  { ccFrustumPlanes :: [V4 Foreign.C.CFloat]  -- 6 planes
  , ccEntityCount :: Word32
  , ccPad2 :: V3 Word32
  } deriving (Show)

instance Storable ComputeCullData where
  sizeOf _ = 128
  alignment _ = 16
  peek ptr = do
    planes <- sequence [peekByteOff ptr (i * 16) | i <- [0..5]]
    count <- peekByteOff ptr 96
    pad <- peekByteOff ptr 112
    pure (ComputeCullData planes count pad)
  poke ptr (ComputeCullData planes count pad) = do
    forM_ (zip [0..5] planes) $ \(i, p) -> pokeByteOff ptr (i * 16) p
    pokeByteOff ptr 96 count
    pokeByteOff ptr 112 pad

-- | Resources for GPU-driven compute culling.
data ComputeCullResources = ComputeCullResources
  { ccrPipeline :: Vulkan.VkPipeline
  , ccrPipelineLayout :: Vulkan.VkPipelineLayout
  , ccrDescriptorSet :: Vulkan.VkDescriptorSet
  , ccrEntityBuffer :: Vulkan.VkBuffer
  , ccrEntityMemory :: Vulkan.VkDeviceMemory
  , ccrVisibleFlagsBuffer :: Vulkan.VkBuffer
  , ccrVisibleFlagsMemory :: Vulkan.VkDeviceMemory
  , ccrCullDataBuffer :: Vulkan.VkBuffer
  , ccrCullDataMemory :: Vulkan.VkDeviceMemory
  , ccrMaxEntities :: Int
  }

data EngineConfig = EngineConfig
  { targetRenderFPS :: !Integer,
    targetPhysicsFPS :: !Integer,
    targetNetworkFPS :: !Integer,
    targetInputFPS :: !Integer,
    title :: !Text,
    debugSocketPath :: !(Maybe FilePath),
    timeoutSeconds :: !(Maybe Integer)
  }
  deriving (Show)

data FrameTime = FrameTime
  { lastTime :: !Integer,
    currentTime :: !Integer,
    deltaTime :: !Integer
  }
  deriving (Show)

-- | Accumulated frame timing statistics for performance baseline.
data FrameStats = FrameStats
  { fsFrameCount :: !Int,        -- ^ Frames since last log
    fsAccumTime :: !Integer,     -- ^ Accumulated frame time (ns)
    fsMinTime :: !Integer,       -- ^ Minimum frame time (ns)
    fsMaxTime :: !Integer,       -- ^ Maximum frame time (ns)
    fsTotalFrames :: !Int        -- ^ Total frames rendered
  }

emptyFrameStats :: FrameStats
emptyFrameStats = FrameStats 0 0 999999999999 0 0

-- | Update frame stats with a new frame time. Returns stats and maybe a log message.
updateFrameStats :: FrameStats -> Integer -> (FrameStats, Maybe Text)
updateFrameStats stats frameTime =
  let count = fsFrameCount stats + 1
      accum = fsAccumTime stats + frameTime
      minT = min (fsMinTime stats) frameTime
      maxT = max (fsMaxTime stats) frameTime
      total = fsTotalFrames stats + 1
      newStats = FrameStats count accum minT maxT total
  in if count >= 60
       then let avg = accum `div` fromIntegral count
                avgMs = fromIntegral avg / 1_000_000 :: Double
                minMs = fromIntegral minT / 1_000_000 :: Double
                maxMs = fromIntegral maxT / 1_000_000 :: Double
                fps = 1_000_000_000.0 / fromIntegral avg :: Double
                msg = Text.pack $
                  "Frame stats [last 60 frames]: avg=" ++ show avgMs ++ "ms, min=" ++ show minMs ++ "ms, max=" ++ show maxMs ++ "ms, fps=" ++ show fps
                          ++ " | total frames=" ++ show total
            in (FrameStats 0 0 999999999999 0 total, Just msg)
       else (newStats, Nothing)

type Position = V3 Float

type Distance = Float

data WorldState cam = WorldState
  { activeCamera :: TVar cam
  }

data GameState cam = GameState
  { world :: TVar (WorldState cam),
    isRunning :: TVar Bool,
    moveForward :: TVar Bool,
    moveBackward :: TVar Bool,
    strafeLeft :: TVar Bool,
    strafeRight :: TVar Bool,
    inspectFrame :: TVar Bool,
    inspector :: TVar (Maybe FrameInspector),
    renderDebugState :: TVar (Maybe RenderDebugInfo),
    wireframeEnabled :: TVar Bool
  }

data RenderDebugInfo = RenderDebugInfo
  { rdiFrameNumber :: Int,
    rdiCameraPos :: V3 Float,
    rdiCameraTarget :: V3 Float,
    rdiProjectionMatrix :: [[Float]],
    rdiEntities :: [EntityDebugInfo]
  }
  deriving (Show)

data EntityDebugInfo = EntityDebugInfo
  { ediEntityId :: Int,
    ediWorldMatrix :: [[Float]],
    ediPosition :: V3 Float,
    ediSampleVerticesNDC :: [V3 Float]
  }
  deriving (Show)

instance ToJSON RenderDebugInfo where
  toJSON r =
    object
      [ "frame_number" .= rdiFrameNumber r,
        "camera_pos" .= rdiCameraPos r,
        "camera_target" .= rdiCameraTarget r,
        "projection_matrix" .= rdiProjectionMatrix r,
        "entities" .= rdiEntities r
      ]

instance ToJSON EntityDebugInfo where
  toJSON e =
    object
      [ "entity_id" .= ediEntityId e,
        "world_matrix" .= ediWorldMatrix e,
        "position" .= ediPosition e,
        "sample_vertices_ndc" .= ediSampleVerticesNDC e
      ]

data ControlMessage
  = Terminate

-- | The main loop that runs the game engine. It initializes systems like the window, 
-- rendering, input handling, and game state update. It launches separate threads for 
-- rendering, game state updates, and input handling, and synchronizes between them using 
-- channels and MVars. The function takes the mesh name to render and engine configuration
-- as arguments. It sets up the initial game state with default values.
mainLoop :: MonadIO m => String -> EngineConfig -> m ()
mainLoop meshName EngineConfig {..} = do
  logInfoIO LogGeneral "starting mainLoop"
  camera <- liftIO $ STM.newTVarIO (Camera.defaultOrbitalCamera)
  isRunning <- liftIO $ STM.newTVarIO True

  controlChannel <- liftIO $ TChan.newBroadcastTChanIO
  worldState <- liftIO $ STM.newTVarIO (WorldState camera)
  actionQueue <- liftIO $ STM.newTQueueIO
  debugCmdQueue <- liftIO $ STM.newTQueueIO
  -- movement state
  tvMoveForward <- liftIO $ STM.newTVarIO (False)
  tvMoveBackward <- liftIO $ STM.newTVarIO (False)
  tvStrafeLeft <- liftIO $ STM.newTVarIO (False)
  tvStrafeRight <- liftIO $ STM.newTVarIO (False)

  tvInspectFrame <- liftIO $ STM.newTVarIO False
  tvInspector <- liftIO $ STM.newTVarIO (Just (defaultInspector "snapshots"))
  tvRenderDebugState <- liftIO $ STM.newTVarIO Nothing
  tvWireframeEnabled <- liftIO $ STM.newTVarIO True

  let gameState =
        GameState
          worldState
          isRunning
          tvMoveForward
          tvMoveBackward
          tvStrafeLeft
          tvStrafeRight
          tvInspectFrame
          tvInspector
          tvRenderDebugState
          tvWireframeEnabled

  -- Start debug server if configured
  mDebugServer <- case debugSocketPath of
    Just path -> do
      h <- startDebugServer path actionQueue debugCmdQueue
      logInfoIO LogGeneral $ "debug server listening on " <> Text.pack path
      pure (Just h)
    Nothing -> pure Nothing

  -- Start timeout timer if configured
  case timeoutSeconds of
    Just seconds | seconds > 0 -> do
      logInfoIO LogGeneral $ "timeout set to " <> showT seconds <> " seconds"
      _ <- liftIO $ forkIO $ do
        threadDelay (fromIntegral seconds * 1000000)
        logInfoIO LogGeneral "timeout reached, sending Terminate"
        STM.atomically $ TChan.writeTChan controlChannel Terminate
      pure ()
    _ -> pure ()

  SDL.initialize @[] [SDL.InitEvents]

  logInfoIO LogGeneral "Initialize base Render context"
  let initWidth = 1920
      initHeight = 1080
  window <- Window.createWindow title (initWidth, initHeight)
  windowExts <- Window.windowExtensions window
  (inst, layers) <- Instance.createInstance windowExts
  surface <- Window.createSurface inst window
  physicalDevice <- PhysicalDevice.selectPhysicalDevice inst
  Window.showWindow window

  renderLoopFinished <- liftIO $ newEmptyMVar
  _ <- liftIO $ forkIO $ runManaged $ renderLoop physicalDevice surface layers targetRenderFPS gameState renderLoopFinished controlChannel meshName

  stateUpdateLoopFinished <- liftIO $ newEmptyMVar
  _ <- liftIO $ forkIO $ stateUpdateLoop targetPhysicsFPS gameState stateUpdateLoopFinished actionQueue debugCmdQueue controlChannel

  let inputLoop :: MonadIO m => m ()
      inputLoop = do
        events <- SDL.pollEvents
        let actionEvents = catMaybes $ map (payloadToActionEvent . SDL.eventPayload) events
            quitting = (Escape, True) `elem` actionEvents
        liftIO $ STM.atomically $ for_ actionEvents $ TQueue.writeTQueue actionQueue
        running <- liftIO $ STM.readTVarIO isRunning
        SDL.delay 20
        unless (quitting || not running) inputLoop

  inputLoop
  logInfoIO LogGeneral "sending Terminate message"
  liftIO $ STM.atomically $ TChan.writeTChan controlChannel Terminate
  logInfoIO LogGeneral "waiting for other threads finished"
  liftIO $ mapM_ takeMVar [renderLoopFinished, stateUpdateLoopFinished]

  -- Stop debug server
  liftIO $ for_ mDebugServer stopDebugServer

  logInfoIO LogGeneral "destroying SDL window"
  SDL.destroyWindow window
  SDL.quit
  logInfoIO LogGeneral "mainLoop finished"

-- | Render a frame in the render loop. Checks for control messages, gets the 
-- current camera state, updates the uniform buffer, draws the frame, presents 
-- it, and handles restarting/terminating conditions.
renderFrameLoop ::
  (MonadFail m, MonadIO m, Camera cam) =>
  RenderContext ->
  DeferredResources ->
  Int ->
  Integer ->
  [Vulkan.VkSemaphore] ->
  TChan ControlMessage ->
  [Vulkan.VkDeviceMemory] ->
  TVar cam ->
  STM.TVar Bool ->
  STM.TVar (Maybe FrameInspector) ->
  STM.TVar (Maybe RenderDebugInfo) ->
  ECS.World ->
  ResourceManager ->
  Int ->
  Vulkan.VkSampler ->
  [Vulkan.VkDescriptorSet] ->
  IntMap Word32 ->
  STM.TVar Bool ->
  IORef FrameStats ->
  ComputeCullResources ->
  m Bool
renderFrameLoop ctx@RenderContext {..} dr@DeferredResources {..} frameNumber targetFPS imageAvailableSemaphores control frameMvpMemories tvCamera tvInspect tvInsp tvRenderDebug ecsWorld rm entityUniformSize textureSampler frameDescriptorSets textureIndexMap tvWireframe frameStatsRef ccr@ComputeCullResources {..} = do
  frameStartTime <- liftIO $ toNanoSecs <$> getTime Monotonic
  maybeControlMessage <- liftIO $ STM.atomically $ TChan.tryReadTChan control
  (needRestart, terminating) <- case maybeControlMessage of
    Nothing -> do
      let imageAvailableSemaphore = imageAvailableSemaphores !! (frameNumber)
          mvpMemory = frameMvpMemories !! frameNumber
      camera <- liftIO $ STM.readTVarIO tvCamera
      drawList <- extractDrawList ecsWorld rm textureIndexMap
      -- Compute debug NDC positions (using transposed matrices to match GPU)
      liftIO $ do
        let camPos = realToFrac <$> Camera.cameraPosition camera
            camTarget = realToFrac <$> Camera.cameraTarget camera
            -- GPU reads matrices as column-major, so we transpose row-major Haskell matrices
            projMat = Linear.Matrix.transpose $ (realToFrac <$>) <$> projectionMatrix :: M44 Float
            viewMat = Linear.Matrix.transpose $ (realToFrac <$>) <$> Camera.unViewMatrix (Camera.toMatrix camera) :: M44 Float
            sampleLocalVerts :: [V3 Float]
            sampleLocalVerts = [V3 (-0.5) (-0.5) (-0.5), V3 0.5 (-0.5) (-0.5), V3 0.5 0.5 (-0.5), V3 (-0.5) 0.5 (-0.5),
                                V3 (-0.5) (-0.5) 0.5, V3 0.5 (-0.5) 0.5, V3 0.5 0.5 0.5, V3 (-0.5) 0.5 0.5]
            toNDC :: M44 Float -> V3 Float -> V3 Float
            toNDC mvp (V3 x y z) =
              let x', y', z' :: Float
                  x' = x; y' = y; z' = z
                  V4 cx cy cz cw = (mvp !* V4 x' y' z' 1.0) :: V4 Float
              in if abs cw > 0.001 then V3 (cx / cw) (cy / cw) (cz / cw) else V3 cx cy cz
            entityDebugInfos = zipWith (\idx dc ->
              let modelMat = Linear.Matrix.transpose $ (realToFrac <$>) <$> dcWorldMatrix dc :: M44 Float
                  mvp = projMat !*! viewMat !*! modelMat
                  ndcVerts = map (toNDC mvp) sampleLocalVerts
              in EntityDebugInfo
                  { ediEntityId = idx,
                    ediWorldMatrix = map (map realToFrac) (toListOfV4 (fmap (fmap realToFrac) modelMat)),
                    ediPosition = realToFrac <$> tPosition (dcTransform dc),
                    ediSampleVerticesNDC = ndcVerts
                  }
              ) [0..] drawList
        STM.atomically $ STM.writeTVar tvRenderDebug $ Just RenderDebugInfo
          { rdiFrameNumber = frameNumber,
            rdiCameraPos = camPos,
            rdiCameraTarget = camTarget,
            rdiProjectionMatrix = map (map realToFrac) (toListOfV4 (fmap (fmap realToFrac) projMat)),
            rdiEntities = entityDebugInfos
          }
      case drawList of
        [] -> pure (False, False)
        _ -> do
          let view = Linear.Matrix.transpose $ Camera.unViewMatrix (Camera.toMatrix camera)
              projection = Linear.Matrix.transpose projectionMatrix
          -- Update uniform buffer regions for each entity
          liftIO $ for_ (zip [0..] drawList) $ \(entityIdx, dc) -> do
            let model = Linear.Matrix.transpose $ (realToFrac <$>) <$> dcWorldMatrix dc
                offset = entityIdx * entityUniformSize
            Buffer.updateUniformBufferRegion device mvpMemory offset [model, view, projection]

          let recordAction imageIdx frameIdx = do
                let commandBuffer = graphicsCommandBuffers !! fromIntegral imageIdx
                    gBufferFramebuffer = drGBufferFramebuffers !! fromIntegral imageIdx
                    lightingFramebuffer = drLightingFramebuffers !! fromIntegral imageIdx
                    frameDescriptorSet = frameDescriptorSets !! frameIdx
                    lightingDescriptorSet = drLightingDescriptorSets !! fromIntegral imageIdx
                    gBufferImagesForFrame = drGBufferImages !! fromIntegral imageIdx
                    gBufferPassCtx = PassContext
                      { pcCommandBuffer = commandBuffer
                      , pcPipeline = drGBufferPipeline
                      , pcPipelineLayout = drGBufferPipelineLayout
                      , pcDescriptorSet = Vulkan.vkNullPtr  -- not used with per-entity sets
                      , pcFramebuffer = gBufferFramebuffer
                      , pcRenderPass = drGBufferRenderPass
                      , pcExtent = rcSurfaceExtent
                      }
                    lightingPassCtx = PassContext
                      { pcCommandBuffer = commandBuffer
                      , pcPipeline = drLightingPipeline
                      , pcPipelineLayout = drLightingPipelineLayout
                      , pcDescriptorSet = lightingDescriptorSet
                      , pcFramebuffer = lightingFramebuffer
                      , pcRenderPass = drLightingRenderPass
                      , pcExtent = rcSurfaceExtent
                      }
                wireframeEnabled' <- liftIO $ STM.readTVarIO tvWireframe

                -- Build deferred render graph for this frame
                let (graphRes, graphPasses) = Graph.execRenderGraphBuilder $
                      buildDeferredGraph DeferredPassData
                        { dpdExtent = rcSurfaceExtent
                        , dpdGBufferRenderPass = drGBufferRenderPass
                        , dpdGBufferFramebuffer = gBufferFramebuffer
                        , dpdGBufferPipeline = drGBufferPipeline
                        , dpdGBufferLayout = drGBufferPipelineLayout
                        , dpdGBufferDescriptor = frameDescriptorSet
                        , dpdGBufferSampler = textureSampler
                        , dpdDrawList = drawList
                        , dpdEntityUniformSize = entityUniformSize
                        , dpdDevice = device
                        , dpdLightingRenderPass = drLightingRenderPass
                        , dpdLightingFramebuffer = lightingFramebuffer
                        , dpdLightingPipeline = drLightingPipeline
                        , dpdLightingLayout = drLightingPipelineLayout
                        , dpdLightingDescriptor = lightingDescriptorSet
                        , dpdGBufferImages = gBufferImagesForFrame
                        , dpdWireframePipeline = drWireframePipeline
                        , dpdWireframeLayout = drWireframePipelineLayout
                        , dpdWireframeEnabled = wireframeEnabled'
                        }
                -- Compile and execute graph
                case Graph.compileGraph graphRes graphPasses of
                  Left err -> liftIO $ logInfoIO LogRender $ "graph compilation failed: " <> Text.pack (show err)
                  Right compiled -> do
                    CommandBuffer.withCommandBuffer commandBuffer $ do
                      -- Compute culling dispatch
                      let numWorkgroups = ((length drawList + 63) `div` 64)
                      when (numWorkgroups > 0) $ do
                        liftIO $ Vulkan.vkCmdBindPipeline commandBuffer Vulkan.VK_PIPELINE_BIND_POINT_COMPUTE ccrPipeline
                        liftIO $ Foreign.Marshal.Array.withArray [ccrDescriptorSet] $ \dsPtr ->
                          Vulkan.vkCmdBindDescriptorSets
                            commandBuffer
                            Vulkan.VK_PIPELINE_BIND_POINT_COMPUTE
                            ccrPipelineLayout
                            0
                            1
                            dsPtr
                            0
                            Vulkan.vkNullPtr
                        liftIO $ CommandBuffer.cmdDispatch commandBuffer (fromIntegral numWorkgroups) 1 1

                      let passes = Graph.cgPasses compiled
                      for_ passes $ \cp -> do
                        let pass = Graph.cpPass cp
                            recordFn = unPassRecordFunc (rpRecord pass)
                            passCtx = if rpName pass == "gbuffer" then gBufferPassCtx else lightingPassCtx
                        liftIO $ recordFn passCtx

          res <- liftIO $ drawFrame ctx imageAvailableSemaphore frameNumber recordAction
          case res of
            Render.FrameOk imageIndex -> do
              presentResult <- liftIO $ presentFrame ctx imageIndex (renderFinishedSemaphores !! (fromIntegral imageIndex))
              case presentResult of
                Vulkan.VK_SUCCESS -> do
                  shouldInspect <- liftIO $ STM.atomically $ do
                    b <- STM.readTVar tvInspect
                    when b $ STM.writeTVar tvInspect False
                    pure b
                  when shouldInspect $ do
                    mInsp <- liftIO $ STM.readTVarIO tvInsp
                    for_ mInsp $ \insp -> do
                      startTime <- liftIO $ getTime Monotonic
                      let snapshots = map drawCallToSnapshot drawList
                      snap <- buildFrameSnapshot (fromIntegral frameNumber) startTime ctx camera ((realToFrac <$>) <$> projectionMatrix) snapshots
                      liftIO $ insp snap
                  pure (False, False)
                Vulkan.VK_SUBOPTIMAL_KHR -> pure (True, False)
                Vulkan.VK_ERROR_OUT_OF_DATE_KHR -> pure (True, False)
                _ -> liftIO $ fail "presentFrame failed"
            Render.FrameSuboptimal _ -> do
              liftIO $ fail "suboptimal"
            Render.FrameOutOfDate -> do
              liftIO $ logInfoIO LogGeneral "resizing swapchain"
              pure (True, False)
            Render.FrameFailed err -> liftIO $ fail err
    Just Terminate -> do
      liftIO $ logInfoIO LogGeneral "terminating render loop by signal"
      pure (True, True)

  frameEndTime <- liftIO $ toNanoSecs <$> getTime Monotonic
  if needRestart
    then liftIO $ do
      logInfoIO LogGeneral "waiting IDLE state for device"
      Vulkan.vkDeviceWaitIdle device >>= throwVkResult
      logInfoIO LogGeneral "terminating renderFrameLoop"
      pure terminating
    else do
      let renderTime = frameEndTime - frameStartTime
          delay = ((1000000000 `div` targetFPS) - renderTime) `div` 1000
      liftIO $ do
        threadDelay (fromIntegral delay)
        stats <- readIORef frameStatsRef
        let (newStats, mMsg) = updateFrameStats stats renderTime
        writeIORef frameStatsRef newStats
        for_ mMsg $ \msg -> logInfoIO LogRender msg
      renderFrameLoop
        ctx
        dr
        ((frameNumber + 1) `mod` Render.maxFramesInFlight)
        targetFPS
        imageAvailableSemaphores
        control
        frameMvpMemories
        tvCamera
        tvInspect
        tvInsp
        tvRenderDebug
        ecsWorld
        rm
        entityUniformSize
        textureSampler
        frameDescriptorSets
        textureIndexMap
        tvWireframe
        frameStatsRef
        ccr

-- | Main rendering loop.
--
-- Sets up Vulkan resources like device, pipeline, buffers etc. and enters the main
-- loop which renders frames continuously.
renderLoop ::
  (Camera cam, MonadFail m, MonadManaged m, MonadIO m) =>
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkSurfaceKHR ->
  [String] ->
  Integer ->
  GameState cam ->
  MVar () ->
  TChan ControlMessage ->
  String ->
  m ()
renderLoop physicalDevice surface layers targetFPS gameState finishedSemaphore controlChannel meshName = do
  control <- liftIO $ STM.atomically $ TChan.dupTChan controlChannel

  -- Create resource manager for mesh and texture
  rm <- newResourceManager

  (device, (graphicsQueueFamilyIndex, presentQueueFamilyIndex)) <- Device.managedRenderDevice physicalDevice surface layers

  graphicsQueueHandler <- Device.getDeviceQueueHandler device graphicsQueueFamilyIndex 0
  presentQueueHandler <- Device.getDeviceQueueHandler device presentQueueFamilyIndex 0

  liftIO $ FIR.compileTo "data/shaders/fir/vert.spv" [FIR.SPIRV (FIR.Version 1 5)] Shaders.vertex
  liftIO $ FIR.compileTo "data/shaders/fir/frag.spv" [FIR.SPIRV (FIR.Version 1 5)] Shaders.fragment

  liftIO $ FIR.compileTo "data/shaders/fir/gbuf_vert.spv" [FIR.SPIRV (FIR.Version 1 5)] GBufferShaders.vertex
  liftIO $ FIR.compileTo "data/shaders/fir/gbuf_frag.spv" [FIR.SPIRV (FIR.Version 1 5)] GBufferShaders.fragment
  liftIO $ FIR.compileTo "data/shaders/fir/light_vert.spv" [FIR.SPIRV (FIR.Version 1 5)] LightingShaders.vertex
  liftIO $ FIR.compileTo "data/shaders/fir/light_frag.spv" [FIR.SPIRV (FIR.Version 1 5)] LightingShaders.fragment

  liftIO $ FIR.compileTo "data/shaders/fir/wire_vert.spv" [FIR.SPIRV (FIR.Version 1 5)] WireframeShaders.vertex
  liftIO $ FIR.compileTo "data/shaders/fir/wire_geom.spv" [FIR.SPIRV (FIR.Version 1 5)] WireframeShaders.geometry
  liftIO $ FIR.compileTo "data/shaders/fir/wire_frag.spv" [FIR.SPIRV (FIR.Version 1 5)] WireframeShaders.fragment

  liftIO $ FIR.compileTo "data/shaders/fir/cull_comp.spv" [FIR.SPIRV (FIR.Version 1 5)] CullShaders.program

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

  -- Compute culling infrastructure
  computeDescriptorSetLayout <- DescriptorSetLayout.managedComputeDescriptorSetLayout device
  computePipelineLayout <- PipelineLayout.managedPipelineLayout device [computeDescriptorSetLayout]
  computePipeline <- ComputePipeline.managedComputePipeline device computePipelineLayout cullShader
  computeDescriptorPool <- DescriptorPool.managedComputeDescriptorPool device
  computeDescriptorSet <- DescriptorSet.allocateDescriptorSet device computeDescriptorPool [computeDescriptorSetLayout]

  imageAvailableSemaphores <- replicateM Render.maxFramesInFlight (Semaphore.managedSemaphore device)
  renderFinishedSemaphores <- replicateM 4 (Semaphore.managedSemaphore device)
  renderFinishedFences <- replicateM Render.maxFramesInFlight (Fence.managedFence device)

  -- Create texture command buffer early (needed for both glTF and OBJ paths)
  textureCommandBuffer <- CommandBuffer.createCommandBuffer device graphicsCommandPool
  logDebugIO LogTexture "textureCommandBuffer created"

  -- Initialize asset cache for texture preprocessing
  assetCache <- initCache ".haskan2-cache"

  let isGLTF = ".gltf" `Text.isSuffixOf` Text.pack meshName || ".glb" `Text.isSuffixOf` Text.pack meshName

  -- Create ECS World and load scene
  (ecsWorld, numEntities, sceneBounds, texturePixelMap) <- if isGLTF
    then do
      -- Load glTF scene
      result <- importGLTF rm physicalDevice device graphicsQueueHandler textureCommandBuffer assetCache meshName
      let world = girWorld result
          meshes = girMeshes result
          textures = girTextures result
          textureData = girTextureData result
          -- Build a map from TextureHandle ID to (width, height, pixels)
          pixelMap = IntMap.fromList $
            zip (map (fromIntegral . unTextureHandle) textures) textureData

      -- Compute scene bounding box from all mesh vertices
      let sceneBbox = computeSceneBounds meshes rm
      logInfoIO LogGeneral $ "scene bounds: " <> showT sceneBbox

      -- Add ground plane with checkerboard texture
      let groundMesh = Mesh.groundPlaneMesh 50.0
      groundMeshHandle <- Buffer.createMeshResource rm physicalDevice device (Mesh.vertices groundMesh) (Mesh.indices groundMesh)
      let checkerTexData = Texture.generateCheckerboardTexture 256 256 32
      checkerTexHandle <- Texture.createTextureFromData rm physicalDevice device 256 256 checkerTexData graphicsQueueHandler textureCommandBuffer
      groundEntity <- ECS.spawnEntity world
      ECS.setTransform world groundEntity (Transform (V3 0 0 (-0.5)) (Quaternion 1 (V3 0 0 0)) (V3 1 1 1))
      ECS.setMesh world groundEntity groundMeshHandle
      ECS.setMaterial world groundEntity checkerTexHandle

      pure (world, length meshes + 1, sceneBbox, pixelMap)
    else do
      -- Load OBJ model (original behavior)
      world <- ECS.createWorld
      (mesh, _) <- Model.fromObj <$> ObjLoader.parseObj ("data/models/obj/" <> meshName)
      meshHandle <- Buffer.createMeshResource rm physicalDevice device (Mesh.vertices mesh) (Mesh.indices mesh)

      -- Compute bounds from OBJ mesh
      let objBounds = computeMeshBounds mesh
      logInfoIO LogGeneral $ "OBJ mesh bounds: " <> showT objBounds

      -- Spawn 3 cube entities at different positions
      entity1 <- ECS.spawnEntity world
      ECS.setTransform world entity1 (Transform (V3 0 0 0) (Quaternion 1 (V3 0 0 0)) (V3 1 1 1))
      ECS.setMesh world entity1 meshHandle

      entity2 <- ECS.spawnEntity world
      ECS.setTransform world entity2 (Transform (V3 2 0 0) (Quaternion 1 (V3 0 0 0)) (V3 1 1 1))
      ECS.setMesh world entity2 meshHandle

      entity3 <- ECS.spawnEntity world
      ECS.setTransform world entity3 (Transform (V3 (-2) 0 0) (Quaternion 1 (V3 0 0 0)) (V3 1 1 1))
      ECS.setMesh world entity3 meshHandle

      -- Add ground plane with checkerboard texture
      let groundMesh = Mesh.groundPlaneMesh 50.0
      groundMeshHandle <- Buffer.createMeshResource rm physicalDevice device (Mesh.vertices groundMesh) (Mesh.indices groundMesh)
      let checkerTexData = Texture.generateCheckerboardTexture 256 256 32
      checkerTexHandle <- Texture.createTextureFromData rm physicalDevice device 256 256 checkerTexData graphicsQueueHandler textureCommandBuffer
      groundEntity <- ECS.spawnEntity world
      ECS.setTransform world groundEntity (Transform (V3 0 0 (-0.5)) (Quaternion 1 (V3 0 0 0)) (V3 1 1 1))
      ECS.setMesh world groundEntity groundMeshHandle
      ECS.setMaterial world groundEntity checkerTexHandle

      pure (world, 4, objBounds, IntMap.empty)  -- 3 cubes + ground plane

  -- Adjust camera based on scene bounds
  worldState <- liftIO $ STM.readTVarIO (world gameState)
  let tvCamera = activeCamera worldState
  currentCam <- liftIO $ STM.readTVarIO tvCamera
  let adjustedCam = adjustCameraForScene sceneBounds currentCam
  liftIO $ STM.atomically $ STM.writeTVar tvCamera adjustedCam
  logInfoIO LogGeneral $ "camera adjusted to distance=" <> showT (Camera.cameraDistance adjustedCam)

  -- Determine actual entity count for buffer/descriptor allocation
  initialDrawList <- extractDrawList ecsWorld rm IntMap.empty
  let numDrawEntities = length initialDrawList
  logInfoIO LogRender $ "initial draw list has " <> showT numDrawEntities <> " entities"

  -- Create per-frame uniform buffers for multi-entity rendering
  -- Each entity gets 256 bytes (padded from 192 bytes for 3 M44 matrices)
  let entityUniformSize = 256 :: Int
      totalUniformSize = numDrawEntities * entityUniformSize
      padTo256 :: [M44 Foreign.C.CFloat] -> [M44 Foreign.C.CFloat]
      padTo256 mats = mats ++ replicate ((entityUniformSize - length mats * sizeOf (undefined :: M44 Foreign.C.CFloat)) `div` sizeOf (undefined :: M44 Foreign.C.CFloat)) identity
      initialMvpData = concatMap (\m -> padTo256 [m, identity, projectionMatrix]) (replicate numDrawEntities modelMatrix)

  logDebugIO LogBuffer $ "initialMvpData length=" <> showT (length initialMvpData) <> " size=" <> showT (length initialMvpData * sizeOf (undefined :: M44 Foreign.C.CFloat))
  frameMvpBuffers <- replicateM Render.maxFramesInFlight $
    Buffer.managedUniformBuffer physicalDevice device initialMvpData
  logDebugIO LogBuffer $ "frameMvpBuffers created, count=" <> showT (length frameMvpBuffers)

  -- Create compute culling buffers
  let maxEntities = 4096 :: Int
      dummyEntityData = ComputeEntityData
        { ceTransform = identity
        , ceAabbMin = V4 (-1000) (-1000) (-1000) 1
        , ceAabbMax = V4 1000 1000 1000 1
        , ceMaterialIndex = 0
        , cePad = V3 0 0 0
        }
      dummyCullData = ComputeCullData
        { ccFrustumPlanes = replicate 6 (V4 0 0 0 0)
        , ccEntityCount = fromIntegral numDrawEntities
        , ccPad2 = V3 0 0 0
        }
      initialVisibleFlags = replicate maxEntities (0 :: Word32)

  (entitySsboBuffer, entitySsboMemory) <- Buffer.managedStorageBuffer physicalDevice device (replicate maxEntities dummyEntityData) Vulkan.VK_ZERO_FLAGS
  (visibleFlagsBuffer, visibleFlagsMemory) <- Buffer.managedStorageBuffer physicalDevice device initialVisibleFlags Vulkan.VK_ZERO_FLAGS
  (cullDataBuffer, cullDataMemory) <- Buffer.managedUniformBuffer physicalDevice device [dummyCullData]
  logDebugIO LogBuffer $ "compute buffers created: entitySSBO=" <> showT (maxEntities * sizeOf (undefined :: ComputeEntityData)) <> " visibleFlags=" <> showT (maxEntities * sizeOf (undefined :: Word32)) <> " cullData=" <> showT (sizeOf (undefined :: ComputeCullData))

  -- Update compute descriptor set with buffers
  DescriptorSet.updateComputeDescriptorSets device computeDescriptorSet entitySsboBuffer visibleFlagsBuffer cullDataBuffer
  logDebugIO LogRender "compute descriptor set updated"

  let computeCullResources = ComputeCullResources
        { ccrPipeline = computePipeline
        , ccrPipelineLayout = computePipelineLayout
        , ccrDescriptorSet = computeDescriptorSet
        , ccrEntityBuffer = entitySsboBuffer
        , ccrEntityMemory = entitySsboMemory
        , ccrVisibleFlagsBuffer = visibleFlagsBuffer
        , ccrVisibleFlagsMemory = visibleFlagsMemory
        , ccrCullDataBuffer = cullDataBuffer
        , ccrCullDataMemory = cullDataMemory
        , ccrMaxEntities = maxEntities
        }

  logInfoIO LogTexture "creating sampler"
  textureSampler <- Texture.managedSampler device
  logInfoIO LogTexture "sampler created"

  -- Helper: bilinear resize of RGBA8 image data
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
        in Vector.fromList [dstPixel dx dy !! c | dy <- [0..dh-1], dx <- [0..dw-1], c <- [0..3]]

  -- Build set of unique texture handles from ECS materials (not draw list,
  -- because glTF textures use dummy handles not registered in resource manager)
  ecsMaterials <- liftIO $ STM.readTVarIO (ECS.wMaterials ecsWorld)
  let uniqueTextures = nub $ IntMap.elems ecsMaterials
      numUniqueTextures = length uniqueTextures

  logInfoIO LogTexture $ "unique textures: " <> showT numUniqueTextures

  -- Build texture handle -> bindless index map
  let textureIndexMap = IntMap.fromList $ zip (map (fromIntegral . unTextureHandle) uniqueTextures) [0..]
      unTextureHandle (TextureHandle h) = h

  -- Create individual textures for bindless descriptor array
  bindlessTextureViews <- if numUniqueTextures == 0
    then do
      -- No textures, create a single white texture
      let whiteTexData = Texture.generateGridTexture 2 2 1
      whiteHandle <- Texture.createTextureFromData rm physicalDevice device 2 2 whiteTexData graphicsQueueHandler textureCommandBuffer
      mView <- Texture.textureImageView rm whiteHandle
      case mView of
        Just view -> pure [view]
        Nothing -> liftIO $ fail "failed to create white texture"
    else do
      -- Create individual texture for each unique texture
      views <- forM uniqueTextures $ \texHandle -> do
        let hId = fromIntegral (unTextureHandle texHandle)
        pixelData <- case IntMap.lookup hId texturePixelMap of
          -- glTF path: decoded pixel data available
          Just (tw, th, pixelData) ->
            if tw == 256 && th == 256
              then pure pixelData
              else pure $ resizeImageBilinear pixelData tw th 256 256
          -- OBJ path: read from GPU texture resource
          Nothing -> do
            mTexRes <- lookupTexture rm texHandle
            case mTexRes of
              Nothing -> pure $ Texture.generateCheckerboardTexture 256 256 32
              Just texRes -> case trPixelData texRes of
                Nothing -> pure $ Texture.generateCheckerboardTexture 256 256 32
                Just pixelData -> do
                  let tw = trWidth texRes
                      th = trHeight texRes
                  if tw == 256 && th == 256
                    then pure pixelData
                    else pure $ resizeImageBilinear pixelData tw th 256 256
        texHandle' <- Texture.createTextureFromData rm physicalDevice device 256 256 pixelData graphicsQueueHandler textureCommandBuffer
        mView <- Texture.textureImageView rm texHandle'
        case mView of
          Just view -> pure view
          Nothing -> liftIO $ fail "failed to create texture view"
      pure views

  logInfoIO LogTexture $ "bindless textures created: " <> showT (length bindlessTextureViews)

  -- Create descriptor pool sized for frame descriptor sets (one per frame)
  let totalDescriptorSets = Render.maxFramesInFlight
  descriptorPool <- DescriptorPool.managedDescriptorPool device totalDescriptorSets
  logDebugIO LogRender $ "descriptor pool created for " <> showT totalDescriptorSets <> " sets"

  -- Allocate one descriptor set per frame
  frameDescriptorSets <- replicateM totalDescriptorSets $
    DescriptorSet.allocateDescriptorSet device descriptorPool [descriptorSetLayout]
  logDebugIO LogRender $ "allocated " <> showT (length frameDescriptorSets) <> " frame descriptor sets"

  -- Update each frame descriptor set with the frame's uniform buffer and bindless textures
  logInfoIO LogVulkan "updating frame descriptor sets"
  for_ (zip [0..] frameMvpBuffers) $ \(frameIdx, (buf, _)) -> do
    let ds = frameDescriptorSets !! frameIdx
    DescriptorSet.updateDescriptorSetsBindless
      device
      ds
      buf
      (fromIntegral entityUniformSize)
      textureSampler
      bindlessTextureViews
  logInfoIO LogVulkan "frame descriptor sets updated"

  -- Create push constant range for material index (fragment shader, 4 bytes)
  let pushConstantRange =
        Vulkan.createVk
          ( Vulkan.set @"stageFlags" Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT
              Vulkan.&* Vulkan.set @"offset" 0
              Vulkan.&* Vulkan.set @"size" 4
          )

  logInfoIO LogRender "all resources created, entering render loop"

  let mkRenderContext =
        Render.createRenderContext
          physicalDevice
          device
          surface
          pipelineLayout
          vertShader
          fragShader
          []  -- frameDescriptorSets no longer used for g-buffer
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
      frameMvpMemories = map snd frameMvpBuffers
      outerLoop :: (MonadFail m, MonadIO m) => Bool -> m ()
      outerLoop exit = do
        if exit
          then pure ()
          else do
            renderFrameLoopFinished <- liftIO $ with mkRenderContext $ \context ->
              with (createDeferredResources physicalDevice device context descriptorSetLayout [pushConstantRange] gbufVertShader gbufFragShader lightVertShader lightFragShader wireVertShader wireGeomShader wireFragShader) $ \dr ->
                renderFrameLoop context dr 0 targetFPS imageAvailableSemaphores control frameMvpMemories tvCamera tvInspect tvInsp tvRenderDebug ecsWorld rm entityUniformSize textureSampler frameDescriptorSets textureIndexMap tvWireframe frameStatsRef computeCullResources
            outerLoop renderFrameLoopFinished


  logInfoIO LogGeneral "Starting render loop"
  outerLoop False

  logInfoIO LogGeneral "renderLoop finished"
  -- Destroy resource-manager resources before managed scope exits
  destroyAllResources rm
  liftIO $ putMVar finishedSemaphore ()

modelMatrix :: M44 Foreign.C.CFloat
modelMatrix =
  let rotate = identity
      translate = identity
   in translate !*! rotate

projectionMatrix :: M44 Foreign.C.CFloat
projectionMatrix =
  Linear.Projection.perspective
    (pi / 12) -- FOV
    (16 / 9) -- aspect ratio
    0.1 -- near plane
    10000.0 -- far plane

drawCallToSnapshot :: DrawCall -> RenderableSnapshot
drawCallToSnapshot DrawCall {..} =
  RenderableSnapshot
    { rsName = "entity"
    , rsWorldMatrix = (realToFrac <$>) <$> dcWorldMatrix
    , rsScale = V3 1 1 1
    , rsVisible = True
    , rsMaterial = maybe "default" (const "textured") dcMaterial
    , rsMesh = "mesh"
    , rsIndexCount = mrIndexCount dcMesh
    }

-- | stateUpdateLoop is the main game loop that updates the game state 
-- based on input events and simulation ticks. It takes the target FPS, 
-- current GameState, a finished semaphore, input event queue, and control 
-- channel. Inside the loop it reads input events, updates the camera and 
-- player state, runs physics simulation ticks, and loops again until 
-- terminated by a control signal.
stateUpdateLoop :: (Camera cam, MonadIO m) => Integer -> GameState cam -> MVar () -> TQueue ActionEvent -> CommandQueue -> TChan ControlMessage -> m ()
stateUpdateLoop targetFPS gameState finishedSemaphore actionQueue debugCmdQueue controlChannel = liftIO $ do
  control <- STM.atomically $ TChan.dupTChan controlChannel

  let physicsStep = 1 / 120
      frameDelay = physicsStep * 100000
      camSpeed = 10

  let loop :: (Camera cam, MonadIO m) => Integer -> GameState cam -> Integer -> m ()
      loop tFPS _gameState prevTime = liftIO $ do
        maybeControlMessage <- STM.atomically $ TChan.tryReadTChan control
        case maybeControlMessage of
          Nothing -> do
            newTime <- liftIO $ toNanoSecs <$> getTime Monotonic
            actions <- STM.atomically $ TQueue.flushTQueue actionQueue
            debugCmds <- STM.atomically $ TQueue.flushTQueue debugCmdQueue
            worldState <- STM.readTVarIO (world gameState)
            let camera = activeCamera worldState
            for_ actions $ \action ->
              case action of
                (MoveForward, b) -> STM.atomically $ STM.writeTVar (moveForward gameState) b
                (MoveBackward, b) -> STM.atomically $ STM.writeTVar (moveBackward gameState) b
                (StrafeLeft, b) -> STM.atomically $ STM.writeTVar (strafeLeft gameState) b
                (StrafeRight, b) -> STM.atomically $ STM.writeTVar (strafeRight gameState) b
                (MouseMove (V2 x y), _) ->
                  STM.atomically
                    ( updateCamera
                        (activeCamera worldState)
                        [ Camera.Rotate
                            ( V3 ((fromIntegral x) / frameDelay) ((fromIntegral y) / frameDelay) 0.0
                            )
                        ]
                    )
                (Zoom amount, _) ->
                  STM.atomically
                    ( updateCamera
                        (activeCamera worldState)
                        [Camera.Zoom (realToFrac amount)]
                    )
                (Escape, _) -> STM.atomically $ STM.writeTVar (isRunning gameState) False
                (FrameInspect, True) -> STM.atomically $ STM.writeTVar (inspectFrame gameState) True
                (FrameInspect, False) -> pure ()
                (ToggleWireframe, True) -> do
                  current <- STM.readTVarIO (wireframeEnabled gameState)
                  STM.atomically $ STM.writeTVar (wireframeEnabled gameState) (not current)
                  logInfoIO LogGeneral $ "wireframe toggled: " <> showT (not current)
                (ToggleWireframe, False) -> pure ()
            -- Handle debug commands with responses
            for_ debugCmds $ \(cmd, respVar) -> do
              case cmd of
                SetCameraDistance d -> do
                  STM.atomically $ STM.modifyTVar' (activeCamera worldState) (\cam -> setDistance cam (realToFrac d))
                  STM.atomically $ STM.putTMVar respVar (AckResponse "camera_distance_set")
                SetCameraTarget (V3 tx ty tz) -> do
                  STM.atomically $ STM.modifyTVar' (activeCamera worldState) (\cam ->
                    setTarget cam (V3 (realToFrac tx) (realToFrac ty) (realToFrac tz)))
                  STM.atomically $ STM.putTMVar respVar (AckResponse "camera_target_set")
                SetCameraAngles az el -> do
                  STM.atomically $ STM.modifyTVar' (activeCamera worldState) (\cam ->
                    setAngles cam (realToFrac az) (realToFrac el))
                  STM.atomically $ STM.putTMVar respVar (AckResponse "camera_angles_set")
                TriggerFrameInspect -> do
                  STM.atomically $ STM.writeTVar (inspectFrame gameState) True
                  STM.atomically $ STM.putTMVar respVar (AckResponse "frame_inspect_triggered")
                SetTimeScale _ -> do
                  STM.atomically $ STM.putTMVar respVar (AckResponse "time_scale_not_implemented")
                GetState -> do
                  cam <- STM.readTVarIO (activeCamera worldState)
                  running <- STM.readTVarIO (isRunning gameState)
                  inspecting <- STM.readTVarIO (inspectFrame gameState)
                  let pos = realToFrac <$> cameraPosition cam
                      tgt = realToFrac <$> cameraTarget cam
                      dist = realToFrac $ cameraDistance cam
                      az = realToFrac $ cameraAzimuth cam
                      el = realToFrac $ cameraElevation cam
                      snapshot = GameStateSnapshot
                        { gssCamera = DebugCameraSnapshot pos tgt dist az el
                        , gssRunning = running
                        , gssFrameInspectorEnabled = inspecting
                        }
                  STM.atomically $ STM.putTMVar respVar (StateResponse snapshot)
                GetRenderState -> do
                  mDebugInfo <- STM.readTVarIO (renderDebugState gameState)
                  case mDebugInfo of
                    Just debugInfo -> do
                      let val = toJSON debugInfo
                      STM.atomically $ STM.putTMVar respVar (RenderStateResponse val)
                    Nothing -> do
                      STM.atomically $ STM.putTMVar respVar (ErrorResponse "no render debug info available yet")
            let dt = newTime - prevTime

            (fwd, bwd, sl, sr, isRunning) <- STM.atomically $ do
              a <- STM.readTVar (moveForward gameState)
              b <- STM.readTVar (moveBackward gameState)
              c <- STM.readTVar (strafeLeft gameState)
              d <- STM.readTVar (strafeRight gameState)
              e <- STM.readTVar (isRunning gameState)
              pure (a, b, c, d, e)

            let camMove = camSpeed / frameDelay
            when (fwd) $ STM.atomically $ updateCamera (activeCamera worldState) [Camera.MoveForward camMove]
            when (bwd) $ STM.atomically $ updateCamera (activeCamera worldState) [Camera.MoveForward (-camMove)]
            when (sl) $ STM.atomically $ updateCamera (activeCamera worldState) [Camera.MoveRight (-camMove)]
            when (sr) $ STM.atomically $ updateCamera (activeCamera worldState) [Camera.MoveRight camMove]
            threadDelay (round frameDelay)
            when isRunning $ loop tFPS _gameState newTime
          Just Terminate -> do
            logInfoIO LogGeneral "terminating stateUpdate loop by signal"
            STM.atomically $ STM.writeTVar (isRunning _gameState) False

  currentTime <- liftIO $ toNanoSecs <$> getTime Monotonic
  loop targetFPS gameState currentTime
  logInfoIO LogGeneral "stateUpdateLoop finished"
  putMVar finishedSemaphore ()

updateCamera ::
  Camera cam =>
  TVar cam ->
  [Camera.Modifier Foreign.C.CFloat] ->
  STM ()
updateCamera tv mods = STM.modifyTVar' tv (Camera.update <*> pure mods)

-- | Compute bounding box from Mesh vertices.
computeMeshBounds :: Mesh.Mesh -> BBox
computeMeshBounds mesh =
  fromPoints (map (fmap realToFrac . vPos) (Mesh.vertices mesh))

-- | Compute bounding box from all mesh resources in the scene.
computeSceneBounds :: [MeshHandle] -> ResourceManager -> BBox
computeSceneBounds meshes rm = unsafePerformIO $ do
  boundsList <- mapM (\mh -> do
    mMesh <- lookupMesh rm mh
    case mMesh of
      Just meshRes -> pure $ mrBounds meshRes
      Nothing -> pure emptyBBox
    ) meshes
  pure $ foldl mergeBBox emptyBBox boundsList

-- | Set camera distance based on scene bounding box.
adjustCameraForScene :: Camera a => BBox -> a -> a
adjustCameraForScene bbox cam =
  let diag = bboxDiagonal bbox
      targetDist = diag * 1.8
      -- Clamp to reasonable range
      dist = max 3.0 (min 100.0 targetDist)
  in setMaxDistance (setDistance cam (realToFrac dist)) (realToFrac (dist * 3.0))
