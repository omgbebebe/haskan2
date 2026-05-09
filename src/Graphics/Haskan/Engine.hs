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
import Control.Exception (SomeException, try)
import Control.Lens ((^.))
import Control.Monad (forM, forM_, replicateM, unless, when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged, runManaged, with)
import Data.Aeson (ToJSON (..), object, (.=))
import Data.Foldable (for_, toList)
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HashMap
import Data.Hashable (Hashable (..))
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (nub, sort)
import Data.Maybe (catMaybes)
import Data.Sequence (Seq(..))
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector.Storable qualified as Vector
import Data.Word (Word32, Word64)
import Data.Int (Int32)

import FIR qualified
import Foreign.C qualified
import Foreign.Marshal.Array qualified
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (Storable (..), peekByteOff, pokeByteOff)
import GHC.Generics
import Graphics.Haskan.Camera (Camera (..))
import Graphics.Haskan.Camera qualified as Camera
import Graphics.Haskan.Debug.FrameInspector (FrameInspector, RenderableSnapshot (..), defaultInspector, buildFrameSnapshot)
import Graphics.Haskan.Debug.Interface (DebugCommand (..), DebugMessage (..), DebugResponse (..), GameStateSnapshot (..), DebugCameraSnapshot (..), debugMessageToActionEvent, parseDebugMessage, encodeDebugResponse)
import Graphics.Haskan.Debug.Screenshot qualified as Screenshot
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
import Graphics.Haskan.Scene.Transform qualified as Transform
import Graphics.Haskan.Assets.Cache (initCache)
import Graphics.Haskan.BoundingBox (BBox (..), bboxCenter, bboxDiagonal, emptyBBox, fromPoints, mergeBBox, mergePoint)
import Graphics.Haskan.Resources (throwVkResult, allocaAndPeek)
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
import Linear (M44, V2 (..), V3 (..), V4 (..), (^+^), (^-^))
import Linear.Matrix (identity, transpose, (!*), (!*!))
import Linear.Projection qualified
import Linear.Quaternion (Quaternion (..))
import Linear.V3 (_x, _y, _z)
import Linear.V4 (_w)
import SDL qualified
import System.IO.Unsafe (unsafePerformIO)
import System.Clock (Clock (..), getTime, toNanoSecs)
import System.Directory (doesFileExist)

toListOfV4 :: V4 (V4 a) -> [[a]]
toListOfV4 (V4 r1 r2 r3 r4) = [toList r1, toList r2, toList r3, toList r4]
  where
    toList (V4 a b c d) = [a, b, c, d]

-- | Fork an IO action with exception handling. Always puts the MVar on completion.
forkIOWithHandler :: String -> MVar () -> IO () -> IO ()
forkIOWithHandler name finishedSemaphore action = do
  _ <- forkIO $ do
    result <- try @SomeException action
    case result of
      Left err -> do
        logInfoIO LogGeneral $ Text.pack name <> " thread crashed: " <> Text.pack (show err)
        putMVar finishedSemaphore ()
      Right () -> putMVar finishedSemaphore ()
  pure ()

-- | Bounded input buffer with overflow tracking.
data InputBuffer = InputBuffer
  { ibEvents :: !(TVar (Seq ActionEvent))
  , ibOverflow :: !(TVar Word64)
  }

newInputBuffer :: IO InputBuffer
newInputBuffer = do
  events <- STM.newTVarIO Seq.empty
  overflow <- STM.newTVarIO 0
  pure (InputBuffer events overflow)

