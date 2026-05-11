module Graphics.Haskan.Mesh where

import Data.Word (Word32)
import Foreign.C qualified
import Graphics.Haskan.Face (Face (..))
import Graphics.Haskan.Vertex (Vertex (..))
import Linear (V2 (..), V3 (..), V4 (..), cross, normalize, (*^))

data Mesh = Mesh
  { vertices :: [Vertex],
    indices :: [Word32]
  }
  deriving (Eq, Show)

-- | Create a large ground plane mesh in the XZ plane (Y=0).
-- Size is the half-extent; total plane is from (-size,-size) to (size,size).
groundPlaneMesh :: Foreign.C.CFloat -> Mesh
groundPlaneMesh size =
  let s = size
      t = V4 1 0 0 1
      -- Four corners of the plane (XZ plane, normal +Y)
      v0 = Vertex (V3 (-s) 0 (-s)) (V2 0 0) (V3 0 1 0) t (V3 1 1 1)
      v1 = Vertex (V3 s 0 (-s)) (V2 50 0) (V3 0 1 0) t (V3 1 1 1)
      v2 = Vertex (V3 s 0 s) (V2 50 50) (V3 0 1 0) t (V3 1 1 1)
      v3 = Vertex (V3 (-s) 0 s) (V2 0 50) (V3 0 1 0) t (V3 1 1 1)
   in Mesh
        { vertices = [v0, v1, v2, v3],
          indices = [0, 1, 2, 0, 2, 3]
        }

-- | Create a unit cube centered at origin (side length = 1).
-- UVs follow Vulkan convention: (0,0) = top-left.
-- Each face maps the full texture with correct orientation when viewed from outside.
unitCube :: Mesh
unitCube =
  let s = 0.5
      -- Front face (z = s, normal +Z, tangent +X)
      -- When viewed from +Z: bottom-left -> bottom-right -> top-right -> top-left
      -- Vulkan V=0=top, V=1=bottom. Top of face (y=s) gets V=1, bottom (y=-s) gets V=0.
      vf0 = Vertex (V3 (-s) (-s) s) (V2 0 0) (V3 0 0 1) (V4 1 0 0 1) (V3 1 1 1)
      vf1 = Vertex (V3 s (-s) s) (V2 1 0) (V3 0 0 1) (V4 1 0 0 1) (V3 1 1 1)
      vf2 = Vertex (V3 s s s) (V2 1 1) (V3 0 0 1) (V4 1 0 0 1) (V3 1 1 1)
      vf3 = Vertex (V3 (-s) s s) (V2 0 1) (V3 0 0 1) (V4 1 0 0 1) (V3 1 1 1)
      -- Back face (z = -s, normal -Z, tangent -X)
      vb0 = Vertex (V3 s (-s) (-s)) (V2 0 0) (V3 0 0 (-1)) (V4 (-1) 0 0 1) (V3 1 1 1)
      vb1 = Vertex (V3 (-s) (-s) (-s)) (V2 1 0) (V3 0 0 (-1)) (V4 (-1) 0 0 1) (V3 1 1 1)
      vb2 = Vertex (V3 (-s) s (-s)) (V2 1 1) (V3 0 0 (-1)) (V4 (-1) 0 0 1) (V3 1 1 1)
      vb3 = Vertex (V3 s s (-s)) (V2 0 1) (V3 0 0 (-1)) (V4 (-1) 0 0 1) (V3 1 1 1)
      -- Right face (x = s, normal +X, tangent -Z)
      vr0 = Vertex (V3 s (-s) s) (V2 0 0) (V3 1 0 0) (V4 0 0 (-1) 1) (V3 1 1 1)
      vr1 = Vertex (V3 s (-s) (-s)) (V2 1 0) (V3 1 0 0) (V4 0 0 (-1) 1) (V3 1 1 1)
      vr2 = Vertex (V3 s s (-s)) (V2 1 1) (V3 1 0 0) (V4 0 0 (-1) 1) (V3 1 1 1)
      vr3 = Vertex (V3 s s s) (V2 0 1) (V3 1 0 0) (V4 0 0 (-1) 1) (V3 1 1 1)
      -- Left face (x = -s, normal -X, tangent +Z)
      vl0 = Vertex (V3 (-s) (-s) (-s)) (V2 0 0) (V3 (-1) 0 0) (V4 0 0 1 1) (V3 1 1 1)
      vl1 = Vertex (V3 (-s) (-s) s) (V2 1 0) (V3 (-1) 0 0) (V4 0 0 1 1) (V3 1 1 1)
      vl2 = Vertex (V3 (-s) s s) (V2 1 1) (V3 (-1) 0 0) (V4 0 0 1 1) (V3 1 1 1)
      vl3 = Vertex (V3 (-s) s (-s)) (V2 0 1) (V3 (-1) 0 0) (V4 0 0 1 1) (V3 1 1 1)
      -- Top face (y = s, normal +Y, tangent +X)
      -- When viewed from +Y: top-left -> top-right -> bottom-right -> bottom-left
      vt0 = Vertex (V3 (-s) s (-s)) (V2 0 1) (V3 0 1 0) (V4 1 0 0 1) (V3 1 1 1)
      vt1 = Vertex (V3 s s (-s)) (V2 1 1) (V3 0 1 0) (V4 1 0 0 1) (V3 1 1 1)
      vt2 = Vertex (V3 s s s) (V2 1 0) (V3 0 1 0) (V4 1 0 0 1) (V3 1 1 1)
      vt3 = Vertex (V3 (-s) s s) (V2 0 0) (V3 0 1 0) (V4 1 0 0 1) (V3 1 1 1)
      -- Bottom face (y = -s, normal -Y, tangent +X)
      vbot0 = Vertex (V3 (-s) (-s) (-s)) (V2 0 0) (V3 0 (-1) 0) (V4 1 0 0 1) (V3 1 1 1)
      vbot1 = Vertex (V3 s (-s) (-s)) (V2 1 0) (V3 0 (-1) 0) (V4 1 0 0 1) (V3 1 1 1)
      vbot2 = Vertex (V3 s (-s) s) (V2 1 1) (V3 0 (-1) 0) (V4 1 0 0 1) (V3 1 1 1)
      vbot3 = Vertex (V3 (-s) (-s) s) (V2 0 1) (V3 0 (-1) 0) (V4 1 0 0 1) (V3 1 1 1)
      verts = [vf0, vf1, vf2, vf3, vb0, vb1, vb2, vb3, vr0, vr1, vr2, vr3, vl0, vl1, vl2, vl3, vt0, vt1, vt2, vt3, vbot0, vbot1, vbot2, vbot3]
      idxs =
        [ -- Front
          0, 2, 1, 0, 3, 2,
          -- Back
          4, 6, 5, 4, 7, 6,
          -- Right
          8, 10, 9, 8, 11, 10,
          -- Left
          12, 13, 14, 12, 14, 15,
          -- Top
          16, 17, 18, 16, 18, 19,
          -- Bottom
          20, 22, 21, 20, 23, 22
        ]
   in Mesh {vertices = verts, indices = idxs}

