{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Graphics.Haskan.Vulkan.Shaders.Deferred.GBuffer where

import FIR
import Math.Linear

------------------------------------------------
-- pipeline input

-- Same as forward: position, UV, normal, color
type VertexInput =
  '[ Slot 0 0 ':-> V 3 Float, -- position
     Slot 1 0 ':-> V 2 Float, -- UV coordinates
     Slot 2 0 ':-> V 3 Float, -- normal
     Slot 3 0 ':-> V 3 Float  -- colour
   ]

------------------------------------------------
-- vertex shader

type VertexDefs =
  '[ "in_position" ':-> Input '[Location 0] (V 3 Float),
     "in_uv"       ':-> Input '[Location 1] (V 2 Float),
     "in_normal"   ':-> Input '[Location 2] (V 3 Float),
     "in_colour"   ':-> Input '[Location 3] (V 3 Float),
     "out_position" ':-> Output '[Location 0] (V 4 Float),
     "out_normal"   ':-> Output '[Location 1] (V 4 Float),
     "out_albedo"   ':-> Output '[Location 2] (V 4 Float),
     "out_uv"       ':-> Output '[Location 3] (V 2 Float),
     "ubo"
       ':-> Uniform
              '[Binding 0, DescriptorSet 0]
              ( Struct
                  '[ "model" ':-> M 4 4 Float,
                     "view" ':-> M 4 4 Float,
                     "projection" ':-> M 4 4 Float
                   ]
              ),
     "main" ':-> EntryPoint '[] Vertex
   ]

vertex :: ShaderModule "main" VertexShader VertexDefs _
vertex = shader do
  ~(Vec3 r g b) <- get @"in_colour"
  ~(Vec3 x y z) <- get @"in_position"
  ~(Vec3 nx ny nz) <- get @"in_normal"
  uv <- get @"in_uv"
  projection <- use @(Name "ubo" :.: Name "projection")
  model <- use @(Name "ubo" :.: Name "model")
  view <- use @(Name "ubo" :.: Name "view")
  let mvp = (projection !*! view) !*! model
      worldPos = model !*^ Vec4 x y z 1
      worldNorm = model !*^ Vec4 nx ny nz 0
  pos <- def @"pos" @R (mvp !*^ Vec4 x y z 1)
  put @"out_position" worldPos
  put @"out_normal" worldNorm
  put @"out_albedo" (Vec4 r g b 1)
  put @"out_uv" uv
  put @"gl_Position" pos

------------------------------------------------
-- fragment shader

type FragmentDefs =
  '[ "in_position" ':-> Input '[Location 0] (V 4 Float),
      "in_normal"   ':-> Input '[Location 1] (V 4 Float),
      "in_albedo"   ':-> Input '[Location 2] (V 4 Float),
      "in_uv"       ':-> Input '[Location 3] (V 2 Float),
      "out_position" ':-> Output '[Location 0] (V 4 Float),
      "out_normal"   ':-> Output '[Location 1] (V 4 Float),
      "out_albedo"   ':-> Output '[Location 2] (V 4 Float),
      "tex"
        ':-> Texture2D
               '[Binding 1, DescriptorSet 0]
               (RGBA8 UNorm),
      "main" ':-> EntryPoint '[OriginUpperLeft] Fragment
    ]

fragment :: ShaderModule "main" FragmentShader FragmentDefs _
fragment = shader do
  pos <- get @"in_position"
  norm <- get @"in_normal"
  uv <- get @"in_uv"
  texColor <- use @(ImageTexel "tex") NilOps uv
  put @"out_position" pos
  put @"out_normal" norm
  put @"out_albedo" texColor
