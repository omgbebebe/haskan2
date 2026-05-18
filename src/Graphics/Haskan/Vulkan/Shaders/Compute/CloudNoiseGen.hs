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
      p = Vec3 x y z

      -- Simple 3D hash
      hash3 px py pz =
        let dp = px * 127.1 + py * 311.7 + pz * 74.7 + seed
         in fract (sin dp * 43758.5453)

      -- Trilinear interpolation helper
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

      -- FBM octaves (unrolled to avoid nested lets)
      o1 = vnoise (x * freq) (y * freq) (z * freq)
      o2 = vnoise (x * freq * 2.0) (y * freq * 2.0) (z * freq * 2.0) * persist
      o3 = vnoise (x * freq * 4.0) (y * freq * 4.0) (z * freq * 4.0) * persist * persist
      o4 = vnoise (x * freq * 8.0) (y * freq * 8.0) (z * freq * 8.0) * persist * persist * persist

      maxAmp = 1.0 + persist + persist * persist + persist * persist * persist
      macroNoise = (o1 + o2 + o3 + o4) / maxAmp

      mediumNoise = vnoise (x * 14.8 + 100.0) (y * 14.8 + 200.0) (z * 14.8 + 300.0)
      highNoise   = vnoise (x * 29.6 + 400.0) (y * 29.6 + 500.0) (z * 29.6 + 600.0)
      microNoise  = vnoise (x * 59.2 + 700.0) (y * 59.2 + 800.0) (z * 59.2 + 900.0)

  imageWrite @"noiseImage" (Vec3 gidX gidY gidZ) (Vec4 macroNoise mediumNoise highNoise microNoise)