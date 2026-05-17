{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Graphics.Haskan.Vulkan.Shaders.Compute.RadianceGen
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
  '[ "radianceImage" ':-> StorageImage '[DescriptorSet 0, Binding 0] (Properties IntegralCoordinates Float Cube (Just NotDepthImage) NonArrayed SingleSampled Storage (Just (RGBA16 F))),
     "skyGenData" ':-> Uniform '[DescriptorSet 0, Binding 1] SkyGenData,
     "main" ':-> EntryPoint '[LocalSize 8 8 1] Compute
   ]

program :: Module Defs
program = Module $ entryPoint @"main" @Compute do
  ~(Vec3 gidX gidY faceIdx) <- get @"gl_GlobalInvocationID"

  -- Read sun direction and HW coefficients from uniform buffer
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

  let size = 511.0 -- 512 - 1
      u = (fromIntegral gidX :: Code Float) / size
      v = (fromIntegral gidY :: Code Float) / size
      s = u * 2.0 - 1.0
      t = v * 2.0 - 1.0

      -- Compute direction based on face index (Vulkan cubemap layer mapping)
      dirX = if faceIdx == 0 then 1.0 else (if faceIdx == 1 then (-1.0) else (if faceIdx == 4 then (-s) else s))
      dirY = if faceIdx == 2 then 1.0 else (if faceIdx == 3 then (-1.0) else (-t))
      dirZ = if faceIdx == 4 then 1.0 else (if faceIdx == 5 then (-1.0) else (if faceIdx == 0 then s else (if faceIdx == 1 then (-s) else (if faceIdx == 2 then (-t) else t))))

      viewDir = normalise (Vec3 dirX dirY dirZ)
      sunDir = normalise (Vec3 sunDirX sunDirY sunDirZ)

      -- Hosek-Wilkie sky radiance evaluation
      cosTheta = max 0.0001 (abs (view @(Index 1) viewDir))
      cosGamma = clamp (dot viewDir sunDir) (-1.0) 1.0
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

      -- Soft sun disc
      sunDisc = sunIntensity * smoothstep 0.999 1.0 cosGamma

      resultR = max 0.0 (radR + sunDisc)
      resultG = max 0.0 (radG + sunDisc)
      resultB = max 0.0 (radB + sunDisc)

      result = Vec4 resultR resultG resultB 1.0

  -- Write to cube storage image (Vec3 coordinates: x, y, face)
  imageWrite @"radianceImage" (Vec3 gidX gidY faceIdx) result
