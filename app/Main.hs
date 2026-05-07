module Main where

import Data.List (isPrefixOf)
import Graphics.Haskan qualified as Haskan
import System.Environment (getArgs)
import System.Exit (die)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [] -> die "Usage: haskan2 [<options>] <model-name>\nOptions:\n  --timeout=N    Exit after N seconds"
    (modelName : extraArgs) | not (isOption modelName) -> do
      putStrLn ("Loading model: " ++ modelName)
      Haskan.runHaskan "Haskan Demo" modelName extraArgs
    args' -> do
      -- Try to find model name among args
      case dropWhile isOption args' of
        [] -> die "Usage: haskan2 [<options>] <model-name>\nOptions:\n  --timeout=N    Exit after N seconds"
        (modelName : extraArgs) -> do
          putStrLn ("Loading model: " ++ modelName)
          Haskan.runHaskan "Haskan Demo" modelName (filter (/= modelName) args')
  where
    isOption s = "--" `isPrefixOf` s