-- | Create a UV-mapped sphere centered at origin.
-- latSegments: number of latitude segments (excluding poles)
-- lonSegments: number of longitude segments
-- radius: sphere radius
uvSphere :: Int -> Int -> Foreign.C.CFloat -> Mesh
uvSphere latSegments lonSegments radius =
  let r = radius
      latCount = latSegments
      lonCount = lonSegments
      -- Helper to compute vertex at given lat/lon index
      mkVert latIdx lonIdx =
        let theta = pi * fromIntegral latIdx / fromIntegral latCount
            phi = 2 * pi * fromIntegral lonIdx / fromIntegral lonCount
            x = realToFrac (r * sin theta * cos phi) :: Foreign.C.CFloat
            y = realToFrac (r * cos theta) :: Foreign.C.CFloat
            z = realToFrac (r * sin theta * sin phi) :: Foreign.C.CFloat
            nx = realToFrac (sin theta * cos phi) :: Foreign.C.CFloat
            ny = realToFrac (cos theta) :: Foreign.C.CFloat
            nz = realToFrac (sin theta * sin phi) :: Foreign.C.CFloat
            u = realToFrac (fromIntegral lonIdx / fromIntegral lonCount) :: Foreign.C.CFloat
            v = realToFrac (fromIntegral latIdx / fromIntegral latCount) :: Foreign.C.CFloat
            tx = realToFrac (-sin phi) :: Foreign.C.CFloat
            ty = realToFrac (0 :: Float) :: Foreign.C.CFloat
            tz = realToFrac (cos phi) :: Foreign.C.CFloat
        in Vertex (V3 x y z) (V2 u v) (V3 nx ny nz) (V4 tx ty tz 1) (V3 1 1 1)
      -- Generate vertices: latCount+1 rows, lonCount+1 columns
      verts = [mkVert latIdx lonIdx | latIdx <- [0..latCount], lonIdx <- [0..lonCount]]
      -- Generate indices for quads (two triangles per quad)
      idxs = concat
         [ let base = latIdx * (lonCount + 1) + lonIdx
               nextBase = (latIdx + 1) * (lonCount + 1) + lonIdx
            in [ fromIntegral base
               , fromIntegral nextBase
               , fromIntegral (nextBase + 1)
               , fromIntegral base
               , fromIntegral (nextBase + 1)
               , fromIntegral (base + 1)
               ]
        | latIdx <- [0..latCount-1]
        , lonIdx <- [0..lonCount-1]
        ]
  in Mesh {vertices = verts, indices = idxs}

