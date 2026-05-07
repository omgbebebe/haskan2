{-# LANGUAGE DeriveGeneric #-}
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
import Control.Monad (replicateM, unless, when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged, runManaged, with)
import Data.Foldable (for_)
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HashMap
import Data.Hashable (Hashable (..))
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as Text
import FIR qualified
import Foreign.C qualified
import GHC.Generics
import Graphics.Haskan.Camera (Camera (..))
import Graphics.Haskan.Camera qualified as Camera
import Graphics.Haskan.Debug.FrameInspector (FrameInspector, RenderableSnapshot (..), defaultInspector, buildFrameSnapshot)
import Graphics.Haskan.Debug.Interface (DebugCommand (..), DebugMessage (..), DebugResponse (..), GameStateSnapshot (..), DebugCameraSnapshot (..), debugMessageToActionEvent, parseDebugMessage, encodeDebugResponse)
import Graphics.Haskan.Debug.Server (DebugServerHandle, CommandQueue, startDebugServer, stopDebugServer)
import Graphics.Haskan.Input (Action (..), ActionEvent, payloadToActionEvent)
import Graphics.Haskan.Logger (logI)
import Graphics.Haskan.Mesh qualified as Mesh
import Graphics.Haskan.Model qualified as Model
import Graphics.Haskan.Resources (throwVkResult)
import Graphics.Haskan.Utils.ObjLoader qualified as ObjLoader
import Graphics.Haskan.Vertex (Vertex (..))
import Graphics.Haskan.Vulkan.Buffer qualified as Buffer
import Graphics.Haskan.Vulkan.CommandBuffer qualified as CommandBuffer
import Graphics.Haskan.Vulkan.CommandPool qualified as CommandPool
import Graphics.Haskan.Vulkan.DescriptorPool qualified as DescriptorPool
import Graphics.Haskan.Vulkan.DescriptorSet qualified as DescriptorSet
import Graphics.Haskan.Vulkan.DescriptorSetLayout qualified as DescriptorSetLayout
import Graphics.Haskan.Vulkan.Device qualified as Device
import Graphics.Haskan.Vulkan.Fence qualified as Fence
import Graphics.Haskan.Vulkan.Instance qualified as Instance
import Graphics.Haskan.Vulkan.PhysicalDevice qualified as PhysicalDevice
import Graphics.Haskan.Vulkan.PipelineLayout qualified as PipelineLayout
import Graphics.Haskan.Vulkan.Render (drawFrame, presentFrame)
import Graphics.Haskan.Vulkan.Render qualified as Render
import Graphics.Haskan.Vulkan.Resources
import Graphics.Haskan.Vulkan.Semaphore qualified as Semaphore
import Graphics.Haskan.Vulkan.ShaderModule qualified as ShaderModule
import Graphics.Haskan.Vulkan.Shaders.Texture qualified as Shaders
import Graphics.Haskan.Vulkan.Texture qualified as Texture
import Graphics.Haskan.Vulkan.Types (RenderContext (..))
import Graphics.Haskan.Window qualified as Window
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Ext qualified as Vulkan
import Linear (M44, V2 (..), V3 (..))
import Linear.Matrix (identity, transpose, (!*!))
import Linear.Projection qualified
import SDL qualified
import System.Clock (Clock (..), getTime, toNanoSecs)

data EngineConfig = EngineConfig
  { targetRenderFPS :: !Integer,
    targetPhysicsFPS :: !Integer,
    targetNetworkFPS :: !Integer,
    targetInputFPS :: !Integer,
    title :: !Text,
    debugSocketPath :: !(Maybe FilePath)
  }
  deriving (Show)

data FrameTime = FrameTime
  { lastTime :: !Integer,
    currentTime :: !Integer,
    deltaTime :: !Integer
  }
  deriving (Show)

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
    inspector :: TVar (Maybe FrameInspector)
  }

data ControlMessage
  = Terminate

