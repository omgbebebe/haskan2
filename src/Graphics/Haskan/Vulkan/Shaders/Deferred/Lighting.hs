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
  --   0: (-1, -1) -> UV (0, 1)
  --   1: ( 3, -1) -> UV (2, 1)
  --   2: (-1,  3) -> UV (0,-1)
  -- This covers the entire screen with a single large triangle.
  -- V is flipped so screen Y aligns with Vulkan texture V
  -- (screen top -> UV v=0 -> texture top).
  vertIdx <- get @"gl_VertexIndex"
  let fi = fromIntegral vertIdx :: Code Float
      x = if fi == 0 then (-1) else if fi == 1 then 3 else (-1)
      y = if fi == 0 then (-1) else if fi == 1 then (-1) else 3
      u = if fi == 0 then 0 else if fi == 1 then 2 else 0
      v = if fi == 0 then 1 else if fi == 1 then 1 else (-1)
  put @"out_uv" (Vec2 u v)
  put @"gl_Position" (Vec4 x y 0 1)

------------------------------------------------
-- fragment shader
-- Samples g-buffer and computes PBR directional light
-- All math done with scalars to avoid FIR vector-scalar inference issues

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
      metallic = view @(Index 3) posSample
      roughness = view @(Index 3) normSample
      ao = view @(Index 3) albSample

      -- Normalize normal
      normLen = sqrt (normX * normX + normY * normY + normZ * normZ + 0.0001)
      nx = normX / normLen
      ny = normY / normLen
      nz = normZ / normLen

      -- Light direction
      ldx = 1.0 / sqrt 3.0
      ldy = 1.0 / sqrt 3.0
      ldz = 1.0 / sqrt 3.0

      -- View direction (camera at origin)
      vlen = sqrt (posX * posX + posY * posY + posZ * posZ + 0.0001)
      vx = (-posX) / vlen
      vy = (-posY) / vlen
      vz = (-posZ) / vlen

      -- Dot products
      nDotL = max 0 (nx * ldx + ny * ldy + nz * ldz)
      nDotV = max 0 (nx * vx + ny * vy + nz * vz)

      -- Half vector
      hx = ldx + vx
      hy = ldy + vy
      hz = ldz + vz
      hlen = sqrt (hx * hx + hy * hy + hz * hz + 0.0001)
      hnx = hx / hlen
      hny = hy / hlen
      hnz = hz / hlen

      nDotH = max 0 (nx * hnx + ny * hny + nz * hnz)
      vDotH = max 0 (vx * hnx + vy * hny + vz * hnz)

      -- PBR BRDF (all scalar)
      -- F0
      f0x = 0.04 * (1 - metallic) + albR * metallic
      f0y = 0.04 * (1 - metallic) + albG * metallic
      f0z = 0.04 * (1 - metallic) + albB * metallic

      -- Fresnel (Schlick)
      omv = 1 - vDotH
      omv2 = omv * omv
      omv4 = omv2 * omv2
      omv5 = omv4 * omv
      fresx = f0x + (1 - f0x) * omv5
      fresy = f0y + (1 - f0y) * omv5
      fresz = f0z + (1 - f0z) * omv5

      -- GGX Normal Distribution
      alpha = roughness * roughness
      alphaSq = alpha * alpha
      denom = nDotH * nDotH * (alphaSq - 1) + 1
      d = alphaSq / (3.14159265 * denom * denom)

      -- Geometry (Schlick-Smith)
      k = (alpha + 1) * (alpha + 1) / 8
      g1L = nDotL / (nDotL * (1 - k) + k)
      g1V = nDotV / (nDotV * (1 - k) + k)
      g = g1L * g1V

      -- Specular
      specDenom = 4 * nDotL * nDotV + 0.001
      specx = d * fresx * g / specDenom
      specy = d * fresy * g / specDenom
      specz = d * fresz * g / specDenom

      -- Diffuse (Lambert)
      diffx = albR * (1 - metallic) / 3.14159265
      diffy = albG * (1 - metallic) / 3.14159265
      diffz = albB * (1 - metallic) / 3.14159265

      -- Combine
      brdfx = diffx + specx
      brdfy = diffy + specy
      brdfz = diffz + specz

      litx = brdfx * nDotL
      lity = brdfy * nDotL
      litz = brdfz * nDotL

      -- Ambient + AO
      ambx = albR * 0.03 * ao
      amby = albG * 0.03 * ao
      ambz = albB * 0.03 * ao

      colx = ambx + litx
      coly = amby + lity
      colz = ambz + litz

      -- Tone mapping (Reinhard)
      mapx = colx / (colx + 1)
      mapy = coly / (coly + 1)
      mapz = colz / (colz + 1)

      -- Gamma correction (approximate with sqrt for gamma 2.0)
      gamx = sqrt mapx
      gamy = sqrt mapy
      gamz = sqrt mapz

  put @"out_colour" (Vec4 gamx gamy gamz 1)
