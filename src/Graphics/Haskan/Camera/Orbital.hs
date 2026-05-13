{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Camera.Orbital
  ( OrbitalCamera(..)
  , defaultOrbitalCamera
  , orbitalCameraPosition
  , orbitalCameraForward
  , orbitalToMatrix
  , orientationFromAzEl
  , quatToAzimuth
  , quatToElevation
  , updateOrbital
  , animateOrbital
  ) where

import Control.Lens ((^.))
import Data.Maybe (fromMaybe)
import Foreign.C qualified
import Linear (V2 (..), V3 (..), _x, _y, _z, cross, dot)
import Linear.Epsilon (Epsilon)
import Linear.Matrix (M44 (..))
import Linear.Metric (normalize)
import Linear ((*^), (^*))
import Linear.Quaternion (Quaternion (..), axisAngle, rotate, slerp)
import Graphics.Haskan.Camera.Types
  ( Camera(..)
  , InterpolationMethod(..)
  , Modifier(..)
  , ViewMatrix(..)
  , lookAtNegativeYUp
  , nlerpQuaternion
  , worldUp
  )

data OrbitalCamera = OrbitalCamera
  { target :: V3 Foreign.C.CFloat
  , distance :: Foreign.C.CFloat
  , minDistance :: Foreign.C.CFloat
  , maxDistance :: Foreign.C.CFloat
  , orientation :: !(Quaternion Foreign.C.CFloat)
  , targetOrientation :: !(Quaternion Foreign.C.CFloat)
  , animationStartOrientation :: !(Quaternion Foreign.C.CFloat)
  , animationElapsed :: !Foreign.C.CFloat
  , animationSpeed :: !Foreign.C.CFloat
  , animationMethod :: !InterpolationMethod
  , azimuthBounds :: Maybe (V2 Foreign.C.CFloat)
  , elevationBounds :: Maybe (V2 Foreign.C.CFloat)
  , azimuthDumping :: Maybe Foreign.C.CFloat
  , elevationDumping :: Maybe Foreign.C.CFloat
  , distanceDumping :: Maybe Foreign.C.CFloat
  }
  deriving (Show)

defaultOrbitalCamera :: OrbitalCamera
defaultOrbitalCamera =
  OrbitalCamera
    { target = V3 0.0 0.0 0.0
    , distance = 20.0
    , minDistance = 0.1
    , maxDistance = 10000.0
    , orientation = initOrientation
    , targetOrientation = initOrientation
    , animationStartOrientation = initOrientation
    , animationElapsed = 0
    , animationSpeed = 0.1
    , animationMethod = Slerp
    , azimuthBounds = Nothing
    , elevationBounds = Nothing
    , azimuthDumping = Nothing
    , distanceDumping = Nothing
    , elevationDumping = Nothing
    }
  where
    initOrientation = orientationFromAzEl 0 (pi / 6)

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
      view = lookAtNegativeYUp pos (target cam) worldUp
   in ViewMatrix view

orientationFromAzEl :: Foreign.C.CFloat -> Foreign.C.CFloat -> Quaternion Foreign.C.CFloat
orientationFromAzEl az el =
  let azQ = axisAngle worldUp (-az)
      right = normalize (V3 (cos az) 0 (sin az))
      elQ = axisAngle right el
   in elQ * azQ

quatToAzimuth :: Quaternion Foreign.C.CFloat -> Foreign.C.CFloat
quatToAzimuth (Quaternion qw (V3 qx qy qz)) =
  - (atan2 (2 * (qw * qy + qx * qz)) (1 - 2 * (qy * qy + qx * qx)))

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
    (MoveY n) -> cam {target = target + (V3 0.0 n 0.0)}
    (MoveForward n) ->
      let fwd = orbitalCameraForward cam
          V3 fx _ fz = fwd
          fwdXZ = normalize (V3 fx 0 fz)
       in cam {target = target + (fwdXZ ^* n)}
    (MoveRight n) ->
      let fwd = orbitalCameraForward cam
          V3 fx _ fz = fwd
          fwdXZ = normalize (V3 fx 0 fz)
          rightXZ = normalize (worldUp `cross` fwdXZ)
       in cam {target = target + (rightXZ ^* n)}
    (Rotate (V3 yaw pitch _roll)) ->
      let yawQ = axisAngle worldUp (-yaw)
          currentForward = orbitalCameraForward cam
          right = normalize (worldUp `cross` currentForward)
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
