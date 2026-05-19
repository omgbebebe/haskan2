{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -fno-warn-partial-type-signatures #-}

module Graphics.Haskan.Vulkan.Shaders.Deferred.GodRays
  ( VertexDefs,
    GodRayFragmentDefs,
    vertex,
    fragment,
  )
where

import FIR
import Math.Linear

-- Shared vertex shader with Lighting/Cloud passes
-- Fullscreen triangle, outputs UV

type VertexDefs =
  '[ "out_uv" ':-> Output '[Location 0] (V 2 Float),
     "main" ':-> EntryPoint '[] Vertex
   ]

vertex :: ShaderModule "main" VertexShader VertexDefs _
vertex = shader do
  -- Fullscreen triangle covering the viewport
  -- vert 0: (-1, -1) clip -> UV (0, 1)
  -- vert 1: ( 3, -1) clip -> UV (2, 1)
  -- vert 2: (-1,  3) clip -> UV (0,-1)
  vid <- get @"gl_VertexIndex"
  let x = if vid == 1 then 3.0 else (-1.0)
      y = if vid == 2 then 3.0 else (-1.0)
      u = if vid == 1 then 2.0 else 0.0
      v = if vid == 2 then (-1.0) else 1.0
  put @"gl_Position" (Vec4 x y 0.0 1.0)
  put @"out_uv" (Vec2 u v)

type GodRayPushConstant =
  Struct
    '[ "sunScreenX" ':-> Float,
       "sunScreenY" ':-> Float,
       "intensity" ':-> Float,
       "numSamples" ':-> Float,
       "decay" ':-> Float,
       "density" ':-> Float,
       "weight" ':-> Float,
       "exposure" ':-> Float,
       "padding" ':-> V 3 Float
     ]

type GodRayFragmentDefs =
  '[ "in_uv" ':-> Input '[Location 0] (V 2 Float),
     "cloud_result" ':-> Texture2D '[Binding 0, DescriptorSet 0] (RGBA16 F),
     "god_ray_data"
       ':-> PushConstant
              '[]
              GodRayPushConstant,
     "out_colour" ':-> Output '[Location 0] (V 4 Float),
     "main" ':-> EntryPoint '[OriginUpperLeft] Fragment
   ]

fragment :: ShaderModule "main" FragmentShader GodRayFragmentDefs _
fragment = shader do
  uv <- get @"in_uv"
  let (Vec2 uvX uvY) = uv

  -- Read push constants
  godRayData <- get @"god_ray_data"
  let sunScreenX = view @(Name "sunScreenX") godRayData
      sunScreenY = view @(Name "sunScreenY") godRayData
      intensity = view @(Name "intensity") godRayData
      numSamples = view @(Name "numSamples") godRayData
      decay = view @(Name "decay") godRayData
      density = view @(Name "density") godRayData
      weight = view @(Name "weight") godRayData
      exposure = view @(Name "exposure") godRayData

  -- Direction from current pixel to sun position
  let deltaX = uvX - sunScreenX
      deltaY = uvY - sunScreenY
      distToSun = sqrt (deltaX * deltaX + deltaY * deltaY)

      -- Only compute god rays if sun is on screen and intensity > 0
      sunOnScreen =
        step 0.0 sunScreenX
          * step sunScreenX 1.0
          * step 0.0 sunScreenY
          * step sunScreenY 1.0

  -- Radial blur: sample along line from pixel toward sun
  -- Beer-Lambert attenuation with in-scattering for proper crepuscular rays
  _ <- def @"transmittance" @RW @Float 1.0
  _ <- def @"accLight" @RW @Float 0.0
  _ <- def @"sampleDecay" @RW @Float 1.0
  _ <- def @"sampleU" @RW @Float uvX
  _ <- def @"sampleV" @RW @Float uvY

  -- Unrolled 32 iterations using a while loop
  _ <- def @"i" @RW @Int32 0
  loop do
    i <- get @"i"
    when (fromIntegral i >= (32.0 :: Code Float)) do
      break @1

    su <- get @"sampleU"
    sv <- get @"sampleV"
    ~(Vec4 _cloudR _cloudG _cloudB cloudA) <- use @(ImageTexel "cloud_result") NilOps (Vec2 su sv)

    t <- get @"transmittance"
    sd <- get @"sampleDecay"
    let stepOcclusion = cloudA * density
        newT = t * exp (-stepOcclusion)
        -- In-scatter: light that reaches this point and scatters toward camera
        scatter = t * (1.0 - exp (-stepOcclusion)) * sd * weight

    put @"transmittance" newT
    modify @"accLight" (+ scatter)
    put @"sampleDecay" (sd * decay)
    put @"sampleU" (su - deltaX * density)
    put @"sampleV" (sv - deltaY * density)
    modify @"i" (+ 1)

  finalLight <- get @"accLight"

  -- Apply exposure and intensity, mask by sun visibility
  let godRayR = finalLight * exposure * intensity * sunOnScreen
      godRayG = finalLight * exposure * intensity * sunOnScreen
      godRayB = finalLight * exposure * intensity * sunOnScreen

  put @"out_colour" (Vec4 godRayR godRayG godRayB 1.0)
