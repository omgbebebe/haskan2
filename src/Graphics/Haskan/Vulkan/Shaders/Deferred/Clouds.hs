{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -fno-warn-partial-type-signatures #-}

-- |
-- Module: Graphics.Haskan.Vulkan.Shaders.Deferred.Clouds
--
-- === Deferred Rendering Pipeline — Stage 3: Volumetric Cloud Pass ===
--
-- This module implements a quarter-resolution volumetric cloud rendering pass
-- that ray-marches through a procedural cloud volume and composites with the skybox.
-- Output is blended with history for temporal anti-aliasing.
--
-- === Vertex Shader (Fullscreen Triangle) ===
--
-- **Inputs:**
--   * gl_VertexIndex: implicit vertex index (0, 1, 2)
--
-- **Push Constants:**
--   * cameraPos: V3 Float — world-space camera position (minimal, 12 bytes)
--
-- **Uniform Buffer (Binding 4, DS0):**
--   * cloud_frame_data: CloudFrameData struct containing:
--     - cameraX/Y/Z      : Float — world-space camera position
--     - ray0/ray1/ray2   : V3 Float — per-corner frustum rays
--     - sunDir           : V3 Float — normalized sun direction
--     - cloudHeight      : Float — cloud layer bottom Y coordinate
--     - time             : Float — animation time
--     - blendFactor      : Float — temporal blend weight
--     - windDirX/Z       : Float — wind direction for noise animation
--     - prevViewProj0-3  : V4 Float — previous frame view-projection matrix rows
--     - cloudCoverage    : Float — coverage threshold
--     - cloudDetail      : Float — detail strength
--     - cloudAbsorption  : Float — light absorption coefficient
--
-- **Algorithm:** Same fullscreen triangle as Lighting pass.
--
-- **Outputs:**
--   * out_uv  (Location 0): V2 Float — screen-space UVs
--   * out_ray (Location 1): V3 Float — world-space ray direction
--
-- === Fragment Shader ===
--
-- **Inputs:**
--   * in_uv  (Location 0): V2 Float — interpolated screen UV
--   * in_ray (Location 1): V3 Float — interpolated world ray direction
--
-- **Textures:**
--   * env_map      (Binding 0, DS0): TextureCube RGBA8 UNorm
--     - Skybox environment map for background color
--   * cloud_noise  (Binding 1, DS0): Texture3D RGBA8 UNorm
--     - 3D noise texture (256^3) with 4 octaves:
--       - R = Perlin-Worley blend (macro shape)
--       - G = Worley 8^3  (medium erosion)
--       - B = Worley 16^3 (high-frequency detail)
--       - A = Worley 32^3 (micro-detail)
--   * cloud_history(Binding 2, DS0): Texture2D RGBA16 F
--     - Previous frame cloud result for temporal accumulation
--
-- lgorithm — Volumetric Ray Marching:**
--
-- **Ray Setup:**
-- - dir = normalize(rayDir)
-- - cloudThickness = 800.0
-- - cloudTop = cloudBottom + cloudThickness
-- - Dual-plane slab intersection for camera below/inside/above cloud layer
-- - stepSize = totalRayLength / 24.0
--
-- **Dithered Entry Point:**
-- - hash = fract(sin(uv.x*12.9898 + uv.y*78.233) * 43758.5453)
-- - offset = hash * stepSize
-- - tEntry = tNear + offset
--
-- **24-Step Dynamic Ray March (loop with early exit):**
-- Mutable accumulators: step, rayPos, transmittance, accR/G/B.
-- Loop breaks when step >= 24 or transmittance < 0.01.
--
-- Per step:
--
-- a. **Domain Warping (Curl-like displacement):**
--    - w_x = sin(p_y*freq + p_z*freq*0.7) * warpAmp
--    - w_y = cos(p_x*freq + p_z*freq*0.5) * warpAmp
--    - w_z = sin(p_z*freq*0.7 + p_x*freq*0.6) * warpAmp
--
-- b. **Noise Sampling:**
--    - uvw = fract((p + w) * noiseScale - windOffset)
--    - Sample cloud_noise at uvw
--
-- c. **Density Composition:**
--    - density = max(0, noiseR*(1 - cloudDetail*(noiseG*0.3+noiseB*0.15+noiseA*0.075)) - (1-cloudCoverage))
--    - * heightMask * 4.0
--
-- d. **Height Mask:**
--    - h = (pY - cloudBottom) / cloudThickness
--    - heightMask = smoothstep(0, 0.15, h) * (1 - smoothstep(0.85, 1, h))
--
-- **Nested 4-Step Light March (per primary step):**
-- - Secondary ray toward sun, 4 samples
-- - Accumulates light density along sun direction
-- - Beer-Powder: lightT = max(exp(-d*1.5), 0.7*exp(-d*0.25))
--
-- **Henyey-Greenstein Phase Function:**
-- - cosTheta = dot(dir, sunDir)
-- - HG(g) = (1 - g²) / (4π * (1 + g² - 2*g*cosTheta)^1.5)
-- - phase = 0.7 * HG(0.6) + 0.3 * HG(-0.3)
--
-- **Radiance Accumulation (Beer-Lambert):**
-- - In-scattering: S_i = cloudBase * lightT * phase * density * stepSize
-- - Transmittance: T_i = T_{i-1} * exp(-density * stepSize)
--
-- **Wind-Aware Temporal Reprojection:**
-- - World-space entry offset by wind displacement (dt * windSpeed * windDir)
-- - Reproject to previous frame using prevViewProj
-- - Blend: result = history * 0.85 * blendFactor + current * (1 - 0.85*blendFactor)
-- - Valid only if reprojected UV is inside [0,1]
--
-- utput:**
-- * out_colour (Location 0): V4 Float
--   - R,G,B = temporally blended cloud color
--   - A     = 1.0
--
-- exture Input Formats:**
-- * env_map:     Cube map RGBA8 UNorm (6 faces, 512x512)
-- * cloud_noise: 3D RGBA8 UNorm (256x256x256)
--    * cloud_history: 2D RGBA16 F (quarter resolution)
module Graphics.Haskan.Vulkan.Shaders.Deferred.Clouds where

import FIR
import Math.Linear

-- Shared vertex shader with Lighting pass
-- Fullscreen triangle, outputs UV and ray direction

type CloudFrameData =
  Struct
    '[ "cameraX" ':-> Float,
       "cameraY" ':-> Float,
       "cameraZ" ':-> Float,
       "ray0" ':-> V 3 Float,
       "ray1" ':-> V 3 Float,
       "ray2" ':-> V 3 Float,
       "sunDir" ':-> V 3 Float,
       "cloudHeight" ':-> Float,
       "time" ':-> Float,
       "blendFactor" ':-> Float,
       "prevViewProj0" ':-> V 4 Float,
       "prevViewProj1" ':-> V 4 Float,
       "prevViewProj2" ':-> V 4 Float,
       "prevViewProj3" ':-> V 4 Float,
       "windDirX" ':-> Float,
       "windDirZ" ':-> Float,
       "prevTime" ':-> Float,
       "cloudCoverage" ':-> Float,
       "cloudDetail" ':-> Float,
       "cloudAbsorption" ':-> Float,
       "weatherCoverageScale" ':-> Float,
       "weatherTypeBias" ':-> Float,
       "stormIntensity" ':-> Float,
       "weatherAnimSpeed" ':-> Float,
       "frameIndex" ':-> Float
     ]

