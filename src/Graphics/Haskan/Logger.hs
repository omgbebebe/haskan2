{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}

module Graphics.Haskan.Logger
  ( LogLevel (..)
  , LogCategory (..)
  , LoggerConfig (..)
  , defaultLoggerConfig
  , readLoggerConfig
  , logDebug
  , logInfo
  , logWarn
  , logError
  , logFatal
  , traceM
  , showT
  ) where

import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.List (elemIndex)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import System.Clock (Clock (..), TimeSpec (..), getTime)
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)
import System.Log.FastLogger

data LogLevel = Debug | Info | Warning | Error | Fatal
  deriving (Eq, Ord, Show, Enum)

data LogCategory
  = LogVulkan
  | LogECS
  | LogRender
  | LogInput
  | LogTexture
  | LogBuffer
  | LogGeneral
  deriving (Eq, Show)

data LoggerConfig = LoggerConfig
  { lcMinLevel :: !LogLevel
  , lcCategories :: ![LogCategory]
  }

defaultLoggerConfig :: LoggerConfig
defaultLoggerConfig = LoggerConfig Info []

{-# NOINLINE globalConfig #-}
globalConfig :: LoggerConfig
globalConfig = unsafePerformIO readLoggerConfig

readLoggerConfig :: IO LoggerConfig
readLoggerConfig = do
  mLevel <- lookupEnv "HASKAN_LOG_LEVEL"
  mCats <- lookupEnv "HASKAN_LOG_CATEGORIES"
  let level = case mLevel of
        Just "debug" -> Debug
        Just "info" -> Info
        Just "warn" -> Warning
        Just "error" -> Error
        Just "fatal" -> Fatal
        _ -> Info
      cats = case mCats of
        Just "" -> []
        Just s -> map parseCategory (Text.splitOn "," (Text.pack s))
        Nothing -> []
  pure (LoggerConfig level cats)

parseCategory :: Text -> LogCategory
parseCategory = \case
  "vulkan" -> LogVulkan
  "ecs" -> LogECS
  "render" -> LogRender
  "input" -> LogInput
  "texture" -> LogTexture
  "buffer" -> LogBuffer
  _ -> LogGeneral

showT :: Show a => a -> Text
showT = Text.pack . show

formatTimestamp :: TimeSpec -> Text
formatTimestamp (TimeSpec s ns) =
  let micros = fromIntegral ns `div` 1_000 :: Int
      microsTxt = Text.justifyRight 6 '0' (showT micros)
   in showT s <> "." <> microsTxt

logMsg :: MonadIO m => LogLevel -> LogCategory -> Text -> m ()
#ifdef RELEASE
logMsg Debug _ _ = pure ()
#endif
logMsg level cat msg = liftIO $ do
  let cfg = globalConfig
      catMatch = null (lcCategories cfg) || cat `elem` lcCategories cfg
      levelMatch = level >= lcMinLevel cfg
  when (catMatch && levelMatch) $ do
    ts <- formatTimestamp <$> getTime Realtime
    let prefix = ts <> " [" <> showT level <> "] [" <> showT cat <> "] "
    withFastLogger (LogStdout 4096) $ \l ->
      log' l (toLogStr (prefix <> msg))

log' :: FastLogger -> LogStr -> IO ()
log' logger msg = logger (msg <> "\n")

logDebug :: MonadIO m => LogCategory -> Text -> m ()
logDebug = logMsg Debug

logInfo :: MonadIO m => LogCategory -> Text -> m ()
logInfo = logMsg Info

logWarn :: MonadIO m => LogCategory -> Text -> m ()
logWarn = logMsg Warning

logError :: MonadIO m => LogCategory -> Text -> m ()
logError = logMsg Error

logFatal :: MonadIO m => LogCategory -> Text -> m ()
logFatal = logMsg Fatal

traceM :: (MonadIO m, Show a) => LogCategory -> Text -> m a -> m a
traceM cat name action = do
  logDebug cat (name <> " { enter }")
  res <- action
  logDebug cat (name <> " { exit = " <> showT res <> " }")
  pure res
