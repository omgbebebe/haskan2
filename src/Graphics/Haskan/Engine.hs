{-# language DeriveGeneric #-}
{-# language RecordWildCards #-}
{-# language DatatypeContexts #-}
module Graphics.Haskan.Engine where

-- base
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, takeMVar, putMVar)
import Control.Monad (when, replicateM, unless)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Coerce (coerce)
import Data.Foldable (for_)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Foreign.C
import GHC.Generics
import Debug.Trace

-- async
import qualified Control.Concurrent.Async as Async

-- clock
import System.Clock (Clock(..), getTime, toNanoSecs)

-- FIR
import qualified FIR
import FIR
  ( runCompilationsTH
  , Struct((:&),End)
  , ModuleRequirements(..)
  )

-- hashable
import Data.Hashable (Hashable(..))

-- lens
import Control.Lens ((&), (.~))

-- linear
import Linear (V2(..), V3(..), V4(..), M44, fromQuaternion)
import Linear.Matrix ((!*!), identity, m33_to_m44, translation)
import qualified Linear.Matrix
import qualified Linear.Projection
import qualified Linear.Quaternion

-- managed
import Control.Monad.Managed (MonadManaged, with, runManaged, using)

-- sdl2
import qualified SDL

-- stm
import Control.Concurrent.STM (STM)
import qualified Control.Concurrent.STM as STM
import Control.Concurrent.STM.TVar (TVar)
import Control.Concurrent.STM.TChan (TChan)
import qualified Control.Concurrent.STM.TChan as TChan
import Control.Concurrent.STM.TQueue (TQueue)
import qualified Control.Concurrent.STM.TQueue as TQueue

-- unordered-containers
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap

-- vulkan-api
import qualified Graphics.Vulkan as Vulkan
import qualified Graphics.Vulkan.Core_1_0 as Vulkan
import qualified Graphics.Vulkan.Ext as Vulkan

-- haskan
import Graphics.Haskan.Camera (Camera(..))
import qualified Graphics.Haskan.Camera as Camera
import qualified Graphics.Haskan.Events as Events
import qualified Graphics.Haskan.Face as Face
import           Graphics.Haskan.Logger (logI, showT)
import qualified Graphics.Haskan.Mesh as Mesh
import qualified Graphics.Haskan.Model as Model
import           Graphics.Haskan.Resources (throwVkResult)
import           Graphics.Haskan.Vulkan.Render (drawFrame, presentFrame)
import qualified Graphics.Haskan.Vulkan.Buffer as Buffer
import qualified Graphics.Haskan.Vulkan.Render as Render
import qualified Graphics.Haskan.Vulkan.CommandPool as CommandPool
import qualified Graphics.Haskan.Vulkan.CommandBuffer as CommandBuffer
import qualified Graphics.Haskan.Vulkan.DescriptorPool as DescriptorPool
import qualified Graphics.Haskan.Vulkan.DescriptorSet as DescriptorSet
import qualified Graphics.Haskan.Vulkan.DescriptorSetLayout as DescriptorSetLayout
import qualified Graphics.Haskan.Vulkan.Device as Device
import qualified Graphics.Haskan.Vulkan.Fence as Fence
import qualified Graphics.Haskan.Vulkan.Instance as Instance
import qualified Graphics.Haskan.Vulkan.PipelineLayout as PipelineLayout
import qualified Graphics.Haskan.Vulkan.PhysicalDevice as PhysicalDevice
import qualified Graphics.Haskan.Vulkan.Semaphore as Semaphore
import qualified Graphics.Haskan.Vulkan.ShaderModule as ShaderModule
import qualified Graphics.Haskan.Vulkan.Texture as Texture
import           Graphics.Haskan.Vulkan.Types (RenderContext(..))
import           Graphics.Haskan.Vertex (Vertex(..))
import qualified Graphics.Haskan.Window as Window

import qualified Graphics.Haskan.Utils.ObjLoader as ObjLoader
import qualified Graphics.Haskan.Utils.PieLoader as PieLoader

import qualified Graphics.Haskan.Vulkan.Shaders.Texture as Shaders

data Action
  = MoveForward
  | MoveBackward
  | StrafeLeft
  | StrafeRight
  | MouseMove (V2 Int)
  | Escape
  deriving (Eq, Show)

type ActionEvent = (Action, Bool)

data EngineConfig =
  EngineConfig{ targetRenderFPS :: !Integer
              , targetPhysicsFPS :: !Integer
              , targetNetworkFPS :: !Integer
              , targetInputFPS :: !Integer
              , title :: !Text
              }
  deriving (Show)

data FrameTime =
  FrameTime{ lastTime :: !Integer
           , currentTime :: !Integer
           , deltaTime :: !Integer
           } deriving (Show)

type Position = V3 Float
type Distance = Float
type Orientation = (Linear.Quaternion.Quaternion Float)

{-
data Camera
  = LookAt { camPos :: Position
           , camLookAt :: Position
           }
  | Orbital { camTarget :: Position
            , camDistance :: Distance
            , camOrientation :: Orientation
            , camDumping :: Maybe (V2 Float)
            }
-}

data Camera cam => WorldState cam =
  WorldState { activeCamera :: TVar cam
             }

data GameState cam =
  GameState { world :: TVar (WorldState cam)
            , isRunning :: TVar Bool
            , moveForward :: TVar Bool
            , moveBackward :: TVar Bool
            , strafeLeft :: TVar Bool
            , strafeRight :: TVar Bool
            }

data ControlMessage
  = Terminate

--mainLoop :: MonadIO m => EventsQueue -> RenderContext -> m ()
--mainLoop eventsQueue ctx@RenderContext{..} = do
--mainLoop :: MonadIO m => HaskanConfig -> RenderContext -> m Bool
mainLoop :: MonadIO m => String -> EngineConfig -> m ()
mainLoop meshName EngineConfig{..} = do
  logI "starting mainLoop"
  camera <- liftIO $ STM.newTVarIO (Camera.defaultOrbitalCamera)
  isRunning <- liftIO $ STM.newTVarIO True

  controlChannel <- liftIO $ TChan.newBroadcastTChanIO
  worldState <- liftIO $ STM.newTVarIO (WorldState camera)
  actionQueue <- liftIO $ STM.newTQueueIO
  -- movement state
  tvMoveForward <- liftIO $ STM.newTVarIO (False)
  tvMoveBackward <- liftIO $ STM.newTVarIO (False)
  tvStrafeLeft <- liftIO $ STM.newTVarIO (False)
  tvStrafeRight <- liftIO $ STM.newTVarIO (False)
 
  let
    gameState =
      GameState
        worldState
        isRunning
        tvMoveForward
        tvMoveBackward
        tvStrafeLeft
        tvStrafeRight

  SDL.initialize @[] [SDL.InitEvents]

  logI "Initialize base Render context"
  let initWidth = 1920
      initHeight = 1080
  window <- Window.createWindow title (initWidth, initHeight)
  windowExts <- Window.windowExtensions window
  (inst, layers)   <- Instance.createInstance windowExts
  surface          <- Window.createSurface inst window
  physicalDevice   <- PhysicalDevice.selectPhysicalDevice inst
  Window.showWindow window
 
  -- timeNow <- liftIO $ toNanoSecs <$> getTime Monotonic
  renderLoopFinished <- liftIO $ newEmptyMVar
  _ <- liftIO $ forkIO (runManaged (renderLoop physicalDevice surface layers targetRenderFPS gameState renderLoopFinished controlChannel meshName))

  stateUpdateLoopFinished <- liftIO $ newEmptyMVar
  _ <- liftIO $ forkIO (stateUpdateLoop targetPhysicsFPS gameState stateUpdateLoopFinished actionQueue controlChannel)


  let
    inputLoop :: MonadIO m => m ()
    inputLoop = do
      events <- SDL.pollEvents
      let
        actionEvents = catMaybes $ map (payloadToActionEvent . SDL.eventPayload) events
        quitting = (Escape, True) `elem` actionEvents
      liftIO $ STM.atomically $ for_ actionEvents $ TQueue.writeTQueue actionQueue
      SDL.delay 20
      {-
      event <- SDL.pollEvent
      case event of
        Just event -> do
          let
            action = payloadToActionEvent . SDL.eventPayload $ event
          case action of
            Just action -> liftIO $ STM.atomically $ TQueue.writeTQueue actionQueue action
            Nothing -> pure ()
        Nothing -> pure ()
      -}
      unless ( quitting ) inputLoop

  inputLoop
{-
  liftIO $ Async.withAsync
    (runManaged (renderLoop physicalDevice surface layers targetRenderFPS gameState renderLoopFinished controlChannel)) $ \render ->
      Async.withAsync (stateUpdateLoop targetPhysicsFPS gameState stateUpdateLoopFinished actionQueue controlChannel) $ \updater -> do
        inputLoop
        logI "sending Terminate message"
        liftIO $ STM.atomically $ TChan.writeTChan controlChannel Terminate
        Async.waitBoth render updater
-}
  logI "sending Terminate message"
  liftIO $ STM.atomically $ TChan.writeTChan controlChannel Terminate
  logI "waiting for other threads finished"
  liftIO $ Async.forConcurrently_ [renderLoopFinished, stateUpdateLoopFinished] $ \sem -> do
    takeMVar sem

  logI "destroying SDL window"
  SDL.destroyWindow window
  SDL.quit
--  inputLoopFinished <- liftIO $ newEmptyMVar
--  _ <- liftIO $ forkIO (runManaged $ inputLoop targetInputFPS inputLoopFinished actionQueue controlChannel)

{-
  liftIO $ Async.forConcurrently_ [renderLoopFinished, stateUpdateLoopFinished] $ \sem -> do
    takeMVar sem
    logI "sending Terminate message"
    STM.atomically $ TChan.writeTChan controlChannel Terminate
-}
{-
  let
    waitForFinished = do
--      logI "waiting all threads to finish"
      sems <- for [renderLoopFinished, physicsLoopFinished] $ \semaphore ->
        isEmptyMVar semaphore
      when (any not sems) $ do
        logI "sending Terminate message"
        STM.atomically $ TChan.writeTChan controlChannel Terminate
      threadDelay (10^4)
      unless (all not sems) waitForFinished

  waitForFinished
-}
  logI "mainLoop finished"

renderFrameLoop
  :: (MonadFail m, MonadIO m, Camera cam)
  => RenderContext
  -> Int
  -> Integer
  -> [Vulkan.VkSemaphore]
  -> TChan ControlMessage
  -> Vulkan.VkDeviceMemory
  -> TVar cam
  -> m Bool
renderFrameLoop ctx@RenderContext{..} frameNumber targetFPS imageAvailableSemaphores control mvpMemory tvCamera = do
  frameStartTime <- liftIO $ toNanoSecs <$> getTime Monotonic
  maybeControlMessage <- liftIO $ STM.atomically $ TChan.tryReadTChan control
  (needRestart, terminating) <- case maybeControlMessage of
    Nothing -> do
      let imageAvailableSemaphore = imageAvailableSemaphores !! (frameNumber)
      camera <- liftIO $ STM.readTVarIO tvCamera
      let model = modelMatrix
          view = Camera.unViewMatrix (Camera.toMatrix camera) --viewMatrix (coerce (camPos camera)) (coerce (camLookAt camera))
          projection = projectionMatrix
      Buffer.updateUniformBuffer device mvpMemory [model, view, projection]
      res <- liftIO $ drawFrame ctx imageAvailableSemaphore frameNumber
      case res of
        Render.FrameOk imageIndex -> do
          presentResult <- liftIO $ presentFrame ctx imageIndex (renderFinishedSemaphores !! (fromIntegral imageIndex))
          case presentResult of
            Vulkan.VK_SUCCESS -> pure (False, False)
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
  if (needRestart)
    then liftIO $ do
      logI "waiting IDLE state for device"
      Vulkan.vkDeviceWaitIdle device >>= throwVkResult
      logI "terminating renderFrameLoop"
      pure terminating
    else do
      let
        renderTime = frameEndTime - frameStartTime
        delay = ((1000000000 `div` targetFPS) - renderTime) `div` 1000
      liftIO $ threadDelay (fromIntegral delay)
      -- logI $ "renderTime: " <> showT renderTime <> " => delay: " <> showT delay
      renderFrameLoop
        ctx
        ((frameNumber + 1) `mod` Render.maxFramesInFlight)
        targetFPS
        imageAvailableSemaphores
        control
        mvpMemory
        tvCamera

--renderLoop :: MonadIO m => Integer -> RenderContext -> GameState -> MVar () -> TChan ControlMessage -> (String -> IO ()) -> m ()
renderLoop
  :: (Camera cam, MonadFail m, MonadManaged m)
  => Vulkan.VkPhysicalDevice
  -> Vulkan.VkSurfaceKHR
  -> [String]
  -> Integer
  -> GameState cam
  -> MVar ()
  -> TChan ControlMessage
  -> String
  -> m ()
renderLoop physicalDevice surface layers targetFPS gameState finishedSemaphore controlChannel meshName = do
  control <- liftIO $ STM.atomically $ TChan.dupTChan controlChannel

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

  --mesh <- Model.fromPie . head . PieLoader.levels <$> PieLoader.parsePie "data/models/pie/blbrbgen.pie"
  --mesh <- Model.fromPie . head . PieLoader.levels <$> PieLoader.parsePie "data/models/pie/blhq4.pie"
  --mesh <- Model.fromPie . head . PieLoader.levels <$> PieLoader.parsePie "data/models/pie/drhbod10.pie"
  --mesh <- Model.fromPie . head . PieLoader.levels <$> PieLoader.parsePie "data/models/pie/cube.pie"
  (mesh,_) <- Model.fromObj <$> ObjLoader.parseObj ("data/models/obj/" <> meshName)
  --(mesh,_) <- Model.fromObj <$> ObjLoader.parseObj "data/models/bmw27.obj"
  --(mesh,_) <- Model.fromObj <$> ObjLoader.parseObj "data/models/suzanne_subdiv1.obj"
  --(mesh,_) <- Model.fromObj <$> ObjLoader.parseObj "data/models/cube.obj"
  {-
  let
    zPos1 = ( 5)
    zPos2 = ( 3)
    zPos3 = ( 1)
    vertices =
      [Vertex {vPos = V3 (-1.0) ( 1.0) zPos1, vTexUV = V2 0.0 0.0, vNorm = V3 0.0 1.0 0.0, vCol = V4 255 0 0 255} -- 0
      ,Vertex {vPos = V3 (-1.0) (-1.0) zPos1, vTexUV = V2 0.0 1.0, vNorm = V3 0.0 1.0 0.0, vCol = V4 255 0 0 255} -- 1
      ,Vertex {vPos = V3 ( 1.0) (-1.0) zPos1, vTexUV = V2 1.0 1.0, vNorm = V3 0.0 1.0 0.0, vCol = V4 255 0 0 255} -- 2
      ,Vertex {vPos = V3 ( 1.0) ( 1.0) zPos1, vTexUV = V2 1.0 0.0, vNorm = V3 0.0 1.0 0.0, vCol = V4 255 0 0 255} -- 3

      ,Vertex {vPos = V3 (-1.0) ( 1.0) zPos2, vTexUV = V2 0.0 0.0, vNorm = V3 0.0 1.0 0.0, vCol = V4 0 255 0 255} -- 4
      ,Vertex {vPos = V3 (-1.0) (-1.0) zPos2, vTexUV = V2 0.0 1.0, vNorm = V3 0.0 1.0 0.0, vCol = V4 0 255 0 255} -- 5
      ,Vertex {vPos = V3 ( 1.0) (-1.0) zPos2, vTexUV = V2 1.0 1.0, vNorm = V3 0.0 1.0 0.0, vCol = V4 0 255 0 255} -- 6
      ,Vertex {vPos = V3 ( 1.0) ( 1.0) zPos2, vTexUV = V2 1.0 0.0, vNorm = V3 0.0 1.0 0.0, vCol = V4 0 255 0 255} -- 7

      ,Vertex {vPos = V3 (-1.0) ( 1.0) zPos3, vTexUV = V2 0.0 0.0, vNorm = V3 0.0 1.0 0.0, vCol = V4 255 255 0 255} -- 8
      ,Vertex {vPos = V3 (-1.0) (-1.0) zPos3, vTexUV = V2 0.0 1.0, vNorm = V3 0.0 1.0 0.0, vCol = V4 255 255 0 255} -- 9
      ,Vertex {vPos = V3 ( 1.0) (-1.0) zPos3, vTexUV = V2 1.0 1.0, vNorm = V3 0.0 1.0 0.0, vCol = V4 255 255 0 255} -- 10
      ,Vertex {vPos = V3 ( 1.0) ( 1.0) zPos3, vTexUV = V2 1.0 0.0, vNorm = V3 0.0 1.0 0.0, vCol = V4 255 255 0 255} -- 11
      ]
    indices = [
        0, 1, 2
      , 2, 3, 0

      , 4, 5, 6
      , 6, 7, 4

      , 8, 9, 10
      , 10, 11, 8
      ]
-}
  vertexBuffer <-
    Buffer.managedVertexBuffer
    physicalDevice
    device
    (Mesh.vertices mesh)

  indexBuffer <-
    Buffer.managedIndexBuffer
    physicalDevice
    device
    (Mesh.indices mesh)


  (mvpBuffer, mvpMemory) <-
    Buffer.managedUniformBuffer
       physicalDevice
       device
       [ modelMatrix, identity, projectionMatrix ]

  textureCommandBuffer <- CommandBuffer.createCommandBuffer device graphicsCommandPool
  textureImageView <-
    Texture.managedTexture
    physicalDevice
    device
--    "data/texture/redbricks2b/redbricks2b-albedo.png"
    "data/texture/page-14-droid-hubs.png"
    graphicsQueueHandler
    textureCommandBuffer

  textureSampler <- Texture.managedSampler device

  for_ descriptorSets $
    \descriptorSet ->
      DescriptorSet.updateDescriptorSets
        device
        descriptorSet
        mvpBuffer
        textureImageView
        textureSampler

  let
    mkRenderContext = Render.createRenderContext
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
      (length (Mesh.indices mesh))

  -- need to fetch RenderContext from Managed monad to allow proper resource deallocation
  worldState <- liftIO $ STM.readTVarIO (world gameState)
  let
    tvCamera = activeCamera worldState
    outerLoop :: (MonadFail m, MonadIO m) => Bool -> m ()
    outerLoop exit = do
      if exit
      then pure ()
      else do
        renderFrameLoopFinished <- liftIO $ with mkRenderContext $ \context ->
          renderFrameLoop context 0 targetFPS imageAvailableSemaphores control mvpMemory tvCamera
        outerLoop renderFrameLoopFinished

  logI "Starting render loop"
  liftIO $ outerLoop False

  logI "renderLoop finished"
  liftIO $ putMVar finishedSemaphore ()

modelMatrix :: M44 Foreign.C.CFloat
modelMatrix =
  let
    --rotate = m33_to_m44 (fromQuaternion (Linear.Quaternion.axisAngle (V3 1.0 1.0 0.0) (pi / 12)))
    --translate = identity & translation .~ V3 0 0 (5.0)
    rotate = identity
    translate = identity
  --in Linear.Matrix.transpose $ translate !*! rotate
  in translate !*! rotate
--  Linear.Matrix.identity

{-
viewMatrix :: V3 Foreign.C.CFloat -> V3 Foreign.C.CFloat -> M44 Foreign.C.CFloat
viewMatrix eyePos target = Linear.Matrix.transpose $
  Linear.Projection.lookAt eyePos target (V3 0.0 (-1.0) 0.0)
-}
projectionMatrix :: M44 Foreign.C.CFloat
projectionMatrix = Linear.Matrix.transpose $
--  Linear.Projection.infinitePerspective
  Linear.Projection.perspective
    (pi / 12) -- FOV
    (16/9) -- aspect ratio
    0.1 -- near plane
    10000.0 -- far plane

--  in Linear.Matrix.transpose (projection !*! view !*! model)

stateUpdateLoop :: (Camera cam, MonadIO m) => Integer -> GameState cam -> MVar () -> TQueue ActionEvent -> TChan ControlMessage -> m ()
stateUpdateLoop targetFPS gameState finishedSemaphore actionQueue controlChannel = liftIO $ do
  control <- STM.atomically $ TChan.dupTChan controlChannel

  let physicsStep = 1/120
      frameDelay = physicsStep * 100000
      camSpeed = 10

  let
    loop :: (Camera cam, MonadIO m) => Integer -> GameState cam -> Integer -> m ()
    loop tFPS _gameState prevTime = liftIO $ do
      maybeControlMessage <- STM.atomically $ TChan.tryReadTChan control
      case maybeControlMessage of
        Nothing -> do
          newTime <- liftIO $ toNanoSecs <$> getTime Monotonic
          actions <- STM.atomically $ TQueue.flushTQueue actionQueue
          worldState <- STM.readTVarIO (world gameState)
          let
            camera = activeCamera worldState
          for_ actions $ \action ->
            case action of
              (MoveForward, b) -> STM.atomically $ STM.writeTVar (moveForward gameState) b
              (MoveBackward, b) -> STM.atomically $ STM.writeTVar (moveBackward gameState) b
              (StrafeLeft, b) -> STM.atomically $ STM.writeTVar (strafeLeft gameState) b
              (StrafeRight, b) -> STM.atomically $ STM.writeTVar (strafeRight gameState) b
              (MouseMove (V2 x y), _) ->
                STM.atomically
                  (
                    updateCamera (activeCamera worldState)
                      [Camera.Rotate (
                          V3 ((fromIntegral x)/frameDelay) ((fromIntegral y)/frameDelay) 0.0
                          )
                      ]
                  )
              (Escape, _) -> STM.atomically $ STM.writeTVar (isRunning gameState) False
          let dt = newTime - prevTime

          (fwd, bwd, sl, sr, isRunning) <- STM.atomically $ do
            a <- STM.readTVar (moveForward gameState)
            b <- STM.readTVar (moveBackward gameState)
            c <- STM.readTVar (strafeLeft gameState)
            d <- STM.readTVar (strafeRight gameState)
            e <- STM.readTVar (isRunning gameState)
            pure (a,b,c,d,e)

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


updateCamera
  :: Camera cam
  => TVar cam
  -> [Camera.Modifier Foreign.C.CFloat]
  -> STM ()
updateCamera tvCamera mods = STM.modifyTVar' tvCamera $
  \cam -> Camera.update cam mods

data Event

data KeyModifier
  = LShift
  | RShift
  | LCtrl
  | RCtrl
  | LAlt
  | RAlt
  | LGUI
  | RGUI
  | NumLock
  | CapsLock
  | AltGr
  deriving (Eq, Enum, Generic, Show)

type KeyBindings = HashMap ([KeyModifier],SDL.Keycode) (Action)
instance Hashable KeyModifier
instance Hashable SDL.Keycode

defaultBindings :: KeyBindings
defaultBindings = HashMap.fromList
  [ ( ([], SDL.KeycodeW), MoveForward)
  , ( ([], SDL.KeycodeS), MoveBackward)
  , ( ([], SDL.KeycodeA), StrafeLeft)
  , ( ([], SDL.KeycodeD), StrafeRight )
  -- quit
  , ( ([LShift], SDL.KeycodeQ), Escape )
  ]
 
updateGameState :: Camera cam => TVar (GameState cam) -> TQueue Event -> STM ()
updateGameState gameState tqEvents = do
  events <- TQueue.flushTQueue tqEvents
  pure ()

modifiersToList :: SDL.KeyModifier -> [KeyModifier]
modifiersToList SDL.KeyModifier{..} = []
  <> if keyModifierLeftShift then [LShift] else []
  <> if keyModifierRightShift then [RShift] else []
  <> if keyModifierLeftCtrl then [LCtrl] else []
  <> if keyModifierRightCtrl then [RCtrl] else []
  <> if keyModifierLeftAlt then [LAlt] else []
  <> if keyModifierRightAlt then [RAlt] else []
--  <> if keyModifierLeftGUI then [LGUI] else []
--  <> if keyModifierRightGUI then [RGUI] else []
--  <> if keyModifierNumLock then [NumLock] else []
--  <> if keyModifierCapsLock then [CapsLock] else []
--  <> if keyModifierAltGr then [AltGr] else []
 
payloadToActionEvent :: SDL.EventPayload -> Maybe ActionEvent
payloadToActionEvent SDL.QuitEvent = Just (Escape, True)
payloadToActionEvent (SDL.KeyboardEvent keyboardEvent) = keyToAction keyboardEvent
payloadToActionEvent (SDL.MouseMotionEvent mouseMotionEvent) = mouseMotionToAction mouseMotionEvent
payloadToActionEvent _ = Nothing

mouseMotionToAction :: SDL.MouseMotionEventData -> Maybe ActionEvent
mouseMotionToAction (SDL.MouseMotionEventData _window _mouseDevice _mouseButtons _absolutePosition relativePosition) =
  let
    (SDL.V2 relX relY) = relativePosition
  in Just ((MouseMove (V2 (fromIntegral (relX*10)) (fromIntegral (relY*10)))), True)
 
keyToAction :: SDL.KeyboardEventData -> Maybe ActionEvent
keyToAction (SDL.KeyboardEventData _window motion isRepeated keysym)
  | isRepeated = Nothing
  | otherwise =
      let
        modifiers = modifiersToList (SDL.keysymModifier keysym)
        key = SDL.keysymKeycode keysym
      in case HashMap.lookup (modifiers, key) defaultBindings of
           Just action -> Just (action,motion == SDL.Pressed)
           Nothing -> Nothing

keyToAction _ = Nothing
