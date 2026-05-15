{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -fno-warn-partial-type-signatures #-}

-- |
-- Module: Graphics.Haskan.Vulkan.Shaders.Deferred.GBuffer
--
-- === Deferred Rendering Pipeline — Stage 1: G-Buffer Pass ===
--
-- This module implements the geometry pass of a deferred renderer.
-- It rasterizes scene geometry into a multi-target framebuffer (G-buffer)
-- that stores per-pixel material properties for later lighting computation.
--
-- === Vertex Shader ===
--
-- **Inputs:**
--   * Position       (Location 0): V3 Float — object-space vertex position
--   * UV             (Location 1): V2 Float — texture coordinates
--   * Normal         (Location 2): V3 Float — object-space normal vector
--   * Tangent        (Location 3): V4 Float — (xyz = tangent direction, w = handedness sign)
--   * Colour         (Location 4): V3 Float — per-vertex color (fallback when no texture)
--
-- **Uniforms / Buffers:**
--   * UBO (Binding 0, DescriptorSet 0):
--     - view       : M 4 4 Float — camera view matrix
--     - projection : M 4 4 Float — perspective projection matrix
--   * Entities SSBO (Binding 2, DescriptorSet 0):
--     - Per-entity: transform (M 4 4), normalMatrix (M 4 4), materialIndex (Word32)
--
-- **Algorithm — Vertex Transformation:**
--   1. Model matrix fetched from entity SSBO via gl_InstanceIndex
--   2. Normal matrix = transpose(inverse(model)) for correct normal transformation
--   3. MVP = projection * view * model
--   4. worldPos    = model * vec4(position, 1)
--   5. worldNorm   = normalMatrix * vec4(normal, 0)
--   6. worldTangent = normalMatrix * tangent
--
-- **Outputs (interpolated to fragment stage):**
--   * out_position     (Location 0): V4 Float — world position (xyz) + metallic (w)
--   * out_normal       (Location 1): V4 Float — world normal (xyz) + roughness (w)
--   * out_albedo       (Location 2): V4 Float — base color (rgb) + ambient occlusion (a)
--   * out_uv           (Location 3): V2 Float — texture coordinates
--   * out_materialIndex(Location 4): Word32  — flat, bindless texture array index
--   * out_entityIndex  (Location 5): Word32  — flat, entity SSBO index
--   * out_tangent      (Location 6): V4 Float — world tangent (xyz) + handedness (w)
--
-- === Fragment Shader ===
--
-- **Inputs:** All vertex outputs interpolated per-pixel.
--
-- **Textures:**
--   * tex (Binding 1, DescriptorSet 0): BindlessTexture2D RGBA8 UNorm
--     - Indexable texture array. Index = materialIndex for albedo,
--       metallicRoughnessIndex for PBR map, normalIndex for normal map,
--       occlusionIndex for AO map, emissiveIndex for emissive map.
--
-- **Algorithm — PBR Material Sampling:**
--   1. Sample albedo texture at UV (fallback to vertex color if unavailable)
--   2. Sample metallic-roughness map:
--      - G channel = roughness
--      - B channel = metallic
--      - Fallback to scalar metallicFactor / roughnessFactor from SSBO
--   3. Normal mapping (TBN reconstruction):
--      - Normalize interpolated normal and tangent
--      - bitangent = cross(normal, tangent) * handedness
--      - Sample normal map, decode [0,1] -> [-1,1]
--      - Transform from tangent space to world space: worldN = TBN * sampledNormal
--   4. Sample occlusion map (R channel), apply occlusionStrength
--   5. Sample emissive map (RGB)
--
-- **G-Buffer Output Layout:**
--   * Position (Location 0): RGBA16F
--     - R,G,B = world position xyz
--     - A       = metallic factor
--   * Normal (Location 1): RGBA8 UNorm
--     - R,G,B = world normal encoded [-1,1] -> [0,1] (*0.5+0.5)
--     - A       = roughness
--   * Albedo (Location 2): RGBA8 UNorm
--     - R,G,B = base color
--     - A       = ambient occlusion
--   * Emissive (Location 3): RGBA8 UNorm
--     - R,G,B = emissive color
--     - A       = unused (1.0)
--
-- **Texture Input Formats:**
--   * Albedo: RGBA8 UNorm (sRGB or linear depending on asset)
--   * Metallic-Roughness: RGBA8 UNorm (R=unused, G=roughness, B=metallic, A=unused)
--   * Normal: RGBA8 UNorm (R,G,B = normal XYZ, A=unused)
--   * Occlusion: RGBA8 UNorm (R=occlusion, GBA=unused)
--   * Emissive: RGBA8 UNorm (R,G,B = emissive)
module Graphics.Haskan.Vulkan.Shaders.Deferred.GBuffer where

import FIR
import Graphics.Haskan.Vulkan.Shaders.EntityData
import Math.Linear

------------------------------------------------
-- pipeline input

type VertexInput =
  '[ Slot 0 0 ':-> V 3 Float, -- position
     Slot 1 0 ':-> V 2 Float, -- UV coordinates
     Slot 2 0 ':-> V 3 Float, -- normal
     Slot 3 0 ':-> V 4 Float, -- tangent (xyz = direction, w = handedness)
     Slot 4 0 ':-> V 3 Float -- colour
   ]

