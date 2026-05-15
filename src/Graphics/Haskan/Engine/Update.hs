module Graphics.Haskan.Engine.Update
  ( stateUpdateLoop,
    updateCamera,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, putMVar)
import Control.Concurrent.STM (STM)
import Control.Concurrent.STM qualified as STM
import Control.Concurrent.STM.TChan (TChan)
import Control.Concurrent.STM.TChan qualified as TChan
import Control.Concurrent.STM.TQueue (TQueue)
import Control.Concurrent.STM.TQueue qualified as TQueue
import Control.Concurrent.STM.TVar (TVar)
import Control.Monad (forM_, unless, when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (ToJSON (..))
import Data.Foldable (toList)
import Foreign.C qualified
import Graphics.Haskan.Camera (AnyCamera (..), Camera (..), toAnyCamera)
import Graphics.Haskan.Camera qualified as Camera
import Graphics.Haskan.DayNight (SunState (..), computeSunState, defaultDayNightConfig)
import Graphics.Haskan.Debug.Interface (DebugCameraSnapshot (..), DebugCommand (..), DebugMessage (..), DebugResponse (..), GameStateSnapshot (..), debugMessageToActionEvent, encodeDebugResponse, parseDebugMessage)
import Graphics.Haskan.Debug.Server (CommandQueue)
import Graphics.Haskan.Engine.Types (CameraMode (..), ControlMessage (..), GameState (..), InputBuffer (..), LightData (..), WorldState (..), flushInputBuffer)
import Graphics.Haskan.Input (Action (..), ActionEvent)
import Graphics.Haskan.Logger (LogCategory (..), logInfoIO, showT)
import Linear (V2 (..), V3 (..))
import SDL qualified
import SDL.Input.Mouse qualified as SDL.Mouse
import System.Clock (Clock (..), getTime, toNanoSecs)

stateUpdateLoop :: (MonadIO m) => Integer -> GameState AnyCamera -> MVar () -> InputBuffer -> CommandQueue -> TChan ControlMessage -> m ()
stateUpdateLoop targetFPS gameState finishedSemaphore inputBuffer debugCmdQueue controlChannel = liftIO $ do
  logInfoIO LogGeneral "stateUpdateLoop starting"
  control <- STM.atomically $ TChan.dupTChan controlChannel

  let camSpeed = 10.0 :: Foreign.C.CFloat

  let loop :: (MonadIO m) => Integer -> GameState AnyCamera -> Integer -> m ()
      loop tFPS _gameState prevTime = liftIO $ do
        maybeControlMessage <- STM.atomically $ TChan.tryReadTChan control
        case maybeControlMessage of
          Nothing -> do
            newTime <- liftIO $ toNanoSecs <$> getTime Monotonic
            let dtSeconds = min 0.1 (realToFrac (newTime - prevTime) / 1e9) :: Foreign.C.CFloat
            (actions, overflowCount) <- STM.atomically $ flushInputBuffer inputBuffer
            when (overflowCount > 0) $ logInfoIO LogGeneral $ "input buffer overflow: " <> showT overflowCount <> " events dropped"
            unless (null actions) $ logInfoIO LogGeneral $ "stateUpdate: processing " <> showT (length actions) <> " actions, first=" <> showT (take 1 actions)
            debugCmds <- STM.atomically $ TQueue.flushTQueue debugCmdQueue
            worldState <- STM.readTVarIO (world gameState)
            let camera = activeCamera worldState
            mouseCaptured <- STM.readTVarIO (mouseCaptureEnabled gameState)
            forM_ actions $ \action ->
              case action of
                (MoveForward, b, _) -> STM.atomically $ STM.writeTVar (moveForward gameState) b
                (MoveBackward, b, _) -> STM.atomically $ STM.writeTVar (moveBackward gameState) b
                (StrafeLeft, b, _) -> STM.atomically $ STM.writeTVar (strafeLeft gameState) b
                (StrafeRight, b, _) -> STM.atomically $ STM.writeTVar (strafeRight gameState) b
                (MouseMove (V2 x y), _, isRepeated) ->
                  when mouseCaptured $
                    unless isRepeated $
                      STM.atomically
                        ( updateCamera
                            (activeCamera worldState)
                            [ Camera.Rotate
                                (V3 (fromIntegral x * 0.1 * dtSeconds) (fromIntegral y * 0.1 * dtSeconds) 0.0)
                            ]
                        )
                (Zoom amount, _, _) ->
                  STM.atomically
                    ( updateCamera
                        (activeCamera worldState)
                        [Camera.Zoom (realToFrac amount)]
                    )
                (Escape, _, _) -> STM.atomically $ STM.writeTVar (isRunning gameState) False
                (FrameInspect, True, _) -> STM.atomically $ STM.writeTVar (inspectFrame gameState) True
                (FrameInspect, False, _) -> pure ()
                (ToggleWireframe, True, _) -> do
                  current <- STM.readTVarIO (wireframeEnabled gameState)
                  STM.atomically $ STM.writeTVar (wireframeEnabled gameState) (not current)
                  logInfoIO LogGeneral $ "wireframe toggled: " <> showT (not current)
                (ToggleWireframe, False, _) -> pure ()
                (ToggleMouseCapture, True, _) -> do
                  current <- STM.readTVarIO (mouseCaptureEnabled gameState)
                  let newState = not current
                  STM.atomically $ STM.writeTVar (mouseCaptureEnabled gameState) newState
                  SDL.Mouse.setMouseLocationMode (if newState then SDL.Mouse.RelativeLocation else SDL.Mouse.AbsoluteLocation)
                  logInfoIO LogGeneral $ "mouse capture toggled: " <> showT newState
                (ToggleMouseCapture, False, _) -> pure ()
                (ToggleAxisOverlay, True, _) -> do
                  current <- STM.readTVarIO (axisOverlayEnabled gameState)
                  let newState = if current == 1.0 then 0.0 else 1.0
                  STM.atomically $ STM.writeTVar (axisOverlayEnabled gameState) newState
                  logInfoIO LogGeneral $ "axis overlay toggled: " <> showT newState
                (ToggleAxisOverlay, False, _) -> pure ()
                (ToggleGroundPlane, True, _) -> do
                  current <- STM.readTVarIO (groundPlaneEnabled gameState)
                  let newState = if current == 1.0 then 0.0 else 1.0
                  STM.atomically $ STM.writeTVar (groundPlaneEnabled gameState) newState
                  logInfoIO LogGeneral $ "ground plane toggled: " <> showT newState
                (ToggleGroundPlane, False, _) -> pure ()
                (DebugMode mode, True, _) -> do
                  STM.atomically $ STM.writeTVar (debugMode gameState) (fromIntegral mode)
                  logInfoIO LogGeneral $ "debug mode set to " <> showT mode
                (DebugMode _, False, _) -> pure ()
                (SaveScreenshot, True, _) -> do
                  STM.atomically $ STM.writeTVar (pendingScreenshot gameState) True
                  logInfoIO LogGeneral "screenshot requested"
                (SaveScreenshot, False, _) -> pure ()
                (SaveAllStages, True, _) -> do
                  STM.atomically $ STM.writeTVar (pendingAllStages gameState) True
                  logInfoIO LogGeneral "save all stages requested"
                (SaveAllStages, False, _) -> pure ()
                (SaveSwapchainScreenshot, True, _) -> do
                  STM.atomically $ STM.writeTVar (pendingSwapchainScreenshot gameState) True
                  logInfoIO LogGeneral "swapchain screenshot requested"
                (SaveSwapchainScreenshot, False, _) -> pure ()
                (CloudHeightUp, True, _) -> do
                  current <- STM.readTVarIO (cloudHeight gameState)
                  let newHeight = min 30000.0 (current + 100.0)
                  STM.atomically $ STM.writeTVar (cloudHeight gameState) newHeight
                  logInfoIO LogGeneral $ "cloud height: " <> showT newHeight
                (CloudHeightUp, False, _) -> pure ()
                (CloudHeightDown, True, _) -> do
                  current <- STM.readTVarIO (cloudHeight gameState)
                  let newHeight = max 500.0 (current - 100.0)
                  STM.atomically $ STM.writeTVar (cloudHeight gameState) newHeight
                  logInfoIO LogGeneral $ "cloud height: " <> showT newHeight
                (CloudHeightDown, False, _) -> pure ()
                (WindRotateLeft, True, _) -> do
                  dir <- STM.readTVarIO (windDirection gameState)
                  let newDir = dir + 15.0
                  STM.atomically $ STM.writeTVar (windDirection gameState) newDir
                  logInfoIO LogGeneral $ "wind direction: " <> showT newDir <> " deg"
                (WindRotateLeft, False, _) -> pure ()
                (WindRotateRight, True, _) -> do
                  dir <- STM.readTVarIO (windDirection gameState)
                  let newDir = dir - 15.0
                  STM.atomically $ STM.writeTVar (windDirection gameState) newDir
                  logInfoIO LogGeneral $ "wind direction: " <> showT newDir <> " deg"
                (WindRotateRight, False, _) -> pure ()
                (CloudPreset idx, True, _) -> do
                  let presets =
                        [ (1500.0, 0.45, 0.35, 1.5),  -- Cumulus
                          (800.0,  0.85, 0.20, 2.0),  -- Stratus
                          (1000.0, 0.60, 0.30, 1.5),  -- Stratocumulus
                          (1000.0, 0.60, 0.50, 3.0),  -- Cumulonimbus
                          (8000.0, 0.30, 0.60, 0.4)   -- Cirrus
                        ]
                      (baseH, cov, det, abso) = if idx >= 0 && idx < length presets
                        then presets !! idx
                        else (1500.0, 0.45, 0.35, 1.5)
                  STM.atomically $ do
                    STM.writeTVar (cloudHeight gameState) baseH
                    STM.writeTVar (cloudCoverage gameState) cov
                    STM.writeTVar (cloudDetail gameState) det
                    STM.writeTVar (cloudAbsorption gameState) abso
                  logInfoIO LogGeneral $ "cloud preset " <> showT idx <> ": base=" <> showT baseH <> " coverage=" <> showT cov <> " detail=" <> showT det <> " absorption=" <> showT abso
                (CloudPreset _, False, _) -> pure ()
                (SwitchCameraMode, True, _) -> do
                  currentMode <- STM.readTVarIO (cameraMode gameState)
                  let newMode = case currentMode of
                        CameraModeOrbital -> CameraModeFly
                        CameraModeFly -> CameraModeOrbital
                  worldState <- STM.readTVarIO (world gameState)
                  currentCam <- STM.readTVarIO (activeCamera worldState)
                  let newCam = toAnyCamera currentCam
                  STM.atomically $ do
                    STM.writeTVar (cameraMode gameState) newMode
                    STM.writeTVar (activeCamera worldState) newCam
                  logInfoIO LogGeneral $ "camera mode switched to " <> showT newMode
                (SwitchCameraMode, False, _) -> pure ()
            forM_ debugCmds $ \(cmd, respVar) -> do
              case cmd of
                SetCameraDistance d -> do
                  STM.atomically $ STM.modifyTVar' (activeCamera worldState) (\cam -> setDistance cam (realToFrac d))
                  STM.atomically $ STM.putTMVar respVar (AckResponse "camera_distance_set")
                SetCameraTarget (V3 tx ty tz) -> do
                  STM.atomically $
                    STM.modifyTVar'
                      (activeCamera worldState)
                      ( \cam ->
                          setTarget cam (V3 (realToFrac tx) (realToFrac ty) (realToFrac tz))
                      )
                  STM.atomically $ STM.putTMVar respVar (AckResponse "camera_target_set")
                SetCameraAngles az el -> do
                  STM.atomically $
                    STM.modifyTVar'
                      (activeCamera worldState)
                      ( \cam ->
                          setAngles cam (realToFrac az) (realToFrac el)
                      )
                  STM.atomically $ STM.putTMVar respVar (AckResponse "camera_angles_set")
                TriggerFrameInspect -> do
                  STM.atomically $ STM.writeTVar (inspectFrame gameState) True
                  STM.atomically $ STM.putTMVar respVar (AckResponse "frame_inspect_triggered")
                SetTimeScale _ -> do
                  STM.atomically $ STM.putTMVar respVar (AckResponse "time_scale_not_implemented")
                GetState -> do
                  cam <- STM.readTVarIO (activeCamera worldState)
                  running <- STM.readTVarIO (isRunning gameState)
                  inspecting <- STM.readTVarIO (inspectFrame gameState)
                  let pos = realToFrac <$> cameraPosition cam
                      tgt = realToFrac <$> cameraTarget cam
                      dist = realToFrac $ cameraDistance cam
                      az = realToFrac $ cameraAzimuth cam
                      el = realToFrac $ cameraElevation cam
                      snapshot =
                        GameStateSnapshot
                          { gssCamera = DebugCameraSnapshot pos tgt dist az el,
                            gssRunning = running,
                            gssFrameInspectorEnabled = inspecting
                          }
                  STM.atomically $ STM.putTMVar respVar (StateResponse snapshot)
                GetRenderState -> do
                  mDebugInfo <- STM.readTVarIO (renderDebugState gameState)
                  case mDebugInfo of
                    Just debugInfo -> do
                      let val = toJSON debugInfo
                      STM.atomically $ STM.putTMVar respVar (RenderStateResponse val)
                    Nothing -> do
                      STM.atomically $ STM.putTMVar respVar (ErrorResponse "no render debug info available yet")

            (fwd, bwd, sl, sr, isRunning) <- STM.atomically $ do
              a <- STM.readTVar (moveForward gameState)
              b <- STM.readTVar (moveBackward gameState)
              c <- STM.readTVar (strafeLeft gameState)
              d <- STM.readTVar (strafeRight gameState)
              e <- STM.readTVar (isRunning gameState)
              pure (a, b, c, d, e)

            keyMod <- SDL.getModState
            let shiftHeld = SDL.keyModifierLeftShift keyMod || SDL.keyModifierRightShift keyMod
                speedMult = if shiftHeld then 10.0 else 1.0
                camMove = camSpeed * speedMult * dtSeconds
            when fwd $ STM.atomically $ updateCamera (activeCamera worldState) [Camera.MoveForward camMove]
            when bwd $ STM.atomically $ updateCamera (activeCamera worldState) [Camera.MoveForward (-camMove)]
            when sl $ STM.atomically $ updateCamera (activeCamera worldState) [Camera.MoveRight (-camMove)]
            when sr $ STM.atomically $ updateCamera (activeCamera worldState) [Camera.MoveRight camMove]
            STM.atomically $ STM.modifyTVar' (activeCamera worldState) (`Camera.animate` dtSeconds)

            -- Update day/night cycle
            dnEnabled <- STM.readTVarIO (gameDayNightEnabled gameState)
            when dnEnabled $ do
              currentTime <- STM.readTVarIO (gameTimeOfDay gameState)
              speed <- STM.readTVarIO (gameTimeSpeed gameState)
              let newTime = fmod (currentTime + realToFrac dtSeconds * speed / 3600.0) 24.0
              STM.atomically $ STM.writeTVar (gameTimeOfDay gameState) newTime
              let sunState = computeSunState defaultDayNightConfig newTime
              when (floor newTime /= floor currentTime) $ do
                logInfoIO LogGeneral $ "time=" <> showT newTime <> " sunDir=" <> showT (ssDirection sunState) <> " intensity=" <> showT (ssIntensity sunState)
              -- Update first light (the sun)
              lightsList <- STM.readTVarIO (lights gameState)
              let updatedLights = case lightsList of
                    [] -> []
                    (sun : rest) ->
                      sun
                        { ldDirection = realToFrac <$> ssDirection sunState,
                          ldIntensity = realToFrac (ssIntensity sunState),
                          ldColor = realToFrac <$> ssColor sunState
                        }
                        : rest
              STM.atomically $ STM.writeTVar (lights gameState) updatedLights

            let targetDelayMicros = 1000000 `div` fromIntegral tFPS
            threadDelay (fromIntegral targetDelayMicros)
            when isRunning $ loop tFPS _gameState newTime
          Just Terminate -> do
            logInfoIO LogGeneral "terminating stateUpdate loop by signal"
            STM.atomically $ STM.writeTVar (isRunning _gameState) False

  currentTime <- liftIO $ toNanoSecs <$> getTime Monotonic
  loop targetFPS gameState currentTime
  logInfoIO LogGeneral "stateUpdateLoop finished"
  putMVar finishedSemaphore ()

updateCamera ::
  (Camera cam) =>
  TVar cam ->
  [Camera.Modifier Foreign.C.CFloat] ->
  STM ()
updateCamera tv mods = STM.modifyTVar' tv (Camera.update <*> pure mods)

fmod :: Float -> Float -> Float
fmod x y = x - y * fromIntegral (floor (x / y) :: Int)
