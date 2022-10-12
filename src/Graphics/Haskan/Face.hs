module Graphics.Haskan.Face where

newtype Face a = Face {unFace :: (Int, Int, Int)}

instance Eq a => Eq (Face a) where
  (==) (Face (a1,b1,c1)) (Face (a2,b2,c2)) =
    (a1 == a2 && b1 == b2 && c1 == c2) ||
    (a1 == b2 && b1 == c2 && c1 == a2) ||
    (a1 == c2 && b1 == a2 && c1 == b2)

instance Ord a => Ord (Face a) where
  compare (Face f1) (Face f2) = f1 `compare` f2

instance Show a => Show (Face a) where
  show (Face x) = show x

newtype QuadFace a = QuadFace {unQuadFace :: (Int, Int, Int,Int)}

instance Eq a => Eq (QuadFace a) where
  (==) (QuadFace (a1,b1,c1,d1)) (QuadFace (a2,b2,c2,d2)) =
    (a1 == a2 && b1 == b2 && c1 == c2 && d1 == d2) ||
    (a1 == b2 && b1 == c2 && c1 == d2 && d1 == a2) ||
    (a1 == c2 && b1 == d2 && c1 == a2 && d1 == b2) ||
    (a1 == d2 && b1 == a2 && c1 == b2 && d1 == c2)

instance Ord a => Ord (QuadFace a) where
  compare (QuadFace f1) (QuadFace f2) = f1 `compare` f2

instance Show a => Show (QuadFace a) where
  show (QuadFace x) = show x
