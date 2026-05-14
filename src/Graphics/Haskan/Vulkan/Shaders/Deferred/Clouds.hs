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

type CloudVertexDefs =
  '[ "out_uv" ':-> Output '[Location 0] (V 2 Float),
     "out_ray" ':-> Output '[Location 1] (V 3 Float),
     "cameraPos"
       ':-> PushConstant
              '[]
              CloudPushConstant,
     "main" ':-> EntryPoint '[] Vertex
   ]

type CloudPushConstant =
  Struct
    '[ "cameraX" ':-> Float,
       "cameraY" ':-> Float,
       "cameraZ" ':-> Float,
       "debugMode" ':-> Float,
       "axisOverlay" ':-> Float,
       "groundPlane" ':-> Float,
       "sunAzimuth" ':-> Float,
       "lightCount" ':-> Float,
       "ray0" ':-> V 3 Float,
       "ray1" ':-> V 3 Float,
       "ray2" ':-> V 3 Float,
       "skyTintR" ':-> Float,
       "skyTintG" ':-> Float,
       "skyTintB" ':-> Float,
       "iblIntensity" ':-> Float,
       "sunDir" ':-> V 3 Float,
        "cloudHeight" ':-> Float,
        "time" ':-> Float,
        "blendFactor" ':-> Float,
        "prevViewProj0" ':-> V 4 Float,
        "prevViewProj1" ':-> V 4 Float,
        "prevViewProj2" ':-> V 4 Float,
        "prevViewProj3" ':-> V 4 Float
      ]

