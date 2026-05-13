{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module Graphics.Haskan.Vulkan.Shaders.LightData where

import FIR
import Math.Linear

type LightData =
  Struct
    '[ "position" ':-> V 3 Float,
       "intensity" ':-> Float,
       "color" ':-> V 3 Float,
       "type" ':-> Word32,
       "direction" ':-> V 3 Float,
       "range" ':-> Float
     ]

type LightsData =
  Struct
    '[ "data" ':-> Array 256 LightData
     ]