-- | The main loop that runs the game engine. It initializes systems like the window, 
-- rendering, input handling, and game state update. It launches separate threads for 
-- rendering, game state updates, and input handling, and synchronizes between them using 
-- channels and MVars. The function takes the mesh name to render and engine configuration
-- as arguments. It sets up the initial game state with default values.
mainLoop :: MonadIO m => String -> EngineConfig -> m ()
mainLoop meshName EngineConfig {..} = do
  logI "starting mainLoop"
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

  -- Start debug server if configured
  mDebugServer <- liftIO $ case debugSocketPath of
    Just path -> do
      h <- startDebugServer path actionQueue debugCmdQueue
      logI $ "debug server listening on " <> Text.pack path
      pure (Just h)
    Nothing -> pure Nothing

  SDL.initialize @[] [SDL.InitEvents]

  logI "Initialize base Render context"
  let initWidth = 1920
      initHeight = 1080
  window <- Window.createWindow title (initWidth, initHeight)
  windowExts <- Window.windowExtensions window
  (inst, layers) <- Instance.createInstance windowExts
  surface <- Window.createSurface inst window
  physicalDevice <- PhysicalDevice.selectPhysicalDevice inst
  Window.showWindow window

  renderLoopFinished <- liftIO $ newEmptyMVar
  _ <- liftIO $ forkIO (runManaged (renderLoop physicalDevice surface layers targetRenderFPS gameState renderLoopFinished controlChannel meshName))

  stateUpdateLoopFinished <- liftIO $ newEmptyMVar
  _ <- liftIO $ forkIO (stateUpdateLoop targetPhysicsFPS gameState stateUpdateLoopFinished actionQueue debugCmdQueue controlChannel)

  let inputLoop :: MonadIO m => m ()
      inputLoop = do
        events <- SDL.pollEvents
        let actionEvents = catMaybes $ map (payloadToActionEvent . SDL.eventPayload) events
            quitting = (Escape, True) `elem` actionEvents
        liftIO $ STM.atomically $ for_ actionEvents $ TQueue.writeTQueue actionQueue
        SDL.delay 20
        unless (quitting) inputLoop

  inputLoop
  logI "sending Terminate message"
  liftIO $ STM.atomically $ TChan.writeTChan controlChannel Terminate
  logI "waiting for other threads finished"
  liftIO $ mapM_ takeMVar [renderLoopFinished, stateUpdateLoopFinished]

  -- Stop debug server
  liftIO $ for_ mDebugServer stopDebugServer

  logI "destroying SDL window"
  SDL.destroyWindow window
  SDL.quit
  logI "mainLoop finished"

-- | Render a frame in the render loop. Checks for control messages, gets the 
-- current camera state, updates the uniform buffer, draws the frame, presents 
-- it, and handles restarting/terminating conditions.
renderFrameLoop ::
  (MonadFail m, MonadIO m, Camera cam) =>
  RenderContext ->
  Int ->
  Integer ->
  [Vulkan.VkSemaphore] ->
  TChan ControlMessage ->
  Vulkan.VkDeviceMemory ->
  TVar cam ->
  STM.TVar Bool ->
  STM.TVar (Maybe FrameInspector) ->
  Int ->
  m Bool
