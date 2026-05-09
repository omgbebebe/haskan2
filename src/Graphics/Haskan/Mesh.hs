module Graphics.Haskan.Mesh where

import Data.Word (Word32)
import Foreign.C qualified
import Graphics.Haskan.Face (Face (..))
import Graphics.Haskan.Vertex (Vertex (..))
import Linear (V2 (..), V3 (..), V4 (..))

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
      t = V4 1 0 0 1
      -- Four corners of the plane
      v0 = Vertex (V3 (-s) (-s) 0) (V2 0 0) (V3 0 0 1) t (V3 1 1 1)
      v1 = Vertex (V3 s (-s) 0) (V2 50 0) (V3 0 0 1) t (V3 1 1 1)
      v2 = Vertex (V3 s s 0) (V2 50 50) (V3 0 0 1) t (V3 1 1 1)
      v3 = Vertex (V3 (-s) s 0) (V2 0 50) (V3 0 0 1) t (V3 1 1 1)
   in Mesh
        { vertices = [v0, v1, v2, v3],
          indices = [0, 1, 2, 0, 2, 3]
        }

-- | Create a unit cube centered at origin (side length = 1).
unitCube :: Mesh
unitCube =
  let s = 0.5
      tX = V4 1 0 0 1
      tZ = V4 0 0 1 1
      -- Front face (z = s, normal +Z, tangent +X)
      vf0 = Vertex (V3 (-s) (-s) s) (V2 0 0) (V3 0 0 1) tX (V3 1 1 1)
      vf1 = Vertex (V3 s (-s) s) (V2 1 0) (V3 0 0 1) tX (V3 1 1 1)
      vf2 = Vertex (V3 s s s) (V2 1 1) (V3 0 0 1) tX (V3 1 1 1)
      vf3 = Vertex (V3 (-s) s s) (V2 0 1) (V3 0 0 1) tX (V3 1 1 1)
      -- Back face (z = -s, normal -Z, tangent +X)
      vb0 = Vertex (V3 (-s) (-s) (-s)) (V2 1 0) (V3 0 0 (-1)) tX (V3 1 1 1)
      vb1 = Vertex (V3 s (-s) (-s)) (V2 0 0) (V3 0 0 (-1)) tX (V3 1 1 1)
      vb2 = Vertex (V3 s s (-s)) (V2 0 1) (V3 0 0 (-1)) tX (V3 1 1 1)
      vb3 = Vertex (V3 (-s) s (-s)) (V2 1 1) (V3 0 0 (-1)) tX (V3 1 1 1)
      -- Right face (x = s, normal +X, tangent +Z)
      vr0 = Vertex (V3 s (-s) (-s)) (V2 0 0) (V3 1 0 0) tZ (V3 1 1 1)
      vr1 = Vertex (V3 s (-s) s) (V2 1 0) (V3 1 0 0) tZ (V3 1 1 1)
      vr2 = Vertex (V3 s s s) (V2 1 1) (V3 1 0 0) tZ (V3 1 1 1)
      vr3 = Vertex (V3 s s (-s)) (V2 0 1) (V3 1 0 0) tZ (V3 1 1 1)
      -- Left face (x = -s, normal -X, tangent +Z)
      vl0 = Vertex (V3 (-s) (-s) s) (V2 0 0) (V3 (-1) 0 0) tZ (V3 1 1 1)
      vl1 = Vertex (V3 (-s) (-s) (-s)) (V2 1 0) (V3 (-1) 0 0) tZ (V3 1 1 1)
      vl2 = Vertex (V3 (-s) s (-s)) (V2 1 1) (V3 (-1) 0 0) tZ (V3 1 1 1)
      vl3 = Vertex (V3 (-s) s s) (V2 0 1) (V3 (-1) 0 0) tZ (V3 1 1 1)
      -- Top face (y = s, normal +Y, tangent +X)
      vt0 = Vertex (V3 (-s) s (-s)) (V2 0 0) (V3 0 1 0) tX (V3 1 1 1)
      vt1 = Vertex (V3 s s (-s)) (V2 1 0) (V3 0 1 0) tX (V3 1 1 1)
      vt2 = Vertex (V3 s s s) (V2 1 1) (V3 0 1 0) tX (V3 1 1 1)
      vt3 = Vertex (V3 (-s) s s) (V2 0 1) (V3 0 1 0) tX (V3 1 1 1)
      -- Bottom face (y = -s, normal -Y, tangent +X)
      vbot0 = Vertex (V3 (-s) (-s) s) (V2 0 0) (V3 0 (-1) 0) tX (V3 1 1 1)
      vbot1 = Vertex (V3 s (-s) s) (V2 1 0) (V3 0 (-1) 0) tX (V3 1 1 1)
      vbot2 = Vertex (V3 s (-s) (-s)) (V2 1 1) (V3 0 (-1) 0) tX (V3 1 1 1)
      vbot3 = Vertex (V3 (-s) (-s) (-s)) (V2 0 1) (V3 0 (-1) 0) tX (V3 1 1 1)
      verts = [vf0, vf1, vf2, vf3, vb0, vb1, vb2, vb3, vr0, vr1, vr2, vr3, vl0, vl1, vl2, vl3, vt0, vt1, vt2, vt3, vbot0, vbot1, vbot2, vbot3]
      idxs =
        [ -- Front
          0, 1, 2, 0, 2, 3,
          -- Back
          4, 6, 5, 4, 7, 6,
          -- Right
          8, 9, 10, 8, 10, 11,
          -- Left
          12, 13, 14, 12, 14, 15,
          -- Top
          16, 17, 18, 16, 18, 19,
          -- Bottom
          20, 21, 22, 20, 22, 23
        ]
   in Mesh {vertices = verts, indices = idxs}

-- subdivisions: number of quads along each axis (total quads = subdivisions^2)
-- size: half-extent of the plane
groundPlaneMeshGrid :: Int -> Foreign.C.CFloat -> Mesh
groundPlaneMeshGrid subdivisions size =
  let n = subdivisions
      s = size
      step = (2 * s) / fromIntegral n
      t = V4 1 0 0 1
      -- Generate vertices on a grid
      verts =
        [ let x = -s + fromIntegral i * step
              y = -s + fromIntegral j * step
              -- Checkerboard color
              isDark = (i + j) `mod` 2 == 0
              col = if isDark then V3 0.15 0.15 0.15 else V3 0.35 0.35 0.35
           in Vertex (V3 x y 0) (V2 (fromIntegral i) (fromIntegral j)) (V3 0 0 1) t col
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
