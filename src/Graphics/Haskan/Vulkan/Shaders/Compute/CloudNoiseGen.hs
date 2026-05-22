{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Graphics.Haskan.Vulkan.Shaders.Compute.CloudNoiseGen
  ( Defs,
    program,
  )
where

import FIR
import FIR.Prim.Image (ImageCoordinateKind (..))
import Math.Linear

type NoiseParams =
  Struct
    '[ "seed" ':-> Float,
       "frequency" ':-> Float,
       "persistence" ':-> Float,
       "zSlice" ':-> Float
     ]

type Defs =
  '[ "noiseImage" ':-> StorageImage '[DescriptorSet 0, Binding 0] (Properties IntegralCoordinates Float ThreeD (Just NotDepthImage) NonArrayed SingleSampled Storage (Just (RGBA8 UNorm))),
     "noiseParams" ':-> Uniform '[DescriptorSet 0, Binding 1] NoiseParams,
     "main" ':-> EntryPoint '[LocalSize 8 8 4] Compute
   ]

program :: Module Defs
program = Module $ entryPoint @"main" @Compute do
  ~(Vec3 gidX gidY gidZ) <- get @"gl_GlobalInvocationID"

  seed <- use @(Name "noiseParams" :.: Name "seed")
  freq <- use @(Name "noiseParams" :.: Name "frequency")
  persist <- use @(Name "noiseParams" :.: Name "persistence")

  let size = 255.0
      x = (fromIntegral gidX :: Code Float) / size
      y = (fromIntegral gidY :: Code Float) / size
      z = (fromIntegral gidZ :: Code Float) / size

      -- Tileable 3D hash: wraps cell coordinates to [0, period)
      hash3 px py pz period =
        let pxWrap = fract (px / period) * period
            pyWrap = fract (py / period) * period
            pzWrap = fract (pz / period) * period
            dp = pxWrap * 127.1 + pyWrap * 311.7 + pzWrap * 74.7 + seed
         in fract (sin dp * 43758.5453)

      hash3b px py pz period =
        let pxWrap = fract (px / period) * period
            pyWrap = fract (py / period) * period
            pzWrap = fract (pz / period) * period
            dp = pxWrap * 269.5 + pyWrap * 183.3 + pzWrap * 421.1 + seed + 1000.0
         in fract (sin dp * 43758.5453)

      -- Trilinear interpolation
      triLerp c000 c100 c010 c110 c001 c101 c011 c111 fx fy fz =
        let cx00 = mix c000 c100 fx
            cx10 = mix c010 c110 fx
            cx01 = mix c001 c101 fx
            cx11 = mix c011 c111 fx
            cxy0 = mix cx00 cx10 fy
            cxy1 = mix cx01 cx11 fy
         in mix cxy0 cxy1 fz

      -- Tileable value noise at a point
      vnoise px py pz period =
        let ix = floor px
            iy = floor py
            iz = floor pz
            fx = fract px
            fy = fract py
            fz = fract pz
            ux = fx * fx * (3.0 - 2.0 * fx)
            uy = fy * fy * (3.0 - 2.0 * fy)
            uz = fz * fz * (3.0 - 2.0 * fz)
            n000 = hash3 ix iy iz period
            n100 = hash3 (ix + 1.0) iy iz period
            n010 = hash3 ix (iy + 1.0) iz period
            n110 = hash3 (ix + 1.0) (iy + 1.0) iz period
            n001 = hash3 ix iy (iz + 1.0) period
            n101 = hash3 (ix + 1.0) iy (iz + 1.0) period
            n011 = hash3 ix (iy + 1.0) (iz + 1.0) period
            n111 = hash3 (ix + 1.0) (iy + 1.0) (iz + 1.0) period
         in triLerp n000 n100 n010 n110 n001 n101 n011 n111 ux uy uz

      -- Value noise with different hash (for domain warping)
      vnoiseB px py pz period =
        let ix = floor px
            iy = floor py
            iz = floor pz
            fx = fract px
            fy = fract py
            fz = fract pz
            ux = fx * fx * (3.0 - 2.0 * fx)
            uy = fy * fy * (3.0 - 2.0 * fy)
            uz = fz * fz * (3.0 - 2.0 * fz)
            n000 = hash3b ix iy iz period
            n100 = hash3b (ix + 1.0) iy iz period
            n010 = hash3b ix (iy + 1.0) iz period
            n110 = hash3b (ix + 1.0) (iy + 1.0) iz period
            n001 = hash3b ix iy (iz + 1.0) period
            n101 = hash3b (ix + 1.0) iy (iz + 1.0) period
            n011 = hash3b ix (iy + 1.0) (iz + 1.0) period
            n111 = hash3b (ix + 1.0) (iy + 1.0) (iz + 1.0) period
         in triLerp n000 n100 n010 n110 n001 n101 n011 n111 ux uy uz

      vnoise1 px py pz f period = vnoise (px * f) (py * f) (pz * f) period

      -- Frequencies as powers of 2 so they tile seamlessly in 256^3
      macroFreq = 2.0
      mediumFreq = 8.0
      highFreq = 16.0
      microFreq = 32.0

      -- Domain warp: coordinates must be x*period with no offsets,
      -- so warp(0) == warp(1) for seamless tiling.
      -- period must be integer for grid-point wrapping to align.
      warpFreq = macroFreq
      warpAmt = 0.25

      wx = vnoiseB (x * warpFreq) (y * warpFreq) (z * warpFreq) warpFreq * warpAmt
      wy = vnoiseB (y * warpFreq) (z * warpFreq) (x * warpFreq) warpFreq * warpAmt
      wz = vnoiseB (z * warpFreq) (x * warpFreq) (y * warpFreq) warpFreq * warpAmt

      -- Warped coordinates for macro noise
      wx1 = x + wx
      wy1 = y + wy
      wz1 = z + wz

      -- FBM: each octave uses period = frequency for distinct grid points.
      -- With fixed period, hash wraps higher-freq grid points to the same
      -- values, collapsing FBM into repeated low-freq patterns.
      o1 = vnoise1 wx1 wy1 wz1 macroFreq macroFreq
      o2 = vnoise1 wx1 wy1 wz1 (macroFreq * 2.0) (macroFreq * 2.0) * persist
      o3 = vnoise1 wx1 wy1 wz1 (macroFreq * 4.0) (macroFreq * 4.0) * persist * persist
      o4 = vnoise1 wx1 wy1 wz1 (macroFreq * 8.0) (macroFreq * 8.0) * persist * persist * persist

      maxAmp = 1.0 + persist + persist * persist + persist * persist * persist
      macroNoise = (o1 + o2 + o3 + o4) / maxAmp

      -- Detail channels: no warp needed (fragment shader handles domain warping)
      mediumNoise = vnoise1 x y z mediumFreq mediumFreq
      highNoise = vnoise1 x y z highFreq highFreq
      microNoise = vnoise1 x y z microFreq microFreq

  imageWrite @"noiseImage" (Vec3 gidX gidY gidZ) (Vec4 macroNoise mediumNoise highNoise microNoise)
