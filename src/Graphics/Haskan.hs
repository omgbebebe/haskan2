{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan (RunOptions (..), runHaskan, runSimple) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Graphics.Haskan.Engine (EngineConfig (..), UVCheckMode (..))
import Graphics.Haskan.Engine qualified as Engine
import Graphics.Haskan.Logger (LogCategory (..), logInfoIO)
import Graphics.Haskan.Mesh (Mesh)
import Graphics.Haskan.Render.RenderSystem (DrawCall (..))

-- | All runtime options for the full Haskan engine.
data RunOptions = RunOptions
  { roTitle :: !Text,
    roMeshName :: !String,
    roTimeout :: !(Maybe Integer),
    roDebugSocket :: !(Maybe FilePath),
    roUVCheckCube :: !Bool,
    roUVCheckSphere :: !Bool,
    roUVCheckPlane :: !Bool,
    roEnvDir :: !String,
    roNumLights :: !Int,
    roInitialTime :: !Float,
    roTimeSpeed :: !Float,
    roDayNight :: !Bool,
    roCloudTest :: !Bool,
    roProceduralSky :: !Bool
  }

runHaskan :: RunOptions -> IO ()
runHaskan RunOptions {..} = do
  logInfoIO LogGeneral "Initializing Haskan Engine"
  logInfoIO LogGeneral "Starting Engine main loop"
  Engine.mainLoop
    roMeshName
    EngineConfig
      { targetRenderFPS = 120,
        targetPhysicsFPS = 60,
        targetNetworkFPS = 10,
        targetInputFPS = 60,
        title = roTitle,
        debugSocketPath = roDebugSocket,
        timeoutSeconds = roTimeout,
        uvCheckMode =
          if roUVCheckCube
            then Just UVCheckCube
            else
              if roUVCheckSphere
                then Just UVCheckSphere
                else
                  if roUVCheckPlane
                    then Just UVCheckPlane
                    else Nothing,
        envMapDir = roEnvDir,
        lightCount = roNumLights,
        initialTimeOfDay = roInitialTime,
        timeSpeed = roTimeSpeed,
        dayNightEnabled = roDayNight,
        cloudTestMode = roCloudTest,
        proceduralSkyEnabled = roProceduralSky,
        meshTerrainEnabled = True,
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
        meshTerrainEnabled = False,
        simpleMesh = Just mesh
      }
  logInfoIO LogGeneral "Shutting down Haskan"
