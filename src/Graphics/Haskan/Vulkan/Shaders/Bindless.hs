{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Graphics.Haskan.Vulkan.Shaders.Bindless
  ( vertex,
    fragment,
  )
where

import FIR
import Math.Linear

-- Vertex: same as g-buffer but passes UV and normal.
-- Material array layer is passed via push constant in fragment shader.

type VertexDefs =
  '[ "in_position" ':-> Input '[Location 0] (V 3 Float),
     "in_uv" ':-> Input '[Location 1] (V 2 Float),
     "in_normal" ':-> Input '[Location 2] (V 3 Float),
     "out_uv" ':-> Output '[Location 0] (V 2 Float),
     "out_normal" ':-> Output '[Location 1] (V 3 Float),
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
  ~(Vec3 x y z) <- get @"in_position"
  uv <- get @"in_uv"
  normal <- get @"in_normal"
  projection <- use @(Name "ubo" :.: Name "projection")
  model <- use @(Name "ubo" :.: Name "model")
  view <- use @(Name "ubo" :.: Name "view")
  let mvp = (projection !*! view) !*! model
      worldPos = model !*^ Vec4 x y z 1
      worldNormal = model !*^ Vec4 (view @(Index 0) normal) (view @(Index 1) normal) (view @(Index 2) normal) 0
  put @"out_uv" uv
  put @"out_normal" (Vec3 (view @(Index 0) worldNormal) (view @(Index 1) worldNormal) (view @(Index 2) worldNormal))
  put @"gl_Position" (mvp !*^ Vec4 x y z 1)

-- Fragment: sample from a Texture2DArray.
-- The material index (array layer) is supplied via push constant.
-- Coordinates are vec3: (u, v, layer).

type FragmentDefs =
  '[ "in_uv" ':-> Input '[Location 0] (V 2 Float),
     "in_normal" ':-> Input '[Location 1] (V 3 Float),
     "out_position" ':-> Output '[Location 0] (V 4 Float),
     "out_normal" ':-> Output '[Location 1] (V 4 Float),
     "out_albedo" ':-> Output '[Location 2] (V 4 Float),
     "tex"
       ':-> Texture2DArray
              '[Binding 1, DescriptorSet 0]
              (RGBA8 UNorm),
     "materialIndex"
       ':-> PushConstant
              '[]
              (Struct '["index" ':-> Word32]),
     "main" ':-> EntryPoint '[OriginUpperLeft] Fragment
   ]

fragment :: ShaderModule "main" FragmentShader FragmentDefs _
fragment = shader do
  uv <- get @"in_uv"
  normal <- get @"in_normal"
  matIdx <- use @(Name "materialIndex" :.: Name "index")
  -- FIR 'Word32' is unsigned integer; we need a floating-point layer index for sampling.
  -- Convert to Code Float via fromIntegral.
  let layer = fromIntegral matIdx :: Code Float
      coord = Vec3 (view @(Index 0) uv) (view @(Index 1) uv) layer
  texColor <- use @(ImageTexel "tex") NilOps coord
  let texR = view @(Index 0) texColor
      texG = view @(Index 1) texColor
      texB = view @(Index 2) texColor
  put @"out_position" (Vec4 0 0 0 1)
  put @"out_normal" (Vec4 (view @(Index 0) normal) (view @(Index 1) normal) (view @(Index 2) normal) 0)
  put @"out_albedo" (Vec4 texR texG texB 1)
