module Graphics.Haskan.Logger where

-- base
import Control.Monad.IO.Class (MonadIO, liftIO)

-- fast-logger
import System.Log.FastLogger

-- text
import Data.Text (Text)
import qualified Data.Text as Text


showT :: Show a => a -> Text
showT = Text.pack . show

logI :: MonadIO m => Text -> m ()
logI msg =
  liftIO $ withFastLogger (LogStdout 1024) (\l ->
    log' l (toLogStr msg)
  )

log' :: FastLogger -> LogStr -> IO ()
log' logger msg = logger (msg <> "\n")
