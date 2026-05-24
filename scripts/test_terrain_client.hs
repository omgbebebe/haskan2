#!/usr/bin/env runhaskell
{-# LANGUAGE BlockArguments #-}

-- | Quick test script for terrain tile fetching.
-- Run this to verify your terrain generator API is responding.
module Main where

import Control.Monad (forM_)
import Graphics.Haskan.Terrain.Client (defaultTerrainHost, fetchTerrainTile)
import System.Environment (getArgs)

main :: IO ()
main = do
  args <- getArgs
  let host = case args of
        (h : _) -> h
        [] -> defaultTerrainHost

  putStrLn $ "Testing terrain API at: " ++ host
  putStrLn "Fetching tile (-25, -135) with seed 17791103700256013888..."

  result <- fetchTerrainTile host (-25) (-135) 1024 0 1792 17791103700256013888 "relief"

  case result of
    Left err -> do
      putStrLn $ "FAILED: " ++ show err
    Right tile -> do
      putStrLn $ "SUCCESS: " ++ show (ttWidth tile) ++ "x" ++ show (ttHeight tile) ++ " tile"
      putStrLn $ "Pixel count: " ++ show (ttWidth tile * ttHeight tile * 4)
