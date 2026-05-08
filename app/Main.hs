module Main where

import Graphics.Haskan qualified as Haskan
import Graphics.Haskan.Logger (setLogFile)
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
  }

cliParser :: Parser CliOpts
cliParser =
  CliOpts
    <$> argument str
      ( metavar "MODEL"
     <> help "Model file name (e.g. unit_cube.obj)"
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
     <> help "Write logs to file instead of stdout"
      ))

opts :: ParserInfo CliOpts
opts = info (cliParser <**> helper)
  ( fullDesc
 <> progDesc "Haskan2 Vulkan rendering engine"
 <> header "haskan2 - a Haskell Vulkan engine"
  )

main :: IO ()
main = do
  cli <- execParser opts
  case optLogFile cli of
    Just path -> setLogFile path
    Nothing   -> pure ()
  putStrLn ("Loading model: " ++ optModelName cli)
  Haskan.runHaskan
    (optTitle cli)
    (optModelName cli)
    (optTimeout cli)
    (optDebugSocket cli)
