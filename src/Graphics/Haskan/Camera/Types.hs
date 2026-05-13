{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Camera.Types
  ( InterpolationMethod(..)
  , ViewMatrix(..)
  , Modifier(..)
  , Camera(..)
  , worldUp
  , lookAtNegativeYUp
  , nlerpQuaternion
  ) where

import Control.Lens ((^.))
import Foreign.C qualified
import Linear (V2 (..), V3 (..), V4 (..), cross, dot)
import Linear.V3 (_x, _y, _z)
import Linear.Epsilon (Epsilon)
import Linear.Matrix (M44 (..))
import Linear.Metric (normalize)
import Linear ((*^), (^*))
import Linear.Quaternion (Quaternion (..), axisAngle, rotate, slerp)
import Linear.Quaternion qualified as Quat

data InterpolationMethod
  = Instantaneous
  | Linear
  | Slerp
  deriving (Show, Eq, Enum, Bounded)

newtype ViewMatrix = ViewMatrix {unViewMatrix :: M44 Foreign.C.CFloat}

data Modifier a
  = MoveX a
  | MoveY a
  | MoveForward a
  | MoveRight a
  | Rotate (V3 a)
  | Zoom a

class Camera a where
  update :: a -> [Modifier Foreign.C.CFloat] -> a
  toMatrix :: a -> ViewMatrix
  cameraPosition :: a -> V3 Foreign.C.CFloat
  cameraForward :: a -> V3 Foreign.C.CFloat
  cameraTarget :: a -> V3 Foreign.C.CFloat
  cameraDistance :: a -> Foreign.C.CFloat
  cameraMaxDistance :: a -> Foreign.C.CFloat
  cameraAzimuth :: a -> Foreign.C.CFloat
  cameraElevation :: a -> Foreign.C.CFloat
  setTarget :: a -> V3 Foreign.C.CFloat -> a
  setAngles :: a -> Foreign.C.CFloat -> Foreign.C.CFloat -> a
  setDistance :: a -> Foreign.C.CFloat -> a
  setMaxDistance :: a -> Foreign.C.CFloat -> a
  animate :: a -> Foreign.C.CFloat -> a

  cameraPosition _ = V3 0 0 0
  cameraForward _ = V3 0 0 (-1)
  cameraTarget _ = V3 0 0 0
  cameraDistance _ = 0
  cameraMaxDistance _ = 1e9
  cameraAzimuth _ = 0
  cameraElevation _ = 0
  setTarget a _ = a
  setAngles a _ _ = a
  setDistance a _ = a
  setMaxDistance a _ = a
  animate a _ = a

worldUp :: V3 Foreign.C.CFloat
worldUp = V3 0 1 0

lookAtNegativeYUp :: (Epsilon a, Floating a) => V3 a -> V3 a -> V3 a -> M44 a
lookAtNegativeYUp eye center up =
  let forward = normalize (center - eye)
      right = normalize (forward `cross` up)
      actualUp = right `cross` forward
   in V4
        (V4 (right ^. _x) (right ^. _y) (right ^. _z) (-(eye `dot` right)))
        (V4 (actualUp ^. _x) (actualUp ^. _y) (actualUp ^. _z) (-(eye `dot` actualUp)))
        (V4 (-(forward ^. _x)) (-(forward ^. _y)) (-(forward ^. _z)) (eye `dot` forward))
        (V4 0 0 0 1)

nlerpQuaternion :: (RealFloat a, Epsilon a) => Quaternion a -> Quaternion a -> a -> Quaternion a
nlerpQuaternion q1 q2 t =
  let q2' = if quatDot q1 q2 < 0 then negate q2 else q2
      result = q1 + fmap (* t) (q2' - q1)
  in normalize result
  where
    quatDot (Quaternion w1 v1) (Quaternion w2 v2) = w1 * w2 + dot v1 v2
