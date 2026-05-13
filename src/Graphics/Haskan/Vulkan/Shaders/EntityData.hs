{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module Graphics.Haskan.Vulkan.Shaders.EntityData where

import FIR
import Math.Linear

type EntityData =
  Struct
    '[ "transform" ':-> M 4 4 Float,
       "normalMatrix" ':-> M 4 4 Float,
       "aabbMin" ':-> V 4 Float,
       "aabbMax" ':-> V 4 Float,
       "materialIndex" ':-> Word32,
       "firstIndex" ':-> Word32,
       "vertexOffset" ':-> Int32,
       "indexCount" ':-> Word32,
       "metallicRoughnessIndex" ':-> Word32,
       "metallicFactor" ':-> Float,
       "roughnessFactor" ':-> Float,
       "normalIndex" ':-> Word32,
       "occlusionIndex" ':-> Word32,
       "occlusionStrength" ':-> Float,
       "emissiveIndex" ':-> Word32
     ]

type EntitiesData =
  Struct
    '[ "data" ':-> Array 16384 EntityData
     ]