type CloudVertexDefs =
  '[ "out_uv" ':-> Output '[Location 0] (V 2 Float),
     "out_ray" ':-> Output '[Location 1] (V 3 Float),
     "cloud_frame_data"
       ':-> Uniform
              '[Binding 4, DescriptorSet 0]
              CloudFrameData,
     "main" ':-> EntryPoint '[] Vertex
   ]

cloudVertex :: ShaderModule "main" VertexShader CloudVertexDefs _
cloudVertex = shader do
  vertIdx <- get @"gl_VertexIndex"
  let fi = fromIntegral vertIdx :: Code Float
      x = if fi == 0 then (-1) else if fi == 1 then 3 else (-1)
      y = if fi == 0 then (-1) else if fi == 1 then (-1) else 3
      u = if fi == 0 then 0 else if fi == 1 then 2 else 0
      v = if fi == 0 then 1 else if fi == 1 then 1 else (-1)

  frameData <- get @"cloud_frame_data"
  let ray0 = view @(Name "ray0") frameData
      ray1 = view @(Name "ray1") frameData
      ray2 = view @(Name "ray2") frameData
      rayDir = if fi == 0 then ray0 else if fi == 1 then ray1 else ray2

  put @"out_uv" (Vec2 u v)
  put @"out_ray" rayDir
  put @"gl_Position" (Vec4 x y 0 1)

