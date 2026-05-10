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
     "out_ray" ':-> Output '[Location 1] (V 3 Float),
     "cameraPos"
       ':-> PushConstant
              '[]
              CameraPushConstant,
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

  -- Select ray direction for this vertex from push constant
  cameraPush <- get @"cameraPos"
  let ray0 = view @(Name "ray0") cameraPush
      ray1 = view @(Name "ray1") cameraPush
      ray2 = view @(Name "ray2") cameraPush
      rayDir = if fi == 0 then ray0 else if fi == 1 then ray1 else ray2

  put @"out_uv" (Vec2 u v)
  put @"out_ray" rayDir
  put @"gl_Position" (Vec4 x y 0 1)

------------------------------------------------
-- fragment shader
-- Samples g-buffer and computes PBR directional light
-- All math done with scalars to avoid FIR vector-scalar inference issues

type CameraPushConstant = Struct
  '[ "cameraX" ':-> Float
   , "cameraY" ':-> Float
   , "cameraZ" ':-> Float
   , "debugMode" ':-> Word32
   , "ray0" ':-> V 3 Float
   , "ray1" ':-> V 3 Float
   , "ray2" ':-> V 3 Float
   ]

type FragmentDefs =
  '[ "in_uv" ':-> Input '[Location 0] (V 2 Float),
     "in_ray" ':-> Input '[Location 1] (V 3 Float),
      "gbuf_position"
        ':-> Texture2D'
               '[Binding 0, DescriptorSet 0]
               (RGBA32 F)
               (RGBA16 F),
     "gbuf_normal"
       ':-> Texture2D
              '[Binding 1, DescriptorSet 0]
              (RGBA8 UNorm),
      "gbuf_albedo"
        ':-> Texture2D
               '[Binding 2, DescriptorSet 0]
               (RGBA8 UNorm),
      "gbuf_emissive"
        ':-> Texture2D
               '[Binding 3, DescriptorSet 0]
               (RGBA8 UNorm),
      "env_map"
        ':-> TextureCube
               '[Binding 4, DescriptorSet 0]
               (RGBA8 UNorm),
        "irradiance_map"
          ':-> TextureCube
                 '[Binding 5, DescriptorSet 0]
                 (RGBA8 UNorm),
        "brdf_lut"
          ':-> Texture2D
                 '[Binding 6, DescriptorSet 0]
                 (RGBA8 UNorm),
       "cameraPos"
         ':-> PushConstant
                '[]
                CameraPushConstant,
        "out_colour" ':-> Output '[Location 0] (V 4 Float),
       "main" ':-> EntryPoint '[OriginUpperLeft] Fragment
     ]

-- Debug mode values
-- 0 = normal lit
-- 1 = albedo
-- 2 = normals (world-space)
-- 3 = roughness
-- 4 = metallic
-- 5 = position
-- 6 = emissive
-- 7 = AO
-- 8 = NdotL
-- 9 = irradiance
-- 10 = specular IBL
-- 11 = Fresnel

