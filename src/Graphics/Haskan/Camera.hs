{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Camera where

import Control.Lens ((&), (.~), (^.))
import Data.Maybe (fromMaybe)
import Foreign.C qualified
import Linear (V2 (..), V3 (..), V4 (..), _x, _y, cross)
import Linear.Epsilon (Epsilon)
import Linear.Matrix (M44 (..), (!*!))
import Linear.Matrix qualified as Matrix
import Linear.Metric (normalize, dot)
import Linear ((*^), (^*))
import Linear.Projection qualified as Projection
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

data OrbitalCamera = OrbitalCamera
  { target :: V3 Foreign.C.CFloat,
    distance :: Foreign.C.CFloat,
    minDistance :: Foreign.C.CFloat,
    maxDistance :: Foreign.C.CFloat,
    orientation :: !(Quaternion Foreign.C.CFloat),
    targetOrientation :: !(Quaternion Foreign.C.CFloat),
    animationStartOrientation :: !(Quaternion Foreign.C.CFloat),
    animationElapsed :: !Foreign.C.CFloat,
    animationSpeed :: !Foreign.C.CFloat,
    animationMethod :: !InterpolationMethod,
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
      targetOrientation = Quaternion 1 (V3 0 0 0),
      animationStartOrientation = Quaternion 1 (V3 0 0 0),
      animationElapsed = 0,
      animationSpeed = 0.1,
      animationMethod = Slerp,
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

-- | Construct orientation from azimuth (yaw around Y) and elevation (pitch around local right axis).
orientationFromAzEl :: Foreign.C.CFloat -> Foreign.C.CFloat -> Quaternion Foreign.C.CFloat
orientationFromAzEl az el =
  let azQ = axisAngle (V3 0 1 0) az
      right = normalize (V3 (cos az) 0 (-sin az))
      elQ = axisAngle right el
  in elQ * azQ

-- | Extract azimuth (yaw around Y) from quaternion constructed via orientationFromAzEl.
quatToAzimuth :: Quaternion Foreign.C.CFloat -> Foreign.C.CFloat
quatToAzimuth (Quaternion qw (V3 qx qy qz)) =
  atan2 (2 * (qw * qy + qx * qz)) (1 - 2 * (qy * qy + qx * qx))

-- | Extract elevation (pitch around local right axis) from quaternion constructed via orientationFromAzEl.
quatToElevation :: Quaternion Foreign.C.CFloat -> Foreign.C.CFloat
quatToElevation (Quaternion qw (V3 qx qy qz)) =
  asin (2 * (qw * qx - qy * qz))

-- | Normalized linear interpolation between two quaternions.
nlerpQuaternion :: (RealFloat a, Epsilon a) => Quaternion a -> Quaternion a -> a -> Quaternion a
nlerpQuaternion q1 q2 t =
  let q2' = if quatDot q1 q2 < 0 then negate q2 else q2
      result = q1 + fmap (* t) (q2' - q1)
  in normalize result
  where
    quatDot (Quaternion w1 v1) (Quaternion w2 v2) = w1 * w2 + dot v1 v2

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
    let newOrientation = orientationFromAzEl az el
    in cam { orientation = newOrientation
           , targetOrientation = newOrientation
           , animationStartOrientation = newOrientation
           , animationElapsed = 0
           }
  setDistance cam d = cam { distance = max (minDistance cam) (min (maxDistance cam) d) }
  setMaxDistance cam d = cam { maxDistance = d }
  animate = animateOrbital

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
    (Rotate (V3 yaw pitch _roll)) ->
      let yawQ = axisAngle (V3 0 1 0) yaw
          currentForward = orbitalCameraForward cam
          right = normalize (currentForward `cross` V3 0 1 0)
          pitchQ = axisAngle right pitch
          deltaQ = pitchQ * yawQ
          rawTarget = deltaQ * targetOrientation

          -- Elevation clamping
          rawForward = normalize (rotate rawTarget (V3 0 0 (-1)))
          rawEl = asin (rawForward ^. _y)
          (V2 elMin elMax) = fromMaybe (V2 (-pi/2 + 0.01) (pi/2 - 0.01)) elevationBounds
          clampedEl = max elMin (min elMax rawEl)

          newTarget = if abs (rawEl - clampedEl) < 0.0001
            then rawTarget
            else orientationFromAzEl (quatToAzimuth rawTarget) clampedEl
      in cam { targetOrientation = newTarget
             , animationStartOrientation = orientation
             , animationElapsed = 0
             }
    (Zoom n) ->
      -- Zoom changes the camera distance (negative = zoom out, positive = zoom in)
      let newDist = max minDistance (min maxDistance (distance + n))
      in cam {distance = newDist}

animateOrbital :: OrbitalCamera -> Foreign.C.CFloat -> OrbitalCamera
animateOrbital cam dt =
  if animationSpeed cam <= 0 || animationMethod cam == Instantaneous
    then cam { orientation = targetOrientation cam, animationElapsed = 0 }
    else
      let elapsed = animationElapsed cam + dt
          t = min 1.0 (elapsed / animationSpeed cam)
          start = animationStartOrientation cam
          target = targetOrientation cam
          newOrientation = case animationMethod cam of
            Linear -> nlerpQuaternion start target t
            Slerp -> slerp start target t
            Instantaneous -> target
      in cam { orientation = newOrientation, animationElapsed = elapsed }

updateCamera :: Camera c => c -> [Modifier Foreign.C.CFloat] -> c
updateCamera cam mods = update cam mods
