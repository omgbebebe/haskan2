{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

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
       "sunAzimuth" ':-> Float,
       "ray0" ':-> V 3 Float,
       "ray1" ':-> V 3 Float,
       "ray2" ':-> V 3 Float,
       "skyTintR" ':-> Float,
       "skyTintG" ':-> Float,
       "skyTintB" ':-> Float,
       "iblIntensity" ':-> Float,
       "sunDir" ':-> V 3 Float,
       "cloudHeight" ':-> Float,
       "time" ':-> Float
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
  let (Vec3 rayDirX rayDirY rayDirZ) = rayDir

  let rayLen = sqrt (rayDirX * rayDirX + rayDirY * rayDirY + rayDirZ * rayDirZ + 0.0001)
      dirX = rayDirX / rayLen
      dirY = rayDirY / rayLen
      dirZ = rayDirZ / rayLen

  cameraPos <- get @"cameraPos"
  let sunAzimuth = view @(Name "sunAzimuth") cameraPos
      camX = view @(Name "cameraX") cameraPos
      camY = view @(Name "cameraY") cameraPos
      camZ = view @(Name "cameraZ") cameraPos
      ~(Vec3 sunDirX sunDirY sunDirZ) = view @(Name "sunDir") cameraPos
      cloudBottom = view @(Name "cloudHeight") cameraPos
      time = view @(Name "time") cameraPos

  let cosAz = cos sunAzimuth
      sinAz = sin sunAzimuth
      rotateY (Vec3 rx ry rz) = Vec3 (rx * cosAz - rz * sinAz) ry (rx * sinAz + rz * cosAz)

  ~(Vec4 skyR skyG skyB _) <- use @(ImageTexel "env_map") NilOps (Vec3 dirX dirY dirZ)

  let cloudThickness = 800.0
      cloudTop = cloudBottom + cloudThickness
      totalRayLength = cloudThickness / max 0.01 dirY
      stepSize = totalRayLength / 6.0

      ditherHash = fract (sin (uvX * 12.9898 + uvY * 78.233) * 43758.5453)
      ditherOffset = ditherHash * stepSize

      tEntry = (cloudBottom - camY) / max 0.01 dirY + ditherOffset
      entryX = camX + dirX * tEntry
      entryY = cloudBottom
      entryZ = camZ + dirZ * tEntry

      noiseScale = 0.001
      windSpeed = 0.05
      windOffset = time * windSpeed
      warpFreq = 0.002
      warpAmp = 500.0

      -- Step positions (unrolled)
      p0x = entryX + dirX * (stepSize * 0.5)
      p0y = entryY + dirY * (stepSize * 0.5)
      p0z = entryZ + dirZ * (stepSize * 0.5)
      w0x = sin (p0y * warpFreq) * warpAmp
      w0y = cos (p0x * warpFreq) * warpAmp
      w0z = sin (p0z * warpFreq * 0.7) * warpAmp
      s0x = fract ((p0x + w0x) * noiseScale - windOffset)
      s0y = fract ((p0y + w0y) * noiseScale)
      s0z = fract ((p0z + w0z) * noiseScale)

      p1x = entryX + dirX * (stepSize * 1.5)
      p1y = entryY + dirY * (stepSize * 1.5)
      p1z = entryZ + dirZ * (stepSize * 1.5)
      w1x = sin (p1y * warpFreq) * warpAmp
      w1y = cos (p1x * warpFreq) * warpAmp
      w1z = sin (p1z * warpFreq * 0.7) * warpAmp
      s1x = fract ((p1x + w1x) * noiseScale - windOffset)
      s1y = fract ((p1y + w1y) * noiseScale)
      s1z = fract ((p1z + w1z) * noiseScale)

      p2x = entryX + dirX * (stepSize * 2.5)
      p2y = entryY + dirY * (stepSize * 2.5)
      p2z = entryZ + dirZ * (stepSize * 2.5)
      w2x = sin (p2y * warpFreq) * warpAmp
      w2y = cos (p2x * warpFreq) * warpAmp
      w2z = sin (p2z * warpFreq * 0.7) * warpAmp
      s2x = fract ((p2x + w2x) * noiseScale - windOffset)
      s2y = fract ((p2y + w2y) * noiseScale)
      s2z = fract ((p2z + w2z) * noiseScale)

      p3x = entryX + dirX * (stepSize * 3.5)
      p3y = entryY + dirY * (stepSize * 3.5)
      p3z = entryZ + dirZ * (stepSize * 3.5)
      w3x = sin (p3y * warpFreq) * warpAmp
      w3y = cos (p3x * warpFreq) * warpAmp
      w3z = sin (p3z * warpFreq * 0.7) * warpAmp
      s3x = fract ((p3x + w3x) * noiseScale - windOffset)
      s3y = fract ((p3y + w3y) * noiseScale)
      s3z = fract ((p3z + w3z) * noiseScale)

      p4x = entryX + dirX * (stepSize * 4.5)
      p4y = entryY + dirY * (stepSize * 4.5)
      p4z = entryZ + dirZ * (stepSize * 4.5)
      w4x = sin (p4y * warpFreq) * warpAmp
      w4y = cos (p4x * warpFreq) * warpAmp
      w4z = sin (p4z * warpFreq * 0.7) * warpAmp
      s4x = fract ((p4x + w4x) * noiseScale - windOffset)
      s4y = fract ((p4y + w4y) * noiseScale)
      s4z = fract ((p4z + w4z) * noiseScale)

      p5x = entryX + dirX * (stepSize * 5.5)
      p5y = entryY + dirY * (stepSize * 5.5)
      p5z = entryZ + dirZ * (stepSize * 5.5)
      w5x = sin (p5y * warpFreq) * warpAmp
      w5y = cos (p5x * warpFreq) * warpAmp
      w5z = sin (p5z * warpFreq * 0.7) * warpAmp
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

  let heightF0 = smoothstep 0.0 0.15 ((entryY + dirY * (stepSize * 0.5) - cloudBottom) / cloudThickness) * (1.0 - smoothstep 0.85 1.0 ((entryY + dirY * (stepSize * 0.5) - cloudBottom) / cloudThickness))
      heightF1 = smoothstep 0.0 0.15 ((entryY + dirY * (stepSize * 1.5) - cloudBottom) / cloudThickness) * (1.0 - smoothstep 0.85 1.0 ((entryY + dirY * (stepSize * 1.5) - cloudBottom) / cloudThickness))
      heightF2 = smoothstep 0.0 0.15 ((entryY + dirY * (stepSize * 2.5) - cloudBottom) / cloudThickness) * (1.0 - smoothstep 0.85 1.0 ((entryY + dirY * (stepSize * 2.5) - cloudBottom) / cloudThickness))
      heightF3 = smoothstep 0.0 0.15 ((entryY + dirY * (stepSize * 3.5) - cloudBottom) / cloudThickness) * (1.0 - smoothstep 0.85 1.0 ((entryY + dirY * (stepSize * 3.5) - cloudBottom) / cloudThickness))
      heightF4 = smoothstep 0.0 0.15 ((entryY + dirY * (stepSize * 4.5) - cloudBottom) / cloudThickness) * (1.0 - smoothstep 0.85 1.0 ((entryY + dirY * (stepSize * 4.5) - cloudBottom) / cloudThickness))
      heightF5 = smoothstep 0.0 0.15 ((entryY + dirY * (stepSize * 5.5) - cloudBottom) / cloudThickness) * (1.0 - smoothstep 0.85 1.0 ((entryY + dirY * (stepSize * 5.5) - cloudBottom) / cloudThickness))

      cosTheta = dirX * sunDirX + dirY * sunDirY + dirZ * sunDirZ

      hgPhase g =
        let g2 = g * g
            denom = (1.0 + g2 - 2.0 * g * cosTheta) ** 1.5
         in (1.0 - g2) / (4.0 * 3.14159265 * denom)
      phase = 0.7 * hgPhase 0.6 + 0.3 * hgPhase (-0.3)

      cloudBaseR = 1.0
      cloudBaseG = 0.98
      cloudBaseB = 0.95

      d0 = max 0 (n0r * n0a - (n0g * 0.5 + n0b * 0.25) * 0.8 - 0.25) * heightF0 * 4.0
      d1 = max 0 (n1r * n1a - (n1g * 0.5 + n1b * 0.25) * 0.8 - 0.25) * heightF1 * 4.0
      d2 = max 0 (n2r * n2a - (n2g * 0.5 + n2b * 0.25) * 0.8 - 0.25) * heightF2 * 4.0
      d3 = max 0 (n3r * n3a - (n3g * 0.5 + n3b * 0.25) * 0.8 - 0.25) * heightF3 * 4.0
      d4 = max 0 (n4r * n4a - (n4g * 0.5 + n4b * 0.25) * 0.8 - 0.25) * heightF4 * 4.0
      d5 = max 0 (n5r * n5a - (n5g * 0.5 + n5b * 0.25) * 0.8 - 0.25) * heightF5 * 4.0

      ld0 = max 0 (ln0r * ln0a - (ln0g * 0.5 + ln0b * 0.25) * 0.8 - 0.25) * heightF0 * 4.0
      ld1 = max 0 (ln1r * ln1a - (ln1g * 0.5 + ln1b * 0.25) * 0.8 - 0.25) * heightF1 * 4.0
      ld2 = max 0 (ln2r * ln2a - (ln2g * 0.5 + ln2b * 0.25) * 0.8 - 0.25) * heightF2 * 4.0
      ld3 = max 0 (ln3r * ln3a - (ln3g * 0.5 + ln3b * 0.25) * 0.8 - 0.25) * heightF3 * 4.0
      ld4 = max 0 (ln4r * ln4a - (ln4g * 0.5 + ln4b * 0.25) * 0.8 - 0.25) * heightF4 * 4.0
      ld5 = max 0 (ln5r * ln5a - (ln5g * 0.5 + ln5b * 0.25) * 0.8 - 0.25) * heightF5 * 4.0

      lightT d =
        let b = exp (-d * 5.0)
            p = 0.7 * exp (-d * 0.1)
         in max b p
      lightT0 = lightT ld0
      lightT1 = lightT ld1
      lightT2 = lightT ld2
      lightT3 = lightT ld3
      lightT4 = lightT ld4
      lightT5 = lightT ld5

      lightR0 = lightT0 * phase
      lightG0 = lightT0 * phase
      lightB0 = lightT0 * phase
      lightR1 = lightT1 * phase
      lightG1 = lightT1 * phase
      lightB1 = lightT1 * phase
      lightR2 = lightT2 * phase
      lightG2 = lightT2 * phase
      lightB2 = lightT2 * phase
      lightR3 = lightT3 * phase
      lightG3 = lightT3 * phase
      lightB3 = lightT3 * phase
      lightR4 = lightT4 * phase
      lightG4 = lightT4 * phase
      lightB4 = lightT4 * phase
      lightR5 = lightT5 * phase
      lightG5 = lightT5 * phase
      lightB5 = lightT5 * phase

      s0r = cloudBaseR * lightR0 * d0 * stepSize
      s0g = cloudBaseG * lightG0 * d0 * stepSize
      s0b = cloudBaseB * lightB0 * d0 * stepSize
      t0 = exp (-d0 * stepSize)
      a0r = s0r
      a0g = s0g
      a0b = s0b

      s1r = cloudBaseR * lightR1 * d1 * stepSize
      s1g = cloudBaseG * lightG1 * d1 * stepSize
      s1b = cloudBaseB * lightB1 * d1 * stepSize
      t1 = t0 * exp (-d1 * stepSize)
      a1r = a0r + s1r * t0
      a1g = a0g + s1g * t0
      a1b = a0b + s1b * t0

      active2 = step 0.01 t1
      d2_eff = d2 * active2
      s2r = cloudBaseR * lightR2 * d2_eff * stepSize
      s2g = cloudBaseG * lightG2 * d2_eff * stepSize
      s2b = cloudBaseB * lightB2 * d2_eff * stepSize
      t2 = t1 * exp (-d2_eff * stepSize)
      a2r = a1r + s2r * t1
      a2g = a1g + s2g * t1
      a2b = a1b + s2b * t1

      active3 = step 0.01 t2
      d3_eff = d3 * active3
      s3r = cloudBaseR * lightR3 * d3_eff * stepSize
      s3g = cloudBaseG * lightG3 * d3_eff * stepSize
      s3b = cloudBaseB * lightB3 * d3_eff * stepSize
      t3 = t2 * exp (-d3_eff * stepSize)
      a3r = a2r + s3r * t2
      a3g = a2g + s3g * t2
      a3b = a2b + s3b * t2

      active4 = step 0.01 t3
      d4_eff = d4 * active4
      s4r = cloudBaseR * lightR4 * d4_eff * stepSize
      s4g = cloudBaseG * lightG4 * d4_eff * stepSize
      s4b = cloudBaseB * lightB4 * d4_eff * stepSize
      t4 = t3 * exp (-d4_eff * stepSize)
      a4r = a3r + s4r * t3
      a4g = a3g + s4g * t3
      a4b = a3b + s4b * t3

      active5 = step 0.01 t4
      d5_eff = d5 * active5
      s5r = cloudBaseR * lightR5 * d5_eff * stepSize
      s5g = cloudBaseG * lightG5 * d5_eff * stepSize
      s5b = cloudBaseB * lightB5 * d5_eff * stepSize
      t5 = t4 * exp (-d5_eff * stepSize)
      a5r = a4r + s5r * t4
      a5g = a4g + s5g * t4
      a5b = a4b + s5b * t4

      cloudAccR = a5r
      cloudAccG = a5g
      cloudAccB = a5b
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

  put @"out_colour" (Vec4 tintedSkyR tintedSkyG tintedSkyB 1.0)
