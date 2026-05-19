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
             (Properties
                IntegralCoordinates
                Float
                ThreeD
                (Just NotDepthImage)
                NonArrayed
                SingleSampled
                Storage
                (Just (RGBA16 F))),
     "cloudNoise"
       ':-> Texture3D
             '[Binding 1, DescriptorSet 0]
             (RGBA8 UNorm),
     "apUniforms"
       ':-> Uniform
             '[Binding 2, DescriptorSet 0]
             APVolumeUniforms,
     "main" ':-> EntryPoint '[LocalSize 4 4 4] Compute
   ]

-- Stub: will be filled with raymarching in Phase 2.
program :: Module Defs
program = Module $ entryPoint @"main" @Compute do
  -- Global invocation ID = voxel coordinate
  ~(Vec3 vx vy vz) <- get @"gl_GlobalInvocationID"

  -- Write a test color (will be replaced with actual scattering)
  imageWrite @"apImage" (Vec3 vx vy vz) (Vec4 0.0 0.0 0.0 0.0)