fragment :: ShaderModule "main" FragmentShader FragmentDefs _
fragment = shader do
  uv <- get @"in_uv"
  rayDir <- get @"in_ray"
  -- Sample g-buffer with lazy pattern matching to avoid view constraint issues
  ~(Vec4 posX posY posZ metallic) <- use @(ImageTexel "gbuf_position") NilOps uv
  ~(Vec4 normX_raw normY_raw normZ_raw roughness) <- use @(ImageTexel "gbuf_normal") NilOps uv
  ~(Vec4 albR albG albB ao) <- use @(ImageTexel "gbuf_albedo") NilOps uv
  ~(Vec4 emissiveR emissiveG emissiveB _) <- use @(ImageTexel "gbuf_emissive") NilOps uv

  -- Check if background (no geometry written to g-buffer)
  let hasGeometry = abs posX + abs posY + abs posZ > 0.001

  -- Sample skybox for background
  ~(Vec4 skyR skyG skyB _) <- use @(ImageTexel "env_map") NilOps rayDir

  let normX = normX_raw * 2 - 1
      normY = normY_raw * 2 - 1
      normZ = normZ_raw * 2 - 1

      -- Normalize normal
      normLen = sqrt (normX * normX + normY * normY + normZ * normZ + 0.0001)
      nx = normX / normLen
      ny = normY / normLen
      nz = normZ / normLen

      -- Light direction
      ldx = 1.0 / sqrt 3.0
      ldy = 1.0 / sqrt 3.0
      ldz = 1.0 / sqrt 3.0

  -- Camera position (push constant)
  cameraPos <- get @"cameraPos"
  let camX = view @(Name "cameraX") cameraPos
      camY = view @(Name "cameraY") cameraPos
      camZ = view @(Name "cameraZ") cameraPos
      debugMode = view @(Name "debugMode") cameraPos

  let -- View direction (from fragment to camera)
      vdx = camX - posX
      vdy = camY - posY
      vdz = camZ - posZ
      vlen = sqrt (vdx * vdx + vdy * vdy + vdz * vdz + 0.0001)
      vx = vdx / vlen
      vy = vdy / vlen
      vz = vdz / vlen

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

      -- Reflection vector for IBL
      rDotN = 2 * (vx * nx + vy * ny + vz * nz)
      rx = nx * rDotN - vx
      ry = ny * rDotN - vy
      rz = nz * rDotN - vz

      -- Fresnel for IBL (Schlick with NdotV)
      omvIBL = 1 - nDotV
      omvIBL2 = omvIBL * omvIBL
      omvIBL4 = omvIBL2 * omvIBL2
      omvIBL5 = omvIBL4 * omvIBL
      fresIBLx = f0x + (1 - f0x) * omvIBL5
      fresIBLy = f0y + (1 - f0y) * omvIBL5
      fresIBLz = f0z + (1 - f0z) * omvIBL5

  -- Sample BRDF LUT for split-sum approximation
  ~(Vec4 brdfScale brdfBias _ _) <- use @(ImageTexel "brdf_lut") NilOps (Vec2 nDotV roughness)

  -- Sample irradiance (diffuse IBL)
  ~(Vec4 irrR irrG irrB _) <- use @(ImageTexel "irradiance_map") NilOps (Vec3 nx ny nz)

  -- Sample environment map (specular IBL) with roughness-based LOD
  -- Radiance cubemap is 512px with 10 mip levels (0..9)
  let maxMipF = 9.0 :: Code Float
      lod = roughness * maxMipF
  ~(Vec4 envR envG envB _) <- use @(ImageTexel "env_map") (LOD lod NilOps) (Vec3 rx ry rz)

  let -- IBL intensity scale (bright outdoor HDRI)
      envIntensity = 0.3

      -- Diffuse IBL (irradiance * albedo * (1-metallic) * AO)
      iblDiffx = irrR * albR * (1 - metallic) * ao * envIntensity
      iblDiffy = irrG * albG * (1 - metallic) * ao * envIntensity
      iblDiffz = irrB * albB * (1 - metallic) * ao * envIntensity

      -- Specular IBL with BRDF LUT (split-sum approximation)
      -- specular = envMap * (f0 * scale + bias)
      iblSpecx = envR * (fresIBLx * brdfScale + brdfBias) * envIntensity
      iblSpecy = envG * (fresIBLy * brdfScale + brdfBias) * envIntensity
      iblSpecz = envB * (fresIBLz * brdfScale + brdfBias) * envIntensity

      -- Combine: direct light + emissive + IBL
      colx = litx + emissiveR + iblDiffx + iblSpecx
      coly = lity + emissiveG + iblDiffy + iblSpecy
      colz = litz + emissiveB + iblDiffz + iblSpecz

      -- Tone mapping (Reinhard)
      mapx = colx / (colx + 1)
      mapy = coly / (coly + 1)
      mapz = colz / (colz + 1)

      -- Gamma correction (approximate with sqrt for gamma 2.0)
      gamx = sqrt mapx
      gamy = sqrt mapy
      gamz = sqrt mapz

      -- Skybox for background pixels (no geometry)
      finalx = if hasGeometry then gamx else skyR
      finaly = if hasGeometry then gamy else skyG
      finalz = if hasGeometry then gamz else skyB

      -- Debug visualization helpers
      -- Normals: map [-1,1] to [0,1]
      dbgNormX = nx * 0.5 + 0.5
      dbgNormY = ny * 0.5 + 0.5
      dbgNormZ = nz * 0.5 + 0.5

      -- Position: remap near origin for visibility
      dbgPosX = posX * 0.1 + 0.5
      dbgPosY = posY * 0.1 + 0.5
      dbgPosZ = posZ * 0.1 + 0.5

      -- Irradiance debug
      dbgIrrX = irrR * envIntensity
      dbgIrrY = irrG * envIntensity
      dbgIrrZ = irrB * envIntensity

      -- Specular IBL debug
      dbgSpecX = iblSpecx
      dbgSpecY = iblSpecy
      dbgSpecZ = iblSpecz

      -- Fresnel debug
      dbgFresX = fresIBLx
      dbgFresY = fresIBLy
      dbgFresZ = fresIBLz

      -- Debug output selection
      -- Compare against polymorphic literals resolved to Code Word32
      outR = if debugMode == 1 then albR else
             if debugMode == 2 then dbgNormX else
             if debugMode == 3 then roughness else
             if debugMode == 4 then metallic else
             if debugMode == 5 then dbgPosX else
             if debugMode == 6 then emissiveR else
             if debugMode == 7 then ao else
             if debugMode == 8 then nDotL else
             if debugMode == 9 then dbgIrrX else
             if debugMode == 10 then dbgSpecX else
             if debugMode == 11 then dbgFresX else
             finalx

      outG = if debugMode == 1 then albG else
             if debugMode == 2 then dbgNormY else
             if debugMode == 3 then roughness else
             if debugMode == 4 then metallic else
             if debugMode == 5 then dbgPosY else
             if debugMode == 6 then emissiveG else
             if debugMode == 7 then ao else
             if debugMode == 8 then nDotL else
             if debugMode == 9 then dbgIrrY else
             if debugMode == 10 then dbgSpecY else
             if debugMode == 11 then dbgFresY else
             finaly

      outB = if debugMode == 1 then albB else
             if debugMode == 2 then dbgNormZ else
             if debugMode == 3 then roughness else
             if debugMode == 4 then metallic else
             if debugMode == 5 then dbgPosZ else
             if debugMode == 6 then emissiveB else
             if debugMode == 7 then ao else
             if debugMode == 8 then nDotL else
             if debugMode == 9 then dbgIrrZ else
             if debugMode == 10 then dbgSpecZ else
             if debugMode == 11 then dbgFresZ else
             finalz

  put @"out_colour" (Vec4 outR outG outB 1)