------------------------------------------------
-- vertex shader

type VertexDefs =
  '[ "in_position" ':-> Input '[Location 0] (V 3 Float),
     "in_uv" ':-> Input '[Location 1] (V 2 Float),
     "in_normal" ':-> Input '[Location 2] (V 3 Float),
     "in_tangent" ':-> Input '[Location 3] (V 4 Float),
     "in_colour" ':-> Input '[Location 4] (V 3 Float),
     "out_position" ':-> Output '[Location 0] (V 4 Float),
     "out_normal" ':-> Output '[Location 1] (V 4 Float),
     "out_albedo" ':-> Output '[Location 2] (V 4 Float),
     "out_uv" ':-> Output '[Location 3] (V 2 Float),
     "out_materialIndex" ':-> Output '[Location 4, Flat] Word32,
     "out_entityIndex" ':-> Output '[Location 5, Flat] Word32,
     "out_tangent" ':-> Output '[Location 6] (V 4 Float),
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
  normalMatrix <- use @(Name "entities" :.: Name "data" :.: AnIndex Word32 :.: Name "normalMatrix") entityIdx
  matIdx <- use @(Name "entities" :.: Name "data" :.: AnIndex Word32 :.: Name "materialIndex") entityIdx

  let mvp = (projection !*! view) !*! model
      worldPos = model !*^ Vec4 x y z 1
      worldNorm = normalMatrix !*^ Vec4 nx ny nz 0
      worldTangent = normalMatrix !*^ tangent
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
     "in_normal" ':-> Input '[Location 1] (V 4 Float),
     "in_albedo" ':-> Input '[Location 2] (V 4 Float),
     "in_uv" ':-> Input '[Location 3] (V 2 Float),
     "in_materialIndex" ':-> Input '[Location 4, Flat] Word32,
     "in_entityIndex" ':-> Input '[Location 5, Flat] Word32,
     "in_tangent" ':-> Input '[Location 6] (V 4 Float),
     "out_position" ':-> Output '[Location 0] (V 4 Float),
     "out_normal" ':-> Output '[Location 1] (V 4 Float),
     "out_albedo" ':-> Output '[Location 2] (V 4 Float),
     "out_emissive" ':-> Output '[Location 3] (V 4 Float),
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

  -- Read occlusion data from entity SSBO
  occlusionIdx <- use @(Name "entities" :.: Name "data" :.: AnIndex Word32 :.: Name "occlusionIndex") entityIdx
  occlusionStrength <- use @(Name "entities" :.: Name "data" :.: AnIndex Word32 :.: Name "occlusionStrength") entityIdx

  -- Sample occlusion texture if available (red channel = occlusion)
  let useOcclusionTexture = occlusionIdx /= 0
  occlusionSample <- use @(BindlessTexel "tex") occlusionIdx NilOps uv
  let aoRaw = view @(Index 0) occlusionSample
      ao = if useOcclusionTexture then 1.0 - occlusionStrength * (1.0 - aoRaw) else 1.0

  -- Read emissive index from entity SSBO
  emissiveIdx <- use @(Name "entities" :.: Name "data" :.: AnIndex Word32 :.: Name "emissiveIndex") entityIdx

  -- Sample emissive texture if available
  let useEmissiveTexture = emissiveIdx /= 0
  emissiveSample <- use @(BindlessTexel "tex") emissiveIdx NilOps uv
  let emissiveR = if useEmissiveTexture then view @(Index 0) emissiveSample else 0.0
      emissiveG = if useEmissiveTexture then view @(Index 1) emissiveSample else 0.0
      emissiveB = if useEmissiveTexture then view @(Index 2) emissiveSample else 0.0

  put @"out_position" (Vec4 (view @(Index 0) pos) (view @(Index 1) pos) (view @(Index 2) pos) metallicFinal)
  -- Encode normal from [-1,1] to [0,1] for UNORM storage
  put @"out_normal" (Vec4 (worldNx / worldNLen * 0.5 + 0.5) (worldNy / worldNLen * 0.5 + 0.5) (worldNz / worldNLen * 0.5 + 0.5) roughnessFinal)
  put @"out_albedo" (Vec4 (view @(Index 0) texColor) (view @(Index 1) texColor) (view @(Index 2) texColor) ao)
  put @"out_emissive" (Vec4 emissiveR emissiveG emissiveB 1.0)
