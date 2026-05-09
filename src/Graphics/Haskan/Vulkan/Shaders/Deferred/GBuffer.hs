{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Graphics.Haskan.Vulkan.Shaders.Deferred.GBuffer where

import FIR
import Math.Linear
import Graphics.Haskan.Vulkan.Shaders.EntityData

------------------------------------------------
-- pipeline input

type VertexInput =
  '[ Slot 0 0 ':-> V 3 Float, -- position
     Slot 1 0 ':-> V 2 Float, -- UV coordinates
     Slot 2 0 ':-> V 3 Float, -- normal
     Slot 3 0 ':-> V 4 Float, -- tangent (xyz = direction, w = handedness)
     Slot 4 0 ':-> V 3 Float  -- colour
   ]

------------------------------------------------
-- vertex shader

type VertexDefs =
  '[ "in_position" ':-> Input '[Location 0] (V 3 Float),
     "in_uv"       ':-> Input '[Location 1] (V 2 Float),
     "in_normal"   ':-> Input '[Location 2] (V 3 Float),
     "in_tangent"  ':-> Input '[Location 3] (V 4 Float),
     "in_colour"   ':-> Input '[Location 4] (V 3 Float),
      "out_position" ':-> Output '[Location 0] (V 4 Float),
      "out_normal"   ':-> Output '[Location 1] (V 4 Float),
      "out_albedo"   ':-> Output '[Location 2] (V 4 Float),
      "out_uv"       ':-> Output '[Location 3] (V 2 Float),
      "out_materialIndex" ':-> Output '[Location 4, Flat] Word32,
      "out_entityIndex"   ':-> Output '[Location 5, Flat] Word32,
      "out_tangent"       ':-> Output '[Location 6] (V 4 Float),
      "ubo"
        ':-> Uniform
               '[Binding 0, DescriptorSet 0]
               ( Struct
                   '[ "view" ':-> M 4 4 Float,
                      "projection" ':-> M 4 4 Float
                    ]
               ),
      "entities"
        ':-> StorageBuffer
               '[Binding 2, DescriptorSet 0]
               EntitiesData,
      "main" ':-> EntryPoint '[] Vertex
    ]

vertex :: ShaderModule "main" VertexShader VertexDefs _
vertex = shader do
  ~(Vec3 r g b) <- get @"in_colour"
  ~(Vec3 x y z) <- get @"in_position"
  ~(Vec3 nx ny nz) <- get @"in_normal"
  tangent <- get @"in_tangent"
  uv <- get @"in_uv"
  projection <- use @(Name "ubo" :.: Name "projection")
  view <- use @(Name "ubo" :.: Name "view")

  entityIdx <- get @"gl_InstanceIndex"
  model <- use @(Name "entities" :.: Name "data" :.: AnIndex Word32 :.: Name "transform") entityIdx
  matIdx <- use @(Name "entities" :.: Name "data" :.: AnIndex Word32 :.: Name "materialIndex") entityIdx

  let mvp = (projection !*! view) !*! model
      worldPos = model !*^ Vec4 x y z 1
      worldNorm = model !*^ Vec4 nx ny nz 0
      worldTangent = model !*^ tangent
  pos <- def @"pos" @R (mvp !*^ Vec4 x y z 1)
  put @"out_position" worldPos
  put @"out_normal" worldNorm
  put @"out_albedo" (Vec4 r g b 1)
  put @"out_uv" uv
  put @"out_materialIndex" matIdx
  put @"out_entityIndex" entityIdx
  put @"out_tangent" worldTangent
  put @"gl_Position" pos

------------------------------------------------
-- fragment shader

type FragmentDefs =
  '[ "in_position" ':-> Input '[Location 0] (V 4 Float),
      "in_normal"   ':-> Input '[Location 1] (V 4 Float),
      "in_albedo"   ':-> Input '[Location 2] (V 4 Float),
      "in_uv"       ':-> Input '[Location 3] (V 2 Float),
      "in_materialIndex" ':-> Input '[Location 4, Flat] Word32,
      "in_entityIndex"   ':-> Input '[Location 5, Flat] Word32,
      "in_tangent"       ':-> Input '[Location 6] (V 4 Float),
      "out_position" ':-> Output '[Location 0] (V 4 Float),
      "out_normal"   ':-> Output '[Location 1] (V 4 Float),
      "out_albedo"   ':-> Output '[Location 2] (V 4 Float),
       "tex"
         ':-> BindlessTexture2D
                '[Binding 1, DescriptorSet 0]
                (RGBA8 UNorm),
       "entities"
         ':-> StorageBuffer
                '[Binding 2, DescriptorSet 0]
                EntitiesData,
       "main" ':-> EntryPoint '[OriginUpperLeft] Fragment
     ]

