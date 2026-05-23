{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -fno-warn-partial-type-signatures #-}

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
     "out_worldPos" ':-> Output '[Location 2] (V 3 Float),
     "ubo"
       ':-> Uniform
              '[Binding 0, DescriptorSet 0]
              ( Struct
                  '[ "view" ':-> M 4 4 Float,
                     "projection" ':-> M 4 4 Float
                   ]
              ),
     "perDraw"
       ':-> PushConstant
              '[]
              ( Struct
                  '[ "model" ':-> M 4 4 Float,
                     "materialIndex" ':-> Word32
                   ]
              ),
     "main" ':-> EntryPoint '[] Vertex
   ]

vertex :: ShaderModule "main" VertexShader VertexDefs _
vertex = shader do
  ~(Vec3 x y z) <- get @"in_position"
  uv <- get @"in_uv"
  ~(Vec3 nx ny nz) <- get @"in_normal"
  projection <- use @(Name "ubo" :.: Name "projection")
  model <- use @(Name "perDraw" :.: Name "model")
  view <- use @(Name "ubo" :.: Name "view")
  let mvp = (projection !*! view) !*! model :: Code (M 4 4 Float)
      ~(Vec4 wpx wpy wpz _) = model !*^ Vec4 x y z 1
      worldNorm = model !*^ Vec4 nx ny nz 0
      ~(Vec4 wnx wny wnz _) = worldNorm
      normLen = sqrt (wnx * wnx + wny * wny + wnz * wnz + 0.0001)
  put @"out_uv" uv
  put @"out_normal" (Vec3 (wnx / normLen) (wny / normLen) (wnz / normLen))
  put @"out_worldPos" (Vec3 wpx wpy wpz)
  put @"gl_Position" (mvp !*^ Vec4 x y z 1)

-- Fragment: sample from a Texture2DArray.
-- The material index (array layer) is supplied via push constant.
-- Coordinates are vec3: (u, v, layer).

type FragmentDefs =
  '[ "in_uv" ':-> Input '[Location 0] (V 2 Float),
     "in_normal" ':-> Input '[Location 1] (V 3 Float),
     "in_worldPos" ':-> Input '[Location 2] (V 3 Float),
     "out_position" ':-> Output '[Location 0] (V 4 Float),
     "out_normal" ':-> Output '[Location 1] (V 4 Float),
     "out_albedo" ':-> Output '[Location 2] (V 4 Float),
     "out_emissive" ':-> Output '[Location 3] (V 4 Float),
     "tex"
       ':-> Texture2DArray
              '[Binding 1, DescriptorSet 0]
              (RGBA8 UNorm),
     "perDraw"
       ':-> PushConstant
              '[]
              ( Struct
                  '[ "model" ':-> M 4 4 Float,
                     "materialIndex" ':-> Word32
                   ]
              ),
     "main" ':-> EntryPoint '[OriginUpperLeft] Fragment
   ]

fragment :: ShaderModule "main" FragmentShader FragmentDefs _
fragment = shader do
  uv <- get @"in_uv"
  ~(Vec3 nx ny nz) <- get @"in_normal"
  ~(Vec3 wpx wpy wpz) <- get @"in_worldPos"
  matIdx <- use @(Name "perDraw" :.: Name "materialIndex")
  let layer = fromIntegral matIdx :: Code Float
      coord = Vec3 (view @(Index 0) uv) (view @(Index 1) uv) layer
  texColor <- use @(ImageTexel "tex") NilOps coord
  let texR = view @(Index 0) texColor
      texG = view @(Index 1) texColor
      texB = view @(Index 2) texColor
      -- Encode normals like g-buffer: *0.5 + 0.5
      encNx = (nx + 1) * 0.5
      encNy = (ny + 1) * 0.5
      encNz = (nz + 1) * 0.5
  put @"out_position" (Vec4 wpx wpy wpz 0.0)  -- metallic=0
  put @"out_normal" (Vec4 encNx encNy encNz 0.5)  -- roughness=0.5
  put @"out_albedo" (Vec4 texR texG texB 1.0)  -- ao=1
  put @"out_emissive" (Vec4 0 0 0 1)
