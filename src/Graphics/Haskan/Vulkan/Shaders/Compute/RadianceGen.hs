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
  '[ "radianceImage" ':-> StorageImage '[DescriptorSet 0, Binding 0] (Properties IntegralCoordinates Float Cube (Just NotDepthImage) NonArrayed SingleSampled Storage (Just (RGBA16 F))),
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
      s = u * 2.0 - 1.0
      t = v * 2.0 - 1.0
      
      -- Compute direction based on face index (Vulkan cubemap layer mapping)
      dirX = if faceIdx == 0 then 1.0 else (if faceIdx == 1 then (-1.0) else (if faceIdx == 4 then (-s) else s))
      dirY = if faceIdx == 2 then 1.0 else (if faceIdx == 3 then (-1.0) else (-t))
      dirZ = if faceIdx == 4 then 1.0 else (if faceIdx == 5 then (-1.0) else (if faceIdx == 0 then s else (if faceIdx == 1 then (-s) else (if faceIdx == 2 then (-t) else t))))
      
      viewDir = normalise (Vec3 dirX dirY dirZ)
      sunDir = normalise (Vec3 sunDirX sunDirY sunDirZ)
      
      -- Evaluate sky with fixed scattering model (HDR, no tonemapping)
      cosGammaDot = dot viewDir sunDir
      cosGammaClamped = clamp cosGammaDot (-1.0) 1.0
      cosThetaView = abs (view @(Index 1) viewDir)
      
      -- Rayleigh phase function
      rayleighPhase = (3.0 / (16.0 * pi)) * (1.0 + cosGammaClamped * cosGammaClamped)
      
      -- Optical depth model with larger epsilon for smooth horizon
      rayleighOD = 0.3
      mieOD = 0.1
      rayleighTrans = exp (-rayleighOD / (cosThetaView + 0.05))
      mieTrans = exp (-mieOD / (cosThetaView + 0.05))
      
      -- In-scattering (scale ~100x to bring into visible HDR range)
      rayleighScatterR = rayleighR * rayleighPhase * (1.0 - rayleighTrans) * 100.0
      rayleighScatterG = rayleighG * rayleighPhase * (1.0 - rayleighTrans) * 100.0
      rayleighScatterB = rayleighB * rayleighPhase * (1.0 - rayleighTrans) * 100.0
      
      -- Mie phase (Henyey-Greenstein)
      g2 = mieG * mieG
      mieDenom = (1.0 + g2 - 2.0 * mieG * cosGammaClamped) ** 1.5
      miePhase = (1.0 - g2) / (4.0 * pi * mieDenom)
      mieScatter = mieCoeff * miePhase * (1.0 - mieTrans) * 100.0
      
      -- Soft sun disc with smoothstep to avoid banding
      sunDisc = sunIntensity * smoothstep 0.999 1.0 cosGammaClamped
      
      totalR = rayleighScatterR + mieScatter + sunDisc
      totalG = rayleighScatterG + mieScatter + sunDisc
      totalB = rayleighScatterB + mieScatter + sunDisc
      
      sunElev = view @(Index 1) sunDir
      sunElevClamped = clamp sunElev (-0.1) 1.0

      -- Warm tint: strong at horizon (low sun), fading to neutral at zenith
      -- R always 1.0, G/B decrease as sun drops — sunset orange/red
      warmth = clamp (sunElevClamped / 0.3) 0.0 1.0
      colorTempR = 1.0
      colorTempG = 0.45 + 0.55 * warmth
      colorTempB = 0.2 + 0.8 * warmth

      tintedR = totalR * colorTempR
      tintedG = totalG * colorTempG
      tintedB = totalB * colorTempB

      turbidityScale = 1.0 + turbidity * 0.1
      
      result = Vec4 (tintedR * turbidityScale) (tintedG * turbidityScale) (tintedB * turbidityScale) 1.0
  
  -- Write to cube storage image (Vec3 coordinates: x, y, face)
  imageWrite @"radianceImage" (Vec3 gidX gidY faceIdx) result