-- | Create a UV-mapped plane in the XZ plane (Y=0) with UVs 0..1.
-- size: half-extent
uvPlane :: Foreign.C.CFloat -> Mesh
uvPlane size =
  let s = size
      t = V4 1 0 0 1
      v0 = Vertex (V3 (-s) 0 (-s)) (V2 0 0) (V3 0 1 0) t (V3 1 1 1)
      v1 = Vertex (V3 s 0 (-s)) (V2 1 0) (V3 0 1 0) t (V3 1 1 1)
      v2 = Vertex (V3 s 0 s) (V2 1 1) (V3 0 1 0) t (V3 1 1 1)
      v3 = Vertex (V3 (-s) 0 s) (V2 0 1) (V3 0 1 0) t (V3 1 1 1)
   in Mesh
        { vertices = [v0, v1, v2, v3],
          indices = [0, 1, 2, 0, 2, 3]
        }
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

-- | Create a single axis arrow mesh.
-- Takes the axis direction, color, and returns a thin box mesh.
axisArrow :: V3 Foreign.C.CFloat -> V3 Foreign.C.CFloat -> Mesh
axisArrow axisDir color =
  let t = V4 1 0 0 1
      r = 0.02 :: Foreign.C.CFloat
      V3 ax ay az = axisDir
      -- Create basis vectors perpendicular to axis
      perp1 = if abs az < 0.9 then normalize (cross axisDir (V3 0 0 1)) else normalize (cross axisDir (V3 0 1 0))
      perp2 = cross axisDir perp1
      -- Box vertices
      v0 = Vertex (V3 0 0 0 + (-r) *^ perp1 + (-r) *^ perp2) (V2 0 0) axisDir t color
      v1 = Vertex (V3 0 0 0 + (-r) *^ perp1 + r *^ perp2) (V2 0 0) axisDir t color
      v2 = Vertex (V3 0 0 0 + r *^ perp1 + r *^ perp2) (V2 0 0) axisDir t color
      v3 = Vertex (V3 0 0 0 + r *^ perp1 + (-r) *^ perp2) (V2 0 0) axisDir t color
      v4 = Vertex (axisDir + (-r) *^ perp1 + (-r) *^ perp2) (V2 0 0) axisDir t color
      v5 = Vertex (axisDir + (-r) *^ perp1 + r *^ perp2) (V2 0 0) axisDir t color
      v6 = Vertex (axisDir + r *^ perp1 + r *^ perp2) (V2 0 0) axisDir t color
      v7 = Vertex (axisDir + r *^ perp1 + (-r) *^ perp2) (V2 0 0) axisDir t color
      verts = [v0,v1,v2,v3,v4,v5,v6,v7]
      idxs = [ 0,2,1,0,3,2
             , 4,5,6,4,6,7
             , 0,1,5,0,5,4
             , 2,3,7,2,7,6
             , 0,4,7,0,7,3
             , 1,2,6,1,6,5 ]
  in Mesh {vertices = verts, indices = idxs}

-- | Create a unit-length axis arrow mesh.
-- X arrow is red, Y arrow is green, Z arrow is blue.
axisArrows :: Mesh
axisArrows =
  let xArrow = axisArrow (V3 1 0 0) (V3 1 0 0)
      yArrow = axisArrow (V3 0 1 0) (V3 0 1 0)
      zArrow = axisArrow (V3 0 0 1) (V3 0 0 1)
      -- Combine all vertices with offset indices
      xVerts = vertices xArrow
      yVerts = vertices yArrow
      zVerts = vertices zArrow
      xIdxs = indices xArrow
      yIdxs = map (+8) (indices yArrow)
      zIdxs = map (+16) (indices zArrow)
  in Mesh { vertices = xVerts ++ yVerts ++ zVerts
          , indices = xIdxs ++ yIdxs ++ zIdxs }
