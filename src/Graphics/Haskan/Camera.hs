module Graphics.Haskan.Camera
  ( module Graphics.Haskan.Camera.Types,
    module Graphics.Haskan.Camera.Orbital,
    module Graphics.Haskan.Camera.Fly,
    AnyCamera (..),
    updateCamera,
    toAnyCamera,
  )
where

import Foreign.C qualified
import Graphics.Haskan.Camera.Fly
import Graphics.Haskan.Camera.Orbital
import Graphics.Haskan.Camera.Types
import Linear (V3 (..), (*^), (^*))
import Linear.Quaternion (Quaternion (..), axisAngle, rotate)

data AnyCamera
  = Orbital OrbitalCamera
  | Fly FlyCamera
  deriving (Show)

instance Camera AnyCamera where
  update (Orbital c) mods = Orbital (update c mods)
  update (Fly c) mods = Fly (update c mods)

  toMatrix (Orbital c) = toMatrix c
  toMatrix (Fly c) = toMatrix c

  cameraPosition (Orbital c) = cameraPosition c
  cameraPosition (Fly c) = cameraPosition c

  cameraForward (Orbital c) = cameraForward c
  cameraForward (Fly c) = cameraForward c

  cameraTarget (Orbital c) = cameraTarget c
  cameraTarget (Fly c) = cameraTarget c

  cameraDistance (Orbital c) = cameraDistance c
  cameraDistance (Fly c) = cameraDistance c

  cameraMaxDistance (Orbital c) = cameraMaxDistance c
  cameraMaxDistance (Fly c) = cameraMaxDistance c

  cameraAzimuth (Orbital c) = cameraAzimuth c
  cameraAzimuth (Fly c) = cameraAzimuth c

  cameraElevation (Orbital c) = cameraElevation c
  cameraElevation (Fly c) = cameraElevation c

  setTarget (Orbital c) t = Orbital (setTarget c t)
  setTarget (Fly c) t = Fly (setTarget c t)

  setAngles (Orbital c) az el = Orbital (setAngles c az el)
  setAngles (Fly c) az el = Fly (setAngles c az el)

  setDistance (Orbital c) d = Orbital (setDistance c d)
  setDistance (Fly c) d = Fly (setDistance c d)

  setMaxDistance (Orbital c) d = Orbital (setMaxDistance c d)
  setMaxDistance (Fly c) d = Fly (setMaxDistance c d)

  animate (Orbital c) dt = Orbital (animate c dt)
  animate (Fly c) dt = Fly (animate c dt)

updateCamera :: (Camera c) => c -> [Modifier Foreign.C.CFloat] -> c
updateCamera cam mods = update cam mods

-- | Convert between camera types while preserving position and orientation.
toAnyCamera :: AnyCamera -> AnyCamera
toAnyCamera (Orbital orb) =
  let pos = orbitalCameraPosition orb
      fwd = orbitalCameraForward orb
      (az, el) = (quatToAzimuth (orientation orb), quatToElevation (orientation orb))
      fly =
        defaultFlyCamera
          { flyPosition = pos,
            flyOrientation = orientationFromAzEl az el
          }
   in Fly fly
toAnyCamera (Fly fly) =
  let pos = flyPosition fly
      fwd = flyCameraForward fly
      az = cameraAzimuth fly
      el = cameraElevation fly
      orb =
        defaultOrbitalCamera
          { target = pos + fwd ^* 20.0,
            distance = 20.0,
            orientation = orientationFromAzEl az el,
            targetOrientation = orientationFromAzEl az el,
            animationStartOrientation = orientationFromAzEl az el,
            animationElapsed = 0
          }
   in Orbital orb
