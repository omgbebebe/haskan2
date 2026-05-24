{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -fno-warn-partial-type-signatures #-}

-- | Mesh shader terrain pipeline.
module Graphics.Haskan.Vulkan.Shaders.Deferred.TerrainMesh
  ( terrainMesh
  , terrainFragment
  ) where

import FIR
import Math.Linear

-- ---------------------------------------------------------------------------
-- Mesh shader
-- ---------------------------------------------------------------------------

-- | Terrain node SSBO layout (matches TerrainNodeGPU).
type TerrainNodeData =
  Struct
    '[ "worldOffset"    ':-> V 2 Float
     , "worldSize"      ':-> Float
     , "heightScale"    ':-> Float
     , "lodLevel"       ':-> Int32
     , "heightmapLayer" ':-> Word32
     , "climateLayer"   ':-> Word32
     , "morphStart"     ':-> Float
     ]

type MeshDefs =
  '[ "out_position" ':-> Output '[Location 0] (Array 64 (V 4 Float))
   , "out_normal"   ':-> Output '[Location 256] (Array 64 (V 4 Float))
   , "out_uv"       ':-> Output '[Location 512] (Array 64 (V 2 Float))
   , "out_climate"  ':-> Output '[Location 768] (Array 64 Word32)
   , "nodes"
       ':-> StorageBuffer
            '[Binding 0, DescriptorSet 1]
            (Struct '[ "data" ':-> Array 1024 TerrainNodeData ])
   , "heightmap"
       ':-> Texture2DArray
            '[Binding 1, DescriptorSet 1]
            (R32 F)
   , "main"
       ':-> EntryPoint '[ LocalSize 64 1 1
                        , OutputVertices 64
                        , OutputPrimitivesEXT 98
                        , OutputTrianglesEXT
                        ] Mesh
   ]

-- | 8x8 terrain patch mesh shader.
-- Each workgroup emits one patch: 64 vertices, 98 triangles.
terrainMesh :: ShaderModule "main" 'MeshShader MeshDefs _
terrainMesh = meshShader do
  -- Each workgroup processes one terrain node
  ~(Vec3 wxId _wyId _wzId) <- get @"gl_WorkgroupID"
  localIdx <- get @"gl_LocalInvocationIndex"

  -- Read node data from SSBO
  nodeOffset <- use @(Name "nodes" :.: Name "data" :.: AnIndex Word32 :.: Name "worldOffset") wxId
  nodeSize   <- use @(Name "nodes" :.: Name "data" :.: AnIndex Word32 :.: Name "worldSize") wxId
  _nodeLOD   <- use @(Name "nodes" :.: Name "data" :.: AnIndex Word32 :.: Name "lodLevel") wxId
  _hmapLayer <- use @(Name "nodes" :.: Name "data" :.: AnIndex Word32 :.: Name "heightmapLayer") wxId
  climateLayer <- use @(Name "nodes" :.: Name "data" :.: AnIndex Word32 :.: Name "climateLayer") wxId

  -- Compute grid position from local invocation index (0..63)
  let gx = localIdx `mod` 8 :: Code Word32
      gy = localIdx `div` 8 :: Code Word32
      -- UV coordinates within patch [0, 1]
      u = (fromIntegral gx) / 7.0 :: Code Float
      v = (fromIntegral gy) / 7.0 :: Code Float
      -- World position offset within node
      wx = (fromIntegral gx) * (nodeSize / 7.0) - (nodeSize / 2.0)
      wz = (fromIntegral gy) * (nodeSize / 7.0) - (nodeSize / 2.0)

  -- Sample heightmap (placeholder)
  let worldX = (view @(Index 0) nodeOffset) + wx
      worldZ = (view @(Index 1) nodeOffset) + wz
      height = 0.0 :: Code Float

  let pos = Vec4 worldX height worldZ 1 :: Code (V 4 Float)
      normal = Vec4 0 1 0 0 :: Code (V 4 Float)

  -- Only invocation 0 sets mesh outputs
  when (localIdx == 0) do
    setMeshOutputsEXT 64 98

  -- Write per-vertex builtin position
  assign @(Name "gl_MeshVerticesEXT" :.: AnIndex Word32 :.: Name "gl_Position")
    localIdx pos

  -- Write per-vertex user outputs
  assign @(Name "out_position" :.: AnIndex Word32) localIdx pos
  assign @(Name "out_normal" :.: AnIndex Word32) localIdx normal
  assign @(Name "out_uv" :.: AnIndex Word32) localIdx (Vec2 u v)
  assign @(Name "out_climate" :.: AnIndex Word32) localIdx climateLayer

-- ---------------------------------------------------------------------------
-- Fragment shader
-- ---------------------------------------------------------------------------

type FragmentDefs =
  '[ "in_position" ':-> Input '[Location 0] (V 4 Float)
   , "in_normal"   ':-> Input '[Location 256] (V 4 Float)
   , "in_uv"       ':-> Input '[Location 512] (V 2 Float)
   , "in_climate"  ':-> Input '[Location 768, Flat] Word32
   , "out_color"   ':-> Output '[Location 0] (V 4 Float)
   , "climateTex"
       ':-> Texture2DArray
            '[Binding 2, DescriptorSet 1]
            (RGBA8 UNorm)
   , "main" ':-> EntryPoint '[OriginUpperLeft] Fragment
   ]

terrainFragment :: ShaderModule "main" FragmentShader FragmentDefs _
terrainFragment = shader do
  _pos   <- get @"in_position"
  normal <- get @"in_normal"
  uv    <- get @"in_uv"
  _climateLayer <- get @"in_climate"

  -- Simple color based on UV and normal
  let Vec4 _ hy _ _ = normal
      color = Vec4 (view @(Index 0) uv) (view @(Index 1) uv) (hy * 0.5 + 0.5) 1

  put @"out_color" color