fragment :: ShaderModule "main" FragmentShader FragmentDefs _
fragment = shader do
  pos <- get @"in_position"
  norm <- get @"in_normal"
  uv <- get @"in_uv"
  matIdx <- get @"in_materialIndex"
  entityIdx <- get @"in_entityIndex"
  tangent <- get @"in_tangent"
  texColor <- use @(BindlessTexel "tex") matIdx NilOps uv

  -- Read PBR indices and scalar factors from entity SSBO
  mrIdx <- use @(Name "entities" :.: Name "data" :.: AnIndex Word32 :.: Name "metallicRoughnessIndex") entityIdx
  metallic <- use @(Name "entities" :.: Name "data" :.: AnIndex Word32 :.: Name "metallicFactor") entityIdx
  roughness <- use @(Name "entities" :.: Name "data" :.: AnIndex Word32 :.: Name "roughnessFactor") entityIdx
  normalIdx <- use @(Name "entities" :.: Name "data" :.: AnIndex Word32 :.: Name "normalIndex") entityIdx

  -- Sample metallic-roughness texture if index is non-zero, otherwise use scalar factors
  let useMrTexture = mrIdx /= 0
  mrColor <- use @(BindlessTexel "tex") mrIdx NilOps uv
  let metallicFinal = if useMrTexture then view @(Index 2) mrColor else metallic
      roughnessFinal = if useMrTexture then view @(Index 1) mrColor else roughness

  -- Normal mapping
  let normX = view @(Index 0) norm
      normY = view @(Index 1) norm
      normZ = view @(Index 2) norm
      normLen = sqrt (normX * normX + normY * normY + normZ * normZ + 0.0001)
      nx = normX / normLen
      ny = normY / normLen
      nz = normZ / normLen
      tanX = view @(Index 0) tangent
      tanY = view @(Index 1) tangent
      tanZ = view @(Index 2) tangent
      tanW = view @(Index 3) tangent
      tanLen = sqrt (tanX * tanX + tanY * tanY + tanZ * tanZ + 0.0001)
      tx = tanX / tanLen
      ty = tanY / tanLen
      tz = tanZ / tanLen
      -- Bitangent = cross(normal, tangent) * handedness
      bx = ny * tz - nz * ty
      by = nz * tx - nx * tz
      bz = nx * ty - ny * tx
      bnx = bx * tanW
      bny = by * tanW
      bnz = bz * tanW

  -- Sample normal map if available
  let useNormalTexture = normalIdx /= 0
  normalSample <- use @(BindlessTexel "tex") normalIdx NilOps uv
  let nmapX = view @(Index 0) normalSample
      nmapY = view @(Index 1) normalSample
      nmapZ = view @(Index 2) normalSample
      -- Decode from [0,1] to [-1,1]
      ndx = nmapX * 2 - 1
      ndy = nmapY * 2 - 1
      ndz = nmapZ * 2 - 1
      -- Transform to world space using TBN
      worldNx = if useNormalTexture then ndx * tx + ndy * bnx + ndz * nx else nx
      worldNy = if useNormalTexture then ndx * ty + ndy * bny + ndz * ny else ny
      worldNz = if useNormalTexture then ndx * tz + ndy * bnz + ndz * nz else nz
      worldNLen = sqrt (worldNx * worldNx + worldNy * worldNy + worldNz * worldNz + 0.0001)

  put @"out_position" (Vec4 (view @(Index 0) pos) (view @(Index 1) pos) (view @(Index 2) pos) metallicFinal)
  put @"out_normal" (Vec4 (worldNx / worldNLen) (worldNy / worldNLen) (worldNz / worldNLen) roughnessFinal)
  put @"out_albedo" (Vec4 (view @(Index 0) texColor) (view @(Index 1) texColor) (view @(Index 2) texColor) 1)
