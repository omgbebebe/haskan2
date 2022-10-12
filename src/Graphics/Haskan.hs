module Graphics.Haskan (runHaskan) where

-- text
import Data.Text (Text)

-- haskan
import Graphics.Haskan.Engine (EngineConfig(..))
import qualified Graphics.Haskan.Engine as Engine
import Graphics.Haskan.Logger (logI)

data QueueFamily
  = Graphics
  | Compute
  | Transfer
  | Sparse

--init :: MonadIO m => Text -> m ()
runHaskan :: Text -> String -> IO ()
runHaskan title meshName = do
  logI "Initializing Haskan Engine"
  logI "Starting Engine main loop"
  Engine.mainLoop meshName
    EngineConfig{ targetRenderFPS = 120
                , targetPhysicsFPS = 10
                , targetNetworkFPS = 10
                , targetInputFPS = 60
                , title = title
                }
  logI "Shutting down Haskan"
