{-# LANGUAGE LambdaCase #-}

module Graphics.Haskan.Engine.Capabilities.Test
  ( TestState (..),
    TestM,
    runTestM,
    execTestM,
    evalTestM,
    defaultTestState,
    GraphicsCall (..),
  )
where

import Control.Monad.State (StateT, modify, runStateT, state)
import Data.Functor.Identity (Identity (..))
import Data.Text (Text)
import Data.Word (Word32)
import Graphics.Haskan.Camera (AnyCamera)
import Graphics.Haskan.Engine.Capabilities.Clock (MonadClock (..))
import Graphics.Haskan.Engine.Capabilities.Graphics (MonadGraphics (..))
import Graphics.Haskan.Engine.Capabilities.Log (MonadLog (..))
import Graphics.Haskan.Engine.Capabilities.StateReader (MonadStateReader (..))
import Graphics.Haskan.Engine.Capabilities.Telemetry (MonadTelemetry (..))
import Graphics.Haskan.Engine.Types (ControlMessage, FrameStats, LightData, emptyFrameStats, updateFrameStats)
import Graphics.Haskan.Logger (LogCategory, LogLevel)
import Graphics.Haskan.Vulkan.Render qualified as Render
import Graphics.Haskan.Vulkan.Types (RenderResult (..))
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Linear (V3 (..))

data GraphicsCall
  = UploadStorageBuffer Int Int
  | UploadUniformBuffer Int Int
  | DeviceWaitIdle
  | DrawFrameGraphics Int
  | PresentFrameGraphics Word32
  deriving (Eq, Show)

data TestState = TestState
  { tsLogs :: [(LogLevel, LogCategory, Text)],
    tsClockTime :: Integer,
    tsFrameStats :: FrameStats,
    tsCamera :: AnyCamera,
    tsControl :: Maybe ControlMessage,
    tsWireframe :: Bool,
    tsDebugMode :: Word32,
    tsAxisOverlay :: Float,
    tsGroundPlane :: Float,
    tsTimeOfDay :: Float,
    tsDayNightEnabled :: Bool,
    tsCloudHeight :: Float,
    tsInspector :: Maybe (Int -> IO ()),
    tsLights :: [LightData],
    tsInspectFlag :: Bool,
    tsScreenshotFlag :: Bool,
    tsAllStagesFlag :: Bool,
    tsSwapchainScreenshotFlag :: Bool,
    tsGraphicsCalls :: [GraphicsCall]
  }

defaultTestState :: TestState
defaultTestState =
  TestState
    { tsLogs = [],
      tsClockTime = 0,
      tsFrameStats = emptyFrameStats,
      tsCamera = error "defaultTestState: tsCamera not set",
      tsControl = Nothing,
      tsWireframe = False,
      tsDebugMode = 0,
      tsAxisOverlay = 0,
      tsGroundPlane = 0,
      tsTimeOfDay = 12.0,
      tsDayNightEnabled = False,
      tsCloudHeight = 3500.0,
      tsInspector = Nothing,
      tsLights = [],
      tsInspectFlag = False,
      tsScreenshotFlag = False,
      tsAllStagesFlag = False,
      tsSwapchainScreenshotFlag = False,
      tsGraphicsCalls = []
    }

newtype TestM a = TestM {unTestM :: StateT TestState Identity a}
  deriving (Functor, Applicative, Monad)

runTestM :: TestState -> TestM a -> (a, TestState)
runTestM s m = runIdentity (runStateT (unTestM m) s)

execTestM :: TestState -> TestM a -> TestState
execTestM s m = snd (runTestM s m)

evalTestM :: TestState -> TestM a -> a
evalTestM s m = fst (runTestM s m)

instance MonadLog TestM where
  logMessage level cat msg =
    TestM $ modify $ \s -> s {tsLogs = tsLogs s ++ [(level, cat, msg)]}

instance MonadClock TestM where
  getMonotonicTime = TestM $ state $ \s -> let t = tsClockTime s in (t, s {tsClockTime = t + 16000000})
  delayMicros us = TestM $ modify $ \s -> s {tsClockTime = tsClockTime s + fromIntegral us * 1000}

instance MonadTelemetry TestM where
  recordFrameTime rt = TestM $ modify $ \s ->
    let (newStats, _) = updateFrameStats (tsFrameStats s) rt
     in s {tsFrameStats = newStats}
  getTelemetryMessage = pure Nothing

instance MonadStateReader TestM where
  readCamera = TestM $ state $ \s -> (tsCamera s, s)
  readControl = TestM $ state $ \s -> (tsControl s, s {tsControl = Nothing})
  readWireframe = TestM $ state $ \s -> (tsWireframe s, s)
  readDebugMode = TestM $ state $ \s -> (tsDebugMode s, s)
  readAxisOverlay = TestM $ state $ \s -> (tsAxisOverlay s, s)
  readGroundPlane = TestM $ state $ \s -> (tsGroundPlane s, s)
  readTimeOfDay = TestM $ state $ \s -> (tsTimeOfDay s, s)
  readDayNightEnabled = TestM $ state $ \s -> (tsDayNightEnabled s, s)
  readCloudHeight = TestM $ state $ \s -> (tsCloudHeight s, s)
  readInspector = TestM $ state $ \s -> (Nothing, s)
  readLights = TestM $ state $ \s -> (tsLights s, s)
  consumeInspectFlag = TestM $ state $ \s -> let b = tsInspectFlag s in (b, s {tsInspectFlag = False})
  consumeScreenshotFlag = TestM $ state $ \s -> let b = tsScreenshotFlag s in (b, s {tsScreenshotFlag = False})
  consumeAllStagesFlag = TestM $ state $ \s -> let b = tsAllStagesFlag s in (b, s {tsAllStagesFlag = False})
  consumeSwapchainScreenshotFlag = TestM $ state $ \s -> let b = tsSwapchainScreenshotFlag s in (b, s {tsSwapchainScreenshotFlag = False})

instance MonadGraphics TestM where
  uploadStorageBuffer _ _ dat =
    TestM $ modify $ \s -> s {tsGraphicsCalls = tsGraphicsCalls s ++ [UploadStorageBuffer 0 (length dat)]}
  uploadUniformBuffer _ _ dat =
    TestM $ modify $ \s -> s {tsGraphicsCalls = tsGraphicsCalls s ++ [UploadUniformBuffer 0 (length dat)]}
  deviceWaitIdle =
    TestM $ modify $ \s -> s {tsGraphicsCalls = tsGraphicsCalls s ++ [DeviceWaitIdle]}
  drawFrameGraphics _ frameIdx _ =
    TestM $ do
      modify $ \s -> s {tsGraphicsCalls = tsGraphicsCalls s ++ [DrawFrameGraphics frameIdx]}
      pure (FrameOk 0)
  presentFrameGraphics imageIdx _ =
    TestM $ do
      modify $ \s -> s {tsGraphicsCalls = tsGraphicsCalls s ++ [PresentFrameGraphics imageIdx]}
      pure Vulkan.VK_SUCCESS
