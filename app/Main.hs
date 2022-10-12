module Main where

import System.Environment (getArgs)
import qualified Graphics.Haskan as Haskan

main :: IO ()
main = do
  modelName <- head <$> getArgs
  print ("Loading model: " <> modelName)
  Haskan.runHaskan "Haskan Demo" modelName
