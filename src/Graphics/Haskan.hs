module Graphics.Haskan (runHaskan) where

import Data.Text (Text)
import Graphics.Haskan.Engine (EngineConfig (..))
import Graphics.Haskan.Engine qualified as Engine
import Graphics.Haskan.Logger (logInfo, LogCategory(..))

data QueueFamily
  = Graphics
  | Compute
  | Transfer
  | Sparse

runHaskan :: Text -> String -> IO ()
runHaskan title meshName = do
  logInfo LogGeneral "Initializing Haskan Engine"
  logInfo LogGeneral "Starting Engine main loop"
  Engine.mainLoop
    meshName
    EngineConfig
      { targetRenderFPS = 120,
        targetPhysicsFPS = 10,
        targetNetworkFPS = 10,
        targetInputFPS = 60,
        title = title,
        debugSocketPath = Just "/tmp/haskan2.sock"
      }
  logInfo LogGeneral "Shutting down Haskan"
