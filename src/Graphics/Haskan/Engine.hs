{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Engine
  ( mainLoop
  , EngineConfig (..)
  , GameState
  , WorldState
  , ControlMessage (..)
  , FrameStats (..)
  , FrameTime (..)
  , emptyFrameStats
  , updateFrameStats
  , forkIOWithHandler
  , InputBuffer (..)
  , newInputBuffer
  , writeInputBuffer
  , flushInputBuffer
  , makeProjectionMatrix
  , computeSkyboxRays
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (STM)
import Control.Concurrent.STM qualified as STM
import Control.Concurrent.STM.TChan (TChan)
import Control.Concurrent.STM.TChan qualified as TChan
import Control.Concurrent.STM.TQueue (TQueue)
import Control.Concurrent.STM.TQueue qualified as TQueue
import Control.Concurrent.STM.TVar (TVar)
import Control.Monad (forM_, unless, when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (runManaged, with)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as Text
import Graphics.Haskan.Camera (Camera (..))
import Graphics.Haskan.Camera qualified as Camera
import Graphics.Haskan.Debug.FrameInspector (defaultInspector)
import Graphics.Haskan.Debug.Interface (DebugMessage (..), debugMessageToActionEvent)
import Graphics.Haskan.Debug.Server (startDebugServer, stopDebugServer)
import Graphics.Haskan.Engine.Scene (makeProjectionMatrix, computeSkyboxRays)
import Graphics.Haskan.Engine.Types
  ( EngineConfig (..)
  , FrameStats (..)
  , FrameTime (..)
  , GameState (..)
  , WorldState (..)
  , InputBuffer (..)
  , ControlMessage (..)
  , LightData (..)
  , emptyFrameStats
  , updateFrameStats
  , forkIOWithHandler
  , newInputBuffer
  , writeInputBuffer
  , flushInputBuffer
  )
import Graphics.Haskan.Engine.Update (stateUpdateLoop)
import Graphics.Haskan.Engine.Render (renderLoop)
import Graphics.Haskan.Input (Action (..), ActionEvent, payloadToActionEvent)
import Graphics.Haskan.Logger (logInfoIO, LogCategory(..), showT)
import Graphics.Haskan.Vulkan.Instance qualified as Instance
import Graphics.Haskan.Vulkan.PhysicalDevice qualified as PhysicalDevice
import Graphics.Haskan.Window qualified as Window
import Linear (V3 (..))
import SDL qualified
import SDL.Input.Mouse qualified as SDL.Mouse

mainLoop :: MonadIO m => String -> EngineConfig -> m ()
mainLoop meshName EngineConfig {..} = do
  logInfoIO LogGeneral "starting mainLoop"
  camera <- liftIO $ STM.newTVarIO (Camera.defaultOrbitalCamera)
  isRunning <- liftIO $ STM.newTVarIO True

  controlChannel <- liftIO $ TChan.newBroadcastTChanIO
  worldState <- liftIO $ STM.newTVarIO (WorldState camera)
  inputBuffer <- liftIO newInputBuffer
  debugCmdQueue <- liftIO $ STM.newTQueueIO
  tvMoveForward <- liftIO $ STM.newTVarIO (False)
  tvMoveBackward <- liftIO $ STM.newTVarIO (False)
  tvStrafeLeft <- liftIO $ STM.newTVarIO (False)
  tvStrafeRight <- liftIO $ STM.newTVarIO (False)

  tvInspectFrame <- liftIO $ STM.newTVarIO False
  tvInspector <- liftIO $ STM.newTVarIO (Just (defaultInspector "snapshots"))
  tvRenderDebugState <- liftIO $ STM.newTVarIO Nothing
  tvWireframeEnabled <- liftIO $ STM.newTVarIO False
  tvDebugMode <- liftIO $ STM.newTVarIO 0
  tvAxisOverlayEnabled <- liftIO $ STM.newTVarIO 0.0
  tvGroundPlaneEnabled <- liftIO $ STM.newTVarIO 0.0
  tvPendingScreenshot <- liftIO $ STM.newTVarIO False
  tvPendingAllStages <- liftIO $ STM.newTVarIO False
  tvPendingSwapchainScreenshot <- liftIO $ STM.newTVarIO False
  tvMouseCaptureEnabled <- liftIO $ STM.newTVarIO False
  tvLights <- liftIO $ STM.newTVarIO
    ( take lightCount
      [ LightData (V3 1 1 1) 1.0 (V3 1 1 1) 0 (V3 (-1) (-1) (-1)) 0.0
      , LightData (V3 (-1) 1 (-1)) 0.5 (V3 1 0.8 0.6) 0 (V3 1 (-1) 1) 0.0
      , LightData (V3 0 (-1) 0) 0.3 (V3 0.4 0.4 0.6) 0 (V3 0 1 0) 0.0
      , LightData (V3 1 0 0) 0.7 (V3 0.9 0.2 0.2) 0 (V3 (-1) 0 0) 0.0
      , LightData (V3 0 1 0) 0.4 (V3 0.2 0.9 0.2) 0 (V3 0 (-1) 0) 0.0
      , LightData (V3 0 0 1) 0.6 (V3 0.2 0.2 0.9) 0 (V3 0 0 (-1)) 0.0
      , LightData (V3 1 1 (-1)) 0.5 (V3 0.8 0.8 0.2) 0 (V3 (-1) (-1) 1) 0.0
      , LightData (V3 (-1) (-1) 1) 0.4 (V3 0.8 0.2 0.8) 0 (V3 1 1 (-1)) 0.0
      ]
    )

  let gameState =
        GameState
          worldState
          isRunning
          tvMoveForward
          tvMoveBackward
          tvStrafeLeft
          tvStrafeRight
          tvInspectFrame
          tvInspector
          tvRenderDebugState
          tvWireframeEnabled
          tvDebugMode
          tvAxisOverlayEnabled
          tvGroundPlaneEnabled
          tvPendingScreenshot
          tvPendingAllStages
          tvPendingSwapchainScreenshot
          tvMouseCaptureEnabled
          tvLights

  mDebugServer <- case debugSocketPath of
    Just path -> do
      h <- startDebugServer path (\ev -> STM.atomically $ writeInputBuffer inputBuffer ev) debugCmdQueue
      logInfoIO LogGeneral $ "debug server listening on " <> Text.pack path
      pure (Just h)
    Nothing -> pure Nothing

  case timeoutSeconds of
    Just seconds | seconds > 0 -> do
      logInfoIO LogGeneral $ "timeout set to " <> showT seconds <> " seconds"
      _ <- liftIO $ forkIO $ do
        threadDelay (fromIntegral seconds * 1000000)
        logInfoIO LogGeneral "timeout reached, sending Terminate"
        STM.atomically $ TChan.writeTChan controlChannel Terminate
      pure ()
    _ -> pure ()

  SDL.initialize @[] [SDL.InitEvents]

  logInfoIO LogGeneral "Initialize base Render context"
  let initWidth = 1920
      initHeight = 1080
  window <- Window.createWindow title (initWidth, initHeight)
  windowExts <- Window.windowExtensions window
  (inst, layers) <- Instance.createInstance windowExts
  surface <- Window.createSurface inst window
  physicalDevice <- PhysicalDevice.selectPhysicalDevice inst
  Window.showWindow window

  renderLoopFinished <- liftIO $ newEmptyMVar
  liftIO $ forkIOWithHandler "renderLoop" renderLoopFinished $ runManaged $ renderLoop physicalDevice surface layers targetRenderFPS gameState renderLoopFinished controlChannel meshName uvCheckMode envMapDir

  stateUpdateLoopFinished <- liftIO $ newEmptyMVar
  liftIO $ forkIOWithHandler "stateUpdateLoop" stateUpdateLoopFinished $ stateUpdateLoop targetPhysicsFPS gameState stateUpdateLoopFinished inputBuffer debugCmdQueue controlChannel

  let inputLoop :: MonadIO m => m ()
      inputLoop = do
        events <- SDL.pollEvents
        let actionEvents = catMaybes $ map (payloadToActionEvent . SDL.eventPayload) events
            quitting = any (\(a, p, _) -> a == Escape && p) actionEvents
        liftIO $ STM.atomically $ forM_ actionEvents $ writeInputBuffer inputBuffer
        when (not (null actionEvents)) $ logInfoIO LogGeneral $ "input: " <> showT (length actionEvents) <> " events, first=" <> showT (head actionEvents)
        running <- liftIO $ STM.readTVarIO isRunning
        let inputDelayMicros = max 1 (1000000 `div` fromIntegral targetInputFPS)
        liftIO $ threadDelay (fromIntegral inputDelayMicros)
        unless (quitting || not running) inputLoop

  logInfoIO LogGeneral "inputLoop starting"
  inputLoop
  logInfoIO LogGeneral "sending Terminate message"
  liftIO $ STM.atomically $ TChan.writeTChan controlChannel Terminate
  logInfoIO LogGeneral "waiting for other threads finished"
  liftIO $ mapM_ takeMVar [renderLoopFinished, stateUpdateLoopFinished]

  liftIO $ forM_ mDebugServer stopDebugServer

  logInfoIO LogGeneral "destroying SDL window"
  SDL.Mouse.setMouseLocationMode SDL.Mouse.AbsoluteLocation
  SDL.destroyWindow window
  SDL.quit
  logInfoIO LogGeneral "mainLoop finished"
