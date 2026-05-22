module Main where

import Graphics.Haskan.Engine.Render.Internal.Setup (compileAllShaders)
import Graphics.Haskan qualified as Haskan
import Graphics.Haskan.Logger
  ( LogBackend
  , LogLevel (..)
  , stdoutBackend
  , fileBackend
  , setGlobalBackends
  )
import Options.Applicative
import System.Exit (die)
import Data.Text (Text)
import Data.Text qualified as Text

data CliOpts = CliOpts
  { optModelName :: !String
  , optTimeout :: !(Maybe Integer)
  , optTitle :: !Text
  , optDebugSocket :: !(Maybe FilePath)
  , optLogFile :: !(Maybe FilePath)
  , optUVCheckCube :: !Bool
  , optUVCheckSphere :: !Bool
  , optUVCheckPlane :: !Bool
  , optEnvDir :: !String
  , optLights :: !Int
  , optTimeOfDay :: !Float
  , optTimeSpeed :: !Float
  , optDayNight :: !Bool
  , optCloudTest :: !Bool
  , optCompileShaders :: !Bool
  , optWeatherMap :: !(Maybe FilePath)
  , optProceduralSky :: !Bool
  }

cliParser :: Parser CliOpts
cliParser =
  CliOpts
    <$> argument str
      ( metavar "MODEL"
     <> help "Model file name (e.g. unit_cube.obj)"
     <> value ""
      )
    <*> optional (option auto
      ( long "timeout"
     <> short 't'
     <> metavar "SECONDS"
     <> help "Exit after N seconds"
      ))
    <*> (Text.pack <$> strOption
      ( long "title"
     <> short 'T'
     <> metavar "TITLE"
     <> value "Haskan Demo"
     <> showDefault
     <> help "Window title"
      ))
    <*> optional (strOption
      ( long "debug-socket"
     <> metavar "PATH"
     <> help "Unix socket path for debug server"
      ))
    <*> optional (strOption
      ( long "log-file"
     <> metavar "PATH"
     <> help "Write logs to file in addition to stdout"
      ))
    <*> switch
      ( long "uv-check-cube"
     <> help "Render UV-checker cube"
      )
    <*> switch
      ( long "uv-check-sphere"
     <> help "Render UV-checker sphere"
      )
    <*> switch
      ( long "uv-check-plane"
     <> help "Render UV-checker plane"
      )
    <*> strOption
      ( long "env-dir"
     <> metavar "NAME"
     <> value "debug"
     <> showDefault
     <> help "Environment cubemap directory name (in data/textures/cubemaps/)"
       )
    <*> option auto
      ( long "lights"
     <> metavar "N"
     <> value 3
     <> showDefault
     <> help "Number of random lights to spawn"
       )
    <*> option auto
      ( long "time"
     <> metavar "HOURS"
     <> value 12.0
     <> showDefault
     <> help "Initial time of day (0-24 hours)"
       )
    <*> option auto
      ( long "time-speed"
     <> metavar "FACTOR"
     <> value 1.0
     <> showDefault
     <> help "Time speed multiplier (0=paused, 1=real-time, 3600=1hr/sec)"
       )
    <*> switch
      ( long "day-night"
     <> help "Enable day/night cycle"
        )
    <*> switch
      ( long "cloud-test"
     <> help "Cloud test mode: fly camera, single sun, day-night enabled"
         )
    <*> switch
      ( long "compile-shaders"
     <> help "Compile FIR shaders to SPIR-V and exit"
          )
    <*> optional (strOption
      ( long "weather-map"
     <> metavar "PATH"
     <> help "Path to weather map texture (default: data/textures/weather/weather_map.raw)"
      ))
    <*> switch
      ( long "procedural-sky"
     <> help "Use procedural sky instead of cubemap for background"
      )

opts :: ParserInfo CliOpts
opts = info (cliParser <**> helper)
  ( fullDesc
 <> progDesc "Haskan2 Vulkan rendering engine"
 <> header "haskan2 - a Haskell Vulkan engine"
  )

main :: IO ()
main = do
  cli <- execParser opts
  fileBackendMb <- case optLogFile cli of
    Just path -> Just <$> fileBackend Info path
    Nothing   -> pure Nothing
  let backends :: [LogBackend]
      backends = stdoutBackend Info : maybe [] pure fileBackendMb
  setGlobalBackends backends
  if optCompileShaders cli
    then do
      putStrLn "Compiling FIR shaders to SPIR-V..."
      compileAllShaders
      putStrLn "Done."
    else do
      putStrLn ("Loading model: " ++ optModelName cli)
      Haskan.runHaskan
        Haskan.RunOptions
          { Haskan.roTitle = optTitle cli,
            Haskan.roMeshName = optModelName cli,
            Haskan.roTimeout = optTimeout cli,
            Haskan.roDebugSocket = optDebugSocket cli,
            Haskan.roUVCheckCube = optUVCheckCube cli,
            Haskan.roUVCheckSphere = optUVCheckSphere cli,
            Haskan.roUVCheckPlane = optUVCheckPlane cli,
            Haskan.roEnvDir = optEnvDir cli,
            Haskan.roNumLights = optLights cli,
            Haskan.roInitialTime = optTimeOfDay cli,
            Haskan.roTimeSpeed = optTimeSpeed cli,
            Haskan.roDayNight = optDayNight cli,
            Haskan.roCloudTest = optCloudTest cli,
            Haskan.roProceduralSky = optProceduralSky cli
          }
