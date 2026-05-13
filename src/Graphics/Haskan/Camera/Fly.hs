{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Camera.Fly
  ( FlyCamera(..)
  , defaultFlyCamera
  , flyCameraForward
  , flyToMatrix
  , updateFly
  ) where

import Foreign.C qualified
import Linear (V3 (..), _x, _y, _z, cross, dot)
import Linear.Epsilon (Epsilon)
import Linear.Metric (normalize)
import Linear ((*^), (^*))
import Linear.Quaternion (Quaternion (..), axisAngle, rotate)
import Graphics.Haskan.Camera.Types
  ( Camera(..)
  , Modifier(..)
  , ViewMatrix(..)
  , lookAtNegativeYUp
  , worldUp
  )

data FlyCamera = FlyCamera
  { flyPosition :: !(V3 Foreign.C.CFloat)
  , flyOrientation :: !(Quaternion Foreign.C.CFloat)
  , flySpeed :: !Foreign.C.CFloat
  , flyMaxDistance :: !Foreign.C.CFloat
  }
  deriving (Show)

defaultFlyCamera :: FlyCamera
defaultFlyCamera =
  FlyCamera
    { flyPosition = V3 0.0 5.0 20.0
    , flyOrientation = axisAngle worldUp 0 * axisAngle (V3 1 0 0) (-pi / 6)
    , flySpeed = 10.0
    , flyMaxDistance = 10000.0
    }

flyCameraForward :: FlyCamera -> V3 Foreign.C.CFloat
flyCameraForward FlyCamera{..} =
  normalize $ rotate flyOrientation (V3 0 0 (-1))

flyCameraRight :: FlyCamera -> V3 Foreign.C.CFloat
flyCameraRight FlyCamera{..} =
  normalize $ rotate flyOrientation (V3 1 0 0)

flyToMatrix :: FlyCamera -> ViewMatrix
flyToMatrix cam =
  let pos = flyPosition cam
      fwd = flyCameraForward cam
      tgt = pos + fwd
      view = lookAtNegativeYUp pos tgt worldUp
   in ViewMatrix view

forwardToAzEl :: V3 Foreign.C.CFloat -> (Foreign.C.CFloat, Foreign.C.CFloat)
forwardToAzEl (V3 fx fy fz) =
  let az = atan2 (-fz) fx
      lenXZ = sqrt (fx * fx + fz * fz)
      el = atan2 fy lenXZ
   in (az, el)

instance Camera FlyCamera where
  update = updateFly
  toMatrix = flyToMatrix
  cameraPosition = flyPosition
  cameraForward = flyCameraForward
  cameraTarget cam =
    let fwd = flyCameraForward cam
    in flyPosition cam + fwd ^* 10.0
  cameraDistance _ = 0
  cameraMaxDistance = flyMaxDistance
  cameraAzimuth cam = fst $ forwardToAzEl $ flyCameraForward cam
  cameraElevation cam = snd $ forwardToAzEl $ flyCameraForward cam
  setTarget cam tgt =
    let pos = flyPosition cam
        fwd = normalize (tgt - pos)
        (az, el) = forwardToAzEl fwd
        yawQ = axisAngle worldUp (-az)
        right = normalize (worldUp `cross` fwd)
        pitchQ = axisAngle right el
    in cam { flyOrientation = pitchQ * yawQ }
  setAngles cam az el =
    let yawQ = axisAngle worldUp (-az)
        right = normalize (V3 (cos az) 0 (sin az))
        pitchQ = axisAngle right el
    in cam { flyOrientation = pitchQ * yawQ }
  setDistance cam d =
    let fwd = flyCameraForward cam
    in cam { flyPosition = flyPosition cam + fwd ^* d }
  setMaxDistance cam d = cam { flyMaxDistance = d }
  animate cam _ = cam

updateFly :: FlyCamera -> [Modifier Foreign.C.CFloat] -> FlyCamera
updateFly cam = foldl flyModify cam

flyModify :: FlyCamera -> Modifier Foreign.C.CFloat -> FlyCamera
flyModify cam@FlyCamera{..} mod =
  case mod of
    (MoveX n) -> cam { flyPosition = flyPosition + V3 n 0.0 0.0 }
    (MoveY n) -> cam { flyPosition = flyPosition + V3 0.0 n 0.0 }
    (MoveForward n) ->
      let fwd = flyCameraForward cam
      in cam { flyPosition = flyPosition + (fwd ^* n) }
    (MoveRight n) ->
      let right = flyCameraRight cam
      in cam { flyPosition = flyPosition + (right ^* n) }
    (Rotate (V3 yaw pitch _roll)) ->
      let yawQ = axisAngle worldUp (-yaw)
          currentForward = flyCameraForward cam
          right = normalize (worldUp `cross` currentForward)
          pitchQ = axisAngle right pitch
          newOrientation = normalize $ pitchQ * yawQ * flyOrientation
       in cam { flyOrientation = newOrientation }
    (Zoom n) ->
      -- Zoom in fly mode = move forward/backward quickly
      let fwd = flyCameraForward cam
      in cam { flyPosition = flyPosition + (fwd ^* (n * 5.0)) }
