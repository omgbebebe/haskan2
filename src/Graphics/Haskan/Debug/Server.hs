{-# LANGUAGE OverloadedStrings #-}

module Graphics.Haskan.Debug.Server
  ( startDebugServer,
    stopDebugServer,
    DebugServerHandle,
    CommandQueue,
  )
where

import Control.Concurrent (ThreadId, forkIO, killThread)
import Control.Concurrent.STM (TMVar, TQueue)
import Control.Concurrent.STM qualified as STM
import Control.Concurrent.STM.TQueue qualified as TQueue
import Control.Exception (SomeException, bracket, handle)
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
import Graphics.Haskan.Logger (LogCategory (..), logInfoIO)
import Network.Socket
import System.Directory (removeFile)
import System.IO (Handle, IOMode (..), hClose, hFlush, hPutStrLn)

data DebugServerHandle = DebugServerHandle
  { dshThreadId :: !ThreadId,
    dshSocketPath :: !FilePath
  }

type CommandQueue = TQueue (DebugCommand, TMVar DebugResponse)

startDebugServer :: (MonadIO m) => FilePath -> (ActionEvent -> IO ()) -> CommandQueue -> m DebugServerHandle
startDebugServer socketPath writeAction cmdQueue = liftIO $ do
  logInfoIO LogGeneral $ "starting debug server on " <> Text.pack socketPath
  -- Remove old socket if exists
  handle (\(_ :: SomeException) -> pure ()) $ removeFile socketPath

  sock <- socket AF_UNIX Stream defaultProtocol
  bind sock (SockAddrUnix socketPath)
  listen sock 5

  tid <- forkIO $ forever $ do
    (conn, _) <- accept sock
    void $ forkIO $ handleConnection conn writeAction cmdQueue

  pure $ DebugServerHandle tid socketPath

stopDebugServer :: (MonadIO m) => DebugServerHandle -> m ()
stopDebugServer (DebugServerHandle tid path) = liftIO $ do
  logInfoIO LogGeneral "stopping debug server"
  killThread tid
  handle (\(_ :: SomeException) -> pure ()) $ removeFile path

handleConnection :: Socket -> (ActionEvent -> IO ()) -> CommandQueue -> IO ()
handleConnection sock writeAction cmdQueue = handle (\(_ :: SomeException) -> pure ()) $ do
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
            logInfoIO LogGeneral $ "debug parse error: " <> Text.pack err
            hPutStrLn hdl $ "{ \"error\": \"" ++ err ++ "\" }"
            hFlush hdl
            loop hdl
          Right msg -> do
            case debugMessageToActionEvent msg of
              Right mAction -> do
                case mAction of
                  Nothing -> pure ()
                  Just ev -> writeAction ev
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
