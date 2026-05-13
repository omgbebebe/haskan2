{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -fno-warn-partial-type-signatures #-}

module Graphics.Haskan.Vulkan.Shaders.Wireframe
  ( vertex,
    geometry,
    fragment,
  )
where

import FIR
import Graphics.Haskan.Vulkan.Shaders.EntityData
import Math.Linear

-- Vertex: transform by MVP (same UBO as g-buffer)
type VertexDefs =
  '[ "in_position" ':-> Input '[Location 0] (V 3 Float),
     "in_uv" ':-> Input '[Location 1] (V 2 Float),
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
  ~(Vec3 x y z) <- get @"in_position"
  projection <- use @(Name "ubo" :.: Name "projection")
  view <- use @(Name "ubo" :.: Name "view")

  entityIdx <- get @"gl_InstanceIndex"
  model <- use @(Name "entities" :.: Name "data" :.: AnIndex Word32 :.: Name "transform") entityIdx

  let mvp = (projection !*! view) !*! model
  put @"gl_Position" (mvp !*^ Vec4 x y z 1)

-- Geometry: triangles -> line strip, emit 3 edges per triangle
type GeometryDefs =
  '[ "in_uv" ':-> Input '[Location 0] (Array 3 (V 2 Float)),
     "out_uv" ':-> Output '[Location 0] (V 2 Float),
     "main"
       ':-> EntryPoint
              '[ Triangles,
                 OutputLineStrip,
                 OutputVertices 6,
                 Invocations 1
               ]
              Geometry
   ]

geometry :: ShaderModule "main" GeometryShader GeometryDefs _
geometry = shader do
  -- Read the 3 vertices of the input triangle
  v0 <- use @(Name "gl_in" :.: Index 0 :.: Name "gl_Position")
  v1 <- use @(Name "gl_in" :.: Index 1 :.: Name "gl_Position")
  v2 <- use @(Name "gl_in" :.: Index 2 :.: Name "gl_Position")

  -- Edge 0: v0 -> v1
  put @"gl_Position" v0
  emitVertex
  put @"gl_Position" v1
  emitVertex
  endPrimitive

  -- Edge 1: v1 -> v2
  put @"gl_Position" v1
  emitVertex
  put @"gl_Position" v2
  emitVertex
  endPrimitive

  -- Edge 2: v2 -> v0
  put @"gl_Position" v2
  emitVertex
  put @"gl_Position" v0
  emitVertex
  endPrimitive

  pure (Lit ())

-- Fragment: bright green wireframe on albedo (Location 2)
type FragmentDefs =
  '[ "out_albedo" ':-> Output '[Location 2] (V 4 Float),
     "main" ':-> EntryPoint '[OriginUpperLeft] Fragment
   ]

fragment :: ShaderModule "main" FragmentShader FragmentDefs _
fragment = shader do
  put @"out_albedo" (Vec4 0 1 0 1)
