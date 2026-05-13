{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Model where

import Data.HashMap.Strict qualified as HashMap
import Data.List (concatMap, mapAccumL, sort, sortBy, sortOn)
import Data.Maybe (fromMaybe)
import Data.Word (Word32)
import Foreign.C qualified
import Graphics.Haskan.Face (Face (..), QuadFace (..))
import Graphics.Haskan.Mesh (Mesh (..))
import Graphics.Haskan.Utils.ObjLoader qualified as Obj
import Graphics.Haskan.Utils.PieLoader (PieLevel (..))
import Graphics.Haskan.Utils.PieLoader qualified as Pie
import Graphics.Haskan.Vertex (Vertex (..))
import Linear (V2 (..), V3 (..), V4 (..), normalize)

objCube :: IO Obj.Obj
objCube = Obj.parseObj "data/models/cube.obj"

objTorus :: IO Obj.Obj
objTorus = Obj.parseObj "data/models/torus.obj"

suzanneCube :: IO Obj.Obj
suzanneCube = Obj.parseObj "data/models/suzanne_subdiv1.obj"

fromObj Obj.Obj {..} =
  let (vertexMap, faces) =
        mapAccumL
          ( \vertices face ->
              case face of
                (Obj.Triangle _) -> error "triangle faces not supported yet"
                ( Obj.Quad
                    ( V4
                        (v1, t1, n1)
                        (v2, t2, n2)
                        (v3, t3, n3)
                        (v4, t4, n4)
                      )
                  ) ->
                    let qf = QuadFace (v1, v2, v3, v4)
                        colRed = V3 1.0 0.0 0.0
                        vData vi ti ni = (vi, v3ToCFloat (v !! vi), v2ToCFloat (vt !! ti), v3ToCFloat (vn !! ni))
                        vertexData = [vData v1 t1 n1, vData v2 t2 n2, vData v3 t3 n3, vData v4 t4 n4]
                        vertices' = foldl (\vs (i, p, t, n) -> HashMap.insert i (Vertex p t n (V4 1 0 0 1) colRed) vs) vertices vertexData
                     in (vertices', qf)
          )
          HashMap.empty
          f
      (normalizedFaces, _) = normalizeFaces (variants faces)
      (vertexMap', _) =
        mapAccumL
          ( \vertices qf@(QuadFace (i1, i2, i3, i4)) ->
              let v1 = v !! i1
                  v2 = v !! i2
                  v3 = v !! i3
                  normal = calcNormal v3 v2 v1
               in (HashMap.update (\v -> Just (v {vNorm = normal})) i1 vertices, qf)
          )
          vertexMap
          normalizedFaces
      vertices = map snd $ sortOn fst $ HashMap.toList vertexMap'
      indices = toList $ triangulateQF normalizedFaces
   in (Mesh vertices indices, normalizedFaces)

toList :: [V3 Int] -> [Word32]
toList = concatMap (\(V3 a b c) -> [fromIntegral a, fromIntegral b, fromIntegral c])

triangulateQF :: [QuadFace Int] -> [V3 Int]
triangulateQF qs = triangulate $ map (\(QuadFace (a, b, c, d)) -> V4 a b c d) qs

triangulate :: [V4 Int] -> [V3 Int]
triangulate = concatMap quadToTris

quadToTris :: V4 Int -> [V3 Int]
quadToTris (V4 a b c d) = [V3 a b c, V3 a c d]

v2ToCFloat :: V2 Float -> V2 Foreign.C.CFloat
v2ToCFloat (V2 a b) = V2 (realToFrac a) (realToFrac b)

v3ToCFloat :: V3 Float -> V3 Foreign.C.CFloat
v3ToCFloat (V3 a b c) = V3 (realToFrac a) (realToFrac b) (realToFrac c)

variants :: (Foldable t) => t (QuadFace a) -> [QuadFace a]
variants = concatMap (\(QuadFace f) -> map (\n -> QuadFace (rot4 n f)) [0 .. 3])

rot4 :: Int -> (a, a, a, a) -> (a, a, a, a)
rot4 n x@(a, b, c, d) = foldr id x (replicate n rot)
  where
    rot (a, b, c, d) = (b, c, d, a)

normalizeFaces :: (Show a, Eq a, Foldable f) => f (QuadFace a) -> ([QuadFace a], [Int])
normalizeFaces =
  foldr
    ( \f@(QuadFace (a, b, c, d)) (seen, fsts) ->
        if f `elem` seen || a `elem` fsts
          then (seen, fsts)
          else (f : seen, a : fsts)
    )
    ([], [])

fromPie :: PieLevel -> Mesh
fromPie PieLevel {..} = do
  let indices =
        concatMap
          ( \t ->
              let (V3 a b c) = Pie.indices t
               in [fromIntegral a, fromIntegral b, fromIntegral c] -- reverse to counterclockwise
          )
          triangles
      firstNormals =
        map
          ( \t ->
              let (V3 a b c) = Pie.indices t
                  norm = calcNormal (vertices !! a) (vertices !! b) (vertices !! c)
               in (a, norm)
          )
          triangles
      verts =
        zipWith (curry ( \(i, (V3 x y z)) ->
              let norm = fromMaybe (V3 0.0 0.0 0.0) (lookup i firstNormals)
               in Vertex
                    { vPos = V3 (realToFrac x) (realToFrac y) (realToFrac z),
                      vTexUV = V2 0.0 0.0,
                      vNorm = norm,
                      vCol = V3 0.6 0.6 0.0
                    }
          )) [0 ..] vertices
  Mesh verts indices

calcNormal :: V3 Float -> V3 Float -> V3 Float -> V3 Foreign.C.CFloat
calcNormal p1 p2 p3 =
  let (V3 ux uy uz) = p2 - p1
      (V3 vx vy vz) = p3 - p1
      nx = (uy * vz) - (uz * vy)
      ny = (uz * vx) - (ux * vz)
      nz = (ux * vy) - (uy * vx)
   in normalize $ V3 (realToFrac nx) (realToFrac ny) (realToFrac nz)

verts :: [V3 Float]
verts =
  [ V3 (-1.0) 1.0 (-1.0),
    V3 (-1.0) (-1.0) (-1.0),
    V3 1.0 1.0 (-1.0),
    V3 1.0 (-1.0) (-1.0),
    V3 (-1.0) 1.0 1.0,
    V3 (-1.0) (-1.0) 1.0,
    V3 1.0 1.0 1.0,
    V3 1.0 (-1.0) 1.0
  ]

indxs :: [Int]
indxs =
  [ 0,
    1,
    2,
    3,
    2,
    1, -- front
    0,
    2,
    4,
    6,
    4,
    2, -- top
    2,
    3,
    6,
    7,
    6,
    2, -- right
    5,
    1,
    7,
    3,
    7,
    1, -- bottom
    0,
    1,
    5,
    4,
    0,
    5, -- left
    4,
    6,
    5,
    7,
    5,
    6 -- back
  ]

test :: (Show a, Eq a, Ord a) => ([Face a], [Int])
test = removeDoubles $ facesPerturb $ normalizeMesh verts indxs

facesPerturb faces =
  sort $
    concatMap
      ( \(Face (a, b, c)) ->
          [Face (a, b, c), Face (b, c, a), Face (c, a, b)]
      )
      faces

removeDoubles :: (Show a, Eq a) => [Face a] -> ([Face a], [Int])
removeDoubles =
  foldr
    ( \f@(Face (a, b, c)) (seen, fsts) ->
        if f `elem` seen || a `elem` fsts
          then (seen, fsts)
          else (f : seen, a : fsts)
    )
    ([], [])

normalizeMesh vertices indices =
  let minIdx [x, y, z]
        | x <= y && x <= z = 0
        | y <= x && y <= z = 1
        | otherwise = 2
      rotate n (a, b, c) =
        case mod n 3 of
          0 -> (a, b, c)
          1 -> (b, c, a)
          _ -> (c, a, b)
      stride' (a : b : c : xs) = (a, b, c) : stride' xs
      stride' [] = []
      faces =
        fmap
          (\(a, b, c) -> rotate (minIdx [a, b, c]) (a, b, c))
          (stride' indices)
   in --    normals = map (\(a,b,c) -> calcNormal a b c) faces
      Face <$> faces

normalizeIndices indices =
  let minIdx [x, y, z]
        | x <= y && x <= z = 0
        | y <= x && y <= z = 1
        | otherwise = 2
      rotate n (a, b, c) =
        case mod n 3 of
          0 -> (a, b, c)
          1 -> (b, c, a)
          _ -> (c, a, b)
   in fmap (\(a, b, c) -> rotate (minIdx [a, b, c]) (a, b, c)) indices

rotateFace n (a, b, c) =
  case n of
    1 -> (b, c, a)
    2 -> (c, a, b)
    _ -> (a, b, c)

normFaces faces =
  let --    sorted = sortBy compareFst3 faces
      faces' = sortBy compareFst3 (normPass faces)
   in if isNormalized faces'
        then faces'
        else sortBy compareFst3 $ normalizeIndices faces'

fst3 (a, _, _) = a

compareFst3 a b = compare (fst3 a) (fst3 b)

normalizePair (a, b) =
  case compareFst3 a b of
    EQ -> (a, rotateFace 1 b)
    _ -> (a, b)

normPass faces = case faces of
  [] -> []
  x : xs -> scanl (\b a -> if compareFst3 a b == EQ then rotateFace 1 a else a) x xs

isNormalized faces = notElem EQ $ zipWith compareFst3 faces (tail faces)
