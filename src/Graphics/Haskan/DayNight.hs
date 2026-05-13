module Graphics.Haskan.DayNight
  ( DayNightConfig (..),
    defaultDayNightConfig,
    computeSunState,
    SunState (..),
  )
where

import Linear (V3 (..))

-- | Configuration for day/night cycle
data DayNightConfig = DayNightConfig
  { -- | Maximum sun elevation in radians (default: π/3 = 60°)
    dncMaxElevation :: Float,
    -- | Hour when sun rises (default: 6.0)
    dncSunriseTime :: Float,
    -- | Hour when sun sets (default: 18.0)
    dncSunsetTime :: Float,
    -- | Peak sun intensity at noon (default: 1.0)
    dncMaxIntensity :: Float,
    -- | Sun color at noon (default: white)
    dncNoonColor :: V3 Float,
    -- | Sun color at sunrise/sunset (default: warm orange)
    dncSunsetColor :: V3 Float,
    -- | Sky tint during day (default: white)
    dncDaySkyTint :: V3 Float,
    -- | Sky tint at sunset (default: orange)
    dncSunsetSkyTint :: V3 Float,
    -- | Sky tint at night (default: dark blue)
    dncNightSkyTint :: V3 Float,
    -- | IBL intensity during day (default: 0.3)
    dncDayIBLIntensity :: Float,
    -- | IBL intensity at night (default: 0.05)
    dncNightIBLIntensity :: Float
  }
  deriving (Show)

defaultDayNightConfig :: DayNightConfig
defaultDayNightConfig =
  DayNightConfig
    { dncMaxElevation = pi / 3.0,
      dncSunriseTime = 6.0,
      dncSunsetTime = 18.0,
      dncMaxIntensity = 1.0,
      dncNoonColor = V3 1.0 1.0 1.0,
      dncSunsetColor = V3 1.0 0.6 0.3,
      dncDaySkyTint = V3 1.0 1.0 1.0,
      dncSunsetSkyTint = V3 1.0 0.7 0.4,
      dncNightSkyTint = V3 0.1 0.1 0.2,
      dncDayIBLIntensity = 1.0,
      dncNightIBLIntensity = 0.0
    }

-- | Computed sun state for a given time
data SunState = SunState
  { ssDirection :: V3 Float,
    ssIntensity :: Float,
    ssColor :: V3 Float,
    ssSkyTint :: V3 Float,
    ssIBLIntensity :: Float,
    ssAzimuth :: Float
  }
  deriving (Show)

-- | Compute sun state from time of day (0-24 hours)
computeSunState :: DayNightConfig -> Float -> SunState
computeSunState config time =
  let t = clamp 0.0 24.0 time
      sunrise = dncSunriseTime config
      sunset = dncSunsetTime config
      dayLength = sunset - sunrise

      -- Normalized day progress (0 at sunrise, 1 at sunset)
      dayProgress = clamp 0.0 1.0 ((t - sunrise) / dayLength)

      -- Sun angle through the day (0 at sunrise, π/2 at noon, π at sunset)
      sunAngle = dayProgress * pi

      -- Elevation: sine of sun angle, peaking at noon
      elevation = sin sunAngle * dncMaxElevation config

      -- Azimuth for sun direction: rotates 180° from sunrise to sunset
      azimuth = sunAngle

      -- Azimuth for cubemap rotation: continuous 360° over 24 hours
      -- Sun makes a full apparent revolution every 24 hours
      azimuth24h = (t / 24.0) * 2 * pi

      -- Direction (light comes FROM this direction)
      dirX = cos elevation * sin azimuth
      dirY = sin elevation
      dirZ = cos elevation * cos azimuth

      -- Intensity: peaks at noon, zero at night
      intensity = max 0.0 (sin sunAngle) * dncMaxIntensity config

      -- Color: lerp between sunset (morning/evening) and noon colors
      -- Use elevation as lerp factor
      colorLerp = clamp 0.0 1.0 (elevation / dncMaxElevation config)
      noonCol = dncNoonColor config
      sunsetCol = dncSunsetColor config
      color = lerpV3 colorLerp sunsetCol noonCol

      -- Sky tint: lerp between night, sunset, and day
      skyLerp = clamp 0.0 1.0 (sin sunAngle)
      dayTint = dncDaySkyTint config
      sunsetTint = dncSunsetSkyTint config
      nightTint = dncNightSkyTint config

      -- First lerp between night and sunset, then to day
      -- At sunrise/set (skyLerp ≈ 0): closer to sunset
      -- At noon (skyLerp ≈ 1): day
      sunsetLerp = 1.0 - abs (dayProgress - 0.5) * 2.0 -- 1 at sunrise/set, 0 at noon
      tempTint = lerpV3 sunsetLerp dayTint sunsetTint
      skyTint = lerpV3 skyLerp nightTint tempTint

      -- IBL intensity: dim at night, bright at day
      iblLerp = clamp 0.0 1.0 (sin sunAngle)
      iblInt = lerpF iblLerp (dncNightIBLIntensity config) (dncDayIBLIntensity config)
   in SunState
        { ssDirection = normalize (V3 dirX dirY dirZ),
          ssIntensity = intensity,
          ssColor = color,
          ssSkyTint = skyTint,
          ssIBLIntensity = iblInt,
          ssAzimuth = azimuth24h
        }

-- Helpers
clamp :: Float -> Float -> Float -> Float
clamp lo hi x = max lo (min hi x)

lerpF :: Float -> Float -> Float -> Float
lerpF t a b = a + (b - a) * t

lerpV3 :: Float -> V3 Float -> V3 Float -> V3 Float
lerpV3 t (V3 ax ay az) (V3 bx by bz) = V3 (lerpF t ax bx) (lerpF t ay by) (lerpF t az bz)

normalize :: V3 Float -> V3 Float
normalize v =
  let len = sqrt (dotV3 v v)
   in if len > 0.0001 then v / pure len else v

dotV3 :: V3 Float -> V3 Float -> Float
dotV3 (V3 ax ay az) (V3 bx by bz) = ax * bx + ay * by + az * bz
