{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE TypeFamilies #-}

module Graphics.Haskan.Logger
  ( LogLevel (..)
  , LogCategory (..)
  , LogEntry (..)
  , LogFormatter
  , LogBackend (..)
  , defaultFormatter
  , jsonFormatter
  , stdoutBackend
  , stderrBackend
  , fileBackend
  , setGlobalBackends
  , getGlobalBackends
  , Logger (..)
  , runLogger
  , logMessage
  , logDebug
  , logInfo
  , logWarn
  , logError
  , logFatal
  , logDebugIO
  , logInfoIO
  , logWarnIO
  , logErrorIO
  , logFatalIO
  , traceM
  , showT
  ) where

import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Foldable (for_)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (elemIndex)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful
import Effectful.Dispatch.Dynamic
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

data LogEntry = LogEntry
  { leTimestamp :: !TimeSpec
  , leLevel :: !LogLevel
  , leCategory :: !LogCategory
  , leMessage :: !Text
  }

type LogFormatter = LogEntry -> Text

data LogBackend = LogBackend
  { lbName :: !Text
  , lbMinLevel :: !LogLevel
  , lbFormatter :: !LogFormatter
  , lbWrite :: !(Text -> IO ())
  }

data Logger :: Effect where
  LogMessage :: LogLevel -> LogCategory -> Text -> Logger m ()

type instance DispatchOf Logger = Dynamic

logMessage :: Logger :> es => LogLevel -> LogCategory -> Text -> Eff es ()
logMessage level cat msg = send $ LogMessage level cat msg

logDebug :: Logger :> es => LogCategory -> Text -> Eff es ()
logDebug = logMessage Debug

logInfo :: Logger :> es => LogCategory -> Text -> Eff es ()
logInfo = logMessage Info

logWarn :: Logger :> es => LogCategory -> Text -> Eff es ()
logWarn = logMessage Warning

logError :: Logger :> es => LogCategory -> Text -> Eff es ()
logError = logMessage Error

logFatal :: Logger :> es => LogCategory -> Text -> Eff es ()
logFatal = logMessage Fatal

traceM :: (Logger :> es, Show a) => LogCategory -> Text -> Eff es a -> Eff es a
traceM cat name action = do
  logDebug cat (name <> " { enter }")
  res <- action
  logDebug cat (name <> " { exit = " <> showT res <> " }")
  pure res

showT :: Show a => a -> Text
showT = Text.pack . show

formatTimestamp :: TimeSpec -> Text
formatTimestamp (TimeSpec s ns) =
  let micros = fromIntegral ns `div` 1_000 :: Int
      microsTxt = Text.justifyRight 6 '0' (showT micros)
   in showT s <> "." <> microsTxt

defaultFormatter :: LogFormatter
defaultFormatter entry =
  let ts = formatTimestamp (leTimestamp entry)
      prefix = ts <> " [" <> showT (leLevel entry) <> "] [" <> showT (leCategory entry) <> "] "
   in prefix <> leMessage entry

jsonFormatter :: LogFormatter
jsonFormatter entry =
  "{\"timestamp\":\"" <> formatTimestamp (leTimestamp entry) <> "\","
    <> "\"level\":\"" <> showT (leLevel entry) <> "\","
    <> "\"category\":\"" <> showT (leCategory entry) <> "\","
    <> "\"message\":\"" <> Text.replace "\"" "\\\"" (leMessage entry) <> "\"}"

stdoutBackend :: LogLevel -> LogBackend
stdoutBackend minLevel =
  let (logger, _) = unsafePerformIO $ newFastLogger (LogStdout 4096)
      fmt = defaultFormatter
   in LogBackend
        { lbName = "stdout"
        , lbMinLevel = minLevel
        , lbFormatter = fmt
        , lbWrite = \txt -> logger (toLogStr (txt <> "\n"))
        }

stderrBackend :: LogLevel -> LogBackend
stderrBackend minLevel =
  let (logger, _) = unsafePerformIO $ newFastLogger (LogStderr 4096)
      fmt = defaultFormatter
   in LogBackend
        { lbName = "stderr"
        , lbMinLevel = minLevel
        , lbFormatter = fmt
        , lbWrite = \txt -> logger (toLogStr (txt <> "\n"))
        }

fileBackend :: LogLevel -> FilePath -> IO LogBackend
fileBackend minLevel path = do
  (logger, _) <- newFastLogger (LogFileNoRotate path 4096)
  pure $ LogBackend
    { lbName = Text.pack path
    , lbMinLevel = minLevel
    , lbFormatter = defaultFormatter
    , lbWrite = \txt -> logger (toLogStr (txt <> "\n"))
    }

runLogger :: IOE :> es => [LogBackend] -> Eff (Logger : es) a -> Eff es a
runLogger backends = interpret $ \_ -> \case
  LogMessage level cat msg -> liftIO $ do
    ts <- getTime Realtime
    let entry = LogEntry ts level cat msg
    for_ backends $ \backend ->
      when (level >= lbMinLevel backend) $ do
        let formatted = lbFormatter backend entry
        lbWrite backend formatted

-- Global backends for IO-based code during gradual migration

{-# NOINLINE globalBackends #-}
globalBackends :: IORef [LogBackend]
globalBackends = unsafePerformIO $ newIORef [stdoutBackend Info]

setGlobalBackends :: [LogBackend] -> IO ()
setGlobalBackends = writeIORef globalBackends

getGlobalBackends :: IO [LogBackend]
getGlobalBackends = readIORef globalBackends

logMessageIO :: MonadIO m => LogLevel -> LogCategory -> Text -> m ()
logMessageIO level cat msg = liftIO $ do
  backends <- readIORef globalBackends
  ts <- getTime Realtime
  let entry = LogEntry ts level cat msg
  for_ backends $ \backend ->
    when (level >= lbMinLevel backend) $ do
      let formatted = lbFormatter backend entry
      lbWrite backend formatted

logDebugIO :: MonadIO m => LogCategory -> Text -> m ()
logDebugIO = logMessageIO Debug

logInfoIO :: MonadIO m => LogCategory -> Text -> m ()
logInfoIO = logMessageIO Info

logWarnIO :: MonadIO m => LogCategory -> Text -> m ()
logWarnIO = logMessageIO Warning

logErrorIO :: MonadIO m => LogCategory -> Text -> m ()
logErrorIO = logMessageIO Error

logFatalIO :: MonadIO m => LogCategory -> Text -> m ()
logFatalIO = logMessageIO Fatal
