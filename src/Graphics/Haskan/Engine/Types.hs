{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Engine.Types
  ( toListOfV4,
    forkIOWithHandler,
    InputBuffer (..),
    newInputBuffer,
    writeInputBuffer,
    flushInputBuffer,
    LightType (..),
    LightData (..),
    ComputeEntityData (..),
    ComputeCullData (..),
    DrawIndexedIndirectCommand (..),
    ComputeCullResources (..),
    transformAABB,
    extractFrustumPlanes,
    filterVisible,
    EngineConfig (..),
    FrameTime (..),
    FrameStats (..),
    emptyFrameStats,
    updateFrameStats,
    Position,
    Distance,
    WorldState (..),
    GameState (..),
    RenderDebugInfo (..),
    EntityDebugInfo (..),
    ControlMessage (..),
    CameraMode (..),
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, putMVar)
import Control.Concurrent.STM (STM)
import Control.Concurrent.STM qualified as STM
import Control.Concurrent.STM.TChan (TChan)
import Control.Concurrent.STM.TQueue (TQueue)
import Control.Concurrent.STM.TVar (TVar)
import Control.Exception (SomeException, try)
import Control.Lens ((^.))
import Control.Monad (forM, forM_)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (ToJSON (..), object, (.=))
import Data.Foldable (toList)
import Data.IORef (IORef)
import Data.Int (Int32)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.Sequence (Seq (..))
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word32, Word64)
import Foreign.C qualified
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (Storable (..), peekByteOff, pokeByteOff)
import GHC.Generics
import Graphics.Haskan.BoundingBox (BBox (..))
import Graphics.Haskan.Camera (Camera (..))
import Graphics.Haskan.Debug.FrameInspector (FrameInspector, RenderableSnapshot (..))
import Graphics.Haskan.Debug.Interface (DebugCameraSnapshot (..), DebugCommand (..), DebugMessage (..), DebugResponse (..), GameStateSnapshot (..))
import Graphics.Haskan.Debug.Server (CommandQueue, DebugServerHandle)
import Graphics.Haskan.Input (Action (..), ActionEvent, payloadToActionEvent)
import Graphics.Haskan.Logger (LogCategory (..), logInfoIO, showT)
import Graphics.Haskan.Render.RenderSystem (DrawCall (..))
import Graphics.Haskan.Resources (allocaAndPeek, throwVkResult)
import Graphics.Vulkan qualified as Vulkan
import Linear (M44, V2 (..), V3 (..), V4 (..), normalize, (*^), (^+^), (^-^))
import Linear.Matrix (identity, inv33, inv44, transpose, (!*), (!*!))
import Linear.Projection qualified
import Linear.Quaternion (Quaternion (..))
import Linear.V3 (_x, _y, _z)
import Linear.V4 (_w)
import System.Clock (Clock (..), getTime, toNanoSecs)

toListOfV4 :: V4 (V4 a) -> [[a]]
toListOfV4 (V4 r1 r2 r3 r4) = [toList r1, toList r2, toList r3, toList r4]
  where
    toList (V4 a b c d) = [a, b, c, d]

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

