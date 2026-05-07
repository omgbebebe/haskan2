module Graphics.Haskan (runHaskan) where

import Data.Text (Text)
import Graphics.Haskan.Engine (EngineConfig (..))
import Graphics.Haskan.Engine qualified as Engine
import Graphics.Haskan.Logger (logI)

data QueueFamily
  = Graphics
  | Compute
  | Transfer
  | Sparse

runHaskan :: Text -> String -> IO ()
runHaskan title meshName = do
  logI "Initializing Haskan Engine"
  logI "Starting Engine main loop"
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
  logI "Shutting down Haskan"
