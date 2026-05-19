{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Graphics.Haskan.Vulkan.Shaders.Compute.WeatherMapGen
  ( Defs,
    program,
  )
where

import FIR
import FIR.Prim.Image (ImageCoordinateKind (..))
import Math.Linear

type WeatherParams =
  Struct
    '[ "seed" ':-> Float,
       "coverageScale" ':-> Float,
       "typeScale" ':-> Float,
       "heightScale" ':-> Float
     ]

type Defs =
  '[ "weatherImage" ':-> StorageImage '[DescriptorSet 0, Binding 0] (Properties IntegralCoordinates Float TwoD (Just NotDepthImage) NonArrayed SingleSampled Storage (Just (RGBA8 UNorm))),
     "weatherParams" ':-> Uniform '[DescriptorSet 0, Binding 1] WeatherParams,
     "main" ':-> EntryPoint '[LocalSize 8 8 1] Compute
   ]

program :: Module Defs
program = Module $ entryPoint @"main" @Compute do
  ~(Vec3 gidX gidY _gidZ) <- get @"gl_GlobalInvocationID"

  seed <- use @(Name "weatherParams" :.: Name "seed")
  covScale <- use @(Name "weatherParams" :.: Name "coverageScale")
  typeScale <- use @(Name "weatherParams" :.: Name "typeScale")
  hScale <- use @(Name "weatherParams" :.: Name "heightScale")

  let size = 511.0
      x = (fromIntegral gidX :: Code Float) / size
      y = (fromIntegral gidY :: Code Float) / size

      -- Tileable 2D hash: wraps cell coordinates to [0, period)
      hash2 px py period =
        let pxWrap = fract (px / period) * period
            pyWrap = fract (py / period) * period
            dp = pxWrap * 127.1 + pyWrap * 311.7 + seed
         in fract (sin dp * 43758.5453)

      hash2b px py period =
        let pxWrap = fract (px / period) * period
            pyWrap = fract (py / period) * period
            dp = pxWrap * 269.5 + pyWrap * 183.3 + seed + 1000.0
         in fract (sin dp * 43758.5453)

      -- Bilinear interpolation
      biLerp c00 c10 c01 c11 fx fy =
        let cx0 = mix c00 c10 fx
            cx1 = mix c01 c11 fx
         in mix cx0 cx1 fy

      -- Tileable value noise at a point (2D)
      vnoise2 px py period =
        let ix = floor px
            iy = floor py
            fx = fract px
            fy = fract py
            ux = fx * fx * (3.0 - 2.0 * fx)
            uy = fy * fy * (3.0 - 2.0 * fy)
            n00 = hash2 ix iy period
            n10 = hash2 (ix + 1.0) iy period
            n01 = hash2 ix (iy + 1.0) period
            n11 = hash2 (ix + 1.0) (iy + 1.0) period
         in biLerp n00 n10 n01 n11 ux uy

      vnoise2b px py period =
        let ix = floor px
            iy = floor py
            fx = fract px
            fy = fract py
            ux = fx * fx * (3.0 - 2.0 * fx)
            uy = fy * fy * (3.0 - 2.0 * fy)
            n00 = hash2b ix iy period
            n10 = hash2b (ix + 1.0) iy period
            n01 = hash2b ix (iy + 1.0) period
            n11 = hash2b (ix + 1.0) (iy + 1.0) period
         in biLerp n00 n10 n01 n11 ux uy

      vnoise2_1 px py f = vnoise2 (px * f) (py * f) f

      -- Domain warp for coverage (periodic with same period as coverage)
      warpFreq = covScale * 0.3
      warpAmt = 0.2

      wx = vnoise2b (x * warpFreq + 100.0) (y * warpFreq + 200.0) warpFreq * warpAmt
      wy = vnoise2b (x * warpFreq + 300.0) (y * warpFreq + 400.0) warpFreq * warpAmt

      wx1 = x + wx
      wy1 = y + wy

      -- Coverage: large-scale tileable FBM with domain warp
      c1 = vnoise2_1 wx1 wy1 covScale
      c2 = vnoise2_1 wx1 wy1 (covScale * 2.0) * 0.5
      c3 = vnoise2_1 wx1 wy1 (covScale * 4.0) * 0.25
      coverage = (c1 + c2 + c3) / 1.75

      -- Cloud type: different warp + scale
      t1 = vnoise2_1 (x + wx * 0.5) (y + wy * 0.5) typeScale
      t2 = vnoise2_1 (x + wx * 0.5) (y + wy * 0.5) (typeScale * 2.0) * 0.5
      cloudType = (t1 + t2) / 1.5

      -- Height offset: simple tileable noise
      h1 = vnoise2_1 x y hScale
      h2 = vnoise2_1 x y (hScale * 2.0) * 0.5
      heightOffset = (h1 + h2) / 1.5

  imageWrite @"weatherImage" (Vec2 gidX gidY) (Vec4 coverage cloudType heightOffset 1.0)
