{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Camera where

import Control.Lens ((&), (.~))
import Foreign.C qualified
import Linear (V2 (..), V3 (..), V4 (..), _x, _y)
import Linear.Epsilon (Epsilon)
import Linear.Matrix (M44 (..), (!*!))
import Linear.Matrix qualified as Matrix
import Linear.Metric (normalize)
import Linear ((*^), (^*))
import Linear.Projection qualified as Projection
import Linear.Quaternion (Quaternion (..), axisAngle, rotate)
import Linear.Quaternion qualified as Quat

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

data OrbitalCamera = OrbitalCamera
  { target :: V3 Foreign.C.CFloat,
    distance :: Foreign.C.CFloat,
    minDistance :: Foreign.C.CFloat,
    maxDistance :: Foreign.C.CFloat,
    orientation :: !(Quaternion Foreign.C.CFloat),
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
      minDistance = 0.1,
      maxDistance = 20.0,
      orientation = Quaternion 1 (V3 0 0 0),
      azimuthBounds = Nothing,
      elevationBounds = Nothing,
      azimuthDumping = Nothing,
      distanceDumping = Nothing,
      elevationDumping = Nothing
    }

orbitalCameraPosition :: OrbitalCamera -> V3 Foreign.C.CFloat
orbitalCameraPosition OrbitalCamera{..} =
  let offset = V3 0 0 distance
  in target + rotate orientation offset

orbitalCameraForward :: OrbitalCamera -> V3 Foreign.C.CFloat
orbitalCameraForward OrbitalCamera{..} =
  let dir = V3 0 0 (-1)
  in normalize $ rotate orientation dir

orbitalToMatrix :: OrbitalCamera -> ViewMatrix
orbitalToMatrix cam =
  let pos = orbitalCameraPosition cam
  in ViewMatrix $ Projection.lookAt pos (target cam) (V3 0 1 0)

-- | Extract azimuth (yaw around Y) from quaternion
quatToAzimuth :: Quaternion Foreign.C.CFloat -> Foreign.C.CFloat
quatToAzimuth (Quaternion qw (V3 qx qy qz)) =
  atan2 (2 * (qw * qy + qx * qz)) (1 - 2 * (qy * qy + qx * qx))

-- | Extract elevation (pitch around X) from quaternion
quatToElevation :: Quaternion Foreign.C.CFloat -> Foreign.C.CFloat
quatToElevation (Quaternion qw (V3 qx qy qz)) =
  asin (2 * (qw * qx - qy * qz))

instance Camera OrbitalCamera where
  update = updateOrbital
  toMatrix = orbitalToMatrix
  cameraPosition = orbitalCameraPosition
  cameraForward = orbitalCameraForward
  cameraTarget = target
  cameraDistance = distance
  cameraMaxDistance = maxDistance
  cameraAzimuth = quatToAzimuth . orientation
  cameraElevation = quatToElevation . orientation
  setTarget cam t = cam { target = t }
  setAngles cam az el =
    let azQ = axisAngle (V3 0 1 0) az
        elQ = axisAngle (V3 1 0 0) el
    in cam { orientation = elQ * azQ }
  setDistance cam d = cam { distance = max (minDistance cam) (min (maxDistance cam) d) }
  setMaxDistance cam d = cam { maxDistance = d }

updateOrbital :: OrbitalCamera -> [Modifier Foreign.C.CFloat] -> OrbitalCamera
updateOrbital cam = foldl orbitalModify cam

orbitalModify :: OrbitalCamera -> Modifier Foreign.C.CFloat -> OrbitalCamera
orbitalModify cam@OrbitalCamera {..} mod =
  case mod of
    (MoveX n) -> cam {target = target + (V3 n 0.0 0.0)}
    (MoveY n) -> cam {target = target + (V3 0.0 0.0 n)}
    (MoveForward n) ->
      let fwd = orbitalCameraForward cam
          V3 fx _ fz = fwd
          fwdXZ = normalize (V3 fx 0 fz)
      in cam {target = target + (fwdXZ ^* n)}
    (MoveRight n) ->
      let fwd = orbitalCameraForward cam
          V3 fx _ fz = fwd
          fwdXZ = normalize (V3 fx 0 fz)
          -- Right vector = cross(Y-up, forward) in XZ plane
          rightXZ = V3 fz 0 (-fx)
      in cam {target = target + (rightXZ ^* n)}
    (Rotate (V3 yaw pitch roll)) ->
      -- Apply rotation deltas as quaternion rotations (avoids gimbal lock)
      let yawQ = axisAngle (V3 0 1 0) yaw
          pitchQ = axisAngle (V3 1 0 0) pitch
          deltaQ = pitchQ * yawQ
          newOrientation = deltaQ * orientation
      in cam {orientation = newOrientation}
    (Zoom n) ->
      -- Zoom changes the camera distance (negative = zoom out, positive = zoom in)
      let newDist = max minDistance (min maxDistance (distance + n))
      in cam {distance = newDist}

updateCamera :: Camera c => c -> [Modifier Foreign.C.CFloat] -> c
updateCamera cam mods = update cam mods
