{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Graphics.Haskan.Vulkan.Shaders.Sky.Procedural
  ( generateSkyLUT,
    SkyParams (..),
    defaultSkyParams,
  )
where

import Control.Lens ((^.))
import Data.Bits (shiftL, (.&.), (.|.))
import Data.Word (Word16)
import GHC.Float (isInfinite, isNaN)
import Linear (V3 (..), dot, normalize, (*^), (^*), (^+^), (^-^), _x, _y, _z)
import Prelude hiding ((*^), (^+^), (^-^), (^.))

-- | Parameters for procedural sky generation.
data SkyParams = SkyParams
  { spSunDir :: !(V3 Float),
    spSunIntensity :: !Float,
    spRayleighCoeff :: !(V3 Float),
    spMieCoeff :: !Float,
    spMieG :: !Float,
    spTurbidity :: !Float
  }
  deriving (Show)

defaultSkyParams :: SkyParams
defaultSkyParams =
  SkyParams
    { spSunDir = normalize (V3 0.0 0.3 (-1.0)),
      spSunIntensity = 50.0,
      spRayleighCoeff = V3 0.0058 0.0135 0.0331, -- Rayleigh scattering coefficients (RGB)
      spMieCoeff = 0.021,
      spMieG = 0.76,
      spTurbidity = 2.0
    }

-- | Rayleigh phase function.
rayleighPhase :: Float -> Float
rayleighPhase mu =
  3.0 / (16.0 * pi) * (1.0 + mu * mu)

-- | Henyey-Greenstein phase function.
hgPhase :: Float -> Float -> Float
hgPhase g mu =
  let g2 = g * g
      denom = (1.0 + g2 - 2.0 * g * mu) ** 1.5
   in (1.0 - g2) / (4.0 * pi * denom)

-- | Evaluate procedural sky color for a view direction.
evaluateSky ::
  SkyParams ->
  V3 Float -> -- viewDir (normalized)
  V3 Float
evaluateSky params viewDir =
  let sunDir = spSunDir params
      sunIntensity = spSunIntensity params
      rayleighCoeff = spRayleighCoeff params
      mieCoeff = spMieCoeff params
      mieG = spMieG params
      turbidity = spTurbidity params

      -- Cosine of angle between view and sun
      cosGamma = max (-1.0) (min 1.0 (viewDir `dot` sunDir))

      -- Vertical component
      cosTheta = max 0.0 (viewDir ^. _y)

      -- Rayleigh scattering
      rayleighPhaseVal = rayleighPhase cosGamma
      rayleighScatter = rayleighCoeff ^* (rayleighPhaseVal * exp (-0.05 / (cosTheta + 0.001)))

      -- Mie scattering
      miePhaseVal = hgPhase mieG cosGamma
      mieScatter = V3 mieCoeff mieCoeff mieCoeff ^* (miePhaseVal * exp (-0.1 / (cosTheta + 0.001)))

      -- Sun disc
      sunDisc = if cosGamma > 0.9995 then sunIntensity else 0.0

      -- Combine
      total = rayleighScatter ^+^ mieScatter ^+^ V3 sunDisc sunDisc sunDisc

      -- Color temperature based on sun elevation
      sunElev = sunDir ^. _y
      colorTemp
        | sunElev > 0.3 = V3 1.0 1.0 1.0
        | sunElev > 0.0 = V3 1.0 0.75 0.45
        | sunElev > (-0.1) = V3 1.0 0.4 0.2
        | otherwise = V3 0.05 0.05 0.15

      result = let V3 tx ty tz = total; V3 cx cy cz = colorTemp in V3 (tx * cx) (ty * cy) (tz * cz) ^* (1.0 + turbidity * 0.1)
   in result

-- | Generate Sky LUT as raw RGBA16F data.
-- Size: 200x200 pixels.
generateSkyLUT :: SkyParams -> [Word16]
generateSkyLUT params =
  let size = 200
      sunDir = spSunDir params
      -- Reconstruct sun elevation for color temp calculation
      sunElev = sunDir ^. _y

      pixelData = do
        y <- [0 .. size - 1]
        x <- [0 .. size - 1]
        let u = fromIntegral x / 199.0
            v = fromIntegral y / 199.0
            -- Decode UV
            cosGamma = u * 2.0 - 1.0
            cosTheta = v * v
            sinTheta = sqrt (max 0.0 (1.0 - cosTheta * cosTheta))

            -- Canonical view direction
            viewDir = normalize (V3 sinTheta cosTheta 0.0)

            -- Evaluate sky
            radiance = evaluateSky params viewDir

            -- ACES tonemapping (approximate)
            tonemapped = acesApprox radiance

            -- Convert to RGBA16F (simple: scale to 0-1, pack as half-float)
            -- For now, just pack as Word16 from Float
            r = floatToHalf (tonemapped ^. _x)
            g = floatToHalf (tonemapped ^. _y)
            b = floatToHalf (tonemapped ^. _z)
            a = floatToHalf 1.0
        [r, g, b, a]
   in pixelData

-- | Very approximate ACES tonemapping.
acesApprox :: V3 Float -> V3 Float
acesApprox x =
  let a = 2.51
      b = 0.03
      c = 2.43
      d = 0.59
      e = 0.14
      mapped = (x ^* a ^+^ V3 b b b) ^/ (x ^* c ^+^ V3 d d d ^+^ V3 e e e)
      clamp01 v = max 0.0 (min 1.0 v)
   in V3 (clamp01 (mapped ^. _x)) (clamp01 (mapped ^. _y)) (clamp01 (mapped ^. _z))
  where
    (V3 xr xg xb) ^/ (V3 yr yg yb) = V3 (xr / yr) (xg / yg) (xb / yb)

-- | Simple float to half-float conversion (IEEE 754-2008).
floatToHalf :: Float -> Word16
floatToHalf f
  | isInfinite f && f > 0 = 0x7C00
  | isInfinite f && f < 0 = 0xFC00
  | isNaN f = 0x7E00
  | f == 0 = 0
  | otherwise =
      let (mantissa, exponent) = decodeFloat f
          -- Normalize to 1.xxxx
          normalized = abs (fromIntegral mantissa :: Double) / (2 ^^ floatDigits f)
          newExp = exponent + floatDigits f - 1
          -- Convert to half-float exponent bias (15)
          halfExp = newExp + 15
          -- Convert mantissa to 10 bits
          halfMant = round (normalized * 1024) - 1024
       in if halfExp >= 31
            then if f > 0 then 0x7C00 else 0xFC00 -- Inf
            else
              if halfExp <= 0
                then 0 -- Underflow to zero
                else
                  let sign = if f < 0 then 0x8000 else 0
                      expBits = fromIntegral halfExp `shiftL` 10
                      mantBits = fromIntegral halfMant .&. 0x03FF
                   in sign .|. expBits .|. mantBits
  where
    floatDigits :: Float -> Int
    floatDigits _ = 24 -- IEEE 754 single precision