type CloudFragmentDefs =
  '[ "in_uv" ':-> Input '[Location 0] (V 2 Float),
     "in_ray" ':-> Input '[Location 1] (V 3 Float),
      "env_map"
        ':-> TextureCube
               '[Binding 0, DescriptorSet 0]
               (RGBA16 F),
     "cloud_noise"
       ':-> Texture3D
              '[Binding 1, DescriptorSet 0]
              (RGBA8 UNorm),
     "cloud_history"
       ':-> Texture2D
              '[Binding 2, DescriptorSet 0]
              (RGBA16 F),
     "blue_noise"
       ':-> Texture2D
              '[Binding 3, DescriptorSet 0]
              (RGBA8 UNorm),
     "cloud_frame_data"
       ':-> Uniform
              '[Binding 4, DescriptorSet 0]
              CloudFrameData,
     "weather_map"
       ':-> Texture2D
              '[Binding 5, DescriptorSet 0]
              (RGBA8 UNorm),
     "out_colour" ':-> Output '[Location 0] (V 4 Float),
     "main" ':-> EntryPoint '[OriginUpperLeft] Fragment
   ]

cloudFragment :: ShaderModule "main" FragmentShader CloudFragmentDefs _
cloudFragment = shader do
  uv <- get @"in_uv"
  let (Vec2 uvX uvY) = uv
  rayDir <- get @"in_ray"

  frameData <- get @"cloud_frame_data"
  let camX = view @(Name "cameraX") frameData
      camY = view @(Name "cameraY") frameData
      camZ = view @(Name "cameraZ") frameData
      sunDir = view @(Name "sunDir") frameData
      ~(Vec3 sunDirX sunDirY sunDirZ) = sunDir
      cloudBottom = view @(Name "cloudHeight") frameData
      time = view @(Name "time") frameData
      windDirX = view @(Name "windDirX") frameData
      windDirZ = view @(Name "windDirZ") frameData
      cloudCoverage = view @(Name "cloudCoverage") frameData
      cloudDetail = view @(Name "cloudDetail") frameData
      cloudAbsorption = view @(Name "cloudAbsorption") frameData
      weatherCoverageScale = view @(Name "weatherCoverageScale") frameData
      weatherTypeBias = view @(Name "weatherTypeBias") frameData
      stormIntensity = view @(Name "stormIntensity") frameData
      weatherAnimSpeed = view @(Name "weatherAnimSpeed") frameData
      frameIndex = view @(Name "frameIndex") frameData

  -- Sub-pixel jitter for TAA: golden ratio offset per frame
  let goldenRatio = 0.6180339887
      jitterX = fract (frameIndex * goldenRatio) * 0.0005
      jitterY = fract (frameIndex * goldenRatio + 0.5) * 0.0005
      -- Apply jitter to ray direction (not UV, since rayDir is varying)
      jitteredRayDir = rayDir ^+^ Vec3 jitterX jitterY 0.0
      dir = jitteredRayDir ^/ (norm jitteredRayDir + 0.0001)
      ~(Vec3 dirX dirY dirZ) = dir

  -- Analytic sky with directional color temperature
  -- At sunset: warm near sun, deep blue away from sun
  let cosThetaView = abs dirY
      cosGamma = dir ^.^ sunDir
      cosGammaClamped = clamp cosGamma (-1.0) 1.0

      -- Rayleigh phase function
      rayleighPhase = (3.0 / (16.0 * 3.14159265)) * (1.0 + cosGammaClamped * cosGammaClamped)

      -- Optical depth model
      rayleighOD = 0.3
      mieOD = 0.1
      rayleighTrans = exp (-rayleighOD / (cosThetaView + 0.05))
      mieTrans = exp (-mieOD / (cosThetaView + 0.05))

      -- In-scattering (scale ~100x to bring into visible HDR range)
      rayleighScatterR = 0.0058 * rayleighPhase * (1.0 - rayleighTrans) * 100.0
      rayleighScatterG = 0.0135 * rayleighPhase * (1.0 - rayleighTrans) * 100.0
      rayleighScatterB = 0.0331 * rayleighPhase * (1.0 - rayleighTrans) * 100.0

      -- Mie phase (Henyey-Greenstein)
      g = 0.76
      g2 = g * g
      mieDenom = (1.0 + g2 - 2.0 * g * cosGammaClamped) ** 1.5
      miePhase = (1.0 - g2) / (4.0 * 3.14159265 * mieDenom)
      mieScatter = 0.021 * miePhase * (1.0 - mieTrans) * 100.0

      -- Soft sun disc
      sunDisc = 50.0 * smoothstep 0.999 1.0 cosGammaClamped

      -- Directional color temperature
      -- At sunset/sunrise (sun near horizon): warm near sun, cool away
      sunElev = sunDirY
      -- 1.0 when sun near horizon, 0.0 when sun high
      horizonFactor = 1.0 - clamp ((sunElev + 0.1) / 0.4) 0.0 1.0
      -- 1.0 when looking toward sun, 0.0 when perpendicular or away
      viewSunAngle = clamp (dir ^.^ sunDir) (-1.0) 1.0
      sunProximity = max 0.0 viewSunAngle
      -- Warmth peaks when looking at sun near horizon
      warmth = sunProximity * horizonFactor

      -- Color temperature: reduce green/blue for warmth → orange/red near sun
      colorTempR = 1.0
      colorTempG = mix 1.0 0.55 warmth
      colorTempB = mix 1.0 0.25 warmth

      totalR = (rayleighScatterR + mieScatter + sunDisc) * colorTempR
      totalG = (rayleighScatterG + mieScatter + sunDisc) * colorTempG
      totalB = (rayleighScatterB + mieScatter + sunDisc) * colorTempB

      skyR = totalR
      skyG = totalG
      skyB = totalB

  let cloudThickness = 800.0
      cloudTop = cloudBottom + cloudThickness

      -- Slab intersector: handles camera below, inside, or above cloud layer
      -- Smooth clamp to epsilon: no dead zone discontinuity
      dirY_safe = if dirY > 0.0 then max 0.05 dirY else min (-0.05) dirY
      tToBottom = (cloudBottom - camY) / dirY_safe
      tToTop = (cloudTop - camY) / dirY_safe
      tNear = max 0.0 (min tToBottom tToTop)
      tFar = max 0.0 (max tToBottom tToTop)
      totalRayLength = min 5000.0 (tFar - tNear)
      -- Geometric step growth: start small near camera, grow exponentially
      baseStepSize = max 30.0 (min 100.0 (totalRayLength / 32.0))
      growthRate = 1.03
      maxStepSize = 300.0
      emptySkipFactor = 3.0 :: Code Float
      maxEmptySkip = 4.0 :: Code Float
      stepCountF = 96.0 :: Code Float
      -- Detail LOD: fade detail channels beyond distance
      detailFadeStart = 500.0
      detailFadeEnd = 2500.0
      -- Noise mip LOD: sample coarser mips at distance
      lodScale = 400.0
      maxNoiseLod = 2.0
      -- Light march: fixed small steps toward sun
      lightStepCount = if totalRayLength > 2500.0 then 2.0 else if totalRayLength > 1200.0 then 3.0 else 4.0
      lightStepSize = min 120.0 (cloudThickness / lightStepCount)
  -- Sample blue noise for dithered ray entry
  ~(Vec4 blueR _ _ _) <- use @(ImageTexel "blue_noise") NilOps (Vec2 uvX uvY)
  let ditherScale = min 1.0 (totalRayLength / 2000.0)
      ditherOffset = blueR * baseStepSize * 0.5 * ditherScale
      tEntry = tNear + ditherOffset
      entryPos = Vec3 (camX + dirX * tEntry) (camY + dirY * tEntry) (camZ + dirZ * tEntry)

  -- Hoist constant-direction cubemap samples (zenith/nadir don't change per step)
  ~(Vec4 zenithR zenithG zenithB _) <- use @(ImageTexel "env_map") NilOps (Vec3 (0.0 :: Code Float) (1.0 :: Code Float) (0.0 :: Code Float))
  ~(Vec4 nadirR nadirG nadirB _) <- use @(ImageTexel "env_map") NilOps (Vec3 (0.0 :: Code Float) (-1.0 :: Code Float) (0.0 :: Code Float))
  let skyAmbientCubemap = Vec3 zenithR zenithG zenithB
      groundAmbientCubemap = Vec3 nadirR nadirG nadirB

  -- Hoist weather map sample (varies slowly, sample once at entry point)
  let ~(Vec3 epx epy epz) = entryPos
      eDistHorizSq = (epx - camX) * (epx - camX) + (epz - camZ) * (epz - camZ)
      eCurvedY = epy - (eDistHorizSq / (2.0 * 6371000.0))
      eWeatherScale = 0.00005
      eWeatherWindOffsetX = time * 0.002 * windDirX * weatherAnimSpeed
      eWeatherWindOffsetZ = time * 0.002 * windDirZ * weatherAnimSpeed
      eHorizDist = sqrt (epx * epx + epz * epz)
      eLongitude = atan2 epz epx / (2.0 * 3.14159265)
      eLatitude = eCurvedY / 2000.0
      eWeatherUV = Vec2 (eLongitude - eWeatherWindOffsetX * 0.1) ((eLatitude + eHorizDist * eWeatherScale) - eWeatherWindOffsetZ * 0.1)
  ~(Vec4 eWeatherR eWeatherG eWeatherB _eWeatherA) <- use @(ImageTexel "weather_map") NilOps eWeatherUV
  let entryCoverage = clamp (eWeatherR * cloudCoverage * weatherCoverageScale) 0.0 1.0
      entryCloudType = clamp (eWeatherG + weatherTypeBias) 0.0 1.0
      entryStormDarkness = eWeatherB * stormIntensity

      noiseScale = 0.0003
      windSpeed = 0.05
      windOffsetX = time * windSpeed * windDirX
      windOffsetZ = time * windSpeed * windDirZ
      -- Primary domain warp: large amplitude to break up noise tiling
      warpAmp1 = 500.0
      warpFreq1 = 0.0015
      -- Secondary warp: higher frequency, smaller amplitude for detail
      warpAmp2 = 250.0
      warpFreq2 = 0.0042

  -- Dynamic ray march: mutable accumulators
  _ <- def @"step" @RW @Int32 0
  _ <- def @"rayPos" @RW @(V 3 Float) (entryPos ^+^ dir ^* (baseStepSize * 0.5))
  _ <- def @"transmittance" @RW @Float 1.0
  _ <- def @"accR" @RW @Float 0.0
  _ <- def @"accG" @RW @Float 0.0
  _ <- def @"accB" @RW @Float 0.0
  _ <- def @"currentStepSize" @RW @Float baseStepSize
  _ <- def @"distFromCam" @RW @Float tEntry
  _ <- def @"emptySkipMult" @RW @Float 1.0

  let cosTheta = dir ^.^ sunDir
      hgPhase g =
        let g2 = g * g
            denom = (1.0 + g2 - 2.0 * g * cosTheta) ** 1.5
         in (1.0 - g2) / (4.0 * 3.14159265 * denom)
      phase = 0.7 * hgPhase 0.6 + 0.3 * hgPhase (-0.3)
      cloudBase = Vec3 1.0 0.98 0.95

  loop do
    s <- get @"step"
    when (fromIntegral s >= stepCountF) do
      break @1

    t <- get @"transmittance"
    when (t < 0.01) do
      break @1

    css <- get @"currentStepSize"
    esm <- get @"emptySkipMult"
    dist <- get @"distFromCam"
    let stepSize = min maxStepSize (css * esm)

    -- Per-step irrational jitter to break deterministic phase alignment
    let stepNoise = fract (blueR + fromIntegral s * 0.618034)
        jitteredStep = stepSize * (1.0 + 0.15 * (stepNoise - 0.5))

    -- Distance-based detail fade and noise LOD
    let detailFade = 1.0 - smoothstep detailFadeStart detailFadeEnd dist
        noiseLod = clamp (dist / lodScale) 0.0 maxNoiseLod
        effectiveDetail = cloudDetail * detailFade

    rp <- get @"rayPos"
    let ~(Vec3 px py pz) = rp
        -- Spherical Earth curvature: cloud layer follows Earth surface
        earthRadius = 6371000.0
        distHorizSq = (px - camX) * (px - camX) + (pz - camZ) * (pz - camZ)
        curvedY = py - (distHorizSq / (2.0 * earthRadius))
        -- Multi-octave domain warping to break up noise tiling
        wx1 = sin (py * warpFreq1 + pz * warpFreq1 * 0.7) * warpAmp1
        wy1 = cos (px * warpFreq1 + pz * warpFreq1 * 0.5) * warpAmp1
        wz1 = sin (pz * warpFreq1 * 0.7 + px * warpFreq1 * 0.6) * warpAmp1
        wx2 = sin (py * warpFreq2 * 1.3 + px * warpFreq2 * 0.9) * warpAmp2
        wy2 = cos (pz * warpFreq2 * 1.1 + py * warpFreq2 * 0.8) * warpAmp2
        wz2 = sin (px * warpFreq2 * 1.5 + py * warpFreq2 * 1.2) * warpAmp2
        wx = wx1 + wx2
        wy = wy1 + wy2
        wz = wz1 + wz2
        sx = (px + wx) * noiseScale - windOffsetX
        sy = (py + wy) * noiseScale
        sz = (pz + wz) * noiseScale - windOffsetZ

    ~(Vec4 nr ng nb na) <- use @(ImageTexel "cloud_noise") (LOD noiseLod NilOps) (Vec3 sx sy sz)

    let combinedCoverage = entryCoverage
        cloudType = entryCloudType
        stormDarkness = entryStormDarkness
        h = (curvedY - cloudBottom) / cloudThickness
        -- Dynamic cloud height: taller clouds with higher coverage
        heightScale = max 0.3 (combinedCoverage ** 0.25)
        hPct = clamp (h / heightScale) 0.0 1.0
        -- Parametric height profile: organic cloud shape
        baseCurve = mix 0.4 0.8 cloudType
        topDecay = mix 2.0 4.0 cloudType
        heightProfile = (hPct ** baseCurve) * exp (-hPct * topDecay)
        -- Subtractive detail erosion: detail can only reduce density
        detailFBM = ng * 0.625 + nb * 0.25 + na * 0.125
        shapedNoise = max 0.0 (nr - detailFBM * effectiveDetail)
        -- Sparse cloud threshold: coverage controls how much noise survives
        remappedNoise = max 0.0 (shapedNoise - (1.0 - combinedCoverage))
        density = remappedNoise * heightProfile

    -- Ambient from sky cubemap (hoisted, constant directions)
    let ambientStrength = 0.12 * max 0.05 (smoothstep (-0.1) 0.3 sunDirY)
        rawAmbientTerm = (groundAmbientCubemap ^* (1.0 - hPct) ^+^ skyAmbientCubemap ^* hPct) ^* ambientStrength
        -- Darken ambient in storm regions
        stormAmbient = rawAmbientTerm ^* (1.0 - entryStormDarkness * 0.6)

    -- Empty-space skip DISABLED (causes vertical banding)
    let newEmptySkipMult = 1.0

    -- Single light sample for self-shadowing (replaces multi-step light march)
    -- Sample at midpoint of light path toward sun
    let lightMidPos = rp ^+^ sunDir ^* (lightStepSize * lightStepCount * 0.5)
        ~(Vec3 lpx lpy lpz) = lightMidPos
        ldistHorizSq = (lpx - camX) * (lpx - camX) + (lpz - camZ) * (lpz - camZ)
        lcurvedY = lpy - (ldistHorizSq / (2.0 * 6371000.0))
        -- Simplified single-octave warp
        lwx = sin (lpy * warpFreq1 + lpz * warpFreq1 * 0.7) * warpAmp1
        lwy = cos (lpx * warpFreq1 + lpz * warpFreq1 * 0.5) * warpAmp1
        lwz = sin (lpz * warpFreq1 * 0.7 + lpx * warpFreq1 * 0.6) * warpAmp1
        lsx = (lpx + lwx) * noiseScale - windOffsetX
        lsy = (lpy + lwy) * noiseScale
        lsz = (lpz + lwz) * noiseScale - windOffsetZ
        -- Light position distance from camera for LOD
        ldistFromCam = sqrt ((lpx - camX) * (lpx - camX) + (lpy - camY) * (lpy - camY) + (lpz - camZ) * (lpz - camZ))
        lnoiseLod = clamp (ldistFromCam / lodScale) 0.0 maxNoiseLod

    ~(Vec4 lnr lng lnb lna) <- use @(ImageTexel "cloud_noise") (LOD lnoiseLod NilOps) (Vec3 lsx lsy lsz)

    -- Reuse primary step coverage (weather map changes slowly)
    let lh = (lcurvedY - cloudBottom) / cloudThickness
        lhPct = clamp (lh / heightScale) 0.0 1.0
        -- Parametric height profile (matching primary step)
        lheightProfile = (lhPct ** baseCurve) * exp (-lhPct * topDecay)
        -- Subtractive detail erosion (matching primary step)
        ldetailFBM = lng * 0.625 + lnb * 0.25 + lna * 0.125
        lshapedNoise = max 0.0 (lnr - ldetailFBM * effectiveDetail)
        -- Sparse cloud threshold (matching primary step)
        lremappedNoise = max 0.0 (lshapedNoise - (1.0 - entryCoverage))
        ld = lremappedNoise * lheightProfile
        -- Approximate integral over light path with single sample
        finalLightDensity = ld * lightStepCount * lightStepSize

    let d = finalLightDensity * cloudAbsorption
        ms0 = exp (-d * 1.0) -- primary scatter
        ms1 = exp (-d * 0.25) * 0.5 -- secondary scatter
        ms2 = exp (-d * 0.05) * 0.25 -- tertiary scatter
        lightT_d = ms0 + ms1 + ms2
        -- Powder effect: brightens cloud edges facing sun (uses light-density)
        powderTerm = 1.0 - exp (-ld * 2.0)
        powderBoost = mix 1.0 (powderTerm * 2.0 + 1.0) 0.3
        -- Skylight occlusion: reduce ambient in dense self-shadowed regions
        skylightOcclusion = exp (-finalLightDensity * 0.25)
        -- Internal scattering approximation: boost ambient in dense interiors
        internalScatter = 1.0 + density * 0.5
        ambientTerm = (stormAmbient ^* skylightOcclusion) ^* internalScatter

    let directLight = cloudBase ^* (lightT_d * phase * powderBoost * (1.0 - stormDarkness * 0.4))
        s_scatter = (directLight ^+^ ambientTerm) ^* (density * jitteredStep)
        t_new = exp (-density * jitteredStep)
        ~(Vec3 srx sry srz) = s_scatter

    modify @"accR" (+ (srx * t))
    modify @"accG" (+ (sry * t))
    modify @"accB" (+ (srz * t))
    put @"transmittance" (t * t_new)
    put @"rayPos" (rp ^+^ dir ^* jitteredStep)
    -- Geometric step growth: increase base step size for next iteration
    put @"currentStepSize" (css * growthRate)
    put @"emptySkipMult" newEmptySkipMult
    put @"distFromCam" (dist + jitteredStep)
    modify @"step" (+ 1)

  finalTransmittance <- get @"transmittance"
  finalAccR <- get @"accR"
  finalAccG <- get @"accG"
  finalAccB <- get @"accB"
  let cloudSkyR = skyR * finalTransmittance + finalAccR
      cloudSkyG = skyG * finalTransmittance + finalAccG
      cloudSkyB = skyB * finalTransmittance + finalAccB
      cloudOpacity = 1.0 - finalTransmittance

      -- Temporal accumulation with reprojection
      blendFactor = view @(Name "blendFactor") frameData
      prevTime = view @(Name "prevTime") frameData

      -- World-space cloud entry point (undithered for reprojection)
      worldX = camX + dirX * tNear
      worldY = camY + dirY * tNear
      worldZ = camZ + dirZ * tNear

      -- Wind-aware reprojection: subtract wind displacement from world position
      -- so the history sample tracks the moving cloud mass
      dt = max 0.0 (time - prevTime)
      windSpeed = 0.05
      windDeltaX = dt * windSpeed * windDirX
      windDeltaZ = dt * windSpeed * windDirZ
      windWorldX = worldX - windDeltaX
      windWorldY = worldY
      windWorldZ = worldZ - windDeltaZ

      -- Previous frame view-projection matrix columns
      prevVP0 = view @(Name "prevViewProj0") frameData
      prevVP1 = view @(Name "prevViewProj1") frameData
      prevVP2 = view @(Name "prevViewProj2") frameData
      prevVP3 = view @(Name "prevViewProj3") frameData

      -- Manual mat4 * vec4 multiplication (column-vector convention)
      ~(Vec4 m00 m10 m20 m30) = prevVP0
      ~(Vec4 m01 m11 m21 m31) = prevVP1
      ~(Vec4 m02 m12 m22 m32) = prevVP2
      ~(Vec4 m03 m13 m23 m33) = prevVP3

      prevClipX = m00 * windWorldX + m01 * windWorldY + m02 * windWorldZ + m03 * 1.0
      prevClipY = m10 * windWorldX + m11 * windWorldY + m12 * windWorldZ + m13 * 1.0
      prevClipZ = m20 * windWorldX + m21 * windWorldY + m22 * windWorldZ + m23 * 1.0
      prevClipW = m30 * windWorldX + m31 * windWorldY + m32 * windWorldZ + m33 * 1.0

      prevNDCX = prevClipX / max 0.0001 prevClipW
      prevNDCY = prevClipY / max 0.0001 prevClipW

      prevU = prevNDCX * 0.5 + 0.5
      prevV = (-prevNDCY) * 0.5 + 0.5

      validReproj = step 0.0 prevU * step prevU 1.0 * step 0.0 prevV * step prevV 1.0 * step 0.0 prevClipW

      histUV = Vec2 prevU prevV

  ~(Vec4 histR_h histG_h histB_h histA_h) <- use @(ImageTexel "cloud_history") NilOps histUV
  let histR = histR_h
      histG = histG_h
      histB = histB_h
      histA = histA_h
      rayHitCloud = step 0.01 cloudOpacity
      maxLum = max cloudSkyR (max cloudSkyG cloudSkyB)
      brightFade = 1.0 - smoothstep 5.0 30.0 maxLum
      -- Distance-dependent blend: less temporal blend near camera (reduces swimming)
      distFade = smoothstep 200.0 1500.0 totalRayLength
      baseBlend = 0.3 * blendFactor * distFade + 0.2 * blendFactor * (1.0 - distFade)
      -- Alpha-diff ghost suppression: high alpha difference = reject history
      alphaDiff = abs (cloudOpacity - histA)
      ghostSuppress = 1.0 - smoothstep 0.05 0.3 alphaDiff
      reprojBlend = rayHitCloud * baseBlend * validReproj * brightFade * ghostSuppress
      accR = reprojBlend * histR + (1.0 - reprojBlend) * cloudSkyR
      accG = reprojBlend * histG + (1.0 - reprojBlend) * cloudSkyG
      accB = reprojBlend * histB + (1.0 - reprojBlend) * cloudSkyB

  put @"out_colour" (Vec4 accR accG accB cloudOpacity)
