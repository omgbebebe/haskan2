{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module Graphics.Haskan.Vulkan.Shaders.Compute.APVolumeUniforms
  ( APVolumeUniforms,
  )
where

import FIR
import Math.Linear

-- | Uniform data for AP volume compute shader.
-- Packed std140. Total ≈ 180 bytes.
-- invViewProj is stored as 4 vec4 rows to avoid nested vector alignment issues.
type APVolumeUniforms =
  Struct
    '[ "cameraPos" ':-> V 3 Float,
       "invViewProj0" ':-> V 4 Float,
       "invViewProj1" ':-> V 4 Float,
       "invViewProj2" ':-> V 4 Float,
       "invViewProj3" ':-> V 4 Float,
       "sunDir" ':-> V 3 Float,
       "sunColor" ':-> V 3 Float,
       "cloudBase" ':-> Float,
       "cloudTop" ':-> Float,
       "time" ':-> Float,
       "near" ':-> Float,
       "far" ':-> Float,
       "volumeDepth" ':-> Float
     ]
