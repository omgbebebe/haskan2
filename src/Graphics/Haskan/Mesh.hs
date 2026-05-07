module Graphics.Haskan.Mesh where

import Data.Word (Word32)
import Foreign.C qualified
import Graphics.Haskan.Face (Face (..))
import Graphics.Haskan.Vertex (Vertex (..))
import Linear (V2 (..), V3 (..))

data Mesh = Mesh
  { vertices :: [Vertex],
    indices :: [Word32]
  }
  deriving (Eq, Show)

-- | Create a large ground plane mesh in the XY plane (Z=0).
-- Size is the half-extent; total plane is from (-size,-size) to (size,size).
groundPlaneMesh :: Foreign.C.CFloat -> Mesh
groundPlaneMesh size =
  let s = size
      -- Four corners of the plane
      v0 = Vertex (V3 (-s) (-s) 0) (V2 0 0) (V3 0 0 1) (V3 1 1 1)
      v1 = Vertex (V3 s (-s) 0) (V2 50 0) (V3 0 0 1) (V3 1 1 1)
      v2 = Vertex (V3 s s 0) (V2 50 50) (V3 0 0 1) (V3 1 1 1)
      v3 = Vertex (V3 (-s) s 0) (V2 0 50) (V3 0 0 1) (V3 1 1 1)
   in Mesh
        { vertices = [v0, v1, v2, v3],
          indices = [0, 1, 2, 0, 2, 3]
        }

-- | Create a subdivided ground plane with checkerboard vertex colors.
-- subdivisions: number of quads along each axis (total quads = subdivisions^2)
-- size: half-extent of the plane
groundPlaneMeshGrid :: Int -> Foreign.C.CFloat -> Mesh
groundPlaneMeshGrid subdivisions size =
  let n = subdivisions
      s = size
      step = (2 * s) / fromIntegral n
      -- Generate vertices on a grid
      verts =
        [ let x = -s + fromIntegral i * step
              y = -s + fromIntegral j * step
              -- Checkerboard color
              isDark = (i + j) `mod` 2 == 0
              col = if isDark then V3 0.15 0.15 0.15 else V3 0.35 0.35 0.35
           in Vertex (V3 x y 0) (V2 (fromIntegral i) (fromIntegral j)) (V3 0 0 1) col
        | j <- [0 .. n]
        , i <- [0 .. n]
        ]
      -- Generate indices for quads (two triangles per quad)
      idxs =
        concat
          [ let base = j * (n + 1) + i
             in [ fromIntegral base
                , fromIntegral (base + 1)
                , fromIntegral (base + n + 2)
                , fromIntegral base
                , fromIntegral (base + n + 2)
                , fromIntegral (base + n + 1)
                ]
          | j <- [0 .. n - 1]
          , i <- [0 .. n - 1]
          ]
   in Mesh {vertices = verts, indices = idxs}
