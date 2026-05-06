module Main where

import Graphics.Haskan qualified as Haskan
import System.Environment (getArgs)
import System.Exit (die)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [] -> die "Usage: haskan2 <model-name>"
    (modelName : _) -> do
      putStrLn ("Loading model: " ++ modelName)
      Haskan.runHaskan "Haskan Demo" modelName
