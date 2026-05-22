{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Graphics.Haskan.Vulkan.Shaders.Compute.CloudNoiseMipGen
  ( Defs,
    program,
  )
where

import FIR
import FIR.Prim.Image (ImageCoordinateKind (..))
import Math.Linear

type MipParams =
  Struct
    '[ "srcSize" ':-> Int32
     ]

type Defs =
  '[ "srcImage" ':-> StorageImage '[DescriptorSet 0, Binding 0] (Properties IntegralCoordinates Float ThreeD (Just NotDepthImage) NonArrayed SingleSampled Storage (Just (RGBA8 UNorm))),
     "dstImage" ':-> StorageImage '[DescriptorSet 0, Binding 1] (Properties IntegralCoordinates Float ThreeD (Just NotDepthImage) NonArrayed SingleSampled Storage (Just (RGBA8 UNorm))),
     "mipParams" ':-> Uniform '[DescriptorSet 0, Binding 2] MipParams,
     "main" ':-> EntryPoint '[LocalSize 8 8 4] Compute
   ]

program :: Module Defs
program = Module $ entryPoint @"main" @Compute do
  ~(Vec3 gidX gidY gidZ) <- get @"gl_GlobalInvocationID"

  srcSize <- use @(Name "mipParams" :.: Name "srcSize")

  let ix = gidX
      iy = gidY
      iz = gidZ
      ix2 = ix * 2
      iy2 = iy * 2
      iz2 = iz * 2

  -- Read 8 source texels (2x2x2 box filter)
  ~(Vec4 s000_r s000_g s000_b s000_a) <- imageRead @"srcImage" (Vec3 ix2 iy2 iz2)
  ~(Vec4 s100_r s100_g s100_b s100_a) <- imageRead @"srcImage" (Vec3 (ix2 + 1) iy2 iz2)
  ~(Vec4 s010_r s010_g s010_b s010_a) <- imageRead @"srcImage" (Vec3 ix2 (iy2 + 1) iz2)
  ~(Vec4 s110_r s110_g s110_b s110_a) <- imageRead @"srcImage" (Vec3 (ix2 + 1) (iy2 + 1) iz2)
  ~(Vec4 s001_r s001_g s001_b s001_a) <- imageRead @"srcImage" (Vec3 ix2 iy2 (iz2 + 1))
  ~(Vec4 s101_r s101_g s101_b s101_a) <- imageRead @"srcImage" (Vec3 (ix2 + 1) iy2 (iz2 + 1))
  ~(Vec4 s011_r s011_g s011_b s011_a) <- imageRead @"srcImage" (Vec3 ix2 (iy2 + 1) (iz2 + 1))
  ~(Vec4 s111_r s111_g s111_b s111_a) <- imageRead @"srcImage" (Vec3 (ix2 + 1) (iy2 + 1) (iz2 + 1))

  let r = (s000_r + s100_r + s010_r + s110_r + s001_r + s101_r + s011_r + s111_r) / 8.0
      g = (s000_g + s100_g + s010_g + s110_g + s001_g + s101_g + s011_g + s111_g) / 8.0
      b = (s000_b + s100_b + s010_b + s110_b + s001_b + s101_b + s011_b + s111_b) / 8.0
      a = (s000_a + s100_a + s010_a + s110_a + s001_a + s101_a + s011_a + s111_a) / 8.0

  imageWrite @"dstImage" (Vec3 gidX gidY gidZ) (Vec4 r g b a)
