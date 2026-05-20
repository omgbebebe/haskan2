{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Graphics.Haskan.Vulkan.Shaders.Compute.APVolume
  ( Defs,
    program,
  )
where

import FIR
import FIR.Prim.Image (ImageCoordinateKind (..))
import Graphics.Haskan.Vulkan.Shaders.Compute.APVolumeUniforms (APVolumeUniforms)
import Math.Linear

-- | AP volume compute shader bindings.
-- Writes to a 3D RGBA16F storage image.
type Defs =
  '[ "apImage"
       ':-> StorageImage
             '[DescriptorSet 0, Binding 0]
             (Properties
                IntegralCoordinates
                Float
                ThreeD
                (Just NotDepthImage)
                NonArrayed
                SingleSampled
                Storage
                (Just (RGBA16 F))),
     "cloudNoise"
       ':-> Texture3D
             '[Binding 1, DescriptorSet 0]
             (RGBA8 UNorm),
     "apUniforms"
       ':-> Uniform
             '[Binding 2, DescriptorSet 0]
             APVolumeUniforms,
     "main" ':-> EntryPoint '[LocalSize 4 4 4] Compute
   ]

-- Phase 2: AP Volume compute shader with raymarched scattering.
program :: Module Defs
program = Module $ entryPoint @"main" @Compute do
  -- Global invocation ID = voxel coordinate
  ~(Vec3 vx vy vz) <- get @"gl_GlobalInvocationID"

  -- Read uniform data
  uniforms <- get @"apUniforms"
  let camPos     = view @(Name "cameraPos")   uniforms
      vp0        = view @(Name "invViewProj0") uniforms
      vp1        = view @(Name "invViewProj1") uniforms
      vp2        = view @(Name "invViewProj2") uniforms
      vp3        = view @(Name "invViewProj3") uniforms
      sunDir     = view @(Name "sunDir")      uniforms
      sunColor   = view @(Name "sunColor")    uniforms
      cloudBase  = view @(Name "cloudBase")   uniforms
      cloudTop   = view @(Name "cloudTop")    uniforms
      time       = view @(Name "time")        uniforms
      near       = view @(Name "near")        uniforms
      far        = view @(Name "far")         uniforms

  -- Map voxel to screen UV and exponential depth
  let u    = (fromIntegral vx + 0.5) / 64.0
      v    = (fromIntegral vy + 0.5) / 32.0
      t    = fromIntegral vz / 64.0
      -- Exponential depth distribution for more detail near camera
      depth = near * ((far / near) ** t)
      ndcX = u * 2.0 - 1.0
      ndcY = v * 2.0 - 1.0

  -- Unproject far-plane point to get ray direction
  let clipFar = Vec4 ndcX ndcY 1.0 1.0
      -- Manual mat4 * vec4 (column-vector convention)
      worldFarX = dot vp0 clipFar
      worldFarY = dot vp1 clipFar
      worldFarZ = dot vp2 clipFar
      worldFarW = dot vp3 clipFar
      worldFar  = Vec3 (worldFarX / worldFarW)
                       (worldFarY / worldFarW)
                       (worldFarZ / worldFarW)
      rayDir    = normalise (worldFar ^-^ camPos)

  -- World position at this depth
  let worldPos = camPos ^+^ rayDir ^* depth
      ~(Vec3 wx wy wz) = worldPos

  -- Sample 3D cloud noise for density
  let cloudThickness = cloudTop - cloudBase
      h = (wy - cloudBase) / cloudThickness
      -- Height mask: smooth fade at bottom and top
      heightMask = smoothstep 0.0 0.15 h * (1.0 - smoothstep 0.85 1.0 h)
      -- Noise sampling parameters
      noiseScale = 0.0003
      windSpeed = 0.05
      windOffsetX = time * windSpeed
      windOffsetZ = time * windSpeed
      sx = (wx - windOffsetX) * noiseScale
      sy = wy * noiseScale
      sz = (wz - windOffsetZ) * noiseScale

  ~(Vec4 noiseR noiseG noiseB noiseA) <- use @(ImageTexel "cloudNoise") (LOD (0.0 :: Code Float) NilOps) (Vec3 sx sy sz)

  -- Density composition (simplified from Clouds shader)
  let cloudDetail = 0.6
      density = max 0.0 (noiseR * (1.0 - cloudDetail * (noiseG * 0.3 + noiseB * 0.15 + noiseA * 0.075)) - 0.3)
                * heightMask * 4.0

  -- Light march: single sample toward sun for self-shadowing
  let lightPos = worldPos ^+^ sunDir ^* (cloudThickness * 0.5)
      ~(Vec3 lpx lpy lpz) = lightPos
      lh = (lpy - cloudBase) / cloudThickness
      lheightMask = smoothstep 0.0 0.15 lh * (1.0 - smoothstep 0.85 1.0 lh)
      lsx = (lpx - windOffsetX) * noiseScale
      lsy = lpy * noiseScale
      lsz = (lpz - windOffsetZ) * noiseScale

  ~(Vec4 lnoiseR lnoiseG lnoiseB lnoiseA) <- use @(ImageTexel "cloudNoise") (LOD (0.0 :: Code Float) NilOps) (Vec3 lsx lsy lsz)

  let ldensity = max 0.0 (lnoiseR * (1.0 - cloudDetail * (lnoiseG * 0.3 + lnoiseB * 0.15 + lnoiseA * 0.075)) - 0.3)
                 * lheightMask * 4.0
      -- Beer-Lambert transmittance along light path
      lightTrans = exp (-ldensity * cloudThickness * 0.5)

  -- Phase function (Henyey-Greenstein approximation)
  let cosTheta = rayDir ^.^ sunDir
      g = 0.76
      g2 = g * g
      hgDenom = (1.0 + g2 - 2.0 * g * cosTheta) ** 1.5
      phase = (1.0 - g2) / (4.0 * 3.14159265 * hgDenom)

  -- Scattering
  let scatterCoeff = 0.1  -- scattering coefficient
      extinction = density * scatterCoeff
      inScatter = sunColor ^* (lightTrans * phase * extinction)
      -- Absorption (stored in alpha)
      transmittance = exp (-extinction)

  -- Store: RGB = in-scattered light, A = 1 - transmittance (optical depth)
  let result = Vec4 (view @(Index 0) inScatter)
                    (view @(Index 1) inScatter)
                    (view @(Index 2) inScatter)
                    (1.0 - transmittance)

  imageWrite @"apImage" (Vec3 vx vy vz) result
  where
    dot :: Code (V 4 Float) -> Code (V 4 Float) -> Code Float
    dot a b = view @(Index 0) a * view @(Index 0) b
            + view @(Index 1) a * view @(Index 1) b
            + view @(Index 2) a * view @(Index 2) b
            + view @(Index 3) a * view @(Index 3) b
