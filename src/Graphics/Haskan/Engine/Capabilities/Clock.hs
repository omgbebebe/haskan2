module Graphics.Haskan.Engine.Capabilities.Clock
  ( MonadClock (..),
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (Managed)
import Control.Monad.Reader (ReaderT, lift)
import Control.Monad.State (StateT)
import System.Clock (Clock (..), TimeSpec, getTime)

class Monad m => MonadClock m where
  getMonotonicTime :: m TimeSpec
  delayMicros :: Int -> m ()

instance MonadClock IO where
  getMonotonicTime = getTime Monotonic
  delayMicros = threadDelay

instance MonadClock Managed where
  getMonotonicTime = liftIO $ getTime Monotonic
  delayMicros us = liftIO $ threadDelay us

instance MonadClock m => MonadClock (ReaderT r m) where
  getMonotonicTime = lift getMonotonicTime
  delayMicros us = lift $ delayMicros us

instance MonadClock m => MonadClock (StateT s m) where
  getMonotonicTime = lift getMonotonicTime
  delayMicros us = lift $ delayMicros us
