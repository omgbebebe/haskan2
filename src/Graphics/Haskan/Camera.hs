{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Camera where

import Control.Lens ((&), (.~))
import Foreign.C qualified
import Linear (V2 (..), V3 (..), V4 (..))
import Linear.Epsilon (Epsilon)
import Linear.Matrix (M44 (..), (!*!))
import Linear.Matrix qualified as Matrix
import Linear.Metric (normalize)
import Linear.Projection qualified as Projection
import Linear.Quaternion (Quaternion, axisAngle, rotate)
import Linear.Quaternion qualified as Quat

newtype ViewMatrix = ViewMatrix {unViewMatrix :: M44 Foreign.C.CFloat}

data Modifier a
  = MoveX a
  | MoveY a
  | Rotate (V3 a)
  | Zoom a

class Camera a where
  update :: a -> [Modifier Foreign.C.CFloat] -> a
  toMatrix :: a -> ViewMatrix
  cameraPosition :: a -> V3 Foreign.C.CFloat
  cameraForward :: a -> V3 Foreign.C.CFloat
  cameraTarget :: a -> V3 Foreign.C.CFloat
  cameraDistance :: a -> Foreign.C.CFloat
  cameraAzimuth :: a -> Foreign.C.CFloat
  cameraElevation :: a -> Foreign.C.CFloat
  setTarget :: a -> V3 Foreign.C.CFloat -> a
  setAngles :: a -> Foreign.C.CFloat -> Foreign.C.CFloat -> a
  setDistance :: a -> Foreign.C.CFloat -> a

  cameraPosition _ = V3 0 0 0
  cameraForward _ = V3 0 0 (-1)
  cameraTarget _ = V3 0 0 0
  cameraDistance _ = 0
  cameraAzimuth _ = 0
  cameraElevation _ = 0
  setTarget a _ = a
  setAngles a _ _ = a
  setDistance a _ = a

data OrbitalCamera = OrbitalCamera
  { target :: V3 Foreign.C.CFloat,
    distance :: Foreign.C.CFloat,
    minDistance :: Foreign.C.CFloat,
    maxDistance :: Foreign.C.CFloat,
    azimuthAngle :: Foreign.C.CFloat,
    elevationAngle :: Foreign.C.CFloat,
    azimuthBounds :: Maybe (V2 Foreign.C.CFloat),
    elevationBounds :: Maybe (V2 Foreign.C.CFloat),
    azimuthDumping :: Maybe Foreign.C.CFloat,
    elevationDumping :: Maybe Foreign.C.CFloat,
    distanceDumping :: Maybe Foreign.C.CFloat
  }
  deriving (Show)

defaultOrbitalCamera :: OrbitalCamera
defaultOrbitalCamera =
  OrbitalCamera
    { target = V3 0.0 0.0 0.0,
      distance = 20.0,
      minDistance = 1.0,
      maxDistance = 20.0,
      azimuthAngle = 0.0,
      elevationAngle = 0.0,
      azimuthBounds = Nothing,
      elevationBounds = Nothing,
      azimuthDumping = Nothing,
      distanceDumping = Nothing,
      elevationDumping = Nothing
    }

orbitalCameraPosition :: OrbitalCamera -> V3 Foreign.C.CFloat
orbitalCameraPosition OrbitalCamera{..} =
  let azQ = axisAngle (V3 0 1 0) azimuthAngle
      elQ = axisAngle (V3 1 0 0) elevationAngle
      combined = elQ * azQ
      offset = V3 0 0 distance
  in target + rotate combined offset

orbitalCameraForward :: OrbitalCamera -> V3 Foreign.C.CFloat
orbitalCameraForward OrbitalCamera{..} =
  let azQ = axisAngle (V3 0 1 0) azimuthAngle
      elQ = axisAngle (V3 1 0 0) elevationAngle
      combined = elQ * azQ
      dir = V3 0 0 (-1)
  in normalize $ rotate combined dir

orbitalToMatrix :: OrbitalCamera -> ViewMatrix
orbitalToMatrix OrbitalCamera {..} =
  let xAxis = V3 1.0 0.0 0.0
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
  cameraPosition = orbitalCameraPosition
  cameraForward = orbitalCameraForward
  cameraTarget = target
  cameraDistance = distance
  cameraAzimuth = azimuthAngle
  cameraElevation = elevationAngle
  setTarget cam t = cam { target = t }
  setAngles cam az el = cam { azimuthAngle = az, elevationAngle = el }
  setDistance cam d = cam { distance = max (minDistance cam) (min (maxDistance cam) d) }

updateOrbital :: OrbitalCamera -> [Modifier Foreign.C.CFloat] -> OrbitalCamera
updateOrbital cam = foldl orbitalModify cam

orbitalModify :: OrbitalCamera -> Modifier Foreign.C.CFloat -> OrbitalCamera
orbitalModify cam@OrbitalCamera {..} mod =
  case mod of
    (MoveX n) -> cam {target = target + (V3 n 0.0 0.0)}
    (MoveY n) -> cam {target = target + (V3 0.0 0.0 n)}
    (Rotate (V3 yaw pitch roll)) ->
      let yaw' = yaw + azimuthAngle
          pitch' = pitch + elevationAngle
       in cam {azimuthAngle = yaw', elevationAngle = pitch'}
    _ -> cam

updateCamera :: Camera c => c -> [Modifier Foreign.C.CFloat] -> c
updateCamera cam mods = update cam mods
