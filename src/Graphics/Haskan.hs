module Graphics.Haskan (runHaskan) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Graphics.Haskan.Engine (EngineConfig (..))
import Graphics.Haskan.Engine qualified as Engine
import Graphics.Haskan.Logger (LogCategory (..), logInfoIO)

runHaskan :: Text -> String -> Maybe Integer -> Maybe FilePath -> Bool -> Bool -> Bool -> String -> Int -> Float -> Float -> Bool -> Bool -> IO ()
runHaskan title meshName mTimeout mDebugSocket uvCheckCube uvCheckSphere uvCheckPlane envDir numLights initialTime speed dayNight cloudTest = do
  logInfoIO LogGeneral "Initializing Haskan Engine"
  logInfoIO LogGeneral "Starting Engine main loop"
  Engine.mainLoop
    meshName
    EngineConfig
      { targetRenderFPS = 120,
        targetPhysicsFPS = 60,
        targetNetworkFPS = 10,
        targetInputFPS = 60,
        title = title,
        debugSocketPath = mDebugSocket,
        timeoutSeconds = mTimeout,
        uvCheckMode =
          if uvCheckCube
            then Just "cube"
            else
              if uvCheckSphere
                then Just "sphere"
                else
                  if uvCheckPlane
                    then Just "plane"
                    else Nothing,
        envMapDir = envDir,
        lightCount = numLights,
        initialTimeOfDay = initialTime,
        timeSpeed = speed,
        dayNightEnabled = dayNight,
        cloudTestMode = cloudTest
      }
  logInfoIO LogGeneral "Shutting down Haskan"
