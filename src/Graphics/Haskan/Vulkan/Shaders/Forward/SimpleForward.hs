{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -fno-warn-partial-type-signatures #-}

-- |
-- Module: Graphics.Haskan.Vulkan.Shaders.Forward.SimpleForward
--
-- Simple unlit forward rendering shaders for the 'runSimple' API.
-- Vertex shader applies MVP transform and passes through color.
-- Fragment shader outputs the interpolated vertex color directly.
module Graphics.Haskan.Vulkan.Shaders.Forward.SimpleForward
  ( vertex,
    fragment,
  )
where

import FIR
import Math.Linear

------------------------------------------------
-- vertex shader

type VertexDefs =
  '[ "in_position" ':-> Input '[Location 0] (V 3 Float),
     "in_uv" ':-> Input '[Location 1] (V 2 Float),
     "in_normal" ':-> Input '[Location 2] (V 3 Float),
     "in_tangent" ':-> Input '[Location 3] (V 4 Float),
     "in_colour" ':-> Input '[Location 4] (V 3 Float),
     "out_colour" ':-> Output '[Location 0] (V 4 Float),
     "ubo"
       ':-> Uniform
              '[Binding 0, DescriptorSet 0]
              ( Struct
                  '[ "view" ':-> M 4 4 Float,
                     "projection" ':-> M 4 4 Float
                   ]
              ),
     "main" ':-> EntryPoint '[] Vertex
   ]

vertex :: ShaderModule "main" VertexShader VertexDefs _
vertex = shader do
  ~(Vec3 r g b) <- get @"in_colour"
  ~(Vec3 x y z) <- get @"in_position"
  projection <- use @(Name "ubo" :.: Name "projection")
  view <- use @(Name "ubo" :.: Name "view")
  let mvp = projection !*! view
  pos <- def @"pos" @R (mvp !*^ Vec4 x y z 1)
  put @"out_colour" (Vec4 r g b 1)
  put @"gl_Position" pos

------------------------------------------------
-- fragment shader

type FragmentDefs =
  '[ "in_colour" ':-> Input '[Location 0] (V 4 Float),
     "out_colour" ':-> Output '[Location 0] (V 4 Float),
     "main" ':-> EntryPoint '[OriginUpperLeft] Fragment
   ]

fragment :: ShaderModule "main" FragmentShader FragmentDefs _
fragment = shader do
  col <- get @"in_colour"
  put @"out_colour" col
