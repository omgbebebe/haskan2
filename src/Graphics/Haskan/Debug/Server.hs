{-# LANGUAGE OverloadedStrings #-}

module Graphics.Haskan.Debug.Server
  ( startDebugServer
  , stopDebugServer
  , DebugServerHandle
  , CommandQueue
  )
where

import Control.Concurrent (ThreadId, forkIO, killThread)
import Control.Concurrent.STM (TQueue, TMVar)
import Control.Concurrent.STM qualified as STM
import Control.Concurrent.STM.TQueue qualified as TQueue
import Control.Exception (bracket, handle, SomeException)
import Control.Monad (forever, unless, void)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Graphics.Haskan.Debug.Interface
import Graphics.Haskan.Input (ActionEvent)
import Graphics.Haskan.Logger (logInfo, LogCategory(..))
import Network.Socket
import System.Directory (removeFile)
import System.IO (Handle, hClose, hFlush, hPutStrLn, IOMode (..))

data DebugServerHandle = DebugServerHandle
  { dshThreadId :: !ThreadId
  , dshSocketPath :: !FilePath
  }

type CommandQueue = TQueue (DebugCommand, TMVar DebugResponse)

startDebugServer :: MonadIO m => FilePath -> TQueue ActionEvent -> CommandQueue -> m DebugServerHandle
startDebugServer socketPath actionQueue cmdQueue = liftIO $ do
  logInfo LogGeneral $ "starting debug server on " <> Text.pack socketPath
  -- Remove old socket if exists
  handle (\(_ :: SomeException) -> pure ()) $ removeFile socketPath

  sock <- socket AF_UNIX Stream defaultProtocol
  bind sock (SockAddrUnix socketPath)
  listen sock 5

  tid <- forkIO $ forever $ do
    (conn, _) <- accept sock
    void $ forkIO $ handleConnection conn actionQueue cmdQueue

  pure $ DebugServerHandle tid socketPath

stopDebugServer :: MonadIO m => DebugServerHandle -> m ()
stopDebugServer (DebugServerHandle tid path) = liftIO $ do
  logInfo LogGeneral "stopping debug server"
  killThread tid
  handle (\(_ :: SomeException) -> pure ()) $ removeFile path

handleConnection :: Socket -> TQueue ActionEvent -> CommandQueue -> IO ()
handleConnection sock actionQueue cmdQueue = handle (\(_ :: SomeException) -> pure ()) $ do
  bracket (socketToHandle sock ReadWriteMode) hClose $ \hdl -> do
    hPutStrLn hdl "{ \"status\": \"connected\" }"
    hFlush hdl
    loop hdl
 where
  loop hdl = do
    line <- BS.hGetLine hdl
    unless (BS.null line) $ do
      case parseDebugMessage (Text.decodeUtf8 line) of
        Left err -> do
          logInfo LogGeneral $ "debug parse error: " <> Text.pack err
          hPutStrLn hdl $ "{ \"error\": \"" ++ err ++ "\" }"
          hFlush hdl
          loop hdl
        Right msg -> do
          case debugMessageToActionEvent msg of
            Right mAction -> do
              case mAction of
                Nothing -> pure ()
                Just ev -> STM.atomically $ TQueue.writeTQueue actionQueue ev
              hPutStrLn hdl "{ \"status\": \"ok\" }"
              hFlush hdl
              loop hdl
            Left cmd -> do
              -- For commands that need responses, create a TMVar
              respVar <- STM.newEmptyTMVarIO
              STM.atomically $ TQueue.writeTQueue cmdQueue (cmd, respVar)
              -- Wait for response and send it back
              resp <- STM.atomically $ STM.takeTMVar respVar
              hPutStrLn hdl (Text.unpack $ encodeDebugResponse resp)
              hFlush hdl
              loop hdl