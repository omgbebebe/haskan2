module Graphics.Haskan (runHaskan, runSimple) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Graphics.Haskan.Engine (EngineConfig (..))
import Graphics.Haskan.Engine qualified as Engine
import Graphics.Haskan.Logger (LogCategory (..), logInfoIO)
import Graphics.Haskan.Mesh (Mesh)
import Graphics.Haskan.Render.RenderSystem (DrawCall (..))

runHaskan :: Text -> String -> Maybe Integer -> Maybe FilePath -> Bool -> Bool -> Bool -> String -> Int -> Float -> Float -> Bool -> Bool -> Bool -> IO ()
runHaskan title meshName mTimeout mDebugSocket uvCheckCube uvCheckSphere uvCheckPlane envDir numLights initialTime speed dayNight cloudTest proceduralSky = do
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
        cloudTestMode = cloudTest,
        proceduralSkyEnabled = proceduralSky,
        simpleMesh = Nothing
      }
  logInfoIO LogGeneral "Shutting down Haskan"

-- | Minimal API: render a single mesh with default lighting.
-- No file loading, no ECS setup required by the caller.
runSimple :: Text -> Mesh -> IO ()
runSimple title mesh = do
  logInfoIO LogGeneral "Initializing Haskan Engine (simple mode)"
  logInfoIO LogGeneral "Starting Engine main loop"
  Engine.mainLoop
    ""
    EngineConfig
      { targetRenderFPS = 120,
        targetPhysicsFPS = 60,
        targetNetworkFPS = 10,
        targetInputFPS = 60,
        title = title,
        debugSocketPath = Nothing,
        timeoutSeconds = Nothing,
        uvCheckMode = Nothing,
        envMapDir = "debug",
        lightCount = 1,
        initialTimeOfDay = 12.0,
        timeSpeed = 0.0,
        dayNightEnabled = False,
        cloudTestMode = False,
        proceduralSkyEnabled = False,
        simpleMesh = Just mesh
      }
  logInfoIO LogGeneral "Shutting down Haskan"
