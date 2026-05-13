module Graphics.Haskan.Engine.Capabilities.StateReader
  ( MonadStateReader (..),
    readTVarIO,
    consumeTVar,
  )
where

import Control.Concurrent.STM qualified as STM
import Control.Concurrent.STM.TChan (TChan)
import Control.Concurrent.STM.TVar (TVar)
import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (Managed)
import Data.Word (Word32)
import Graphics.Haskan.Camera (AnyCamera)
import Graphics.Haskan.Debug.FrameInspector (FrameInspector)
import Graphics.Haskan.Engine.Types (ControlMessage, LightData)

class (Monad m) => MonadStateReader m where
  readCamera :: m AnyCamera
  readControl :: m (Maybe ControlMessage)
  readWireframe :: m Bool
  readDebugMode :: m Word32
  readAxisOverlay :: m Float
  readGroundPlane :: m Float
  readTimeOfDay :: m Float
  readDayNightEnabled :: m Bool
  readCloudHeight :: m Float
  readInspector :: m (Maybe FrameInspector)
  readLights :: m [LightData]
  consumeInspectFlag :: m Bool
  consumeScreenshotFlag :: m Bool
  consumeAllStagesFlag :: m Bool
  consumeSwapchainScreenshotFlag :: m Bool

readTVarIO :: (MonadIO m) => TVar a -> m a
readTVarIO = liftIO . STM.readTVarIO

consumeTVar :: (MonadIO m) => TVar Bool -> m Bool
consumeTVar tv = liftIO $ STM.atomically $ do
  b <- STM.readTVar tv
  when b $ STM.writeTVar tv False
  pure b

instance MonadStateReader IO where
  readCamera = error "readCamera: not implemented in IO"
  readControl = pure Nothing
  readWireframe = pure False
  readDebugMode = pure 0
  readAxisOverlay = pure 0
  readGroundPlane = pure 0
  readTimeOfDay = pure 12.0
  readDayNightEnabled = pure False
  readCloudHeight = pure 3500.0
  readInspector = pure Nothing
  readLights = pure []
  consumeInspectFlag = pure False
  consumeScreenshotFlag = pure False
  consumeAllStagesFlag = pure False
  consumeSwapchainScreenshotFlag = pure False

instance MonadStateReader Managed where
  readCamera = error "readCamera: not implemented in Managed"
  readControl = pure Nothing
  readWireframe = pure False
  readDebugMode = pure 0
  readAxisOverlay = pure 0
  readGroundPlane = pure 0
  readTimeOfDay = pure 12.0
  readDayNightEnabled = pure False
  readCloudHeight = pure 3500.0
  readInspector = pure Nothing
  readLights = pure []
  consumeInspectFlag = pure False
  consumeScreenshotFlag = pure False
  consumeAllStagesFlag = pure False
  consumeSwapchainScreenshotFlag = pure False