cloudVertex :: ShaderModule "main" VertexShader CloudVertexDefs _
cloudVertex = shader do
  vertIdx <- get @"gl_VertexIndex"
  let fi = fromIntegral vertIdx :: Code Float
      x = if fi == 0 then (-1) else if fi == 1 then 3 else (-1)
      y = if fi == 0 then (-1) else if fi == 1 then (-1) else 3
      u = if fi == 0 then 0 else if fi == 1 then 2 else 0
      v = if fi == 0 then 1 else if fi == 1 then 1 else (-1)

  cameraPush <- get @"cameraPos"
  let ray0 = view @(Name "ray0") cameraPush
      ray1 = view @(Name "ray1") cameraPush
      ray2 = view @(Name "ray2") cameraPush
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
     "cameraPos"
       ':-> PushConstant
              '[]
              CloudPushConstant,
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

  cameraPos <- get @"cameraPos"
  let sunAzimuth = view @(Name "sunAzimuth") cameraPos
      camX = view @(Name "cameraX") cameraPos
      camY = view @(Name "cameraY") cameraPos
      camZ = view @(Name "cameraZ") cameraPos
      sunDir = view @(Name "sunDir") cameraPos
      ~(Vec3 sunDirX sunDirY sunDirZ) = sunDir
      cloudBottom = view @(Name "cloudHeight") cameraPos
      time = view @(Name "time") cameraPos

  let cosAz = cos sunAzimuth
      sinAz = sin sunAzimuth
      rotateY (Vec3 rx ry rz) = Vec3 (rx * cosAz - rz * sinAz) ry (rx * sinAz + rz * cosAz)

  ~(Vec4 skyR skyG skyB _) <- use @(ImageTexel "env_map") NilOps (Vec3 dirX dirY dirZ)

  let cloudThickness = 800.0
      cloudTop = cloudBottom + cloudThickness
      totalRayLength = min 10000.0 (cloudThickness / max 0.01 dirY)
      stepSize = totalRayLength / 6.0

      ditherHash = fract (sin (fma uvY 78.233 (uvX * 12.9898)) * 43758.5453)
      ditherOffset = ditherHash * stepSize

      tEntry = (cloudBottom - camY) / max 0.01 dirY + ditherOffset
      entryPos = Vec3 (camX + dirX * tEntry) cloudBottom (camZ + dirZ * tEntry)
      entryY = cloudBottom

      noiseScale = 0.003
      windSpeed = 0.05
      windOffset = time * windSpeed
      warpFreq = 0.002
      warpAmp = 170.0

      -- Step positions (unrolled)
      p0 = entryPos ^+^ dir ^* (stepSize * 0.5)
      ~(Vec3 p0x p0y p0z) = p0
      w0x = sin (p0y * warpFreq + p0z * warpFreq * 0.7) * warpAmp
      w0y = cos (p0x * warpFreq + p0z * warpFreq * 0.5) * warpAmp
      w0z = sin (p0z * warpFreq * 0.7 + p0x * warpFreq * 0.6) * warpAmp
      s0x = fract ((p0x + w0x) * noiseScale - windOffset)
      s0y = fract ((p0y + w0y) * noiseScale)
      s0z = fract ((p0z + w0z) * noiseScale)

      p1 = entryPos ^+^ dir ^* (stepSize * 1.5)
      ~(Vec3 p1x p1y p1z) = p1
      w1x = sin (p1y * warpFreq + p1z * warpFreq * 0.7) * warpAmp
      w1y = cos (p1x * warpFreq + p1z * warpFreq * 0.5) * warpAmp
      w1z = sin (p1z * warpFreq * 0.7 + p1x * warpFreq * 0.6) * warpAmp
      s1x = fract ((p1x + w1x) * noiseScale - windOffset)
      s1y = fract ((p1y + w1y) * noiseScale)
      s1z = fract ((p1z + w1z) * noiseScale)

      p2 = entryPos ^+^ dir ^* (stepSize * 2.5)
      ~(Vec3 p2x p2y p2z) = p2
      w2x = sin (p2y * warpFreq + p2z * warpFreq * 0.7) * warpAmp
      w2y = cos (p2x * warpFreq + p2z * warpFreq * 0.5) * warpAmp
      w2z = sin (p2z * warpFreq * 0.7 + p2x * warpFreq * 0.6) * warpAmp
      s2x = fract ((p2x + w2x) * noiseScale - windOffset)
      s2y = fract ((p2y + w2y) * noiseScale)
      s2z = fract ((p2z + w2z) * noiseScale)

      p3 = entryPos ^+^ dir ^* (stepSize * 3.5)
      ~(Vec3 p3x p3y p3z) = p3
      w3x = sin (p3y * warpFreq + p3z * warpFreq * 0.7) * warpAmp
      w3y = cos (p3x * warpFreq + p3z * warpFreq * 0.5) * warpAmp
      w3z = sin (p3z * warpFreq * 0.7 + p3x * warpFreq * 0.6) * warpAmp
      s3x = fract ((p3x + w3x) * noiseScale - windOffset)
      s3y = fract ((p3y + w3y) * noiseScale)
      s3z = fract ((p3z + w3z) * noiseScale)

      p4 = entryPos ^+^ dir ^* (stepSize * 4.5)
      ~(Vec3 p4x p4y p4z) = p4
      w4x = sin (p4y * warpFreq + p4z * warpFreq * 0.7) * warpAmp
      w4y = cos (p4x * warpFreq + p4z * warpFreq * 0.5) * warpAmp
      w4z = sin (p4z * warpFreq * 0.7 + p4x * warpFreq * 0.6) * warpAmp
      s4x = fract ((p4x + w4x) * noiseScale - windOffset)
      s4y = fract ((p4y + w4y) * noiseScale)
      s4z = fract ((p4z + w4z) * noiseScale)

      p5 = entryPos ^+^ dir ^* (stepSize * 5.5)
      ~(Vec3 p5x p5y p5z) = p5
      w5x = sin (p5y * warpFreq + p5z * warpFreq * 0.7) * warpAmp
      w5y = cos (p5x * warpFreq + p5z * warpFreq * 0.5) * warpAmp
      w5z = sin (p5z * warpFreq * 0.7 + p5x * warpFreq * 0.6) * warpAmp
      s5x = fract ((p5x + w5x) * noiseScale - windOffset)
      s5y = fract ((p5y + w5y) * noiseScale)
      s5z = fract ((p5z + w5z) * noiseScale)

      sunTexOffsetX = sunDirX * stepSize * noiseScale
      sunTexOffsetY = sunDirY * stepSize * noiseScale
      sunTexOffsetZ = sunDirZ * stepSize * noiseScale
      ls0x = fract (s0x + sunTexOffsetX)
      ls0y = fract (s0y + sunTexOffsetY)
      ls0z = fract (s0z + sunTexOffsetZ)
      ls1x = fract (s1x + sunTexOffsetX)
      ls1y = fract (s1y + sunTexOffsetY)
      ls1z = fract (s1z + sunTexOffsetZ)
      ls2x = fract (s2x + sunTexOffsetX)
      ls2y = fract (s2y + sunTexOffsetY)
      ls2z = fract (s2z + sunTexOffsetZ)
      ls3x = fract (s3x + sunTexOffsetX)
      ls3y = fract (s3y + sunTexOffsetY)
      ls3z = fract (s3z + sunTexOffsetZ)
      ls4x = fract (s4x + sunTexOffsetX)
      ls4y = fract (s4y + sunTexOffsetY)
      ls4z = fract (s4z + sunTexOffsetZ)
      ls5x = fract (s5x + sunTexOffsetX)
      ls5y = fract (s5y + sunTexOffsetY)
      ls5z = fract (s5z + sunTexOffsetZ)

  ~(Vec4 n0r n0g n0b n0a) <- use @(ImageTexel "cloud_noise") NilOps (Vec3 s0x s0y s0z)
  ~(Vec4 n1r n1g n1b n1a) <- use @(ImageTexel "cloud_noise") NilOps (Vec3 s1x s1y s1z)
  ~(Vec4 n2r n2g n2b n2a) <- use @(ImageTexel "cloud_noise") NilOps (Vec3 s2x s2y s2z)
  ~(Vec4 n3r n3g n3b n3a) <- use @(ImageTexel "cloud_noise") NilOps (Vec3 s3x s3y s3z)
  ~(Vec4 n4r n4g n4b n4a) <- use @(ImageTexel "cloud_noise") NilOps (Vec3 s4x s4y s4z)
  ~(Vec4 n5r n5g n5b n5a) <- use @(ImageTexel "cloud_noise") NilOps (Vec3 s5x s5y s5z)

  ~(Vec4 ln0r ln0g ln0b ln0a) <- use @(ImageTexel "cloud_noise") NilOps (Vec3 ls0x ls0y ls0z)
  ~(Vec4 ln1r ln1g ln1b ln1a) <- use @(ImageTexel "cloud_noise") NilOps (Vec3 ls1x ls1y ls1z)
  ~(Vec4 ln2r ln2g ln2b ln2a) <- use @(ImageTexel "cloud_noise") NilOps (Vec3 ls2x ls2y ls2z)
  ~(Vec4 ln3r ln3g ln3b ln3a) <- use @(ImageTexel "cloud_noise") NilOps (Vec3 ls3x ls3y ls3z)
  ~(Vec4 ln4r ln4g ln4b ln4a) <- use @(ImageTexel "cloud_noise") NilOps (Vec3 ls4x ls4y ls4z)
  ~(Vec4 ln5r ln5g ln5b ln5a) <- use @(ImageTexel "cloud_noise") NilOps (Vec3 ls5x ls5y ls5z)

  let heightF0 = smoothstep 0.0 0.15 (fma dirY (stepSize * 0.5) (entryY - cloudBottom) / cloudThickness) * (1.0 - smoothstep 0.85 1.0 (fma dirY (stepSize * 0.5) (entryY - cloudBottom) / cloudThickness))
      heightF1 = smoothstep 0.0 0.15 (fma dirY (stepSize * 1.5) (entryY - cloudBottom) / cloudThickness) * (1.0 - smoothstep 0.85 1.0 (fma dirY (stepSize * 1.5) (entryY - cloudBottom) / cloudThickness))
      heightF2 = smoothstep 0.0 0.15 (fma dirY (stepSize * 2.5) (entryY - cloudBottom) / cloudThickness) * (1.0 - smoothstep 0.85 1.0 (fma dirY (stepSize * 2.5) (entryY - cloudBottom) / cloudThickness))
      heightF3 = smoothstep 0.0 0.15 (fma dirY (stepSize * 3.5) (entryY - cloudBottom) / cloudThickness) * (1.0 - smoothstep 0.85 1.0 (fma dirY (stepSize * 3.5) (entryY - cloudBottom) / cloudThickness))
      heightF4 = smoothstep 0.0 0.15 (fma dirY (stepSize * 4.5) (entryY - cloudBottom) / cloudThickness) * (1.0 - smoothstep 0.85 1.0 (fma dirY (stepSize * 4.5) (entryY - cloudBottom) / cloudThickness))
      heightF5 = smoothstep 0.0 0.15 (fma dirY (stepSize * 5.5) (entryY - cloudBottom) / cloudThickness) * (1.0 - smoothstep 0.85 1.0 (fma dirY (stepSize * 5.5) (entryY - cloudBottom) / cloudThickness))

      cosTheta = dir ^.^ sunDir

      hgPhase g =
        let g2 = g * g
            denom = (1.0 + g2 - 2.0 * g * cosTheta) ** 1.5
         in (1.0 - g2) / (4.0 * 3.14159265 * denom)
      phase = 0.7 * hgPhase 0.6 + 0.3 * hgPhase (-0.3)

      cloudBase = Vec3 1.0 0.98 0.95

      d0 = max 0 (n0r * (1.0 - (n0g * 0.3 + n0b * 0.15 + n0a * 0.075)) - 0.15) * heightF0 * 4.0
      d1 = max 0 (n1r * (1.0 - (n1g * 0.3 + n1b * 0.15 + n1a * 0.075)) - 0.15) * heightF1 * 4.0
      d2 = max 0 (n2r * (1.0 - (n2g * 0.3 + n2b * 0.15 + n2a * 0.075)) - 0.15) * heightF2 * 4.0
      d3 = max 0 (n3r * (1.0 - (n3g * 0.3 + n3b * 0.15 + n3a * 0.075)) - 0.15) * heightF3 * 4.0
      d4 = max 0 (n4r * (1.0 - (n4g * 0.3 + n4b * 0.15 + n4a * 0.075)) - 0.15) * heightF4 * 4.0
      d5 = max 0 (n5r * (1.0 - (n5g * 0.3 + n5b * 0.15 + n5a * 0.075)) - 0.15) * heightF5 * 4.0

      ld0 = max 0 (ln0r * (1.0 - (ln0g * 0.3 + ln0b * 0.15 + ln0a * 0.075)) - 0.15) * heightF0 * 4.0
      ld1 = max 0 (ln1r * (1.0 - (ln1g * 0.3 + ln1b * 0.15 + ln1a * 0.075)) - 0.15) * heightF1 * 4.0
      ld2 = max 0 (ln2r * (1.0 - (ln2g * 0.3 + ln2b * 0.15 + ln2a * 0.075)) - 0.15) * heightF2 * 4.0
      ld3 = max 0 (ln3r * (1.0 - (ln3g * 0.3 + ln3b * 0.15 + ln3a * 0.075)) - 0.15) * heightF3 * 4.0
      ld4 = max 0 (ln4r * (1.0 - (ln4g * 0.3 + ln4b * 0.15 + ln4a * 0.075)) - 0.15) * heightF4 * 4.0
      ld5 = max 0 (ln5r * (1.0 - (ln5g * 0.3 + ln5b * 0.15 + ln5a * 0.075)) - 0.15) * heightF5 * 4.0

      lightT d =
        let b = exp (-d * 1.5)
            p = 0.7 * exp (-d * 0.25)
         in max b p
      lightT0 = lightT ld0
      lightT1 = lightT ld1
      lightT2 = lightT ld2
      lightT3 = lightT ld3
      lightT4 = lightT ld4
      lightT5 = lightT ld5

      s0 = cloudBase ^* (lightT0 * phase * d0 * stepSize)
      t0 = exp (-d0 * stepSize)
      a0 = s0

      s1 = cloudBase ^* (lightT1 * phase * d1 * stepSize)
      t1 = t0 * exp (-d1 * stepSize)
      a1 = a0 ^+^ s1 ^* t0

      active2 = step 0.01 t1
      d2_eff = d2 * active2
      s2 = cloudBase ^* (lightT2 * phase * d2_eff * stepSize)
      t2 = t1 * exp (-d2_eff * stepSize)
      a2 = a1 ^+^ s2 ^* t1

      active3 = step 0.01 t2
      d3_eff = d3 * active3
      s3 = cloudBase ^* (lightT3 * phase * d3_eff * stepSize)
      t3 = t2 * exp (-d3_eff * stepSize)
      a3 = a2 ^+^ s3 ^* t2

      active4 = step 0.01 t3
      d4_eff = d4 * active4
      s4 = cloudBase ^* (lightT4 * phase * d4_eff * stepSize)
      t4 = t3 * exp (-d4_eff * stepSize)
      a4 = a3 ^+^ s4 ^* t3

      active5 = step 0.01 t4
      d5_eff = d5 * active5
      s5 = cloudBase ^* (lightT5 * phase * d5_eff * stepSize)
      t5 = t4 * exp (-d5_eff * stepSize)
      a5 = a4 ^+^ s5 ^* t4

      ~(Vec3 cloudAccR cloudAccG cloudAccB) = a5
      cloudTransmittance = t5

      cloudsMask = step 0.01 dirY
      finalCloudR = cloudAccR * cloudsMask
      finalCloudG = cloudAccG * cloudsMask
      finalCloudB = cloudAccB * cloudsMask
      finalTransmittance = mix 1.0 cloudTransmittance cloudsMask

      cloudSkyR = skyR * finalTransmittance + finalCloudR
      cloudSkyG = skyG * finalTransmittance + finalCloudG
      cloudSkyB = skyB * finalTransmittance + finalCloudB

      -- Apply sky tint
      skyTintR = view @(Name "skyTintR") cameraPos
      skyTintG = view @(Name "skyTintG") cameraPos
      skyTintB = view @(Name "skyTintB") cameraPos
      tintedSkyR = cloudSkyR * skyTintR
      tintedSkyG = cloudSkyG * skyTintG
      tintedSkyB = cloudSkyB * skyTintB

      -- Temporal accumulation with reprojection
      blendFactor = view @(Name "blendFactor") cameraPos

      -- World-space cloud entry point
      worldX = camX + dirX * tEntry
      worldY = cloudBottom
      worldZ = camZ + dirZ * tEntry

      -- Previous frame view-projection matrix columns
      prevVP0 = view @(Name "prevViewProj0") cameraPos
      prevVP1 = view @(Name "prevViewProj1") cameraPos
      prevVP2 = view @(Name "prevViewProj2") cameraPos
      prevVP3 = view @(Name "prevViewProj3") cameraPos

      -- Manual mat4 * vec4 multiplication (column-vector convention)
      ~(Vec4 m00 m10 m20 m30) = prevVP0
      ~(Vec4 m01 m11 m21 m31) = prevVP1
      ~(Vec4 m02 m12 m22 m32) = prevVP2
      ~(Vec4 m03 m13 m23 m33) = prevVP3

      prevClipX = m00 * worldX + m01 * worldY + m02 * worldZ + m03 * 1.0
      prevClipY = m10 * worldX + m11 * worldY + m12 * worldZ + m13 * 1.0
      prevClipZ = m20 * worldX + m21 * worldY + m22 * worldZ + m23 * 1.0
      prevClipW = m30 * worldX + m31 * worldY + m32 * worldZ + m33 * 1.0

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
      reprojBlend = blendFactor * validReproj
      accR = reprojBlend * histR + (1.0 - reprojBlend) * tintedSkyR
      accG = reprojBlend * histG + (1.0 - reprojBlend) * tintedSkyG
      accB = reprojBlend * histB + (1.0 - reprojBlend) * tintedSkyB

  put @"out_colour" (Vec4 accR accG accB 1.0)
