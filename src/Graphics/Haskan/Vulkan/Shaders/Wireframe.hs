{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Graphics.Haskan.Vulkan.Shaders.Wireframe
  ( vertex
  , geometry
  , fragment
  ) where

import FIR
import Math.Linear

-- Vertex: pass through position and UV
type VertexDefs =
  '[ "in_position" ':-> Input '[Location 0] (V 3 Float)
   , "in_uv"       ':-> Input '[Location 1] (V 2 Float)
   , "out_uv"      ':-> Output '[Location 0] (V 2 Float)
   , "main"        ':-> EntryPoint '[] Vertex
   ]

vertex :: ShaderModule "main" VertexShader VertexDefs _
vertex = shader do
  pos <- get @"in_position"
  uv  <- get @"in_uv"
  put @"out_uv" uv
  put @"gl_Position" (Vec4 (view @(Index 0) pos) (view @(Index 1) pos) (view @(Index 2) pos) 1)

-- Geometry: triangles -> line strip, emit 3 edges per triangle
type GeometryDefs =
  '[ "in_uv"  ':-> Input '[Location 0] (Array 3 (V 2 Float))
   , "out_uv" ':-> Output '[Location 0] (V 2 Float)
   , "main"   ':-> EntryPoint
                      '[ Triangles
                       , OutputLineStrip
                       , OutputVertices 6
                       , Invocations 1
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

-- Fragment: bright green wireframe
type FragmentDefs =
  '[ "out_colour" ':-> Output '[Location 0] (V 4 Float)
   , "main"       ':-> EntryPoint '[OriginUpperLeft] Fragment
   ]

fragment :: ShaderModule "main" FragmentShader FragmentDefs _
fragment = shader do
  put @"out_colour" (Vec4 0 1 0 1)
