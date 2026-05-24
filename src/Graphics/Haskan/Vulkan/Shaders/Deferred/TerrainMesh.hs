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
       ':-> Texture2D
            '[Binding 1, DescriptorSet 1]
            (R16 SNorm)
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
  heightScale <- use @(Name "nodes" :.: Name "data" :.: AnIndex Word32 :.: Name "heightScale") wxId
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

  -- World position for heightmap sampling
  let worldX = (view @(Index 0) nodeOffset) + wx
      worldZ = (view @(Index 1) nodeOffset) + wz
      -- Map world position to heightmap UV (single 2560x2560 tile centered at origin)
      texU = worldX / 2560.0 + 0.5
      texV = worldZ / 2560.0 + 0.5

  -- Sample heightmap
  elevRaw <- use @(ImageTexel "heightmap") NilOps (Vec2 texU texV)
  let height = elevRaw * 32767.0 * heightScale

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
       ':-> Texture2D
            '[Binding 2, DescriptorSet 1]
            (RGBA32 F)
   , "main" ':-> EntryPoint '[OriginUpperLeft] Fragment
   ]

terrainFragment :: ShaderModule "main" FragmentShader FragmentDefs _
terrainFragment = shader do
  pos    <- get @"in_position"
  normal <- get @"in_normal"
  uv     <- get @"in_uv"
  _climateLayer <- get @"in_climate"

  let Vec4 worldX _ worldZ _ = pos
      -- Map world position to climate texture UV (single 2560x2560 tile centered at origin)
      texU = worldX / 2560.0 + 0.5
      texV = worldZ / 2560.0 + 0.5

  climateCol <- use @(ImageTexel "climateTex") NilOps (Vec2 texU texV)

  -- Simple lighting based on normal
  let Vec4 nx ny nz _ = normal
      lightDir = normalise (Vec3 0.5 1.0 0.3)
      n = normalise (Vec3 nx ny nz)
      diffuse = max 0.0 (dot n lightDir)
      ambient = 0.3
      intensity = diffuse + ambient
      Vec4 cr cg cb ca = climateCol
      lit = Vec4 (cr * intensity) (cg * intensity) (cb * intensity) ca

  put @"out_color" lit
