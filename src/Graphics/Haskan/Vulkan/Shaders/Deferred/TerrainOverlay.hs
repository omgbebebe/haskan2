{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -fno-warn-partial-type-signatures #-}

module Graphics.Haskan.Vulkan.Shaders.Deferred.TerrainOverlay
  ( terrainVertex,
    terrainFragment,
    TerrainFragmentDefs,
  )
where

import FIR
import Math.Linear

type TerrainFrameData =
  Struct
    '[ "cameraX" ':-> Float,
       "cameraY" ':-> Float,
       "cameraZ" ':-> Float,
       "ray0" ':-> V 3 Float,
       "ray1" ':-> V 3 Float,
       "ray2" ':-> V 3 Float
     ]

type TerrainVertexDefs =
  '[ "out_uv" ':-> Output '[Location 0] (V 2 Float),
     "out_ray" ':-> Output '[Location 1] (V 3 Float),
     "terrain_frame_data"
       ':-> Uniform
              '[Binding 2, DescriptorSet 0]
              TerrainFrameData,
     "main" ':-> EntryPoint '[] Vertex
   ]

terrainVertex :: ShaderModule "main" VertexShader TerrainVertexDefs _
terrainVertex = shader do
  vertIdx <- get @"gl_VertexIndex"
  let fi = fromIntegral vertIdx :: Code Float
      x = if fi == 0 then (-1) else if fi == 1 then 3 else (-1)
      y = if fi == 0 then (-1) else if fi == 1 then (-1) else 3
      u = if fi == 0 then 0 else if fi == 1 then 2 else 0
      v = if fi == 0 then 1 else if fi == 1 then 1 else (-1)

  frameData <- get @"terrain_frame_data"
  let ray0 = view @(Name "ray0") frameData
      ray1 = view @(Name "ray1") frameData
      ray2 = view @(Name "ray2") frameData
      rayDir = if fi == 0 then ray0 else if fi == 1 then ray1 else ray2

  put @"out_uv" (Vec2 u v)
  put @"out_ray" rayDir
  put @"gl_Position" (Vec4 x y 0 1)

type TerrainFragmentDefs =
  '[ "in_uv" ':-> Input '[Location 0] (V 2 Float),
     "in_ray" ':-> Input '[Location 1] (V 3 Float),
     "elevation"
       ':-> Texture2D
              '[Binding 0, DescriptorSet 0]
              (R16 SNorm),
     "climate"
       ':-> Texture2D
              '[Binding 1, DescriptorSet 0]
              (RGBA32 F),
     "terrain_frame_data"
       ':-> Uniform
              '[Binding 2, DescriptorSet 0]
              TerrainFrameData,
     "out_colour" ':-> Output '[Location 0] (V 4 Float),
     "main" ':-> EntryPoint '[OriginUpperLeft] Fragment
   ]

terrainFragment :: ShaderModule "main" FragmentShader TerrainFragmentDefs _
terrainFragment = shader do
  uv <- get @"in_uv"
  rayDir <- get @"in_ray"
  frameData <- get @"terrain_frame_data"

  let (Vec2 uvX uvY) = uv
      (Vec3 rayDirX rayDirY rayDirZ) = rayDir
      camX = view @(Name "cameraX") frameData
      camY = view @(Name "cameraY") frameData
      camZ = view @(Name "cameraZ") frameData

      -- Normalize ray direction
      rayLen = sqrt (rayDirX * rayDirX + rayDirY * rayDirY + rayDirZ * rayDirZ + 0.0001)
      dirX = rayDirX / rayLen
      dirY = rayDirY / rayLen
      dirZ = rayDirZ / rayLen

      -- Ray-plane intersection with Y = 0 (ground plane)
      tGround = if dirY < (-0.001) then (-(camY / dirY)) else 1000000.0
      worldPosX = camX + dirX * tGround
      worldPosZ = camZ + dirZ * tGround

      -- Scale: tile covers 2560 x 2560 world units, centered at origin
      -- This makes the single 256x256 tile stretch to cover a reasonable area
      texU = worldPosX / 2560.0 + 0.5
      texV = worldPosZ / 2560.0 + 0.5
      inBoundsU = texU >= 0.0 && texU <= 1.0
      inBoundsV = texV >= 0.0 && texV <= 1.0
      inBounds = inBoundsU && inBoundsV

  elevRaw <- use @(ImageTexel "elevation") NilOps (Vec2 texU texV)
  ~(Vec4 climateR climateG climateB _) <- use @(ImageTexel "climate") NilOps (Vec2 texU texV)

  let elevMeters = elevRaw * 32767.0

      -- Elevation-based color (grayscale-ish with tint)
      -- Low = dark green, Mid = brown, High = white
      elevNorm = clamp (elevMeters / 500.0) 0.0 1.0
      proceduralCol =
        if elevNorm < 0.2
          then Vec3 0.1 0.3 0.1
          else
            if elevNorm < 0.5
              then Vec3 0.3 0.25 0.15
              else
                if elevNorm < 0.8
                  then Vec3 0.5 0.4 0.3
                  else Vec3 0.9 0.9 0.95

      -- Use climate if it looks valid (not pure white), otherwise procedural
      climateIsWhite = climateR > 0.95 && climateG > 0.95 && climateB > 0.95
      finalCol =
        if inBounds
          then (if climateIsWhite then proceduralCol else Vec3 climateR climateG climateB)
          else proceduralCol

      -- Show terrain whenever ray hits ground plane, regardless of tile bounds
      -- This way we see procedural color outside the tile instead of nothing
      showTerrain = tGround < 100000.0

      (Vec3 finalR finalG finalB) = finalCol
      outCol = if showTerrain then Vec4 finalR finalG finalB 1.0 else Vec4 0.0 0.0 0.0 0.0

  put @"out_colour" outCol