renderFrameLoop ctx@RenderContext {..} frameNumber targetFPS imageAvailableSemaphores control mvpMemory tvCamera tvInspect tvInsp indexCount = do
  frameStartTime <- liftIO $ toNanoSecs <$> getTime Monotonic
  maybeControlMessage <- liftIO $ STM.atomically $ TChan.tryReadTChan control
  (needRestart, terminating) <- case maybeControlMessage of
    Nothing -> do
      let imageAvailableSemaphore = imageAvailableSemaphores !! (frameNumber)
      camera <- liftIO $ STM.readTVarIO tvCamera
      let model = modelMatrix
          view = Camera.unViewMatrix (Camera.toMatrix camera)
          projection = projectionMatrix
      Buffer.updateUniformBuffer device mvpMemory [model, view, projection]
      res <- liftIO $ drawFrame ctx imageAvailableSemaphore frameNumber
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
                  snap <- buildFrameSnapshot (fromIntegral frameNumber) startTime ctx camera ((realToFrac <$>) <$> projectionMatrix)
                    [ RenderableSnapshot
                        { rsName = "mesh"
                        , rsWorldMatrix = (realToFrac <$>) <$> modelMatrix
                        , rsScale = V3 1 1 1
                        , rsVisible = True
                        , rsMaterial = "default"
                        , rsMesh = "unit_cube"
                        , rsIndexCount = indexCount
                        }
                    ]
                  liftIO $ insp snap
              pure (False, False)
            Vulkan.VK_SUBOPTIMAL_KHR -> pure (True, False)
            Vulkan.VK_ERROR_OUT_OF_DATE_KHR -> pure (True, False)
            _ -> fail "presentFrame failed"
        Render.FrameSuboptimal _ -> do
          fail "suboptimal"
        Render.FrameOutOfDate -> do
          logI "resizing swapchain"
          pure (True, False)
        Render.FrameFailed err -> fail err
    Just Terminate -> do
      logI "terminating render loop by signal"
      pure (True, True)

  frameEndTime <- liftIO $ toNanoSecs <$> getTime Monotonic
  if needRestart
    then liftIO $ do
      logI "waiting IDLE state for device"
      Vulkan.vkDeviceWaitIdle device >>= throwVkResult
      logI "terminating renderFrameLoop"
      pure terminating
    else do
      let renderTime = frameEndTime - frameStartTime
          delay = ((1000000000 `div` targetFPS) - renderTime) `div` 1000
      liftIO $ threadDelay (fromIntegral delay)
      renderFrameLoop
        ctx
        ((frameNumber + 1) `mod` Render.maxFramesInFlight)
        targetFPS
        imageAvailableSemaphores
        control
        mvpMemory
        tvCamera
        tvInspect
        tvInsp
        indexCount

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

  liftIO $ FIR.compileTo "data/shaders/fir/vert.spv" [FIR.SPIRV (FIR.Version 1 0)] Shaders.vertex
  liftIO $ FIR.compileTo "data/shaders/fir/frag.spv" [FIR.SPIRV (FIR.Version 1 0)] Shaders.fragment

  vertShader <- ShaderModule.managedShaderModule device "data/shaders/fir/vert.spv"
  fragShader <- ShaderModule.managedShaderModule device "data/shaders/fir/frag.spv"

  descriptorSetLayout <- DescriptorSetLayout.managedDescriptorSetLayout device

  descriptorPool <- DescriptorPool.managedDescriptorPool device 4 -- imageViewCount here
  descriptorSets <- replicateM 4 (DescriptorSet.allocateDescriptorSet device descriptorPool [descriptorSetLayout])

  pipelineLayout <- PipelineLayout.managedPipelineLayout device [descriptorSetLayout]
  graphicsCommandPool <- CommandPool.managedCommandPool device graphicsQueueFamilyIndex

  imageAvailableSemaphores <- replicateM Render.maxFramesInFlight (Semaphore.managedSemaphore device)
  renderFinishedSemaphores <- replicateM 4 (Semaphore.managedSemaphore device)
  renderFinishedFences <- replicateM Render.maxFramesInFlight (Fence.managedFence device)

  (mesh, _) <- Model.fromObj <$> ObjLoader.parseObj ("data/models/obj/" <> meshName)

  -- Create mesh resource via ResourceManager
  meshHandle <- Buffer.createMeshResource rm physicalDevice device (Mesh.vertices mesh) (Mesh.indices mesh)

  -- Resolve mesh handle to raw Vulkan buffers
  (vertexBuffer, indexBuffer, indexCount) <- do
    mBuffers <- Buffer.meshBuffers rm meshHandle
    case mBuffers of
      Just (vb, ib, count) -> pure (vb, ib, count)
      Nothing -> fail "failed to resolve mesh buffers"

  (mvpBuffer, mvpMemory) <-
    Buffer.managedUniformBuffer
      physicalDevice
      device
      [modelMatrix, identity, projectionMatrix]

  textureCommandBuffer <- CommandBuffer.createCommandBuffer device graphicsCommandPool

  -- Create texture resource via ResourceManager
  textureHandle <- Texture.createTextureResource rm physicalDevice device "data/texture/page-14-droid-hubs.png" graphicsQueueHandler textureCommandBuffer

  textureImageView <- do
    mView <- Texture.textureImageView rm textureHandle
    case mView of
      Just view -> pure view
      Nothing -> fail "failed to resolve texture image view"

  textureSampler <- Texture.managedSampler device

  for_ descriptorSets $
    \descriptorSet ->
      DescriptorSet.updateDescriptorSets
        device
        descriptorSet
        mvpBuffer
        textureImageView
        textureSampler

  let mkRenderContext =
        Render.createRenderContext
          physicalDevice
          device
          surface
          pipelineLayout
          vertShader
          fragShader
          descriptorSets
          graphicsCommandPool
          graphicsQueueHandler
          presentQueueHandler
          renderFinishedFences
          renderFinishedSemaphores
          [vertexBuffer]
          [indexBuffer]
          indexCount

  worldState <- liftIO $ STM.readTVarIO (world gameState)
  let tvCamera = activeCamera worldState
      tvInspect = inspectFrame gameState
      tvInsp = inspector gameState
      outerLoop :: (MonadFail m, MonadIO m) => Bool -> m ()
      outerLoop exit = do
        if exit
          then pure ()
          else do
            renderFrameLoopFinished <- liftIO $ with mkRenderContext $ \context ->
              renderFrameLoop context 0 targetFPS imageAvailableSemaphores control mvpMemory tvCamera tvInspect tvInsp indexCount
            outerLoop renderFrameLoopFinished

  logI "Starting render loop"
  liftIO $ outerLoop False

  logI "renderLoop finished"
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
  Linear.Matrix.transpose $
    Linear.Projection.perspective
      (pi / 12) -- FOV
      (16 / 9) -- aspect ratio
      0.1 -- near plane
      10000.0 -- far plane

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
                (Escape, _) -> STM.atomically $ STM.writeTVar (isRunning gameState) False
                (FrameInspect, True) -> STM.atomically $ STM.writeTVar (inspectFrame gameState) True
                (FrameInspect, False) -> pure ()
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
            let dt = newTime - prevTime

            (fwd, bwd, sl, sr, isRunning) <- STM.atomically $ do
              a <- STM.readTVar (moveForward gameState)
              b <- STM.readTVar (moveBackward gameState)
              c <- STM.readTVar (strafeLeft gameState)
              d <- STM.readTVar (strafeRight gameState)
              e <- STM.readTVar (isRunning gameState)
              pure (a, b, c, d, e)

            let camMove = camSpeed / frameDelay
            when (fwd) $ STM.atomically $ updateCamera (activeCamera worldState) [Camera.MoveY (camMove)]
            when (bwd) $ STM.atomically $ updateCamera (activeCamera worldState) [Camera.MoveY (-camMove)]
            when (sl) $ STM.atomically $ updateCamera (activeCamera worldState) [Camera.MoveX camMove]
            when (sr) $ STM.atomically $ updateCamera (activeCamera worldState) [Camera.MoveX (-camMove)]
            threadDelay (round frameDelay)
            when isRunning $ loop (tFPS) _gameState newTime
          Just Terminate -> do
            logI "terminating stateUpdate loop by signal"

  currentTime <- liftIO $ toNanoSecs <$> getTime Monotonic
  loop targetFPS gameState currentTime
  logI "stateUpdateLoop finished"
  putMVar finishedSemaphore ()

updateCamera ::
  Camera cam =>
  TVar cam ->
  [Camera.Modifier Foreign.C.CFloat] ->
  STM ()
updateCamera tv mods = STM.modifyTVar' tv (Camera.update <*> pure mods)

data Event
