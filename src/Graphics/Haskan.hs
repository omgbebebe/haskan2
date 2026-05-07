module Graphics.Haskan (runHaskan) where

import Data.List (isPrefixOf)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Graphics.Haskan.Engine (EngineConfig (..))
import Graphics.Haskan.Engine qualified as Engine
import Graphics.Haskan.Logger (logInfo, LogCategory(..))
import Text.Read (readMaybe)

data QueueFamily
  = Graphics
  | Compute
  | Transfer
  | Sparse

parseTimeout :: [String] -> Maybe Integer
parseTimeout args =
  case filter ("--timeout=" `isPrefixOf`) args of
    (arg : _) -> readMaybe (drop (length ("--timeout=" :: String)) arg)
    [] ->
      case break (== "--timeout") args of
        (_, _ : val : _) -> readMaybe val
        _ -> Nothing

runHaskan :: Text -> String -> [String] -> IO ()
runHaskan title meshName extraArgs = do
  logInfo LogGeneral "Initializing Haskan Engine"
  logInfo LogGeneral "Starting Engine main loop"
  let timeout = parseTimeout extraArgs
  Engine.mainLoop
    meshName
    EngineConfig
      { targetRenderFPS = 120,
        targetPhysicsFPS = 10,
        targetNetworkFPS = 10,
        targetInputFPS = 60,
        title = title,
        debugSocketPath = Just "/tmp/haskan2.sock",
        timeoutSeconds = timeout
      }
  logInfo LogGeneral "Shutting down Haskan"
