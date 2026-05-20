module Main where

import Graphics.Haskan.Mesh (Mesh (..))
import Graphics.Haskan.Vertex (Vertex (..))
import Linear (V2 (..), V3 (..), V4 (..))
import qualified Graphics.Haskan as Haskan

-- | Example 1: Colored Triangle
--
-- This example demonstrates the minimal setup to render a single triangle
-- using Haskan2 as a library. The triangle has three vertices colored
-- red, green, and blue, producing a smooth gradient across the face.
--
-- The mesh is defined entirely on the user side and passed to 'runSimple'.
-- No engine patching, no file loading, no ECS setup required.
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

  let triangle :: Mesh
      triangle =
        let n = V3 0 0 1
            t = V4 1 0 0 1
            v0 = Vertex (V3 0 1 0) (V2 0.5 1.0) n t (V3 1 0 0)
            v1 = Vertex (V3 (-0.866) (-0.5) 0) (V2 0 0) n t (V3 0 1 0)
            v2 = Vertex (V3 0.866 (-0.5) 0) (V2 1 0) n t (V3 0 0 1)
         in Mesh
              { vertices = [v0, v1, v2],
                indices = [0, 1, 2]
              }

  Haskan.runSimple
    "Haskan2 Example 1 - Colored Triangle"
    triangle
