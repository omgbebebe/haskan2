module Main where

import Data.List (sort)
import Graphics.Haskan.Engine.Capabilities.Clock (MonadClock (..))
import Graphics.Haskan.Engine.Capabilities.Graphics (MonadGraphics (..))
import Graphics.Haskan.Engine.Capabilities.Log (MonadLog (..), logInfo, logDebug)
import Graphics.Haskan.Engine.Capabilities.StateReader (MonadStateReader (..))
import Graphics.Haskan.Engine.Capabilities.Telemetry (MonadTelemetry (..))
import Graphics.Haskan.Engine.Capabilities.Test
  ( TestState (..),
    defaultTestState,
    execTestM,
    runTestM,
    GraphicsCall (..),
  )
import Graphics.Haskan.Engine.Types (FrameStats (..))
import Graphics.Haskan.Logger (LogCategory (..), LogLevel (..))
import Graphics.Haskan.Model qualified as Model
import Graphics.Haskan.Vulkan.Types (RenderResult (..))

main :: IO ()
main = do
  putStrLn "Testing normalizeMesh..."
  let mesh = Model.normalizeMesh undefined [1, 2, 3, 4, 5, 6]
  assertEq "normalizeMesh length" 2 (length mesh)

  putStrLn "Testing Model normalization logic..."
  let norm = sort [minimum [a, b, c] | (a, b, c) <- [(1, 2, 3), (4, 5, 6)]]
  assertEq "minIdx rotates correctly" [1, 4] norm

  putStrLn "Testing MonadLog TestM..."
  let st1 =
        execTestM defaultTestState $ do
          logInfo LogGeneral "hello"
          logDebug LogRender "world"
  assertEq "log count" 2 (length (tsLogs st1))
  assertEq "first log level" Info (case tsLogs st1 of ((l, _, _) : _) -> l; _ -> Error)

  putStrLn "Testing MonadClock TestM..."
  let st2 =
        execTestM defaultTestState $ do
          t1 <- getMonotonicTime
          delayMicros 1000
          t2 <- getMonotonicTime
          pure ()
  assertEq "clock advances" (tsClockTime st2 > 0) True

  putStrLn "Testing MonadTelemetry TestM..."
  let st3 =
        execTestM defaultTestState $ do
          recordFrameTime 16666666
          msg <- getTelemetryMessage
          pure msg
  assertEq "total frames" 1 (fsTotalFrames (tsFrameStats st3))
  assertEq "accum time" 16666666 (fsAccumTime (tsFrameStats st3))

  putStrLn "Testing MonadStateReader TestM..."
  let st4 =
        execTestM defaultTestState {tsWireframe = True, tsDebugMode = 7} $ do
          w <- readWireframe
          d <- readDebugMode
          pure (w, d)
  assertEq "wireframe" True (tsWireframe st4)
  assertEq "debug mode" 7 (tsDebugMode st4)

  putStrLn "Testing MonadGraphics TestM..."
  let st5 =
        execTestM defaultTestState $ do
          uploadStorageBuffer undefined 0 ([1, 2, 3] :: [Int])
          uploadUniformBuffer undefined 0 ([4, 5] :: [Int])
          deviceWaitIdle
          res <- drawFrameGraphics undefined 0 undefined
          vkRes <- presentFrameGraphics 0 undefined
          pure (res, vkRes)
  assertEq "graphics calls count" 5 (length (tsGraphicsCalls st5))
  assertEq "first call" (UploadStorageBuffer 0 3) (head (tsGraphicsCalls st5))
  let (drawRes, _) = runTestM defaultTestState $ do
        uploadStorageBuffer undefined 0 ([1, 2, 3] :: [Int])
        uploadUniformBuffer undefined 0 ([4, 5] :: [Int])
        deviceWaitIdle
        res <- drawFrameGraphics undefined 0 undefined
        vkRes <- presentFrameGraphics 0 undefined
        pure (res, vkRes)
  assertEq "draw result" (FrameOk 0) (fst drawRes)

  putStrLn "All tests passed"

assertEq :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEq label x y
  | x == y = return ()
  | otherwise = error $ "FAIL: " ++ label ++ " expected " ++ show y ++ " got " ++ show x