writeInputBuffer :: InputBuffer -> ActionEvent -> STM ()
writeInputBuffer (InputBuffer eventsVar overflowVar) event = do
  events <- STM.readTVar eventsVar
  let events' = events Seq.|> event
  if Seq.length events' > 256
    then do
      STM.writeTVar eventsVar (Seq.drop 1 events')
      STM.modifyTVar' overflowVar (+ 1)
    else STM.writeTVar eventsVar events'

flushInputBuffer :: InputBuffer -> STM ([ActionEvent], Word64)
flushInputBuffer (InputBuffer eventsVar overflowVar) = do
  events <- STM.readTVar eventsVar
  overflow <- STM.readTVar overflowVar
  STM.writeTVar eventsVar Seq.empty
  STM.writeTVar overflowVar 0
  pure (toList events, overflow)

-- | Compute culling entity data (matches shader EntityData, Base/std430 layout).
-- Array stride is 128 bytes.
data ComputeEntityData = ComputeEntityData
  { ceTransform :: M44 Foreign.C.CFloat
  , ceAabbMin :: V4 Foreign.C.CFloat
  , ceAabbMax :: V4 Foreign.C.CFloat
  , ceMaterialIndex :: Word32
  , ceFirstIndex :: Word32
  , ceVertexOffset :: Foreign.C.CInt
  , ceIndexCount :: Word32
  , ceMetallicRoughnessIndex :: Word32
  , ceMetallicFactor :: Foreign.C.CFloat
  , ceRoughnessFactor :: Foreign.C.CFloat
  , ceNormalIndex :: Word32
  , ceOcclusionIndex :: Word32
  , ceOcclusionStrength :: Foreign.C.CFloat
  , ceEmissiveIndex :: Word32
  } deriving (Show)

instance Storable ComputeEntityData where
  sizeOf _ = 144
  alignment _ = 16
  peek ptr = ComputeEntityData
    <$> peekByteOff ptr 0
    <*> peekByteOff ptr 64
    <*> peekByteOff ptr 80
    <*> peekByteOff ptr 96
    <*> peekByteOff ptr 100
    <*> peekByteOff ptr 104
    <*> peekByteOff ptr 108
    <*> peekByteOff ptr 112
    <*> peekByteOff ptr 116
    <*> peekByteOff ptr 120
    <*> peekByteOff ptr 124
    <*> peekByteOff ptr 128
    <*> peekByteOff ptr 132
    <*> peekByteOff ptr 136
  poke ptr (ComputeEntityData t amin amax mat fi vo ic mri met rou ni oi os ei) = do
    pokeByteOff ptr 0 t
    pokeByteOff ptr 64 amin
    pokeByteOff ptr 80 amax
    pokeByteOff ptr 96 mat
    pokeByteOff ptr 100 fi
    pokeByteOff ptr 104 vo
    pokeByteOff ptr 108 ic
    pokeByteOff ptr 112 mri
    pokeByteOff ptr 116 met
    pokeByteOff ptr 120 rou
    pokeByteOff ptr 124 ni
    pokeByteOff ptr 128 oi
    pokeByteOff ptr 132 os
    pokeByteOff ptr 136 ei

-- | Compute culling uniform data (matches shader CullData, Extended/std140 layout).
data ComputeCullData = ComputeCullData
  { ccFrustumPlanes :: [V4 Foreign.C.CFloat]  -- 6 planes at offsets 0,16,32,48,64,80
  , ccCameraPosition :: V4 Foreign.C.CFloat    -- offset 96
  , ccEntityCount :: Word32                    -- offset 112
  , ccLodDistance1 :: Foreign.C.CFloat         -- offset 116
  , ccLodDistance2 :: Foreign.C.CFloat         -- offset 120
  , ccPad3 :: Word32                           -- offset 124
  } deriving (Show)

instance Storable ComputeCullData where
  sizeOf _ = 128
  alignment _ = 16
  peek ptr = do
    planes <- sequence [peekByteOff ptr (i * 16) | i <- [0..5]]
    camPos <- peekByteOff ptr 96
    count <- peekByteOff ptr 112
    lod1 <- peekByteOff ptr 116
    lod2 <- peekByteOff ptr 120
    pad <- peekByteOff ptr 124
    pure (ComputeCullData planes camPos count lod1 lod2 pad)
  poke ptr (ComputeCullData planes camPos count lod1 lod2 pad) = do
    forM_ (zip [0..5] planes) $ \(i, p) -> pokeByteOff ptr (i * 16) p
    pokeByteOff ptr 96 camPos
    pokeByteOff ptr 112 count
    pokeByteOff ptr 116 lod1
    pokeByteOff ptr 120 lod2
    pokeByteOff ptr 124 pad

-- | Matches VkDrawIndexedIndirectCommand layout (20 bytes, 4-byte alignment).
data DrawIndexedIndirectCommand = DrawIndexedIndirectCommand
  { diicIndexCount :: Word32
  , diicInstanceCount :: Word32
  , diicFirstIndex :: Word32
  , diicVertexOffset :: Int32
  , diicFirstInstance :: Word32
  } deriving (Show)

instance Storable DrawIndexedIndirectCommand where
  sizeOf _ = 20
  alignment _ = 4
  peek ptr = DrawIndexedIndirectCommand
    <$> peekByteOff ptr 0
    <*> peekByteOff ptr 4
    <*> peekByteOff ptr 8
    <*> peekByteOff ptr 12
    <*> peekByteOff ptr 16
  poke ptr (DrawIndexedIndirectCommand ic ins fi vo fii) = do
    pokeByteOff ptr 0 ic
    pokeByteOff ptr 4 ins
    pokeByteOff ptr 8 fi
    pokeByteOff ptr 12 vo
    pokeByteOff ptr 16 fii

-- | Resources for GPU-driven compute culling.
data ComputeCullResources = ComputeCullResources
  { ccrPipeline :: Vulkan.VkPipeline
  , ccrPipelineLayout :: Vulkan.VkPipelineLayout
  , ccrDescriptorSet :: Vulkan.VkDescriptorSet
  , ccrEntityBuffer :: Vulkan.VkBuffer
  , ccrEntityMemory :: Vulkan.VkDeviceMemory
  , ccrDrawCommandsBuffer :: Vulkan.VkBuffer
  , ccrDrawCommandsMemory :: Vulkan.VkDeviceMemory
  , ccrCullDataBuffer :: Vulkan.VkBuffer
  , ccrCullDataMemory :: Vulkan.VkDeviceMemory
  , ccrMaxEntities :: Int
  }

-- | Transform local AABB to world space by transforming all 8 corners.
transformAABB :: M44 Float -> BBox -> (V3 Float, V3 Float)
transformAABB worldMat (BBox (V3 minX minY minZ) (V3 maxX maxY maxZ)) =
  let corners =
        [ V3 minX minY minZ, V3 maxX minY minZ, V3 minX maxY minZ, V3 maxX maxY minZ
        , V3 minX minY maxZ, V3 maxX minY maxZ, V3 minX maxY maxZ, V3 maxX maxY maxZ
        ]
      worldCorners = map (\(V3 x y z) -> let V4 wx wy wz _ = worldMat !* V4 x y z 1 in V3 wx wy wz) corners
      xs = map (\(V3 x _ _) -> x) worldCorners
      ys = map (\(V3 _ y _) -> y) worldCorners
      zs = map (\(V3 _ _ z) -> z) worldCorners
  in (V3 (minimum xs) (minimum ys) (minimum zs), V3 (maximum xs) (maximum ys) (maximum zs))

-- | Extract 6 frustum planes from a row-major view-projection matrix.
-- Returns planes in order: left, right, bottom, top, near, far.
-- Plane normal points inward (towards visible volume).
extractFrustumPlanes :: M44 Float -> [V4 Float]
extractFrustumPlanes vp =
  let r1 = vp ^. _x
      r2 = vp ^. _y
      r3 = vp ^. _z
      r4 = vp ^. _w
      left   = r1 ^+^ r4
      right  = r4 ^-^ r1
      bottom = r2 ^+^ r4
      top    = r4 ^-^ r2
      near   = r3 ^+^ r4
      far    = r4 ^-^ r3
  in [left, right, bottom, top, near, far]

-- | Filter draw list using visible flags from previous frame.
filterVisible :: [DrawCall] -> IntMap Word32 -> [DrawCall]
filterVisible drawList visibleFlags =
  [dc | (idx, dc) <- zip [0..] drawList, IntMap.findWithDefault 1 idx visibleFlags == 1]

data EngineConfig = EngineConfig
  { targetRenderFPS :: !Integer,
    targetPhysicsFPS :: !Integer,
    targetNetworkFPS :: !Integer,
    targetInputFPS :: !Integer,
    title :: !Text,
    debugSocketPath :: !(Maybe FilePath),
    timeoutSeconds :: !(Maybe Integer),
    uvCheckMode :: !(Maybe String)
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
    wireframeEnabled :: TVar Bool,
    debugMode :: TVar Word32,
    pendingScreenshot :: TVar Bool,
    pendingAllStages :: TVar Bool
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
  inputBuffer <- liftIO newInputBuffer
  debugCmdQueue <- liftIO $ STM.newTQueueIO
  -- movement state
  tvMoveForward <- liftIO $ STM.newTVarIO (False)
  tvMoveBackward <- liftIO $ STM.newTVarIO (False)
  tvStrafeLeft <- liftIO $ STM.newTVarIO (False)
  tvStrafeRight <- liftIO $ STM.newTVarIO (False)

  tvInspectFrame <- liftIO $ STM.newTVarIO False
  tvInspector <- liftIO $ STM.newTVarIO (Just (defaultInspector "snapshots"))
  tvRenderDebugState <- liftIO $ STM.newTVarIO Nothing
  tvWireframeEnabled <- liftIO $ STM.newTVarIO False
  tvDebugMode <- liftIO $ STM.newTVarIO 0
  tvPendingScreenshot <- liftIO $ STM.newTVarIO False
  tvPendingAllStages <- liftIO $ STM.newTVarIO False

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
          tvDebugMode
          tvPendingScreenshot
          tvPendingAllStages

  -- Start debug server if configured
  mDebugServer <- case debugSocketPath of
    Just path -> do
      h <- startDebugServer path (\ev -> STM.atomically $ writeInputBuffer inputBuffer ev) debugCmdQueue
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
  liftIO $ forkIOWithHandler "renderLoop" renderLoopFinished $ runManaged $ renderLoop physicalDevice surface layers targetRenderFPS gameState renderLoopFinished controlChannel meshName uvCheckMode

  stateUpdateLoopFinished <- liftIO $ newEmptyMVar
  liftIO $ forkIOWithHandler "stateUpdateLoop" stateUpdateLoopFinished $ stateUpdateLoop targetPhysicsFPS gameState stateUpdateLoopFinished inputBuffer debugCmdQueue controlChannel

  let inputLoop :: MonadIO m => m ()
      inputLoop = do
        events <- SDL.pollEvents
        let actionEvents = catMaybes $ map (payloadToActionEvent . SDL.eventPayload) events
            quitting = any (\(a, p, _) -> a == Escape && p) actionEvents
        liftIO $ STM.atomically $ for_ actionEvents $ writeInputBuffer inputBuffer
        when (not (null actionEvents)) $ logInfoIO LogGeneral $ "input: " <> showT (length actionEvents) <> " events, first=" <> showT (head actionEvents)
        running <- liftIO $ STM.readTVarIO isRunning
        let inputDelayMicros = max 1 (1000000 `div` fromIntegral targetInputFPS)
        liftIO $ threadDelay (fromIntegral inputDelayMicros)
        unless (quitting || not running) inputLoop

  logInfoIO LogGeneral "inputLoop starting"
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
  Vulkan.VkSampler ->
  [Vulkan.VkDescriptorSet] ->
  IntMap Word32 ->
  STM.TVar Bool ->
  IORef FrameStats ->
  ComputeCullResources ->
  STM.TVar Word32 ->
  STM.TVar Bool ->
  STM.TVar Bool ->
  Vulkan.VkPhysicalDevice ->
  m Bool
renderFrameLoop ctx@RenderContext {..} dr@DeferredResources {..} frameNumber targetFPS imageAvailableSemaphores control frameMvpMemories tvCamera tvInspect tvInsp tvRenderDebug ecsWorld rm textureSampler frameDescriptorSets textureIndexMap tvWireframe frameStatsRef ccr@ComputeCullResources {..} tvDebugMode tvPendingScreenshot tvPendingAllStages physicalDevice = do
  frameStartTime <- liftIO $ toNanoSecs <$> getTime Monotonic
  maybeControlMessage <- liftIO $ STM.atomically $ TChan.tryReadTChan control
  (needRestart, terminating) <- case maybeControlMessage of
    Nothing -> do
      let imageAvailableSemaphore = imageAvailableSemaphores !! (frameNumber)
          mvpMemory = frameMvpMemories !! frameNumber
      camera <- liftIO $ STM.readTVarIO tvCamera
      drawList <- extractDrawList ecsWorld rm textureIndexMap
      logDebugIO LogRender $ "draw list: " <> showT (length drawList) <> " entities"
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
      -- Upload compute culling data
      entityData <- liftIO $ forM (zip [0..] drawList) $ \(idx, dc) -> do
        let worldMat = dcWorldMatrix dc
            meshRes = dcMesh dc
            (wmin, wmax) = transformAABB worldMat (mrBounds meshRes)
        pure ComputeEntityData
          { ceTransform = (realToFrac <$>) <$> Linear.Matrix.transpose worldMat
          , ceAabbMin = V4 (realToFrac $ wmin ^. _x) (realToFrac $ wmin ^. _y) (realToFrac $ wmin ^. _z) 1
          , ceAabbMax = V4 (realToFrac $ wmax ^. _x) (realToFrac $ wmax ^. _y) (realToFrac $ wmax ^. _z) (1 :: Foreign.C.CFloat)
          , ceMaterialIndex = dcMaterialIndex dc
          , ceFirstIndex = fromIntegral (mrFirstIndex meshRes)
          , ceVertexOffset = fromIntegral (mrVertexOffset meshRes)
          , ceIndexCount = fromIntegral (mrIndexCount meshRes)
          , ceMetallicRoughnessIndex = dcMetallicRoughnessIndex dc
          , ceMetallicFactor = realToFrac (dcMetallicFactor dc)
          , ceRoughnessFactor = realToFrac (dcRoughnessFactor dc)
          , ceNormalIndex = dcNormalIndex dc
          , ceOcclusionIndex = dcOcclusionIndex dc
          , ceOcclusionStrength = realToFrac (dcOcclusionStrength dc)
          , ceEmissiveIndex = dcEmissiveIndex dc
          }
      let vp = (realToFrac <$>) <$> (projectionMatrix !*! Camera.unViewMatrix (Camera.toMatrix camera)) :: M44 Float
          planes = extractFrustumPlanes vp
          camPos = Camera.cameraPosition camera
          cullData = ComputeCullData
            { ccFrustumPlanes = map (fmap realToFrac) planes
            , ccCameraPosition = V4 (realToFrac $ camPos ^. _x) (realToFrac $ camPos ^. _y) (realToFrac $ camPos ^. _z) 1
            , ccEntityCount = fromIntegral (length drawList)
            , ccLodDistance1 = 100.0
            , ccLodDistance2 = 400.0
            , ccPad3 = 0
            }
      liftIO $ Buffer.updateStorageBuffer device ccrEntityMemory 0 entityData
      liftIO $ Buffer.updateUniformBuffer device ccrCullDataMemory [cullData]
      logDebugIO LogRender $ "compute culling data uploaded: " <> showT (length entityData) <> " entities"
      case drawList of
        [] -> pure (False, False)
        _ -> do
          let view = Linear.Matrix.transpose $ Camera.unViewMatrix (Camera.toMatrix camera)
              projection = Linear.Matrix.transpose projectionMatrix
          -- Log camera position periodically for manual positioning
          when (frameNumber `mod` 60 == 0) $ do
            let cp = Camera.cameraPosition camera
            logInfoIO LogGeneral $ "camera: pos=" <> showT cp <> " dist=" <> showT (Camera.cameraDistance camera) <> " az=" <> showT (Camera.cameraAzimuth camera) <> " el=" <> showT (Camera.cameraElevation camera)
          -- Update static view+proj UBO (no per-entity dynamic offsets)
          liftIO $ Buffer.updateUniformBufferRegion device mvpMemory 0 [view, projection]

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
                debugMode' <- liftIO $ STM.readTVarIO tvDebugMode

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
                        , dpdDevice = device
                        , dpdDrawCommandsBuffer = ccrDrawCommandsBuffer
                        , dpdEntityCount = fromIntegral (length drawList)
                        , dpdLightingRenderPass = drLightingRenderPass
                        , dpdLightingFramebuffer = lightingFramebuffer
                        , dpdLightingPipeline = drLightingPipeline
                        , dpdLightingLayout = drLightingPipelineLayout
                        , dpdLightingDescriptor = lightingDescriptorSet
                        , dpdCameraPos = realToFrac <$> Camera.cameraPosition camera
                        , dpdDebugMode = debugMode'
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
                        -- Barrier: compute writes to drawCommands buffer before graphics reads it for indirect draw
                        liftIO $ CommandBuffer.cmdBufferBarrier
                          commandBuffer
                          ccrDrawCommandsBuffer
                          (fromIntegral (ccrMaxEntities * sizeOf (undefined :: DrawIndexedIndirectCommand)))
                          Vulkan.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT
                          Vulkan.VK_ACCESS_SHADER_WRITE_BIT
                          Vulkan.VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT
                          Vulkan.VK_ACCESS_INDIRECT_COMMAND_READ_BIT

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
                  -- Check for screenshot requests
                  liftIO $ do
                    shouldScreenshot <- STM.atomically $ do
                      b <- STM.readTVar tvPendingScreenshot
                      when b $ STM.writeTVar tvPendingScreenshot False
                      pure b
                    when shouldScreenshot $ do
                      Vulkan.vkDeviceWaitIdle device >>= throwVkResult
                      let gbufferImages = drGBufferImages !! fromIntegral imageIndex
                      logInfoIO LogGeneral "capturing screenshot..."
                      Screenshot.saveGBufferStage device physicalDevice rcGraphicsCommandPool graphicsQueueHandler (gbufferImages !! 2) rcSurfaceExtent Vulkan.VK_FORMAT_R8G8B8A8_UNORM "albedo"
                      logInfoIO LogGeneral "screenshot saved"
                    shouldAllStages <- STM.atomically $ do
                      b <- STM.readTVar tvPendingAllStages
                      when b $ STM.writeTVar tvPendingAllStages False
                      pure b
                    when shouldAllStages $ do
                      Vulkan.vkDeviceWaitIdle device >>= throwVkResult
                      let gbufferImages = drGBufferImages !! fromIntegral imageIndex
                      logInfoIO LogGeneral "capturing all pipeline stages..."
                      Screenshot.saveGBufferStage device physicalDevice rcGraphicsCommandPool graphicsQueueHandler (gbufferImages !! 0) rcSurfaceExtent Vulkan.VK_FORMAT_R16G16B16A16_SFLOAT "position"
                      Screenshot.saveGBufferStage device physicalDevice rcGraphicsCommandPool graphicsQueueHandler (gbufferImages !! 1) rcSurfaceExtent Vulkan.VK_FORMAT_R8G8B8A8_UNORM "normal"
                      Screenshot.saveGBufferStage device physicalDevice rcGraphicsCommandPool graphicsQueueHandler (gbufferImages !! 2) rcSurfaceExtent Vulkan.VK_FORMAT_R8G8B8A8_UNORM "albedo"
                      Screenshot.saveGBufferStage device physicalDevice rcGraphicsCommandPool graphicsQueueHandler (gbufferImages !! 3) rcSurfaceExtent Vulkan.VK_FORMAT_R8G8B8A8_UNORM "emissive"
                      logInfoIO LogGeneral "all stages saved"
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
        textureSampler
        frameDescriptorSets
        textureIndexMap
        tvWireframe
        frameStatsRef
        ccr
        tvDebugMode
        tvPendingScreenshot
        tvPendingAllStages
        physicalDevice

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
  Maybe String ->
  m ()
renderLoop physicalDevice surface layers targetFPS gameState finishedSemaphore controlChannel meshName uvCheckMode = do
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

  -- Load IBL cubemaps
  let envDir = "data/hdri/env/"
      radianceFacePaths = map (envDir ++) ["env+X.png", "env-X.png", "env+Y.png", "env-Y.png", "env+Z.png", "env-Z.png"]
      irradianceFacePaths = map (envDir ++) ["irradiance_posx.png", "irradiance_negx.png", "irradiance_posy.png", "irradiance_negy.png", "irradiance_posz.png", "irradiance_negz.png"]
  radianceFaceDatas <- liftIO $ mapM Texture.readImageFromFile radianceFacePaths
  irradianceFaceDatas <- liftIO $ mapM Texture.readImageFromFile irradianceFacePaths
  let (radDatas, radWidths, _) = unzip3 radianceFaceDatas
      (irrDatas, irrWidths, _) = unzip3 irradianceFaceDatas
      radSize = head radWidths
      irrSize = head irrWidths
  radianceCubemap <- Texture.createCubemap rm physicalDevice device radSize radDatas graphicsQueueHandler textureCommandBuffer
  irradianceCubemap <- Texture.createCubemap rm physicalDevice device irrSize irrDatas graphicsQueueHandler textureCommandBuffer
  mRadianceView <- Texture.textureImageView rm radianceCubemap
  mIrradianceView <- Texture.textureImageView rm irradianceCubemap
  logInfoIO LogGeneral $ "IBL cubemaps loaded: radiance=" <> showT radSize <> "px irradiance=" <> showT irrSize <> "px"

  -- Initialize asset cache for texture preprocessing
  assetCache <- initCache ".haskan2-cache"

  let isGLTF = ".gltf" `Text.isSuffixOf` Text.pack meshName || ".glb" `Text.isSuffixOf` Text.pack meshName
      isStressTest = meshName == "stress_test"

  -- Create ECS World and load scene
  (ecsWorld, numEntities, sceneBounds, texturePixelMap) <- case uvCheckMode of
    Just mode -> do
      -- UV check mode: render primitive with UV checker texture
      world <- ECS.createWorld
      let testMesh = case mode of
            "cube" -> Mesh.unitCube
            "sphere" -> Mesh.uvSphere 32 32 0.5
            "plane" -> Mesh.uvPlane 0.5
            _ -> Mesh.unitCube
      meshHandle <- Buffer.createMeshResource rm physicalDevice device (Mesh.vertices testMesh) (Mesh.indices testMesh)
      -- Try to load UV checker texture, fallback to generated checkerboard
      let uvCheckerPath = "data/textures/uv_checker.png"
      uvTexHandle <- liftIO (doesFileExist uvCheckerPath) >>= \exists ->
        if exists
          then do
            (pixelData, tw, th) <- Texture.readImageFromFile uvCheckerPath
            Texture.createTextureFromData rm physicalDevice device tw th pixelData graphicsQueueHandler textureCommandBuffer
          else do
            let checkerTexData = Texture.generateCheckerboardTexture 256 256 32
            Texture.createTextureFromData rm physicalDevice device 256 256 checkerTexData graphicsQueueHandler textureCommandBuffer
      entity <- ECS.spawnEntity world
      ECS.setTransform world entity (Transform (V3 0 0 0) (Quaternion 1 (V3 0 0 0)) (V3 1 1 1))
      ECS.setMesh world entity meshHandle
      ECS.setMaterial world entity uvTexHandle
      ECS.setMetallicFactor world entity 0.0
      ECS.setRoughnessFactor world entity 0.5
      let sceneBbox = BBox (V3 (-1) (-1) (-1)) (V3 1 1 1)
      pure (world, 1, sceneBbox, IntMap.empty)

    Nothing -> if isStressTest
    then do
      -- Stress test: 10,000 cube entities
      world <- ECS.createWorld
      let cubeMesh = Mesh.unitCube
      meshHandle <- Buffer.createMeshResource rm physicalDevice device (Mesh.vertices cubeMesh) (Mesh.indices cubeMesh)
      let whiteTexData = Texture.generateGridTexture 2 2 1
      whiteTexHandle <- Texture.createTextureFromData rm physicalDevice device 2 2 whiteTexData graphicsQueueHandler textureCommandBuffer

      liftIO $ logInfoIO LogGeneral "spawning 10000 stress test entities"
      forM_ [0..9999] $ \i -> do
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
      logInfoIO LogGeneral $ "stress test scene bounds: " <> showT sceneBbox
      pure (world, 10000, sceneBbox, IntMap.empty)

    else if isGLTF
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

      -- Compute world-space scene bounds from ECS entities
      sceneBbox <- liftIO $ computeWorldSpaceBounds world rm
      logInfoIO LogGeneral $ "scene bounds: " <> showT sceneBbox

      pure (world, length meshes, sceneBbox, pixelMap)
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

      -- Add ground plane with checkerboard texture
      let groundMesh = Mesh.groundPlaneMesh 50.0
      groundMeshHandle <- Buffer.createMeshResource rm physicalDevice device (Mesh.vertices groundMesh) (Mesh.indices groundMesh)
      let checkerTexData = Texture.generateCheckerboardTexture 256 256 32
      checkerTexHandle <- Texture.createTextureFromData rm physicalDevice device 256 256 checkerTexData graphicsQueueHandler textureCommandBuffer
      groundEntity <- ECS.spawnEntity world
      ECS.setTransform world groundEntity (Transform (V3 0 0 (-0.5)) (Quaternion 1 (V3 0 0 0)) (V3 1 1 1))
      ECS.setMesh world groundEntity groundMeshHandle
      ECS.setMaterial world groundEntity checkerTexHandle
      ECS.setMetallicFactor world groundEntity 0.0
      ECS.setRoughnessFactor world groundEntity 1.0

      -- Compute world-space bounds from ECS entities (includes ground plane)
      sceneBbox <- liftIO $ computeWorldSpaceBounds world rm
      logInfoIO LogGeneral $ "scene bounds: " <> showT sceneBbox

      pure (world, 4, sceneBbox, IntMap.empty)  -- 3 cubes + ground plane

  -- Adjust camera based on scene bounds
  worldState <- liftIO $ STM.readTVarIO (world gameState)
  let tvCamera = activeCamera worldState
  currentCam <- liftIO $ STM.readTVarIO tvCamera
  let adjustedCam = if isStressTest
        then setDistance (setTarget currentCam (V3 0 0 0 :: V3 Foreign.C.CFloat)) (150.0 :: Foreign.C.CFloat)
        else adjustCameraForScene sceneBounds currentCam
      -- Default camera for UV check mode: slightly elevated, looking at origin
      inspectCam = case uvCheckMode of
        Just _ -> setAngles (setDistance (setTarget adjustedCam (V3 0 0 0 :: V3 Foreign.C.CFloat)) 2.0) 0.78 (realToFrac (pi / 6 :: Double))
        Nothing -> setAngles (setDistance adjustedCam 3.1) 2.3520544 (-0.39384797)
  liftIO $ STM.atomically $ STM.writeTVar tvCamera inspectCam
  logInfoIO LogGeneral $ "camera adjusted to distance=" <> showT (Camera.cameraDistance inspectCam)

  -- Ensure wireframe is off for stress test (performance)
  when isStressTest $ liftIO $ STM.atomically $ STM.writeTVar (wireframeEnabled gameState) False

  -- Determine actual entity count for buffer/descriptor allocation
  initialDrawList <- extractDrawList ecsWorld rm IntMap.empty
  let numDrawEntities = length initialDrawList
  logInfoIO LogRender $ "initial draw list has " <> showT numDrawEntities <> " entities"

  -- Merge all unique meshes into single vertex/index buffers for GPU-driven indirect draw
  liftIO $ do
    let meshHandles = nub (map (mrHandle . dcMesh) initialDrawList)
    unless (null meshHandles) $ do
      (mergedMesh, offsets) <- Buffer.mergeMeshes rm physicalDevice device meshHandles
      -- Update each mesh in registry to use shared merged buffers with correct offsets
      let sharedVertBuf = (mrVertexBuffer mergedMesh) { brDestroy = pure () }
          sharedIdxBuf = (mrIndexBuffer mergedMesh) { brDestroy = pure () }
      forM_ (HashMap.toList offsets) $ \(mh, (fi, vo)) -> do
        mMesh <- lookupMesh rm mh
        forM_ mMesh $ \mesh -> do
          updateMesh rm mh $ mesh
            { mrVertexBuffer = sharedVertBuf
            , mrIndexBuffer = sharedIdxBuf
            , mrFirstIndex = fi
            , mrVertexOffset = 0  -- indices already remapped in mergeMeshes, no additional offset
            }
      logInfoIO LogRender $ "merged " <> showT (length meshHandles) <> " meshes into single buffers"

  -- Create per-frame uniform buffers for view+proj (static, no dynamic offsets)
  let viewProjUniformSize = 128 :: Int
      initialViewProjData = [identity, projectionMatrix] :: [M44 Foreign.C.CFloat]

  logDebugIO LogBuffer $ "initialViewProjData length=" <> showT (length initialViewProjData) <> " size=" <> showT (length initialViewProjData * sizeOf (undefined :: M44 Foreign.C.CFloat))
  frameMvpBuffers <- replicateM Render.maxFramesInFlight $
    Buffer.managedUniformBuffer physicalDevice device initialViewProjData
  logDebugIO LogBuffer $ "frameMvpBuffers created, count=" <> showT (length frameMvpBuffers)

  -- Create compute culling buffers
  let maxEntities = 16384 :: Int
      dummyEntityData = ComputeEntityData
        { ceTransform = identity
        , ceAabbMin = V4 (-1000) (-1000) (-1000) 1
        , ceAabbMax = V4 1000 1000 1000 1
        , ceMaterialIndex = 0
        , ceFirstIndex = 0
        , ceVertexOffset = 0
        , ceIndexCount = 0
        , ceMetallicRoughnessIndex = 0
        , ceMetallicFactor = 0.0
        , ceRoughnessFactor = 0.5
        , ceNormalIndex = 0
        , ceOcclusionIndex = 0
        , ceOcclusionStrength = 1.0
        , ceEmissiveIndex = 0
        }
      dummyCullData = ComputeCullData
        { ccFrustumPlanes = replicate 6 (V4 0 0 0 0)
        , ccCameraPosition = V4 0 0 0 1
        , ccEntityCount = fromIntegral numDrawEntities
        , ccLodDistance1 = 1000.0
        , ccLodDistance2 = 5000.0
        , ccPad3 = 0
        }
      initialDrawCommands = replicate maxEntities (DrawIndexedIndirectCommand 0 0 0 0 0)

  (entitySsboBuffer, entitySsboMemory) <- Buffer.managedStorageBuffer physicalDevice device (replicate maxEntities dummyEntityData) Vulkan.VK_ZERO_FLAGS
  (drawCommandsBuffer, drawCommandsMemory) <- Buffer.managedStorageBuffer physicalDevice device initialDrawCommands Vulkan.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT
  (cullDataBuffer, cullDataMemory) <- Buffer.managedUniformBuffer physicalDevice device [dummyCullData]
  logDebugIO LogBuffer $ "compute buffers created: entitySSBO=" <> showT (maxEntities * sizeOf (undefined :: ComputeEntityData)) <> " drawCommands=" <> showT (maxEntities * sizeOf (undefined :: DrawIndexedIndirectCommand)) <> " cullData=" <> showT (sizeOf (undefined :: ComputeCullData))

  -- Update compute descriptor set with buffers
  DescriptorSet.updateComputeDescriptorSets device computeDescriptorSet entitySsboBuffer drawCommandsBuffer cullDataBuffer
  logDebugIO LogRender "compute descriptor set updated"

  let computeCullResources = ComputeCullResources
        { ccrPipeline = computePipeline
        , ccrPipelineLayout = computePipelineLayout
        , ccrDescriptorSet = computeDescriptorSet
        , ccrEntityBuffer = entitySsboBuffer
        , ccrEntityMemory = entitySsboMemory
        , ccrDrawCommandsBuffer = drawCommandsBuffer
        , ccrDrawCommandsMemory = drawCommandsMemory
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

  -- Update each frame descriptor set with the frame's uniform buffer, bindless textures, and entity SSBO
  logInfoIO LogVulkan "updating frame descriptor sets"
  for_ (zip [0..] frameMvpBuffers) $ \(frameIdx, (buf, _)) -> do
    let ds = frameDescriptorSets !! frameIdx
    DescriptorSet.updateDescriptorSetsBindless
      device
      ds
      buf
      (fromIntegral viewProjUniformSize)
      textureSampler
      bindlessTextureViews
      entitySsboBuffer
  logInfoIO LogVulkan "frame descriptor sets updated"

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
      tvDebugMode = debugMode gameState
      tvPendingScreenshot = pendingScreenshot gameState
      tvPendingAllStages = pendingAllStages gameState
      frameMvpMemories = map snd frameMvpBuffers
      outerLoop :: (MonadFail m, MonadIO m) => Bool -> m ()
      outerLoop exit = do
        if exit
          then pure ()
          else do
            renderFrameLoopFinished <- liftIO $ with mkRenderContext $ \context ->
               with (createDeferredResources physicalDevice device context descriptorSetLayout [] gbufVertShader gbufFragShader lightVertShader lightFragShader wireVertShader wireGeomShader wireFragShader mRadianceView mIrradianceView) $ \dr ->
                renderFrameLoop context dr 0 targetFPS imageAvailableSemaphores control frameMvpMemories tvCamera tvInspect tvInsp tvRenderDebug ecsWorld rm textureSampler frameDescriptorSets textureIndexMap tvWireframe frameStatsRef computeCullResources tvDebugMode tvPendingScreenshot tvPendingAllStages physicalDevice
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
stateUpdateLoop :: (Camera cam, MonadIO m) => Integer -> GameState cam -> MVar () -> InputBuffer -> CommandQueue -> TChan ControlMessage -> m ()
stateUpdateLoop targetFPS gameState finishedSemaphore inputBuffer debugCmdQueue controlChannel = liftIO $ do
  logInfoIO LogGeneral "stateUpdateLoop starting"
  control <- STM.atomically $ TChan.dupTChan controlChannel

  let camSpeed = 10.0 :: Foreign.C.CFloat

  let loop :: (Camera cam, MonadIO m) => Integer -> GameState cam -> Integer -> m ()
      loop tFPS _gameState prevTime = liftIO $ do
        maybeControlMessage <- STM.atomically $ TChan.tryReadTChan control
        case maybeControlMessage of
          Nothing -> do
            newTime <- liftIO $ toNanoSecs <$> getTime Monotonic
            let dtSeconds = min 0.1 (realToFrac (newTime - prevTime) / 1e9) :: Foreign.C.CFloat
            (actions, overflowCount) <- STM.atomically $ flushInputBuffer inputBuffer
            when (overflowCount > 0) $ logInfoIO LogGeneral $ "input buffer overflow: " <> showT overflowCount <> " events dropped"
            when (not (null actions)) $ logInfoIO LogGeneral $ "stateUpdate: processing " <> showT (length actions) <> " actions, first=" <> showT (head actions)
            debugCmds <- STM.atomically $ TQueue.flushTQueue debugCmdQueue
            worldState <- STM.readTVarIO (world gameState)
            let camera = activeCamera worldState
            for_ actions $ \action ->
              case action of
                (MoveForward, b, _) -> STM.atomically $ STM.writeTVar (moveForward gameState) b
                (MoveBackward, b, _) -> STM.atomically $ STM.writeTVar (moveBackward gameState) b
                (StrafeLeft, b, _) -> STM.atomically $ STM.writeTVar (strafeLeft gameState) b
                (StrafeRight, b, _) -> STM.atomically $ STM.writeTVar (strafeRight gameState) b
                (MouseMove (V2 x y), _, isRepeated) ->
                  unless isRepeated $ STM.atomically
                    ( updateCamera
                        (activeCamera worldState)
                        [ Camera.Rotate
                             ( V3 (fromIntegral x * 0.1 * dtSeconds) (fromIntegral y * 0.1 * dtSeconds) 0.0
                             )
                        ]
                    )
                (Zoom amount, _, _) ->
                  STM.atomically
                    ( updateCamera
                        (activeCamera worldState)
                        [Camera.Zoom (realToFrac amount)]
                    )
                (Escape, _, _) -> STM.atomically $ STM.writeTVar (isRunning gameState) False
                (FrameInspect, True, _) -> STM.atomically $ STM.writeTVar (inspectFrame gameState) True
                (FrameInspect, False, _) -> pure ()
                (ToggleWireframe, True, _) -> do
                  current <- STM.readTVarIO (wireframeEnabled gameState)
                  STM.atomically $ STM.writeTVar (wireframeEnabled gameState) (not current)
                  logInfoIO LogGeneral $ "wireframe toggled: " <> showT (not current)
                (ToggleWireframe, False, _) -> pure ()
                (DebugMode mode, True, _) -> do
                  STM.atomically $ STM.writeTVar (debugMode gameState) (fromIntegral mode)
                  logInfoIO LogGeneral $ "debug mode set to " <> showT mode
                (DebugMode _, False, _) -> pure ()
                (SaveScreenshot, True, _) -> do
                  STM.atomically $ STM.writeTVar (pendingScreenshot gameState) True
                  logInfoIO LogGeneral "screenshot requested"
                (SaveScreenshot, False, _) -> pure ()
                (SaveAllStages, True, _) -> do
                  STM.atomically $ STM.writeTVar (pendingAllStages gameState) True
                  logInfoIO LogGeneral "save all stages requested"
                (SaveAllStages, False, _) -> pure ()
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

            (fwd, bwd, sl, sr, isRunning) <- STM.atomically $ do
              a <- STM.readTVar (moveForward gameState)
              b <- STM.readTVar (moveBackward gameState)
              c <- STM.readTVar (strafeLeft gameState)
              d <- STM.readTVar (strafeRight gameState)
              e <- STM.readTVar (isRunning gameState)
              pure (a, b, c, d, e)

            let camMove = camSpeed * dtSeconds
            when (fwd) $ STM.atomically $ updateCamera (activeCamera worldState) [Camera.MoveForward camMove]
            when (bwd) $ STM.atomically $ updateCamera (activeCamera worldState) [Camera.MoveForward (-camMove)]
            when (sl) $ STM.atomically $ updateCamera (activeCamera worldState) [Camera.MoveRight (-camMove)]
            when (sr) $ STM.atomically $ updateCamera (activeCamera worldState) [Camera.MoveRight camMove]
            let targetDelayMicros = 1000000 `div` fromIntegral tFPS
            threadDelay (fromIntegral targetDelayMicros)
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

-- | Compute world-space bounding box from all entities in the ECS world.
computeWorldSpaceBounds :: ECS.World -> ResourceManager -> IO BBox
computeWorldSpaceBounds world rm = do
  entities <- ECS.allEntitiesWithMesh world
  boundsList <- forM entities $ \eid -> do
    mMeshHandle <- ECS.getMesh world eid
    mTransform <- ECS.getTransform world eid
    case (mMeshHandle, mTransform) of
      (Just meshHandle, Just transform) -> do
        mMeshRes <- lookupMesh rm meshHandle
        case mMeshRes of
          Just meshRes -> do
            let worldMat = Transform.toMatrix transform
                (wmin, wmax) = transformAABB worldMat (mrBounds meshRes)
            pure $ Just $ BBox wmin wmax
          Nothing -> pure Nothing
      _ -> pure Nothing
  pure $ foldl mergeBBox emptyBBox (catMaybes boundsList)

-- | Compute bounding box from all mesh resources in the scene (local space).
computeSceneBounds :: [MeshHandle] -> ResourceManager -> BBox
computeSceneBounds meshes rm = unsafePerformIO $ do
  boundsList <- mapM (\mh -> do
    mMesh <- lookupMesh rm mh
    case mMesh of
      Just meshRes -> pure $ mrBounds meshRes
      Nothing -> pure emptyBBox
    ) meshes
  pure $ foldl mergeBBox emptyBBox boundsList

-- | Set camera target and distance based on scene bounding box.
adjustCameraForScene :: Camera a => BBox -> a -> a
adjustCameraForScene bbox cam =
  let center = bboxCenter bbox
      diag = bboxDiagonal bbox
      fov = pi / 12  -- 15 degrees vertical FOV
      padding = 1.5
      r = diag / 2
      -- Distance to fit bounding sphere in frustum
      targetDist = max (0.1 + r) (r / sin (fov / 2) * padding)
      -- Allow zooming out to 5x the initial distance
      maxDist = targetDist * 5.0
      cam' = setTarget cam (fmap realToFrac center)
      cam'' = setMaxDistance cam' (realToFrac maxDist)
  in setDistance cam'' (realToFrac targetDist)
