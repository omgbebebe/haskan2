{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -fno-warn-partial-type-signatures #-}

module Graphics.Haskan.Vulkan.Shaders.Texture where

import FIR
import Math.Linear

------------------------------------------------
-- pipeline input

type VertexInput =
  '[ Slot 0 0 ':-> V 3 Float, -- position
     Slot 1 0 ':-> V 2 Float, -- UV coordinates
     Slot 2 0 ':-> V 3 Float, -- normal
     Slot 3 0 ':-> V 3 Float -- colour
   ]

------------------------------------------------
-- vertex shader

type VertexDefs =
  '[ "in_position" ':-> Input '[Location 0] (V 3 Float),
     "in_uv" ':-> Input '[Location 1] (V 2 Float),
     "in_normal" ':-> Input '[Location 2] (V 3 Float),
     "in_colour" ':-> Input '[Location 3] (V 3 Float),
     "out_colour" ':-> Output '[Location 0] (V 4 Float),
     "out_uv" ':-> Output '[Location 1] (V 2 Float),
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
  uv <- get @"in_uv"
  projection <- use @(Name "ubo" :.: Name "projection")
  model <- use @(Name "ubo" :.: Name "model")
  view <- use @(Name "ubo" :.: Name "view")
  let mvp = (projection !*! view) !*! model
  pos <- def @"pos" @R (mvp !*^ Vec4 x y z 1)
  put @"out_colour" (Vec4 r g b 1)
  put @"out_uv" uv
  put @"gl_Position" pos

------------------------------------------------
-- fragment shader

type FragmentDefs =
  '[ "in_colour" ':-> Input '[Location 0] (V 4 Float),
     "in_uv" ':-> Input '[Location 1] (V 2 Float),
     "logo"
       ':-> Texture2D
              '[Binding 1, DescriptorSet 0]
              (RGBA8 UNorm),
     "out_colour" ':-> Output '[Location 0] (V 4 Float),
     "main" ':-> EntryPoint '[OriginUpperLeft] Fragment
   ]

fragment :: ShaderModule "main" FragmentShader FragmentDefs _
fragment = shader do
  col <- get @"in_colour"
  uv <- get @"in_uv"
  -- naughty texture flipping trick
  let r = view @(Index 0) col
      uv' :: Code (V 2 Float)
      uv' =
        if r < 0.01 || r > 0.99
          then over @(Index 0) (1 -) uv
          else uv
  tex <- use @(ImageTexel "logo") NilOps uv'
  let alpha = view @(Index 3) tex
      res = set @(Index 3) 1 $ alpha *^ tex ^+^ (1 - alpha) *^ col
  put @"out_colour" res
