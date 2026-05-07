{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Graphics.Haskan.Vulkan.Shaders.Deferred.Lighting where

import FIR
import Math.Linear

------------------------------------------------
-- fullscreen triangle vertex shader
-- No vertex input; generates positions and UVs from vertex index

type VertexDefs =
  '[ "out_uv" ':-> Output '[Location 0] (V 2 Float),
     "main" ':-> EntryPoint '[] Vertex
   ]

vertex :: ShaderModule "main" VertexShader VertexDefs _
vertex = shader do
  -- Fullscreen triangle: vertex index 0,1,2
  -- Map to clip-space positions:
  --   0: (-1, -1) -> UV (0, 0)
  --   1: ( 3, -1) -> UV (2, 0)
  --   2: (-1,  3) -> UV (0, 2)
  -- This covers the entire screen with a single large triangle
  vertIdx <- get @"gl_VertexIndex"
  let fi = fromIntegral vertIdx :: Code Float
      x = if fi == 0 then (-1) else if fi == 1 then 3 else (-1)
      y = if fi == 0 then (-1) else if fi == 1 then (-1) else 3
      u = if fi == 0 then 0 else if fi == 1 then 2 else 0
      v = if fi == 0 then 0 else if fi == 1 then 0 else 2
  put @"out_uv" (Vec2 u v)
  put @"gl_Position" (Vec4 x y 0 1)

------------------------------------------------
-- fragment shader
-- Samples g-buffer and computes simple directional light

type FragmentDefs =
  '[ "in_uv" ':-> Input '[Location 0] (V 2 Float),
     "gbuf_position"
       ':-> Texture2D
              '[Binding 0, DescriptorSet 0]
              (RGBA8 UNorm),
     "gbuf_normal"
       ':-> Texture2D
              '[Binding 1, DescriptorSet 0]
              (RGBA8 UNorm),
     "gbuf_albedo"
       ':-> Texture2D
              '[Binding 2, DescriptorSet 0]
              (RGBA8 UNorm),
     "out_colour" ':-> Output '[Location 0] (V 4 Float),
     "main" ':-> EntryPoint '[OriginUpperLeft] Fragment
   ]

fragment :: ShaderModule "main" FragmentShader FragmentDefs _
fragment = shader do
  uv <- get @"in_uv"
  -- Sample g-buffer
  posSample <- use @(ImageTexel "gbuf_position") NilOps uv
  normSample <- use @(ImageTexel "gbuf_normal") NilOps uv
  albSample <- use @(ImageTexel "gbuf_albedo") NilOps uv

  let posX = view @(Index 0) posSample
      posY = view @(Index 1) posSample
      posZ = view @(Index 2) posSample
      normX = view @(Index 0) normSample
      normY = view @(Index 1) normSample
      normZ = view @(Index 2) normSample
      albR = view @(Index 0) albSample
      albG = view @(Index 1) albSample
      albB = view @(Index 2) albSample

      norm = normalise (Vec3 normX normY normZ)

  -- Simple directional light from (1, 1, 1)
  let lightDir = normalise (Vec3 1 1 1)
      diff = max 0 (dot norm lightDir)
      lit = 0.1 + diff
      litR = lit * albR
      litG = lit * albG
      litB = lit * albB

  put @"out_colour" (Vec4 litR litG litB 1)
