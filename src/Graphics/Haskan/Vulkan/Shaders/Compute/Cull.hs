{-# LANGUAGE BlockArguments      #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE RebindableSyntax    #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeOperators       #-}

module Graphics.Haskan.Vulkan.Shaders.Compute.Cull
  ( program
  ) where

import FIR
import Math.Linear
import Graphics.Haskan.Vulkan.Shaders.EntityData

-- | Cull uniform data.
type CullData = Struct
  '[ "frustumPlanes" ':-> Array 6 (V 4 Float)
   , "entityCount"   ':-> Word32
   , "_pad2"         ':-> V 3 Word32
   ]

-- | Draw command output (matches VkDrawIndexedIndirectCommand, 20 bytes).
type DrawCommand = Struct
  '[ "indexCount"    ':-> Word32
   , "instanceCount" ':-> Word32
   , "firstIndex"    ':-> Word32
   , "vertexOffset"  ':-> Int32
   , "firstInstance" ':-> Word32
   ]

type DrawCommandsData = Struct
  '[ "commands" ':-> Array 4096 DrawCommand
   ]

type Defs
  =  '[ "entities"     ':-> StorageBuffer '[ DescriptorSet 0, Binding 0 ] EntitiesData
      , "drawCommands" ':-> StorageBuffer '[ DescriptorSet 0, Binding 1 ] DrawCommandsData
      , "cullData"     ':-> Uniform       '[ DescriptorSet 0, Binding 2 ] CullData
      , "main"         ':-> EntryPoint    '[ LocalSize 64 1 1 ] Compute
      ]

program :: Module Defs
program = Module $ entryPoint @"main" @Compute do
  -- Global invocation ID = entity index
  ~(Vec3 idx _ _) <- get @"gl_GlobalInvocationID"

  entityCount <- use @(Name "cullData" :.: Name "entityCount")

  -- Early out if thread index exceeds entity count
  if idx >= entityCount
    then pure (Lit ())
    else do
      -- Load entity data
      entity    <- use @(Name "entities" :.: Name "data" :.: AnIndex Word32) idx
      let aabbMin = view @(Name "aabbMin") entity
          aabbMax = view @(Name "aabbMax") entity
          firstIdx = view @(Name "firstIndex") entity
          vertexOff = view @(Name "vertexOffset") entity
          idxCount = view @(Name "indexCount") entity

      -- Load frustum planes
      p0 <- use @(Name "cullData" :.: Name "frustumPlanes" :.: AnIndex Word32) 0
      p1 <- use @(Name "cullData" :.: Name "frustumPlanes" :.: AnIndex Word32) 1
      p2 <- use @(Name "cullData" :.: Name "frustumPlanes" :.: AnIndex Word32) 2
      p3 <- use @(Name "cullData" :.: Name "frustumPlanes" :.: AnIndex Word32) 3
      p4 <- use @(Name "cullData" :.: Name "frustumPlanes" :.: AnIndex Word32) 4
      p5 <- use @(Name "cullData" :.: Name "frustumPlanes" :.: AnIndex Word32) 5

      -- Frustum cull: test AABB against all 6 planes
      visible <- testAllPlanes aabbMin aabbMax p0 p1 p2 p3 p4 p5

      -- Write draw command: visible entities draw normally, culled draw nothing
      let ic = if visible == 1 then idxCount else 0
      assign @(Name "drawCommands" :.: Name "commands" :.: AnIndex Word32 :.: Name "indexCount") idx ic
      assign @(Name "drawCommands" :.: Name "commands" :.: AnIndex Word32 :.: Name "instanceCount") idx 1
      assign @(Name "drawCommands" :.: Name "commands" :.: AnIndex Word32 :.: Name "firstIndex") idx firstIdx
      assign @(Name "drawCommands" :.: Name "commands" :.: AnIndex Word32 :.: Name "vertexOffset") idx vertexOff
      assign @(Name "drawCommands" :.: Name "commands" :.: AnIndex Word32 :.: Name "firstInstance") idx idx

-- Test AABB against all 6 frustum planes.
-- Returns 1 if visible, 0 if culled.
testAllPlanes :: Code (V 4 Float) -> Code (V 4 Float) -> Code (V 4 Float) -> Code (V 4 Float) -> Code (V 4 Float) -> Code (V 4 Float) -> Code (V 4 Float) -> Code (V 4 Float) -> Program i i (Code Word32)
testAllPlanes aabbMin aabbMax p0 p1 p2 p3 p4 p5 = do
  v0 <- testPlane aabbMin aabbMax p0
  v1 <- testPlane aabbMin aabbMax p1
  v2 <- testPlane aabbMin aabbMax p2
  v3 <- testPlane aabbMin aabbMax p3
  v4 <- testPlane aabbMin aabbMax p4
  v5 <- testPlane aabbMin aabbMax p5
  pure (v0 * v1 * v2 * v3 * v4 * v5)

testPlane :: Code (V 4 Float) -> Code (V 4 Float) -> Code (V 4 Float) -> Program i i (Code Word32)
testPlane aabbMin aabbMax plane = do
  let nx = view @(Index 0) plane
      ny = view @(Index 1) plane
      nz = view @(Index 2) plane
      nw = view @(Index 3) plane
      minX = view @(Index 0) aabbMin
      minY = view @(Index 1) aabbMin
      minZ = view @(Index 2) aabbMin
      maxX = view @(Index 0) aabbMax
      maxY = view @(Index 1) aabbMax
      maxZ = view @(Index 2) aabbMax
      px = if nx >= 0 then maxX else minX
      py = if ny >= 0 then maxY else minY
      pz = if nz >= 0 then maxZ else minZ
      dist = px * nx + py * ny + pz * nz + nw
  pure (if dist >= 0 then 1 else 0)
