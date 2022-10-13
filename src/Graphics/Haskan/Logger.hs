module Graphics.Haskan.Logger where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Text (Text)
import Data.Text qualified as Text
import System.Log.FastLogger

showT :: Show a => a -> Text
showT = Text.pack . show

logI :: MonadIO m => Text -> m ()
logI msg =
  liftIO $
    withFastLogger
      (LogStdout 1024)
      ( \l ->
          log' l (toLogStr msg)
      )

log' :: FastLogger -> LogStr -> IO ()
log' logger msg = logger (msg <> "\n")
