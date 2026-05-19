{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module Graphics.Haskan.Vulkan.Shaders.Compute.APVolumeUniforms
  ( APVolumeUniforms,
  )
where

import FIR
import Math.Linear

-- | Uniform data for AP volume compute shader.
-- Packed std140. Total ≈ 148 bytes.
type APVolumeUniforms =
  Struct
    '[ "cameraPos" ':-> V 3 Float,
       "invViewProj" ':-> M 4 4 Float,
       "sunDir" ':-> V 3 Float,
       "sunColor" ':-> V 3 Float,
       "cloudBase" ':-> Float,
       "cloudTop" ':-> Float,
       "time" ':-> Float,
       "near" ':-> Float,
       "far" ':-> Float,
       "volumeDepth" ':-> Float
     ]