data InputBuffer = InputBuffer
  { ibEvents :: !(TVar (Seq ActionEvent)),
    ibOverflow :: !(TVar Word64)
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

data LightType = LightDirectional | LightPoint | LightSpot
  deriving (Show, Eq, Enum)

data LightData = LightData
  { ldPosition :: V3 Foreign.C.CFloat,
    ldIntensity :: Foreign.C.CFloat,
    ldColor :: V3 Foreign.C.CFloat,
    ldType :: Word32,
    ldDirection :: V3 Foreign.C.CFloat,
    ldRange :: Foreign.C.CFloat
  }
  deriving (Show)

instance Storable LightData where
  sizeOf _ = 48
  alignment _ = 16
  peek ptr =
    LightData
      <$> peekByteOff ptr 0
      <*> peekByteOff ptr 12
      <*> peekByteOff ptr 16
      <*> peekByteOff ptr 28
      <*> peekByteOff ptr 32
      <*> peekByteOff ptr 44
  poke ptr (LightData pos int col typ dir rng) = do
    pokeByteOff ptr 0 pos
    pokeByteOff ptr 12 int
    pokeByteOff ptr 16 col
    pokeByteOff ptr 28 typ
    pokeByteOff ptr 32 dir
    pokeByteOff ptr 44 rng

data ComputeEntityData = ComputeEntityData
  { ceTransform :: M44 Foreign.C.CFloat,
    ceNormalMatrix :: M44 Foreign.C.CFloat,
    ceAabbMin :: V4 Foreign.C.CFloat,
    ceAabbMax :: V4 Foreign.C.CFloat,
    ceMaterialIndex :: Word32,
    ceFirstIndex :: Word32,
    ceVertexOffset :: Foreign.C.CInt,
    ceIndexCount :: Word32,
    ceMetallicRoughnessIndex :: Word32,
    ceMetallicFactor :: Foreign.C.CFloat,
    ceRoughnessFactor :: Foreign.C.CFloat,
    ceNormalIndex :: Word32,
    ceOcclusionIndex :: Word32,
    ceOcclusionStrength :: Foreign.C.CFloat,
    ceEmissiveIndex :: Word32
  }
  deriving (Show)

instance Storable ComputeEntityData where
  sizeOf _ = 208
  alignment _ = 16
  peek ptr =
    ComputeEntityData
      <$> peekByteOff ptr 0
      <*> peekByteOff ptr 64
      <*> peekByteOff ptr 128
      <*> peekByteOff ptr 144
      <*> peekByteOff ptr 160
      <*> peekByteOff ptr 164
      <*> peekByteOff ptr 168
      <*> peekByteOff ptr 172
      <*> peekByteOff ptr 176
      <*> peekByteOff ptr 180
      <*> peekByteOff ptr 184
      <*> peekByteOff ptr 188
      <*> peekByteOff ptr 192
      <*> peekByteOff ptr 196
      <*> peekByteOff ptr 200
  poke ptr (ComputeEntityData t nm amin amax mat fi vo ic mri met rou ni oi os ei) = do
    pokeByteOff ptr 0 t
    pokeByteOff ptr 64 nm
    pokeByteOff ptr 128 amin
    pokeByteOff ptr 144 amax
    pokeByteOff ptr 160 mat
    pokeByteOff ptr 164 fi
    pokeByteOff ptr 168 vo
    pokeByteOff ptr 172 ic
    pokeByteOff ptr 176 mri
    pokeByteOff ptr 180 met
    pokeByteOff ptr 184 rou
    pokeByteOff ptr 188 ni
    pokeByteOff ptr 192 oi
    pokeByteOff ptr 196 os
    pokeByteOff ptr 200 ei

data ComputeCullData = ComputeCullData
  { ccFrustumPlanes :: [V4 Foreign.C.CFloat],
    ccCameraPosition :: V4 Foreign.C.CFloat,
    ccEntityCount :: Word32,
    ccLodDistance1 :: Foreign.C.CFloat,
    ccLodDistance2 :: Foreign.C.CFloat,
    ccPad3 :: Word32
  }
  deriving (Show)

instance Storable ComputeCullData where
  sizeOf _ = 128
  alignment _ = 16
  peek ptr = do
    planes <- sequence [peekByteOff ptr (i * 16) | i <- [0 .. 5]]
    camPos <- peekByteOff ptr 96
    count <- peekByteOff ptr 112
    lod1 <- peekByteOff ptr 116
    lod2 <- peekByteOff ptr 120
    pad <- peekByteOff ptr 124
    pure (ComputeCullData planes camPos count lod1 lod2 pad)
  poke ptr (ComputeCullData planes camPos count lod1 lod2 pad) = do
    forM_ (zip [0 .. 5] planes) $ \(i, p) -> pokeByteOff ptr (i * 16) p
    pokeByteOff ptr 96 camPos
    pokeByteOff ptr 112 count
    pokeByteOff ptr 116 lod1
    pokeByteOff ptr 120 lod2
    pokeByteOff ptr 124 pad

data DrawIndexedIndirectCommand = DrawIndexedIndirectCommand
  { diicIndexCount :: Word32,
    diicInstanceCount :: Word32,
    diicFirstIndex :: Word32,
    diicVertexOffset :: Int32,
    diicFirstInstance :: Word32
  }
  deriving (Show)

instance Storable DrawIndexedIndirectCommand where
  sizeOf _ = 20
  alignment _ = 4
  peek ptr =
    DrawIndexedIndirectCommand
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

data ComputeCullResources = ComputeCullResources
  { ccrPipeline :: Vulkan.VkPipeline,
    ccrPipelineLayout :: Vulkan.VkPipelineLayout,
    ccrDescriptorSet :: Vulkan.VkDescriptorSet,
    ccrEntityBuffer :: Vulkan.VkBuffer,
    ccrEntityMemory :: Vulkan.VkDeviceMemory,
    ccrDrawCommandsBuffer :: Vulkan.VkBuffer,
    ccrDrawCommandsMemory :: Vulkan.VkDeviceMemory,
    ccrCullDataBuffer :: Vulkan.VkBuffer,
    ccrCullDataMemory :: Vulkan.VkDeviceMemory,
    ccrMaxEntities :: Int
  }

transformAABB :: M44 Float -> BBox -> (V3 Float, V3 Float)
transformAABB worldMat (BBox (V3 minX minY minZ) (V3 maxX maxY maxZ)) =
  let corners =
        [ V3 minX minY minZ,
          V3 maxX minY minZ,
          V3 minX maxY minZ,
          V3 maxX maxY minZ,
          V3 minX minY maxZ,
          V3 maxX minY maxZ,
          V3 minX maxY maxZ,
          V3 maxX maxY maxZ
        ]
      worldCorners = map (\(V3 x y z) -> let V4 wx wy wz _ = worldMat !* V4 x y z 1 in V3 wx wy wz) corners
      xs = map (\(V3 x _ _) -> x) worldCorners
      ys = map (\(V3 _ y _) -> y) worldCorners
      zs = map (\(V3 _ _ z) -> z) worldCorners
   in (V3 (minimum xs) (minimum ys) (minimum zs), V3 (maximum xs) (maximum ys) (maximum zs))

extractFrustumPlanes :: M44 Float -> [V4 Float]
extractFrustumPlanes vp =
  let r1 = vp ^. _x
      r2 = vp ^. _y
      r3 = vp ^. _z
      r4 = vp ^. _w
      left = r1 ^+^ r4
      right = r4 ^-^ r1
      bottom = r2 ^+^ r4
      top = r4 ^-^ r2
      near = r3 ^+^ r4
      far = r4 ^-^ r3
   in [left, right, bottom, top, near, far]

filterVisible :: [DrawCall] -> IntMap Word32 -> [DrawCall]
filterVisible drawList visibleFlags =
  [dc | (idx, dc) <- zip [0 ..] drawList, IntMap.findWithDefault 1 idx visibleFlags == 1]

data EngineConfig = EngineConfig
  { targetRenderFPS :: !Integer,
    targetPhysicsFPS :: !Integer,
    targetNetworkFPS :: !Integer,
    targetInputFPS :: !Integer,
    title :: !Text,
    debugSocketPath :: !(Maybe FilePath),
    timeoutSeconds :: !(Maybe Integer),
    uvCheckMode :: !(Maybe String),
    envMapDir :: !String,
    lightCount :: !Int,
    initialTimeOfDay :: !Float,
    timeSpeed :: !Float,
    dayNightEnabled :: !Bool
  }
  deriving (Show)

data FrameTime = FrameTime
  { lastTime :: !Integer,
    currentTime :: !Integer,
    deltaTime :: !Integer
  }
  deriving (Show)

data FrameStats = FrameStats
  { fsFrameCount :: !Int,
    fsAccumTime :: !Integer,
    fsMinTime :: !Integer,
    fsMaxTime :: !Integer,
    fsTotalFrames :: !Int
  }

emptyFrameStats :: FrameStats
emptyFrameStats = FrameStats 0 0 999999999999 0 0

updateFrameStats :: FrameStats -> Integer -> (FrameStats, Maybe Text)
updateFrameStats stats frameTime =
  let count = fsFrameCount stats + 1
      accum = fsAccumTime stats + frameTime
      minT = min (fsMinTime stats) frameTime
      maxT = max (fsMaxTime stats) frameTime
      total = fsTotalFrames stats + 1
      newStats = FrameStats count accum minT maxT total
   in if count >= 300
        then
          let avg = accum `div` fromIntegral count
              avgMs = fromIntegral avg / 1_000_000 :: Double
              minMs = fromIntegral minT / 1_000_000 :: Double
              maxMs = fromIntegral maxT / 1_000_000 :: Double
              fps = 1_000_000_000.0 / fromIntegral avg :: Double
              msg =
                Text.pack $
                  "Frame stats [last 60 frames]: avg="
                    ++ show avgMs
                    ++ "ms, min="
                    ++ show minMs
                    ++ "ms, max="
                    ++ show maxMs
                    ++ "ms, fps="
                    ++ show fps
                    ++ " | total frames="
                    ++ show total
           in (FrameStats 0 0 999999999999 0 total, Just msg)
        else (newStats, Nothing)

type Position = V3 Float

type Distance = Float

data WorldState cam = WorldState
  { activeCamera :: TVar cam
  }

data CameraMode = CameraModeOrbital | CameraModeFly
  deriving (Show, Eq)

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
    axisOverlayEnabled :: TVar Float,
    groundPlaneEnabled :: TVar Float,
    pendingScreenshot :: TVar Bool,
    pendingAllStages :: TVar Bool,
    pendingSwapchainScreenshot :: TVar Bool,
    mouseCaptureEnabled :: TVar Bool,
    lights :: TVar [LightData],
    gameTimeOfDay :: TVar Float,
    gameTimeSpeed :: TVar Float,
    gameDayNightEnabled :: TVar Bool,
    cloudHeight :: TVar Float,
    cameraMode :: TVar CameraMode,
    orbitalCamera :: TVar cam,
    flyCamera :: TVar cam
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
