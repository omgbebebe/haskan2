{-# LANGUAGE BlockArguments #-}

module Graphics.Haskan.Utils.TangentSpace
  ( computeTangents,
  )
where

import Data.List (foldl')
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Vector (Vector, (!))
import Data.Vector qualified as Vector
import Data.Word (Word32)
import Linear (V2 (..), V3 (..), V4 (..), cross, dot, normalize, (^*), (^+^), (^-^))
import Linear.Vector (zero)

-- | Compute per-vertex tangents (V4 with handedness in W) from positions, normals, UVs, and indices.
-- Uses Vector for O(1) indexing instead of list !! which is O(n).
computeTangents ::
  -- | positions
  Vector (V3 Float) ->
  -- | normals
  Vector (V3 Float) ->
  -- | UVs
  Vector (V2 Float) ->
  -- | indices (triangles)
  Vector Word32 ->
  -- | tangents (xyz = direction, w = handedness)
  Vector (V4 Float)
computeTangents positions normals uvs indices =
  let n = Vector.length positions
      -- Initialize empty tangent/bitangent accumulators
      emptyAcc = Map.fromList [(i, (zero, zero)) | i <- [0 .. n - 1]]

      -- Process each triangle
      processTriangle acc (i0, i1, i2) =
        let p0 = positions ! fromIntegral i0
            p1 = positions ! fromIntegral i1
            p2 = positions ! fromIntegral i2
            uv0 = uvs ! fromIntegral i0
            uv1 = uvs ! fromIntegral i1
            uv2 = uvs ! fromIntegral i2

            V3 p0x p0y p0z = p0
            V3 p1x p1y p1z = p1
            V3 p2x p2y p2z = p2
            V2 uv0x uv0y = uv0
            V2 uv1x uv1y = uv1
            V2 uv2x uv2y = uv2

            edge1x = p1x - p0x
            edge1y = p1y - p0y
            edge1z = p1z - p0z
            edge2x = p2x - p0x
            edge2y = p2y - p0y
            edge2z = p2z - p0z

            du1 = uv1x - uv0x
            dv1 = uv1y - uv0y
            du2 = uv2x - uv0x
            dv2 = uv2y - uv0y

            det = du1 * dv2 - du2 * dv1

            -- Avoid division by zero
            (tan, bitan) =
              if abs det < 1e-6
                then (V3 1 0 0, V3 0 1 0)
                else
                  let f = 1.0 / det
                      tx = f * (dv2 * edge1x - dv1 * edge2x)
                      ty = f * (dv2 * edge1y - dv1 * edge2y)
                      tz = f * (dv2 * edge1z - dv1 * edge2z)
                      bx = f * ((-du2) * edge1x + du1 * edge2x)
                      by = f * ((-du2) * edge1y + du1 * edge2y)
                      bz = f * ((-du2) * edge1z + du1 * edge2z)
                   in (V3 tx ty tz, V3 bx by bz)

            addTgt (t1, b1) (t2, b2) = (t1 ^+^ t2, b1 ^+^ b2)
         in Map.adjust (addTgt (tan, bitan)) (fromIntegral i0) $
              Map.adjust (addTgt (tan, bitan)) (fromIntegral i1) $
                Map.adjust (addTgt (tan, bitan)) (fromIntegral i2) acc

      -- Group indices into triangles
      triangles = group3 (Vector.toList indices)

      -- Accumulate tangents per vertex
      acc = foldl' processTriangle emptyAcc triangles

      -- Finalize: orthogonalize against normal, normalize, compute handedness
      finalize i =
        let V3 nx ny nz = normalize (normals ! i)
            (tanSum, bitanSum) = acc Map.! i
            V3 tx ty tz = tanSum
            -- Gram-Schmidt orthogonalize
            tdotn = tx * nx + ty * ny + tz * nz
            tox = tx - tdotn * nx
            toy = ty - tdotn * ny
            toz = tz - tdotn * nz
            tanLen = sqrt (tox * tox + toy * toy + toz * toz)
            tanOrtho = V3 (tox / tanLen) (toy / tanLen) (toz / tanLen)
            -- Compute handedness: bitangent should match cross(normal, tangent) * w
            V3 tanOx tanOy tanOz = tanOrtho
            bitanRefX = ny * tanOz - nz * tanOy
            bitanRefY = nz * tanOx - nx * tanOz
            bitanRefZ = nx * tanOy - ny * tanOx
            V3 bsx bsy bsz = if bitanSum == zero then bitanRef else normalize bitanSum
              where
                bitanRef = V3 bitanRefX bitanRefY bitanRefZ
            handedness = if (bsx * bitanRefX + bsy * bitanRefY + bsz * bitanRefZ) > 0 then 1.0 else (-1.0)
         in V4 tanOx tanOy tanOz handedness
   in Vector.fromList $ map finalize [0 .. n - 1]

group3 :: [Word32] -> [(Word32, Word32, Word32)]
group3 [] = []
group3 (a : b : c : rest) = (a, b, c) : group3 rest
group3 _ = [] -- incomplete triangle, ignore
