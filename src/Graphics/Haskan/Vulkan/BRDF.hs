{-# LANGUAGE BangPatterns #-}

module Graphics.Haskan.Vulkan.BRDF
  ( generateBRDFLUT,
  )
where

import Data.Vector.Storable (Vector)
import Data.Vector.Storable qualified as Vector
import Data.Word (Word8)
import Linear (V2 (..), V3 (..), dot, normalize, (*^))
import System.Random (mkStdGen, randoms)

-- | Generate a 256x256 BRDF LUT for split-sum approximation.
-- U = NdotV, V = roughness.
-- Returns RGBA8 pixel data (R=scale, G=bias, B=0, A=255).
generateBRDFLUT :: Int -> Int -> Vector Word8
generateBRDFLUT width height =
  Vector.fromList $
    concat
      [ let u = (fromIntegral x + 0.5) / fromIntegral width
            v = (fromIntegral y + 0.5) / fromIntegral height
            (scale, bias) = integrateBRDF u v 128
            r = clamp01 scale
            g = clamp01 bias
         in [r, g, 0, 255]
      | y <- [0 .. height - 1],
        x <- [0 .. width - 1]
      ]
  where
    clamp01 v = round (max 0.0 (min 1.0 v) * 255.0) :: Word8

-- | Monte Carlo integration of the BRDF for given NdotV and roughness.
integrateBRDF :: Float -> Float -> Int -> (Float, Float)
integrateBRDF ndotv roughness samples =
  let !(!scaleSum, !biasSum) = go samples 0.0 0.0 (randoms (mkStdGen 42))
      scale = scaleSum / fromIntegral samples
      bias = biasSum / fromIntegral samples
   in (scale, bias)
  where
    nVec = V3 0 0 1
    vVec = V3 (sqrt (1 - ndotv * ndotv)) 0 ndotv
    piVal = 3.14159265

    go 0 !s !b _ = (s, b)
    go n !s !b (r1 : r2 : rs) =
      let -- Importance sample GGX distribution
          a = roughness * roughness
          phi = 2 * piVal * r1
          cosTheta = sqrt ((1 - r2) / (1 + (a * a - 1) * r2))
          sinTheta = sqrt (1 - cosTheta * cosTheta)
          -- Half-vector in tangent space
          h = normalize (V3 (sinTheta * cos phi) (sinTheta * sin phi) cosTheta)
          -- Light direction
          l = normalize ((2 * dot vVec h) *^ h - vVec)
          ndotl = max 0 (dot nVec l)
          ndoth = max 0 (dot nVec h)
          vdoth = max 0 (dot vVec h)
          -- GGX distribution
          denom = ndoth * ndoth * (a * a - 1) + 1
          d = (a * a) / (piVal * denom * denom)
          -- Geometry term (Smith GGX)
          k = (a + 1) * (a + 1) / 8
          g1v = ndotv / (ndotv * (1 - k) + k)
          g1l = ndotl / (ndotl * (1 - k) + k)
          g = g1v * g1l
          -- PDF (not needed for weight; G_Vis already cancels it)
          pdf = d * ndoth / (4 * vdoth)
          -- Visibility term: G_Vis = G*VdotH/(NdotH*NdotV)
          -- This already equals BRDF*NdotL/PDF, so no extra weight needed
          vis =
            if ndotl > 0 && ndotv > 0
              then g * vdoth / (ndoth * ndotv)
              else 0
          -- Fresnel terms
          fc = (1 - vdoth) ^ (5 :: Int)
          scale' = vis * (1 - fc)
          bias' = vis * fc
       in go (n - 1) (s + scale') (b + bias') rs
    go _ _ _ _ = error "insufficient random numbers"
