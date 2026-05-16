{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Graphics.Haskan.Vulkan.Shaders.Compute.IrradianceGen
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
  '[ "irradianceImage" ':-> StorageImage '[DescriptorSet 0, Binding 0] (Properties IntegralCoordinates Float Cube (Just NotDepthImage) NonArrayed SingleSampled Storage (Just (RGBA8 UNorm))),
     "skyGenData" ':-> Uniform '[DescriptorSet 0, Binding 1] SkyGenData,
     "main" ':-> EntryPoint '[LocalSize 8 8 1] Compute
   ]

-- | Number of samples for hemisphere integration.
numSamples :: Code Word32
numSamples = 64

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
  
  let size = 63.0  -- 64 - 1
      u = (fromIntegral gidX :: Code Float) / size * 2.0 - 1.0
      v = (fromIntegral gidY :: Code Float) / size * 2.0 - 1.0
      
      -- Compute normal direction based on face index
      nX = if faceIdx == 0 then 1.0 else (if faceIdx == 1 then (-1.0) else (if faceIdx == 4 then u else (if faceIdx == 5 then (-u) else u)))
      nY = if faceIdx == 2 then 1.0 else (if faceIdx == 3 then (-1.0) else (-v))
      nZ = if faceIdx == 4 then 1.0 else (if faceIdx == 5 then (-1.0) else (if faceIdx == 0 then (-u) else (if faceIdx == 1 then u else v)))
      
      normal = normalise (Vec3 nX nY nZ)
      sunDir = normalise (Vec3 sunDirX sunDirY sunDirZ)
      
      -- Build orthonormal basis around normal
      -- If normal is close to Y axis, use X as reference, otherwise use Y
      nx = view @(Index 0) normal
      ny = view @(Index 1) normal
      nz = view @(Index 2) normal
      
      refX = if abs ny < 0.999 then 0.0 else 1.0
      refY = if abs ny < 0.999 then 1.0 else 0.0
      refZ = 0.0
      
      tangent = normalise (cross (Vec3 refX refY refZ) normal)
      bitangent = cross normal tangent
  
  -- Hemisphere integration loop
  -- Initialize accumulator
  _ <- def @"accR" @RW @Float 0.0
  _ <- def @"accG" @RW @Float 0.0
  _ <- def @"accB" @RW @Float 0.0
  _ <- def @"sampleIdx" @RW @Word32 0
  
  while (get @"sampleIdx" < pure numSamples) do
    sampleIdx <- get @"sampleIdx"
    accR <- get @"accR"
    accG <- get @"accG"
    accB <- get @"accB"
    
    let -- Grid sampling: 8x8 = 64 samples
        gridSize = 8
        i = sampleIdx `mod` gridSize
        j = sampleIdx `div` gridSize
        
        -- Uniform grid over hemisphere
        phi = 2.0 * pi * (fromIntegral i + 0.5) / 8.0
        theta = pi / 2.0 * (fromIntegral j + 0.5) / 8.0
        
        sinTheta = sin theta
        cosTheta = cos theta
        sinPhi = sin phi
        cosPhi = cos phi
        
        -- Sample direction in local coordinates (tangent, normal, bitangent)
        localX = sinTheta * cosPhi
        localY = cosTheta
        localZ = sinTheta * sinPhi
        
        -- Transform to world space
        sampleDir = normalise ((tangent ^* localX) ^+^ (normal ^* localY) ^+^ (bitangent ^* localZ))
        
        -- Evaluate sky in sample direction
        cosGammaDot = dot sampleDir sunDir
        cosGammaClamped = clamp cosGammaDot (-1.0) 1.0
        cosThetaView = max 0.0 (view @(Index 1) sampleDir)
        
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
        
        radianceR = rayleighScatterR + mieScatter + sunDisc
        radianceG = rayleighScatterG + mieScatter + sunDisc
        radianceB = rayleighScatterB + mieScatter + sunDisc
        
        -- Color temperature
        sunElev = view @(Index 1) sunDir
        colorTempR = if sunElev > 0.3 then 1.0 else (if sunElev > 0.0 then 1.0 else (if sunElev > (-0.1) then 1.0 else 0.05))
        colorTempG = if sunElev > 0.3 then 1.0 else (if sunElev > 0.0 then 0.75 else (if sunElev > (-0.1) then 0.4 else 0.05))
        colorTempB = if sunElev > 0.3 then 1.0 else (if sunElev > 0.0 then 0.45 else (if sunElev > (-0.1) then 0.2 else 0.15))
        
        tintedR = radianceR * colorTempR
        tintedG = radianceG * colorTempG
        tintedB = radianceB * colorTempB
        
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
        
        -- Weight by cosine and solid angle
        -- dOmega = sin(theta) * dtheta * dphi = sin(theta) * (pi/2)/8 * 2*pi/8 = sin(theta) * pi^2 / 32
        -- Weight = cos(theta) * dOmega = cos(theta) * sin(theta) * pi^2 / 32
        solidAngleWeight = cosTheta * sinTheta * pi * pi / 32.0
        
        weightedR = clampedR * solidAngleWeight
        weightedG = clampedG * solidAngleWeight
        weightedB = clampedB * solidAngleWeight
    
    put @"accR" (accR + weightedR)
    put @"accG" (accG + weightedG)
    put @"accB" (accB + weightedB)
    put @"sampleIdx" (sampleIdx + 1)
  
  -- Read final accumulated values
  finalAccR <- get @"accR"
  finalAccG <- get @"accG"
  finalAccB <- get @"accB"
  
  let result = Vec4 finalAccR finalAccG finalAccB 1.0
  
  -- Write to cube storage image
  imageWrite @"irradianceImage" (Vec3 gidX gidY faceIdx) result
