{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Terrain.CDLOD
  ( -- * Types
    TerrainNode(..)
  , CDLODConfig(..)
  , CDLODTree(..)
    -- * Construction
  , defaultCDLODConfig
  , buildCDLODTree
    -- * Node selection
  , selectVisibleNodes
  , NodeSelection(..)
    -- * Morph factor
  , computeMorphFactor
  ) where

import Data.List (sortOn)
import Data.Ord (Down(..))
import Data.Word (Word32)
import Linear (V2(..), V3(..), V4(..), distance)

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

-- | CDLOD runtime configuration.
data CDLODConfig = CDLODConfig
  { ccPatchSize :: !Int           -- ^ Vertices per patch edge (8 for 8×8)
  , ccMaxLOD :: !Int              -- ^ Maximum LOD level (0 = finest)
  , ccWorldSize :: !Float         -- ^ Total world size in meters
  , ccMorphZoneRatio :: !Float    -- ^ Fraction of node edge that morphs (e.g. 0.2)
  , ccLODDistanceRatio :: !Float  -- ^ Distance multiplier per LOD level
  }
  deriving (Show)

defaultCDLODConfig :: CDLODConfig
defaultCDLODConfig = CDLODConfig
  { ccPatchSize = 8
  , ccMaxLOD = 4
  , ccWorldSize = 8192.0
  , ccMorphZoneRatio = 0.25
  , ccLODDistanceRatio = 2.0
  }

-- ---------------------------------------------------------------------------
-- Terrain node
-- ---------------------------------------------------------------------------

-- | A single CDLOD quadtree node.
data TerrainNode = TerrainNode
  { tnWorldOffset :: !(V2 Float)    -- ^ Node origin (x, z) in world space
  , tnWorldSize :: !Float           -- ^ Node edge length in world units
  , tnLOD :: !Int                   -- ^ LOD level (0 = finest)
  , tnHeightmapLayer :: !Word32     -- ^ Texture array layer for heightmap
  , tnClimateLayer :: !Word32       -- ^ Texture array layer for climate
  , tnMorphStart :: !Float          -- ^ Distance where morph begins
  }
  deriving (Show)

-- ---------------------------------------------------------------------------
-- CDLOD tree
-- ---------------------------------------------------------------------------

-- | Flat array of nodes indexed by LOD level.
-- Each LOD level contains a grid of nodes.
data CDLODTree = CDLODTree
  { ctConfig :: !CDLODConfig
  , ctNodes :: [[TerrainNode]]  -- ^ nodes per LOD level
  }
  deriving (Show)

-- | Build a CDLOD tree from configuration.
buildCDLODTree :: CDLODConfig -> CDLODTree
buildCDLODTree cfg@CDLODConfig{..} = CDLODTree
  { ctConfig = cfg
  , ctNodes = map buildLOD [0..ccMaxLOD]
  }
  where
    buildLOD lod =
      let gridCells = 2 ^ lod
          nodeSize = ccWorldSize / fromIntegral gridCells
          halfSize = nodeSize / 2.0
      in [ TerrainNode
             { tnWorldOffset = V2
                 (fromIntegral x * nodeSize - ccWorldSize / 2.0 + halfSize)
                 (fromIntegral y * nodeSize - ccWorldSize / 2.0 + halfSize)
             , tnWorldSize = nodeSize
             , tnLOD = lod
             , tnHeightmapLayer = 0  -- TODO: assign from tile manager
             , tnClimateLayer = 0
             , tnMorphStart = nodeSize * ccMorphZoneRatio * ccLODDistanceRatio
             }
         | y <- [0..gridCells-1]
         , x <- [0..gridCells-1]
         ]

-- ---------------------------------------------------------------------------
-- Node selection
-- ---------------------------------------------------------------------------

-- | Result of node selection for a frame.
data NodeSelection = NodeSelection
  { nsNodes :: [TerrainNode]      -- ^ Visible leaf nodes at appropriate LOD
  , nsMaxLOD :: !Int              -- ^ Maximum LOD used
  }
  deriving (Show)

-- | Select visible nodes given camera position and frustum planes.
-- Top-down: starts from coarsest LOD, recurses to finer LOD for nodes
-- near the camera. At max LOD, keeps all visible nodes.
selectVisibleNodes
  :: CDLODTree
  -> V3 Float       -- ^ Camera position
  -> [V4 Float]     -- ^ Frustum planes (Ax + By + Cz + D = 0)
  -> NodeSelection
selectVisibleNodes CDLODTree{..} cameraPos frustumPlanes =
  let cfg = ctConfig
      maxLod = ccMaxLOD cfg
      selected = go 0
      go lod
        | lod > maxLod = []
        | otherwise =
            let nodes = ctNodes !! lod
                visible = filter (nodeInFrustum frustumPlanes) nodes
            in if lod == maxLod
                 then visible
                 else
                   let (fine, keep) = partition (needsFinerLOD cfg cameraPos) visible
                   in keep ++ if null fine
                        then []
                        else go (lod + 1)
  in NodeSelection
       { nsNodes = sortOn (Down . tnLOD) selected
       , nsMaxLOD = if null selected then 0 else maximum (map tnLOD selected)
       }

-- | Check if a node is inside the frustum.
nodeInFrustum :: [V4 Float] -> TerrainNode -> Bool
nodeInFrustum planes node =
  let V2 cx cz = tnWorldOffset node
      half = tnWorldSize node / 2.0
      -- Bounding box corners (y is height, we use full range)
      corners =
        [ V3 (cx - half) 0       (cz - half)
        , V3 (cx + half) 0       (cz - half)
        , V3 (cx - half) 10000   (cz - half)
        , V3 (cx + half) 10000   (cz - half)
        , V3 (cx - half) 0       (cz + half)
        , V3 (cx + half) 0       (cz + half)
        , V3 (cx - half) 10000   (cz + half)
        , V3 (cx + half) 10000   (cz + half)
        ]
  in all (\plane -> any (pointInFront plane) corners) planes

pointInFront :: V4 Float -> V3 Float -> Bool
pointInFront (V4 a b c d) (V3 x y z) = a * x + b * y + c * z + d >= 0

-- | Determine if a node needs a finer LOD level.
needsFinerLOD :: CDLODConfig -> V3 Float -> TerrainNode -> Bool
needsFinerLOD CDLODConfig{..} cameraPos node =
  let V2 cx cz = tnWorldOffset node
      distToNode = distance cameraPos (V3 cx 0 cz)
      lodDist = tnWorldSize node * ccLODDistanceRatio
  in distToNode < lodDist

-- ---------------------------------------------------------------------------
-- Morph factor
-- ---------------------------------------------------------------------------

-- | Compute morph factor for a vertex within a node.
-- Returns 0.0 (full detail) to 1.0 (fully morphed to parent LOD).
computeMorphFactor
  :: TerrainNode
  -> V3 Float       -- ^ Vertex world position
  -> V3 Float       -- ^ Camera position
  -> Float
computeMorphFactor node vertexPos cameraPos =
  let V2 cx cz = tnWorldOffset node
      half = tnWorldSize node / 2.0
      distToCam = distance vertexPos cameraPos
      morphStart = tnMorphStart node
      -- Linear falloff from morphStart to 0
      t = max 0.0 (min 1.0 (1.0 - distToCam / morphStart))
  in if distToCam < morphStart
       then 0.0
       else t

-- ---------------------------------------------------------------------------
-- Utilities
-- ---------------------------------------------------------------------------

partition :: (a -> Bool) -> [a] -> ([a], [a])
predicate `partition` xs = foldr select ([], []) xs
  where
    select x (ts, fs)
      | predicate x = (x:ts, fs)
      | otherwise   = (ts, x:fs)
