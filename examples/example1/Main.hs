module Main where

import Graphics.Haskan qualified as Haskan

-- | Example 1: Colored Triangle
--
-- This example demonstrates the minimal setup to render a single triangle
-- using Haskan2 as a library. The triangle has three vertices colored
-- red, green, and blue, producing a smooth gradient across the face.
--
-- To run:
--   cabal run example1
--
main :: IO ()
main = do
  putStrLn "Haskan2 Example 1: Colored Triangle"
  putStrLn "  Vertex 0 (top):         Red   (1.0, 0.0, 0.0)"
  putStrLn "  Vertex 1 (bottom-left):  Green (0.0, 1.0, 0.0)"
  putStrLn "  Vertex 2 (bottom-right): Blue  (0.0, 0.0, 1.0)"
  putStrLn ""
  putStrLn "Controls:"
  putStrLn "  Left drag   - orbit camera"
  putStrLn "  Right drag  - pan camera"
  putStrLn "  Scroll      - zoom in/out"
  putStrLn "  Escape      - exit"
  putStrLn ""

  -- Use runHaskan with uvCheckTriangle=True to render the built-in
  -- colored triangle mesh. We disable most features for clarity.
  Haskan.runHaskan
    "Haskan2 Example 1 - Colored Triangle" -- window title
    ""                                      -- no external mesh file
    Nothing                                 -- no timeout
    Nothing                                 -- no debug socket
    False                                   -- uvCheckCube
    False                                   -- uvCheckSphere
    False                                   -- uvCheckPlane
    True                                    -- uvCheckTriangle
    "debug"                                 -- envMapDir (minimal cubemap)
    1                                       -- 1 light
    12.0                                    -- noon time of day
    0.0                                     -- time paused
    False                                   -- no day/night cycle
    False                                   -- not cloud test mode
    False                                   -- no procedural sky
