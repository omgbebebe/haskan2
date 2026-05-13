module Graphics.Haskan.Engine.Capabilities.Telemetry
  ( MonadTelemetry (..),
  )
where

import Data.Maybe (Maybe)
import Data.Text (Text)

import Control.Monad.Managed (Managed)

class Monad m => MonadTelemetry m where
  recordFrameTime :: Integer -> m ()
  getTelemetryMessage :: m (Maybe Text)

instance MonadTelemetry Managed where
  recordFrameTime _ = pure ()
  getTelemetryMessage = pure Nothing

instance MonadTelemetry IO where
  recordFrameTime _ = pure ()
  getTelemetryMessage = pure Nothing
