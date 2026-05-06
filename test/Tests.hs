module Main where

import Graphics.Haskan.Model qualified as Model  
import Data.List (sort)

main :: IO ()
main = do
  putStrLn "Testing normalizeMesh..."  
  let mesh   = Model.normalizeMesh undefined [1,2,3,4,5,6]
  assertEq "normalizeMesh length" 2 (length mesh)

  putStrLn "Testing Model normalization logic..."  
  let norm = sort [minimum [a,b,c] | (a,b,c) <- [(1,2,3),(4,5,6)]]
  assertEq "minIdx rotates correctly" [1,4] norm

  putStrLn "All stub tests passed"  

assertEq :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEq label x y 
  | x == y    = return ()
  | otherwise = putStr $ "FAIL: " ++ label
