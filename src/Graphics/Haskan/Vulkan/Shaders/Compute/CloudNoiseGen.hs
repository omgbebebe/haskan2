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

      -- 3D hash functions
      hash3 px py pz =
        let dp = px * 127.1 + py * 311.7 + pz * 74.7 + seed
         in fract (sin dp * 43758.5453)

      hash3b px py pz =
        let dp = px * 269.5 + py * 183.3 + pz * 421.1 + seed + 1000.0
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

      -- Value noise at a point
      vnoise px py pz =
        let ix = floor px
            iy = floor py
            iz = floor pz
            fx = fract px
            fy = fract py
            fz = fract pz
            ux = fx * fx * (3.0 - 2.0 * fx)
            uy = fy * fy * (3.0 - 2.0 * fy)
            uz = fz * fz * (3.0 - 2.0 * fz)
            n000 = hash3 ix iy iz
            n100 = hash3 (ix + 1.0) iy iz
            n010 = hash3 ix (iy + 1.0) iz
            n110 = hash3 (ix + 1.0) (iy + 1.0) iz
            n001 = hash3 ix iy (iz + 1.0)
            n101 = hash3 (ix + 1.0) iy (iz + 1.0)
            n011 = hash3 ix (iy + 1.0) (iz + 1.0)
            n111 = hash3 (ix + 1.0) (iy + 1.0) (iz + 1.0)
         in triLerp n000 n100 n010 n110 n001 n101 n011 n111 ux uy uz

      -- Value noise with different hash (for domain warping)
      vnoiseB px py pz =
        let ix = floor px
            iy = floor py
            iz = floor pz
            fx = fract px
            fy = fract py
            fz = fract pz
            ux = fx * fx * (3.0 - 2.0 * fx)
            uy = fy * fy * (3.0 - 2.0 * fy)
            uz = fz * fz * (3.0 - 2.0 * fz)
            n000 = hash3b ix iy iz
            n100 = hash3b (ix + 1.0) iy iz
            n010 = hash3b ix (iy + 1.0) iz
            n110 = hash3b (ix + 1.0) (iy + 1.0) iz
            n001 = hash3b ix iy (iz + 1.0)
            n101 = hash3b (ix + 1.0) iy (iz + 1.0)
            n011 = hash3b ix (iy + 1.0) (iz + 1.0)
            n111 = hash3b (ix + 1.0) (iy + 1.0) (iz + 1.0)
         in triLerp n000 n100 n010 n110 n001 n101 n011 n111 ux uy uz

      -- Single octave of value noise
      vnoise1 px py pz f = vnoise (px * f) (py * f) (pz * f)

      -- Domain-warped FBM: low-freq warp distorts high-freq sampling
      -- This creates billowy, cloud-like shapes
      warpFreq = freq * 0.5
      warpAmt = 0.3

      wx = vnoiseB (x * warpFreq + 100.0) (y * warpFreq + 200.0) (z * warpFreq + 300.0) * warpAmt
      wy = vnoiseB (x * warpFreq + 400.0) (y * warpFreq + 500.0) (z * warpFreq + 600.0) * warpAmt
      wz = vnoiseB (x * warpFreq + 700.0) (y * warpFreq + 800.0) (z * warpFreq + 900.0) * warpAmt

      -- Warped coordinates for macro noise
      wx1 = x + wx
      wy1 = y + wy
      wz1 = z + wz

      -- FBM on warped coordinates (4 octaves, unrolled)
      o1 = vnoise1 wx1 wy1 wz1 freq
      o2 = vnoise1 wx1 wy1 wz1 (freq * 2.0) * persist
      o3 = vnoise1 wx1 wy1 wz1 (freq * 4.0) * persist * persist
      o4 = vnoise1 wx1 wy1 wz1 (freq * 8.0) * persist * persist * persist

      maxAmp = 1.0 + persist + persist * persist + persist * persist * persist
      macroNoise = (o1 + o2 + o3 + o4) / maxAmp

      -- Medium detail: domain-warped at different scale
      mwx = x + vnoiseB (x * 2.0 + 50.0) (y * 2.0 + 150.0) (z * 2.0 + 250.0) * 0.2
      mwy = y + vnoiseB (x * 2.0 + 350.0) (y * 2.0 + 450.0) (z * 2.0 + 550.0) * 0.2
      mwz = z + vnoiseB (x * 2.0 + 650.0) (y * 2.0 + 750.0) (z * 2.0 + 850.0) * 0.2
      mediumNoise = vnoise1 mwx mwy mwz 14.8

      -- High detail: simpler domain warp
      hwx = x + vnoiseB (x * 4.0 + 25.0) (y * 4.0 + 75.0) (z * 4.0 + 125.0) * 0.15
      hwy = y + vnoiseB (x * 4.0 + 175.0) (y * 4.0 + 225.0) (z * 4.0 + 275.0) * 0.15
      hwz = z + vnoiseB (x * 4.0 + 325.0) (y * 4.0 + 375.0) (z * 4.0 + 425.0) * 0.15
      highNoise = vnoise1 hwx hwy hwz 29.6

      -- Micro detail: no warp, just value noise
      microNoise = vnoise1 x y z 59.2

  imageWrite @"noiseImage" (Vec3 gidX gidY gidZ) (Vec4 macroNoise mediumNoise highNoise microNoise)
