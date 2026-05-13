module Graphics.Haskan.BoundingBox where

import Linear (V3 (..))

data BBox = BBox
  { bMin :: !(V3 Float),
    bMax :: !(V3 Float)
  }
  deriving (Show, Eq)

emptyBBox :: BBox
emptyBBox = BBox (V3 1e9 1e9 1e9) (V3 (-1e9) (-1e9) (-1e9))

mergeBBox :: BBox -> BBox -> BBox
mergeBBox (BBox aMin aMax) (BBox bMin bMax) =
  BBox (min <$> aMin <*> bMin) (max <$> aMax <*> bMax)

mergePoint :: BBox -> V3 Float -> BBox
mergePoint (BBox bMin bMax) p =
  BBox (min <$> bMin <*> p) (max <$> bMax <*> p)

bboxDiagonal :: BBox -> Float
bboxDiagonal (BBox bMin bMax) =
  let V3 dx dy dz = bMax - bMin
   in sqrt (dx * dx + dy * dy + dz * dz)

bboxCenter :: BBox -> V3 Float
bboxCenter (BBox bMin bMax) = (bMin + bMax) / 2

fromPoints :: [V3 Float] -> BBox
fromPoints = foldl mergePoint emptyBBox
