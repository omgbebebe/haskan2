{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Terrain.NodeSSBO
  ( TerrainNodeGPU(..)
  , packNodesToSSBO
  , nodeSSBOSize
  ) where

import Data.Vector.Storable (Vector)
import Data.Vector.Storable qualified as Vector
import Data.Word (Word32)
import Foreign (Storable(..), castPtr, pokeByteOff)
import Graphics.Haskan.Terrain.CDLOD (TerrainNode(..))
import Linear (V2(..), V4(..))

-- ---------------------------------------------------------------------------
-- GPU-side terrain node structure
--
-- Layout matches GLSL:
--   struct TerrainNode {
--     vec2 worldOffset;      // 8 bytes
--     float worldSize;       // 4 bytes
--     float heightScale;     // 4 bytes
--     int lodLevel;          // 4 bytes
--     int heightmapLayer;    -- actually uint, 4 bytes
--     int climateLayer;      -- actually uint, 4 bytes
--     float morphStart;      // 4 bytes
--   };                       // total: 32 bytes (16-byte aligned)
-- ---------------------------------------------------------------------------

data TerrainNodeGPU = TerrainNodeGPU
  { tngWorldOffset :: !(V2 Float)
  , tngWorldSize :: !Float
  , tngHeightScale :: !Float
  , tngLODLevel :: !Int
  , tngHeightmapLayer :: !Word32
  , tngClimateLayer :: !Word32
  , tngMorphStart :: !Float
  }
  deriving (Show)

instance Storable TerrainNodeGPU where
  sizeOf _ = 32
  alignment _ = 16
  peek _ = error "TerrainNodeGPU peek not implemented"
  poke ptr TerrainNodeGPU{..} = do
    let V2 ox oy = tngWorldOffset
    poke (castPtr ptr) (V4 ox oy tngWorldSize tngHeightScale)
    pokeByteOff ptr 16 tngLODLevel
    pokeByteOff ptr 20 tngHeightmapLayer
    pokeByteOff ptr 24 tngClimateLayer
    pokeByteOff ptr 28 tngMorphStart

-- | Convert CPU terrain nodes to GPU layout.
packNodesToSSBO :: [TerrainNode] -> Vector TerrainNodeGPU
packNodesToSSBO = Vector.fromList . map convert
  where
    convert TerrainNode{..} = TerrainNodeGPU
      { tngWorldOffset = tnWorldOffset
      , tngWorldSize = tnWorldSize
      , tngHeightScale = 1.0
      , tngLODLevel = tnLOD
      , tngHeightmapLayer = tnHeightmapLayer
      , tngClimateLayer = tnClimateLayer
      , tngMorphStart = tnMorphStart
      }

-- | Compute total SSBO size in bytes for given node count.
nodeSSBOSize :: Int -> Int
nodeSSBOSize count = count * sizeOf (undefined :: TerrainNodeGPU)
