{-# language RecordWildCards #-}
module Graphics.Haskan.Camera where

-- base
import qualified Foreign.C

-- lens
import Control.Lens ((&), (.~))

-- linear
import Linear (V2(..), V3(..), V4(..))
import Linear.Epsilon (Epsilon)
import Linear.Matrix (M44(..), (!*!))
import qualified Linear.Matrix as Matrix
import qualified Linear.Projection as Projection
import Linear.Quaternion (Quaternion)
import qualified Linear.Quaternion as Quat

newtype ViewMatrix = ViewMatrix {unViewMatrix :: M44 Foreign.C.CFloat} -- Camera { unCamera :: M44 a } deriving Show

data Modifier a
  = MoveX a
  | MoveY a
  | Rotate (V3 a)
  | Zoom a

class Camera a where
  update :: a -> [Modifier Foreign.C.CFloat] -> a
  toMatrix :: a -> ViewMatrix

data OrbitalCamera
  = OrbitalCamera { target :: V3 Foreign.C.CFloat
                  , distance :: Foreign.C.CFloat
                  , minDistance :: Foreign.C.CFloat
                  , maxDistance :: Foreign.C.CFloat
                  , azimuthAngle :: Foreign.C.CFloat
                  , elevationAngle :: Foreign.C.CFloat
                  , azimuthBounds :: Maybe (V2 Foreign.C.CFloat)
                  , elevationBounds :: Maybe (V2 Foreign.C.CFloat)
                  , azimuthDumping :: Maybe Foreign.C.CFloat
                  , elevationDumping :: Maybe Foreign.C.CFloat
                  , distanceDumping :: Maybe Foreign.C.CFloat
                  } deriving (Show)

defaultOrbitalCamera :: OrbitalCamera
defaultOrbitalCamera =
  OrbitalCamera
  { target = V3 0.0 0.0 0.0
  , distance = 20.0
  , minDistance = 1.0
  , maxDistance = 20.0
  , azimuthAngle = 0.0
  , elevationAngle = 0.0
  , azimuthBounds = Nothing
  , elevationBounds = Nothing
  , azimuthDumping = Nothing
  , distanceDumping = Nothing
  , elevationDumping = Nothing
  }
  where
    xAxis = V3 1.0 0.0 0.0

orbitalToMatrix :: OrbitalCamera -> ViewMatrix
orbitalToMatrix OrbitalCamera{..} =
  let
    xAxis = V3 1.0 0.0 0.0
    yAxis = V3 0.0 1.0 0.0
    zAxis = V3 0.0 0.0 1.0
    translation = target - (V3 0.0 0.0 distance)
    azimuthRotation = Quat.axisAngle yAxis azimuthAngle
    elevationRotation = Quat.axisAngle xAxis elevationAngle
    quat = elevationRotation * azimuthRotation
    rotate = Matrix.mkTransformation quat translation
    viewMatrix = Matrix.transpose $ rotate
  in ViewMatrix viewMatrix

instance Camera OrbitalCamera where
  update = updateOrbital
  toMatrix = orbitalToMatrix

updateOrbital :: OrbitalCamera -> [Modifier Foreign.C.CFloat] -> OrbitalCamera
updateOrbital cam = foldl orbitalModify cam

orbitalModify :: OrbitalCamera -> Modifier Foreign.C.CFloat -> OrbitalCamera
orbitalModify cam@OrbitalCamera{..} mod =
  case mod of
    (MoveX n) -> cam{target = target + (V3 n 0.0 0.0)}
    (MoveY n) -> cam{target = target + (V3 0.0 0.0 n)}
    (Rotate (V3 yaw pitch roll)) ->
      let
        yaw' = yaw + azimuthAngle
        pitch' = pitch + elevationAngle

      in cam{azimuthAngle = yaw', elevationAngle = pitch'}
    _ -> cam

updateCamera :: Camera c => c -> [Modifier Foreign.C.CFloat] -> c
updateCamera cam mods = update cam mods
