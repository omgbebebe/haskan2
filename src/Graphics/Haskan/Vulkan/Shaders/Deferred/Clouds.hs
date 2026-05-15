{-|
Module: Graphics.Haskan.Vulkan.Shaders.Deferred.Clouds

=== Deferred Rendering Pipeline — Stage 3: Volumetric Cloud Pass ===

This module implements a quarter-resolution volumetric cloud rendering pass
that ray-marches through a procedural cloud volume and composites with the skybox.
Output is blended with history for temporal anti-aliasing.

=== Vertex Shader (Fullscreen Triangle) ===

**Inputs:**
  * gl_VertexIndex: implicit vertex index (0, 1, 2)

**Push Constants:**
  * cameraPos: V3 Float — world-space camera position (minimal, 12 bytes)

**Uniform Buffer (Binding 4, DS0):**
  * cloud_frame_data: CloudFrameData struct containing:
    - cameraX/Y/Z      : Float — world-space camera position
    - ray0/ray1/ray2   : V3 Float — per-corner frustum rays
    - sunDir           : V3 Float — normalized sun direction
    - cloudHeight      : Float — cloud layer bottom Y coordinate
    - time             : Float — animation time
    - blendFactor      : Float — temporal blend weight
    - windDirX/Z       : Float — wind direction for noise animation
    - prevViewProj0-3  : V4 Float — previous frame view-projection matrix rows
    - cloudCoverage    : Float — coverage threshold
    - cloudDetail      : Float — detail strength
    - cloudAbsorption  : Float — light absorption coefficient

**Algorithm:** Same fullscreen triangle as Lighting pass.

**Outputs:**
  * out_uv  (Location 0): V2 Float — screen-space UVs
  * out_ray (Location 1): V3 Float — world-space ray direction

=== Fragment Shader ===

**Inputs:**
  * in_uv  (Location 0): V2 Float — interpolated screen UV
  * in_ray (Location 1): V3 Float — interpolated world ray direction

**Textures:**
  * env_map      (Binding 0, DS0): TextureCube RGBA8 UNorm
    - Skybox environment map for background color
  * cloud_noise  (Binding 1, DS0): Texture3D RGBA8 UNorm
    - 3D noise texture (256^3) with 4 octaves:
      - R = Perlin-Worley blend (macro shape)
      - G = Worley 8^3  (medium erosion)
      - B = Worley 16^3 (high-frequency detail)
      - A = Worley 32^3 (micro-detail)
  * cloud_history(Binding 2, DS0): Texture2D RGBA16 F
    - Previous frame cloud result for temporal accumulation

lgorithm — Volumetric Ray Marching:**

**Ray Setup:**
- dir = normalize(rayDir)
- cloudThickness = 800.0
- cloudTop = cloudBottom + cloudThickness
- Dual-plane slab intersection for camera below/inside/above cloud layer
- stepSize = totalRayLength / 24.0

**Dithered Entry Point:**
- hash = fract(sin(uv.x*12.9898 + uv.y*78.233) * 43758.5453)
- offset = hash * stepSize
- tEntry = tNear + offset

**24-Step Dynamic Ray March (loop with early exit):**
Mutable accumulators: step, rayPos, transmittance, accR/G/B.
Loop breaks when step >= 24 or transmittance < 0.01.
   
Per step:
   
a. **Domain Warping (Curl-like displacement):**
   - w_x = sin(p_y*freq + p_z*freq*0.7) * warpAmp
   - w_y = cos(p_x*freq + p_z*freq*0.5) * warpAmp
   - w_z = sin(p_z*freq*0.7 + p_x*freq*0.6) * warpAmp
   
b. **Noise Sampling:**
   - uvw = fract((p + w) * noiseScale - windOffset)
   - Sample cloud_noise at uvw
   
c. **Density Composition:**
   - density = max(0, noiseR*(1 - cloudDetail*(noiseG*0.3+noiseB*0.15+noiseA*0.075)) - (1-cloudCoverage))
   - * heightMask * 4.0
   
d. **Height Mask:**
   - h = (pY - cloudBottom) / cloudThickness
   - heightMask = smoothstep(0, 0.15, h) * (1 - smoothstep(0.85, 1, h))

**Nested 4-Step Light March (per primary step):**
- Secondary ray toward sun, 4 samples
- Accumulates light density along sun direction
- Beer-Powder: lightT = max(exp(-d*1.5), 0.7*exp(-d*0.25))

**Henyey-Greenstein Phase Function:**
- cosTheta = dot(dir, sunDir)
- HG(g) = (1 - g²) / (4π * (1 + g² - 2*g*cosTheta)^1.5)
- phase = 0.7 * HG(0.6) + 0.3 * HG(-0.3)

**Radiance Accumulation (Beer-Lambert):**
- In-scattering: S_i = cloudBase * lightT * phase * density * stepSize
- Transmittance: T_i = T_{i-1} * exp(-density * stepSize)

**Wind-Aware Temporal Reprojection:**
- World-space entry offset by wind displacement (dt * windSpeed * windDir)
- Reproject to previous frame using prevViewProj
- Blend: result = history * 0.85 * blendFactor + current * (1 - 0.85*blendFactor)
- Valid only if reprojected UV is inside [0,1]

utput:**
* out_colour (Location 0): V4 Float
  - R,G,B = temporally blended cloud color
  - A     = 1.0

exture Input Formats:**
* env_map:     Cube map RGBA8 UNorm (6 faces, 512x512)
* cloud_noise: 3D RGBA8 UNorm (256x256x256)
   * cloud_history: 2D RGBA16 F (quarter resolution)
-}

