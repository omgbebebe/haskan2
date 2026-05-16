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
import FIR.Prim.Image (ImageCoordinateKind(..))
import Math.Linear

-- | Sky generation uniform data (same as SkyLUTGen).
type SkyGenData =
  Struct
    '[ "sunDirX" ':-> Float,
       "sunDirY" ':-> Float,
       "sunDirZ" ':-> Float,
       "sunIntensity" ':-> Float,
       "rayleighR" ':-> Float,
       "rayleighG" ':-> Float,
       "rayleighB" ':-> Float,
       "mieCoeff" ':-> Float,
       "mieG" ':-> Float,
       "turbidity" ':-> Float
     ]

type Defs =
  '[ "radianceImage" ':-> StorageImage '[DescriptorSet 0, Binding 0] (Properties IntegralCoordinates Float Cube (Just NotDepthImage) NonArrayed SingleSampled Storage (Just (RGBA8 UNorm))),
     "skyGenData" ':-> Uniform '[DescriptorSet 0, Binding 1] SkyGenData,
     "main" ':-> EntryPoint '[LocalSize 8 8 1] Compute
   ]

program :: Module Defs
program = Module $ entryPoint @"main" @Compute do
  ~(Vec3 gidX gidY faceIdx) <- get @"gl_GlobalInvocationID"
  
  -- Read sky parameters from uniform buffer
  sunDirX <- use @(Name "skyGenData" :.: Name "sunDirX")
  sunDirY <- use @(Name "skyGenData" :.: Name "sunDirY")
  sunDirZ <- use @(Name "skyGenData" :.: Name "sunDirZ")
  sunIntensity <- use @(Name "skyGenData" :.: Name "sunIntensity")
  rayleighR <- use @(Name "skyGenData" :.: Name "rayleighR")
  rayleighG <- use @(Name "skyGenData" :.: Name "rayleighG")
  rayleighB <- use @(Name "skyGenData" :.: Name "rayleighB")
  mieCoeff <- use @(Name "skyGenData" :.: Name "mieCoeff")
  mieG <- use @(Name "skyGenData" :.: Name "mieG")
  turbidity <- use @(Name "skyGenData" :.: Name "turbidity")
  
  let size = 511.0  -- 512 - 1
      u = (fromIntegral gidX :: Code Float) / size
      v = (fromIntegral gidY :: Code Float) / size
      
      -- Compute direction based on face index
      dirX = if faceIdx == 0 then 1.0 else (if faceIdx == 1 then (-1.0) else (if faceIdx == 4 then u else (if faceIdx == 5 then (-u) else u)))
      dirY = if faceIdx == 2 then 1.0 else (if faceIdx == 3 then (-1.0) else (-v))
      dirZ = if faceIdx == 4 then 1.0 else (if faceIdx == 5 then (-1.0) else (if faceIdx == 0 then (-u) else (if faceIdx == 1 then u else v)))
      
      viewDir = normalise (Vec3 dirX dirY dirZ)
      sunDir = normalise (Vec3 sunDirX sunDirY sunDirZ)
      
      -- Evaluate sky (same as SkyLUTGen)
      cosGammaDot = dot viewDir sunDir
      cosGammaClamped = clamp cosGammaDot (-1.0) 1.0
      cosThetaView = max 0.0 (view @(Index 1) viewDir)
      
      rayleighPhase = (3.0 / (16.0 * pi)) * (1.0 + cosGammaClamped * cosGammaClamped)
      rayleighExp = exp (-0.05 / (cosThetaView + 0.001))
      rayleighScatterR = rayleighR * rayleighPhase * rayleighExp
      rayleighScatterG = rayleighG * rayleighPhase * rayleighExp
      rayleighScatterB = rayleighB * rayleighPhase * rayleighExp
      
      g2 = mieG * mieG
      mieDenom = (1.0 + g2 - 2.0 * mieG * cosGammaClamped) ** 1.5
      miePhase = (1.0 - g2) / (4.0 * pi * mieDenom)
      
      mieExp = exp (-0.1 / (cosThetaView + 0.001))
      mieScatter = mieCoeff * miePhase * mieExp
      
      sunDisc = if cosGammaClamped > 0.9995 then sunIntensity else 0.0
      
      totalR = rayleighScatterR + mieScatter + sunDisc
      totalG = rayleighScatterG + mieScatter + sunDisc
      totalB = rayleighScatterB + mieScatter + sunDisc
      
      sunElev = view @(Index 1) sunDir
      colorTempR = if sunElev > 0.3 then 1.0 else (if sunElev > 0.0 then 1.0 else (if sunElev > (-0.1) then 1.0 else 0.05))
      colorTempG = if sunElev > 0.3 then 1.0 else (if sunElev > 0.0 then 0.75 else (if sunElev > (-0.1) then 0.4 else 0.05))
      colorTempB = if sunElev > 0.3 then 1.0 else (if sunElev > 0.0 then 0.45 else (if sunElev > (-0.1) then 0.2 else 0.15))
      
      tintedR = totalR * colorTempR
      tintedG = totalG * colorTempG
      tintedB = totalB * colorTempB
      
      turbidityScale = 1.0 + turbidity * 0.1
      scaledR = tintedR * turbidityScale
      scaledG = tintedG * turbidityScale
      scaledB = tintedB * turbidityScale
      
      -- ACES tonemapping
      acesR = (scaledR * (2.51 * scaledR + 0.03)) / (scaledR * (2.43 * scaledR + 0.59) + 0.14)
      acesG = (scaledG * (2.51 * scaledG + 0.03)) / (scaledG * (2.43 * scaledG + 0.59) + 0.14)
      acesB = (scaledB * (2.51 * scaledB + 0.03)) / (scaledB * (2.43 * scaledB + 0.59) + 0.14)
      
      clampedR = clamp acesR 0.0 1.0
      clampedG = clamp acesG 0.0 1.0
      clampedB = clamp acesB 0.0 1.0
      
      result = Vec4 clampedR clampedG clampedB 1.0
  
  -- Write to cube storage image (Vec3 coordinates: x, y, face)
  imageWrite @"radianceImage" (Vec3 gidX gidY faceIdx) result
