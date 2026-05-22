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
              ( Properties
                  IntegralCoordinates
                  Float
                  ThreeD
                  (Just NotDepthImage)
                  NonArrayed
                  SingleSampled
                  Storage
                  (Just (RGBA16 F))
              ),
     "cloudNoise"
       ':-> Texture3D
              '[Binding 1, DescriptorSet 0]
              (RGBA8 UNorm),
     "apUniforms"
       ':-> Uniform
              '[Binding 2, DescriptorSet 0]
              APVolumeUniforms,
     "weather_map"
       ':-> Texture2D
              '[Binding 3, DescriptorSet 0]
              (RGBA8 UNorm),
     "main" ':-> EntryPoint '[LocalSize 4 4 4] Compute
   ]

-- Phase 2: AP Volume compute shader with raymarched scattering.
-- Density model synced with Clouds.hs: weather-map driven, domain warped,
-- parametric height profile, coverage remapping, and detail erosion.
program :: Module Defs
program = Module $ entryPoint @"main" @Compute do
  -- Global invocation ID = voxel coordinate
  ~(Vec3 vx vy vz) <- get @"gl_GlobalInvocationID"

  -- Read uniform data
  uniforms <- get @"apUniforms"
  let camPos = view @(Name "cameraPos") uniforms
      vp0 = view @(Name "invViewProj0") uniforms
      vp1 = view @(Name "invViewProj1") uniforms
      vp2 = view @(Name "invViewProj2") uniforms
      vp3 = view @(Name "invViewProj3") uniforms
      sunDir = view @(Name "sunDir") uniforms
      sunColor = view @(Name "sunColor") uniforms
      cloudBase = view @(Name "cloudBase") uniforms
      cloudTop = view @(Name "cloudTop") uniforms
      time = view @(Name "time") uniforms
      near = view @(Name "near") uniforms
      far = view @(Name "far") uniforms
      windDirX = view @(Name "windDirX") uniforms
      windDirZ = view @(Name "windDirZ") uniforms
      cloudAbsorption = view @(Name "cloudAbsorption") uniforms
      weatherCoverageScale = view @(Name "weatherCoverageScale") uniforms
      weatherTypeBias = view @(Name "weatherTypeBias") uniforms
      stormIntensity = view @(Name "stormIntensity") uniforms
      weatherAnimSpeed = view @(Name "weatherAnimSpeed") uniforms
      cloudDetail = view @(Name "cloudDetail") uniforms

  -- Map voxel to screen UV and exponential depth
  let u = (fromIntegral vx + 0.5) / 64.0
      v = (fromIntegral vy + 0.5) / 32.0
      t = fromIntegral vz / 64.0
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
      worldFar =
        Vec3
          (worldFarX / worldFarW)
          (worldFarY / worldFarW)
          (worldFarZ / worldFarW)
      rayDir = normalise (worldFar ^-^ camPos)

  -- World position at this depth
  let worldPos = camPos ^+^ rayDir ^* depth
      ~(Vec3 wx wy wz) = worldPos

  -- Cloud thickness and normalized height
  let cloudThickness = cloudTop - cloudBase
      h = (wy - cloudBase) / cloudThickness

  -- Sample weather map at world XZ (matching Clouds shader)
  let weatherScale = 0.00005
      weatherWindOffsetX = time * 0.002 * windDirX * weatherAnimSpeed
      weatherWindOffsetZ = time * 0.002 * windDirZ * weatherAnimSpeed
      weatherUV = Vec2 ((wx - weatherWindOffsetX) * weatherScale) ((wz - weatherWindOffsetZ) * weatherScale)

  ~(Vec4 weatherR weatherG weatherB _weatherA) <- use @(ImageTexel "weather_map") (LOD (0.0 :: Code Float) NilOps) weatherUV

  let coverage = clamp (weatherR * weatherCoverageScale) 0.0 1.0
      cloudType = clamp (weatherG + weatherTypeBias) 0.0 1.0
      stormDarkness = weatherB * stormIntensity

  -- Parametric height profile (matching Clouds shader)
  let heightScale = max 0.3 (coverage ** 0.25)
      hPct = clamp (h / heightScale) 0.0 1.0
      baseCurve = mix 0.4 0.8 cloudType
      topDecay = mix 2.0 4.0 cloudType
      heightProfile = (hPct ** baseCurve) * exp (-hPct * topDecay)

  -- Domain warping (matching Clouds shader)
  let noiseScale = specConstant @0 @Float 0.0003
      windSpeed = 0.05
      windOffsetX = time * windSpeed * windDirX
      windOffsetZ = time * windSpeed * windDirZ
      warpAmpUV1 = 500.0 * noiseScale
      warpAmpUV2 = 250.0 * noiseScale

      bux = wx * noiseScale - windOffsetX
      buy = wy * noiseScale
      buz = wz * noiseScale - windOffsetZ

      -- Tile-periodic UV for warp input: fract ensures seamless tiling
      fux = fract bux
      fuy = fract buy
      fuz = fract buz

      wx1 = sin (fuy * 6.2831853 * 3.0 + fuz * 6.2831853 * 2.0) * warpAmpUV1
      wy1 = cos (fux * 6.2831853 * 3.0 + fuz * 6.2831853 * 1.0) * warpAmpUV1
      wz1 = sin (fuz * 6.2831853 * 2.0 + fux * 6.2831853 * 3.0) * warpAmpUV1
      wx2 = sin (fuy * 6.2831853 * 5.0 + fux * 6.2831853 * 4.0) * warpAmpUV2
      wy2 = cos (fuz * 6.2831853 * 4.0 + fuy * 6.2831853 * 3.0) * warpAmpUV2
      wz2 = sin (fux * 6.2831853 * 6.0 + fuy * 6.2831853 * 5.0) * warpAmpUV2

      wx_warp = wx1 + wx2
      wy_warp = wy1 + wy2
      wz_warp = wz1 + wz2

      sx = bux + wx_warp
      sy = buy + wy_warp
      sz = buz + wz_warp

  ~(Vec4 noiseR noiseG noiseB noiseA) <- use @(ImageTexel "cloudNoise") (LOD (0.0 :: Code Float) NilOps) (Vec3 sx sy sz)

  -- Density composition matching Clouds shader
  let detailFBM = noiseG * 0.625 + noiseB * 0.25 + noiseA * 0.125
      shapedNoise = max 0.0 (noiseR - detailFBM * cloudDetail)
      remappedNoise = max 0.0 (shapedNoise - (1.0 - coverage))
      density = remappedNoise * heightProfile

  -- Light march: single sample toward sun for self-shadowing
  let lightPos = worldPos ^+^ sunDir ^* (cloudThickness * 0.5)
      ~(Vec3 lpx lpy lpz) = lightPos
      lh = (lpy - cloudBase) / cloudThickness
      lhPct = clamp (lh / heightScale) 0.0 1.0
      lheightProfile = (lhPct ** baseCurve) * exp (-lhPct * topDecay)

      -- Simplified single-octave warp for light sample
      lbux = lpx * noiseScale - windOffsetX
      lbuy = lpy * noiseScale
      lbuz = lpz * noiseScale - windOffsetZ
      lfux = fract lbux
      lfuy = fract lbuy
      lfuz = fract lbuz
      lwx = sin (lfuy * 6.2831853 * 3.0 + lfuz * 6.2831853 * 2.0) * warpAmpUV1
      lwy = cos (lfux * 6.2831853 * 3.0 + lfuz * 6.2831853 * 1.0) * warpAmpUV1
      lwz = sin (lfuz * 6.2831853 * 2.0 + lfux * 6.2831853 * 3.0) * warpAmpUV1
      lsx = lbux + lwx
      lsy = lbuy + lwy
      lsz = lbuz + lwz

  ~(Vec4 lnoiseR lnoiseG lnoiseB lnoiseA) <- use @(ImageTexel "cloudNoise") (LOD (0.0 :: Code Float) NilOps) (Vec3 lsx lsy lsz)

  let ldetailFBM = lnoiseG * 0.625 + lnoiseB * 0.25 + lnoiseA * 0.125
      lshapedNoise = max 0.0 (lnoiseR - ldetailFBM * cloudDetail)
      lremappedNoise = max 0.0 (lshapedNoise - (1.0 - coverage))
      ldensity = lremappedNoise * lheightProfile
      -- Beer-Lambert transmittance along light path
      lightTrans = exp (-ldensity * cloudThickness * 0.5 * cloudAbsorption)

  -- Phase function (Henyey-Greenstein approximation)
  let cosTheta = rayDir ^.^ sunDir
      g = specConstant @1 @Float 0.76
      g2 = g * g
      hgDenom = (1.0 + g2 - 2.0 * g * cosTheta) ** 1.5
      phase = (1.0 - g2) / (4.0 * 3.14159265 * hgDenom)

  -- Scattering with cloudAbsorption (not hardcoded 0.1)
  let extinction = density * cloudAbsorption
      inScatter = sunColor ^* (lightTrans * phase * extinction)
      -- Absorption (stored in alpha)
      transmittance = exp (-extinction)

  -- Store: RGB = in-scattered light, A = 1 - transmittance (optical depth)
  let result =
        Vec4
          (view @(Index 0) inScatter)
          (view @(Index 1) inScatter)
          (view @(Index 2) inScatter)
          (1.0 - transmittance)

  imageWrite @"apImage" (Vec3 vx vy vz) result
  where
    dot :: Code (V 4 Float) -> Code (V 4 Float) -> Code Float
    dot a b =
      view @(Index 0) a
        * view @(Index 0) b
        + view @(Index 1) a
        * view @(Index 1) b
        + view @(Index 2) a
        * view @(Index 2) b
        + view @(Index 3) a
        * view @(Index 3) b