{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -fno-warn-partial-type-signatures #-}

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
       "cloudAbsorption" ':-> Float
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
              (RGBA8 UNorm),
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
      "out_colour" ':-> Output '[Location 0] (V 4 Float),
     "main" ':-> EntryPoint '[OriginUpperLeft] Fragment
   ]

cloudFragment :: ShaderModule "main" FragmentShader CloudFragmentDefs _
cloudFragment = shader do
  uv <- get @"in_uv"
  let (Vec2 uvX uvY) = uv
  rayDir <- get @"in_ray"
  let dir = rayDir ^/ (norm rayDir + 0.0001)
      ~(Vec3 dirX dirY dirZ) = dir

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

  ~(Vec4 skyR skyG skyB _) <- use @(ImageTexel "env_map") NilOps (Vec3 dirX dirY dirZ)

  let cloudThickness = 800.0
      cloudTop = cloudBottom + cloudThickness

      -- Slab intersector: handles camera below, inside, or above cloud layer
      dirY_safe = if dirY > 0.001
        then dirY
        else (if dirY < (-0.001) then dirY else 0.001)
      tToBottom = (cloudBottom - camY) / dirY_safe
      tToTop = (cloudTop - camY) / dirY_safe
      tNear = max 0.0 (min tToBottom tToTop)
      tFar = max 0.0 (max tToBottom tToTop)
      totalRayLength = min 10000.0 (tFar - tNear)
      absDirY = step 0.0 dirY * dirY + step dirY 0.0 * (0.0 - dirY)
      stepCountF = max 32.0 (min 64.0 (totalRayLength / 120.0))
      adaptiveStepSize = totalRayLength / stepCountF

  -- Sample blue noise for dithered ray entry
  ~(Vec4 blueR _ _ _) <- use @(ImageTexel "blue_noise") NilOps (Vec2 uvX uvY)
  let ditherOffset = blueR * adaptiveStepSize
      tEntry = tNear + ditherOffset
      entryPos = Vec3 (camX + dirX * tEntry) (camY + dirY * tEntry) (camZ + dirZ * tEntry)

      noiseScale = 0.0003
      windSpeed = 0.05
      windOffsetX = time * windSpeed * windDirX
      windOffsetZ = time * windSpeed * windDirZ
      -- Primary domain warp: large amplitude to break up noise tiling
      warpAmp1 = 300.0
      warpFreq1 = 0.0015
      -- Secondary warp: higher frequency, smaller amplitude for detail
      warpAmp2 = 80.0
      warpFreq2 = 0.0042

  -- Dynamic ray march: mutable accumulators
  _ <- def @"step" @RW @Int32 0
  _ <- def @"rayPos" @RW @(V 3 Float) (entryPos ^+^ dir ^* (adaptiveStepSize * 0.5))
  _ <- def @"transmittance" @RW @Float 1.0
  _ <- def @"accR" @RW @Float 0.0
  _ <- def @"accG" @RW @Float 0.0
  _ <- def @"accB" @RW @Float 0.0

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

    -- Per-step irrational jitter to break deterministic phase alignment
    let stepNoise = fract (blueR + fromIntegral s * 0.618034)
        jitteredStep = adaptiveStepSize * (1.0 + 0.15 * (stepNoise - 0.5))

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
        sx = fract ((px + wx) * noiseScale - windOffsetX)
        sy = fract ((py + wy) * noiseScale)
        sz = fract ((pz + wz) * noiseScale - windOffsetZ)

    ~(Vec4 nr ng nb na) <- use @(ImageTexel "cloud_noise") NilOps (Vec3 sx sy sz)

    let h = (curvedY - cloudBottom) / cloudThickness
        heightMask = smoothstep 0.0 0.15 h * (1.0 - smoothstep 0.85 1.0 h)
        density = max 0 (nr * (1.0 - cloudDetail * (ng * 0.3 + nb * 0.15 + na * 0.075)) - (1.0 - cloudCoverage)) * heightMask

    -- Height-graded ambient with day-night cycle
    -- sunDirY encodes elevation: 1.0 = zenith, 0.0 = horizon, <0 = below horizon
        dayFactor = smoothstep (-0.1) 0.3 sunDirY
        nightFactor = smoothstep (-0.2) 0.0 sunDirY
        -- Noon ambient
        noonGround  = Vec3 0.35 0.30 0.25
        noonSky     = Vec3 0.50 0.60 0.80
        -- Sunset ambient
        sunsetGround = Vec3 0.50 0.25 0.10
        sunsetSky    = Vec3 0.40 0.25 0.35
        -- Night ambient (moonlight)
        nightGround = Vec3 0.02 0.02 0.04
        nightSky    = Vec3 0.03 0.04 0.08
        -- Interpolate through night -> sunset -> noon
        groundAmbient = (nightGround ^* (1.0 - nightFactor) ^+^ sunsetGround ^* nightFactor) ^* (1.0 - dayFactor) ^+^ noonGround ^* dayFactor
        skyAmbient    = (nightSky    ^* (1.0 - nightFactor) ^+^ sunsetSky    ^* nightFactor) ^* (1.0 - dayFactor) ^+^ noonSky    ^* dayFactor
        ambientStrength = 0.18 * max 0.05 dayFactor
        ambientTerm   = (groundAmbient ^* (1.0 - h) ^+^ skyAmbient ^* h) ^* ambientStrength

    -- Nested light march: 4 steps toward sun for self-shadowing
    _ <- def @"lightStep" @RW @Int32 0
    _ <- def @"lightPos" @RW @(V 3 Float) rp
    _ <- def @"lightDensity" @RW @Float 0.0

    let lightStepSize = cloudThickness / 4.0

    loop do
      ls <- get @"lightStep"
      when (ls >= 4) do
        break @1

      lp <- get @"lightPos"
      let ~(Vec3 lpx lpy lpz) = lp
          -- Spherical Earth curvature for light march
          ldistHorizSq = (lpx - camX) * (lpx - camX) + (lpz - camZ) * (lpz - camZ)
          lcurvedY = lpy - (ldistHorizSq / (2.0 * 6371000.0))
          lwx1 = sin (lpy * warpFreq1 + lpz * warpFreq1 * 0.7) * warpAmp1
          lwy1 = cos (lpx * warpFreq1 + lpz * warpFreq1 * 0.5) * warpAmp1
          lwz1 = sin (lpz * warpFreq1 * 0.7 + lpx * warpFreq1 * 0.6) * warpAmp1
          lwx2 = sin (lpy * warpFreq2 * 1.3 + lpx * warpFreq2 * 0.9) * warpAmp2
          lwy2 = cos (lpz * warpFreq2 * 1.1 + lpy * warpFreq2 * 0.8) * warpAmp2
          lwz2 = sin (lpx * warpFreq2 * 1.5 + lpy * warpFreq2 * 1.2) * warpAmp2
          lwx = lwx1 + lwx2
          lwy = lwy1 + lwy2
          lwz = lwz1 + lwz2
          lsx = fract ((lpx + lwx) * noiseScale - windOffsetX)
          lsy = fract ((lpy + lwy) * noiseScale)
          lsz = fract ((lpz + lwz) * noiseScale - windOffsetZ)

      ~(Vec4 lnr lng lnb lna) <- use @(ImageTexel "cloud_noise") NilOps (Vec3 lsx lsy lsz)

      let lh = (lcurvedY - cloudBottom) / cloudThickness
          lheightMask = smoothstep 0.0 0.15 lh * (1.0 - smoothstep 0.85 1.0 lh)
          ld = max 0 (lnr * (1.0 - cloudDetail * (lng * 0.3 + lnb * 0.15 + lna * 0.075)) - (1.0 - cloudCoverage)) * lheightMask

      modify @"lightDensity" (+ (ld * lightStepSize))
      put @"lightPos" (lp ^+^ sunDir ^* lightStepSize)
      modify @"lightStep" (+1)

    finalLightDensity <- get @"lightDensity"
    let d = finalLightDensity * cloudAbsorption
        ms0 = exp (-d * 1.0)           -- primary scatter
        ms1 = exp (-d * 0.25) * 0.5    -- secondary scatter
        ms2 = exp (-d * 0.05) * 0.25   -- tertiary scatter
        lightT_d = ms0 + ms1 + ms2

    let directLight = cloudBase ^* (lightT_d * phase)
        s_scatter = (directLight ^+^ ambientTerm) ^* (density * jitteredStep)
        t_new = exp (-density * jitteredStep)
        ~(Vec3 srx sry srz) = s_scatter

    modify @"accR" (+ (srx * t))
    modify @"accG" (+ (sry * t))
    modify @"accB" (+ (srz * t))
    put @"transmittance" (t * t_new)
    put @"rayPos" (rp ^+^ dir ^* jitteredStep)
    modify @"step" (+1)

  finalTransmittance <- get @"transmittance"
  finalAccR <- get @"accR"
  finalAccG <- get @"accG"
  finalAccB <- get @"accB"

  let cloudSkyR = skyR * finalTransmittance + finalAccR
      cloudSkyG = skyG * finalTransmittance + finalAccG
      cloudSkyB = skyB * finalTransmittance + finalAccB

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

  ~(Vec4 histR_h histG_h histB_h _) <- use @(ImageTexel "cloud_history") NilOps histUV
  let histR = convert histR_h
      histG = convert histG_h
      histB = convert histB_h
      -- Reduced blend factor (0.85 vs 0.92) to reduce ghosting from
      -- residual motion not captured by wind displacement
      reprojBlend = 0.5 * blendFactor * validReproj
      accR = reprojBlend * histR + (1.0 - reprojBlend) * cloudSkyR
      accG = reprojBlend * histG + (1.0 - reprojBlend) * cloudSkyG
      accB = reprojBlend * histB + (1.0 - reprojBlend) * cloudSkyB

  put @"out_colour" (Vec4 accR accG accB 1.0)
