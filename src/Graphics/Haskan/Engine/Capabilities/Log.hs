{-# LANGUAGE LambdaCase #-}

module Graphics.Haskan.Engine.Capabilities.Log
  ( MonadLog (..),
    logInfo,
    logDebug,
    logWarn,
    logError,
    logFatal,
  )
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (Managed, liftIO)
import Control.Monad.Reader (ReaderT, lift)
import Control.Monad.State (StateT)
import Data.Text (Text)
import Graphics.Haskan.Logger
  ( LogCategory,
    LogLevel (..),
    logMessageIO,
  )

class Monad m => MonadLog m where
  logMessage :: LogLevel -> LogCategory -> Text -> m ()

logInfo :: MonadLog m => LogCategory -> Text -> m ()
logInfo = logMessage Info

logDebug :: MonadLog m => LogCategory -> Text -> m ()
logDebug = logMessage Debug

logWarn :: MonadLog m => LogCategory -> Text -> m ()
logWarn = logMessage Warning

logError :: MonadLog m => LogCategory -> Text -> m ()
logError = logMessage Error

logFatal :: MonadLog m => LogCategory -> Text -> m ()
logFatal = logMessage Fatal

instance MonadLog IO where
  logMessage = logMessageIO

instance MonadLog Managed where
  logMessage level cat msg = liftIO $ logMessageIO level cat msg

instance MonadLog m => MonadLog (ReaderT r m) where
  logMessage level cat msg = lift $ logMessage level cat msg

instance MonadLog m => MonadLog (StateT s m) where
  logMessage level cat msg = lift $ logMessage level cat msg
