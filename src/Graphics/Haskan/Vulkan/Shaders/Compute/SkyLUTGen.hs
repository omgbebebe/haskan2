{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Graphics.Haskan.Vulkan.Shaders.Compute.SkyLUTGen
  ( Defs,
    program,
  )
where

import FIR
import FIR.Prim.Image (ImageCoordinateKind (..))
import Math.Linear

-- | Sky generation uniform data (Hosek-Wilkie model).
type SkyGenData =
  Struct
    '[ "sunDirX" ':-> Float,
       "sunDirY" ':-> Float,
       "sunDirZ" ':-> Float,
       "sunIntensity" ':-> Float,
       "hwAR" ':-> Float,
       "hwAG" ':-> Float,
       "hwAB" ':-> Float,
       "hwBR" ':-> Float,
       "hwBG" ':-> Float,
       "hwBB" ':-> Float,
       "hwCR" ':-> Float,
       "hwCG" ':-> Float,
       "hwCB" ':-> Float,
       "hwDR" ':-> Float,
       "hwDG" ':-> Float,
       "hwDB" ':-> Float,
       "hwER" ':-> Float,
       "hwEG" ':-> Float,
       "hwEB" ':-> Float,
       "hwFR" ':-> Float,
       "hwFG" ':-> Float,
       "hwFB" ':-> Float,
       "hwGR" ':-> Float,
       "hwGG" ':-> Float,
       "hwGB" ':-> Float,
       "hwHR" ':-> Float,
       "hwHG" ':-> Float,
       "hwHB" ':-> Float,
       "hwIR" ':-> Float,
       "hwIG" ':-> Float,
       "hwIB" ':-> Float
     ]

type Defs =
  '[ "skyLutImage" ':-> StorageImage '[DescriptorSet 0, Binding 0] (Properties IntegralCoordinates Float TwoD (Just NotDepthImage) NonArrayed SingleSampled Storage (Just (RGBA16 F))),
     "skyGenData" ':-> Uniform '[DescriptorSet 0, Binding 1] SkyGenData,
     "main" ':-> EntryPoint '[LocalSize 8 8 1] Compute
   ]

program :: Module Defs
program = Module $ entryPoint @"main" @Compute do
  ~(Vec3 gidX gidY _) <- get @"gl_GlobalInvocationID"

  sunDirX <- use @(Name "skyGenData" :.: Name "sunDirX")
  sunDirY <- use @(Name "skyGenData" :.: Name "sunDirY")
  sunDirZ <- use @(Name "skyGenData" :.: Name "sunDirZ")
  sunIntensity <- use @(Name "skyGenData" :.: Name "sunIntensity")

  ar <- use @(Name "skyGenData" :.: Name "hwAR")
  ag <- use @(Name "skyGenData" :.: Name "hwAG")
  ab <- use @(Name "skyGenData" :.: Name "hwAB")
  br <- use @(Name "skyGenData" :.: Name "hwBR")
  bg <- use @(Name "skyGenData" :.: Name "hwBG")
  bb <- use @(Name "skyGenData" :.: Name "hwBB")
  cr <- use @(Name "skyGenData" :.: Name "hwCR")
  cg <- use @(Name "skyGenData" :.: Name "hwCG")
  cb <- use @(Name "skyGenData" :.: Name "hwCB")
  dr <- use @(Name "skyGenData" :.: Name "hwDR")
  dg <- use @(Name "skyGenData" :.: Name "hwDG")
  db <- use @(Name "skyGenData" :.: Name "hwDB")
  er <- use @(Name "skyGenData" :.: Name "hwER")
  eg <- use @(Name "skyGenData" :.: Name "hwEG")
  eb <- use @(Name "skyGenData" :.: Name "hwEB")
  fr <- use @(Name "skyGenData" :.: Name "hwFR")
  fg <- use @(Name "skyGenData" :.: Name "hwFG")
  fb <- use @(Name "skyGenData" :.: Name "hwFB")
  gr <- use @(Name "skyGenData" :.: Name "hwGR")
  gg <- use @(Name "skyGenData" :.: Name "hwGG")
  gb <- use @(Name "skyGenData" :.: Name "hwGB")
  hr <- use @(Name "skyGenData" :.: Name "hwHR")
  hg <- use @(Name "skyGenData" :.: Name "hwHG")
  hb <- use @(Name "skyGenData" :.: Name "hwHB")
  ir <- use @(Name "skyGenData" :.: Name "hwIR")
  ig <- use @(Name "skyGenData" :.: Name "hwIG")
  ib <- use @(Name "skyGenData" :.: Name "hwIB")

  -- Decode invocation ID to UV coordinates
  let u = (fromIntegral gidX :: Code Float) / 199.0
      v = (fromIntegral gidY :: Code Float) / 199.0
      cosTheta = max 0.0001 (v * v)

      -- View direction from LUT coordinates
      sunDir = normalise (Vec3 sunDirX sunDirY sunDirZ)
      cosGamma = clamp u (-1.0) 1.0
      gammaSq = cosGamma * cosGamma
      sqrtCosTheta = sqrt cosTheta

      -- F1 = (1 + A * exp(B / (cosTheta + 0.01)))
      f1R = 1.0 + ar * exp (br / (cosTheta + 0.01))
      f1G = 1.0 + ag * exp (bg / (cosTheta + 0.01))
      f1B = 1.0 + ab * exp (bb / (cosTheta + 0.01))

      -- Mie chi: (1 + cos^2) / (1 + I^2 - 2*I*cos)^1.5
      iSqR = ir * ir
      iSqG = ig * ig
      iSqB = ib * ib
      chiR = (1.0 + gammaSq) / ((1.0 + iSqR - 2.0 * ir * cosGamma) ** 1.5)
      chiG = (1.0 + gammaSq) / ((1.0 + iSqG - 2.0 * ig * cosGamma) ** 1.5)
      chiB = (1.0 + gammaSq) / ((1.0 + iSqB - 2.0 * ib * cosGamma) ** 1.5)

      -- F2 = C + D*exp(E*gamma) + F*cos^2(gamma) + G*chi + H*sqrt(cosTheta)
      f2R = cr + dr * exp (er * cosGamma) + fr * gammaSq + gr * chiR + hr * sqrtCosTheta
      f2G = cg + dg * exp (eg * cosGamma) + fg * gammaSq + gg * chiG + hg * sqrtCosTheta
      f2B = cb + db * exp (eb * cosGamma) + fb * gammaSq + gb * chiB + hb * sqrtCosTheta

      -- Total radiance: F1 * F2
      radR = f1R * f2R
      radG = f1G * f2G
      radB = f1B * f2B

      sunDisc = sunIntensity * smoothstep 0.999 1.0 cosGamma

      resultR = max 0.0 (radR + sunDisc)
      resultG = max 0.0 (radG + sunDisc)
      resultB = max 0.0 (radB + sunDisc)

      result = Vec4 resultR resultG resultB 1.0

  -- Write to storage image
  imageWrite @"skyLutImage" (Vec2 gidX gidY) result
