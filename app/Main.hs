module Main where

import Graphics.Haskan qualified as Haskan
import System.Environment (getArgs)

main :: IO ()
main = do
  modelName <- head <$> getArgs
  print ("Loading model: " <> modelName)
  Haskan.runHaskan "Haskan Demo" modelName
