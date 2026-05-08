module Graphics.Haskan (runHaskan) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Graphics.Haskan.Engine (EngineConfig (..))
import Graphics.Haskan.Engine qualified as Engine
import Graphics.Haskan.Logger (logInfoIO, LogCategory(..))

runHaskan :: Text -> String -> Maybe Integer -> Maybe FilePath -> IO ()
runHaskan title meshName mTimeout mDebugSocket = do
  logInfoIO LogGeneral "Initializing Haskan Engine"
  logInfoIO LogGeneral "Starting Engine main loop"
  Engine.mainLoop
    meshName
    EngineConfig
      { targetRenderFPS = 120,
        targetPhysicsFPS = 10,
        targetNetworkFPS = 10,
        targetInputFPS = 60,
        title = title,
        debugSocketPath = mDebugSocket,
        timeoutSeconds = mTimeout
      }
  logInfoIO LogGeneral "Shutting down Haskan"
