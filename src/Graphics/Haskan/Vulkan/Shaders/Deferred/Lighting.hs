{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Graphics.Haskan.Vulkan.Shaders.Deferred.Lighting where

import FIR
import Graphics.Haskan.Vulkan.Shaders.LightData
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
  -- Works with negative viewport height (Vulkan 1.1+):
  --   clip y=-1 -> screen bottom -> UV v=1 (g-buffer bottom)
  --   clip y=1  -> screen top    -> UV v=0 (g-buffer top)
  -- Interpolation across the triangle gives correct UVs for all pixels.
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
-- Samples g-buffer and computes PBR lighting
-- All math done with scalars to avoid FIR vector-scalar inference issues

type CameraPushConstant =
  Struct
    '[ "cameraX" ':-> Float,
       "cameraY" ':-> Float,
       "cameraZ" ':-> Float,
       "debugMode" ':-> Float,
       "axisOverlay" ':-> Float,
       "groundPlane" ':-> Float,
       "sunAzimuth" ':-> Float,
       "lightCount" ':-> Float,
       "ray0" ':-> V 3 Float,
       "ray1" ':-> V 3 Float,
       "ray2" ':-> V 3 Float,
       "skyTintR" ':-> Float,
       "skyTintG" ':-> Float,
       "skyTintB" ':-> Float,
       "iblIntensity" ':-> Float,
       "sunDir" ':-> V 3 Float,
       "cloudHeight" ':-> Float,
       "time" ':-> Float
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
     "lights"
       ':-> StorageBuffer
              '[Binding 7, DescriptorSet 0]
              LightsData,
     "cloud_result"
       ':-> Texture2D
              '[Binding 8, DescriptorSet 0]
              (RGBA16 F),
     "cameraPos"
       ':-> PushConstant
              '[]
              CameraPushConstant,
     "out_colour" ':-> Output '[Location 0] (V 4 Float),
     "main" ':-> EntryPoint '[OriginUpperLeft] Fragment
   ]

-- Debug mode values (all Float type, passed as push constant)
-- 0  = normal lit (default)
-- 1  = albedo          (F1)
-- 2  = normals (world-space) (F2)
-- 3  = roughness       (F3)
-- 4  = metallic        (F4)
-- 5  = position        (F5)
-- 6  = emissive        (F6)
-- 7  = AO              (F7)
-- 8  = NdotL           (F8)
-- 9  = irradiance      (F9)
-- 10 = specular IBL    (Ctrl+F12)
-- 11 = Fresnel         (Shift+F12)
-- 12 = skybox (raw env_map sample, all pixels) (Shift+Ctrl+F12)
-- 13 = cloud density   (Shift+F1)
-- 14 = height mask     (Shift+F2)
-- 15 = raw noise       (Shift+F3)

fragment :: ShaderModule "main" FragmentShader FragmentDefs _
fragment = shader do
  uv <- get @"in_uv"
  let (Vec2 uvX uvY) = uv
  rayDir <- get @"in_ray"
  let (Vec3 rayDirX rayDirY rayDirZ) = rayDir

  -- Normalize ray direction (interpolated varyings are not unit-length)
  let rayLen = sqrt (rayDirX * rayDirX + rayDirY * rayDirY + rayDirZ * rayDirZ + 0.0001)
      dirX = rayDirX / rayLen
      dirY = rayDirY / rayLen
      dirZ = rayDirZ / rayLen

  -- Read push constants early (needed for cubemap rotation)
  cameraPos <- get @"cameraPos"
  let sunAzimuth = view @(Name "sunAzimuth") cameraPos
      iblIntensity = view @(Name "iblIntensity") cameraPos
      camX = view @(Name "cameraX") cameraPos
      camY = view @(Name "cameraY") cameraPos
      camZ = view @(Name "cameraZ") cameraPos
      ~(Vec3 sunDirX sunDirY sunDirZ) = view @(Name "sunDir") cameraPos
      cloudBottom = view @(Name "cloudHeight") cameraPos
      time = view @(Name "time") cameraPos

  -- Precompute cubemap rotation from sun azimuth (kept for potential future use)
  let cosAz = cos sunAzimuth
      sinAz = sin sunAzimuth
      rotateY (Vec3 rx ry rz) = Vec3 (rx * cosAz - rz * sinAz) ry (rx * sinAz + rz * cosAz)

  -- Sample g-buffer with lazy pattern matching to avoid view constraint issues
  ~(Vec4 posX posY posZ metallic) <- use @(ImageTexel "gbuf_position") NilOps uv
  ~(Vec4 normX_raw normY_raw normZ_raw roughness) <- use @(ImageTexel "gbuf_normal") NilOps uv
  ~(Vec4 albR albG albB ao) <- use @(ImageTexel "gbuf_albedo") NilOps uv
  ~(Vec4 emissiveR emissiveG emissiveB _) <- use @(ImageTexel "gbuf_emissive") NilOps uv

  -- Check if background (no geometry written to g-buffer)
  let hasGeometry = abs posX + abs posY + abs posZ > 0.001

  -- Sample skybox for background (NO rotation — mountains/stars stay fixed)
  ~(Vec4 skyR skyG skyB _) <- use @(ImageTexel "env_map") NilOps (Vec3 dirX dirY dirZ)

  -- Sample cloud result texture (rendered in separate pass)
  ~(Vec4 cloudSkyR_h cloudSkyG_h cloudSkyB_h _) <- use @(ImageTexel "cloud_result") NilOps uv

  let cloudSkyR = convert cloudSkyR_h
      cloudSkyG = convert cloudSkyG_h
      cloudSkyB = convert cloudSkyB_h

      dbgCloud = cloudSkyR * 0.5
      dbgHeight = cloudSkyG * 0.5
      dbgNoise = cloudSkyB * 0.5

  let normX = normX_raw * 2 - 1
      normY = normY_raw * 2 - 1
      normZ = normZ_raw * 2 - 1

      -- Normalize normal
      normLen = sqrt (normX * normX + normY * normY + normZ * normZ + 0.0001)
      nx = normX / normLen
      ny = normY / normLen
      nz = normZ / normLen

  -- Remaining push constants
  let debugMode = view @(Name "debugMode") cameraPos
      axisOverlay = view @(Name "axisOverlay") cameraPos
      groundPlane = view @(Name "groundPlane") cameraPos
      lightCount = view @(Name "lightCount") cameraPos
      skyTintR = view @(Name "skyTintR") cameraPos
      skyTintG = view @(Name "skyTintG") cameraPos
      skyTintB = view @(Name "skyTintB") cameraPos

  let -- View direction (from fragment to camera)
      vdx = camX - posX
      vdy = camY - posY
      vdz = camZ - posZ
      vlen = sqrt (vdx * vdx + vdy * vdy + vdz * vdz + 0.0001)
      vx = vdx / vlen
      vy = vdy / vlen
      vz = vdz / vlen

      -- Shared dot product (view-independent)
      nDotV = max 0 (nx * vx + ny * vy + nz * vz)

      -- F0 (shared across all lights)
      f0x = 0.04 * (1 - metallic) + albR * metallic
      f0y = 0.04 * (1 - metallic) + albG * metallic
      f0z = 0.04 * (1 - metallic) + albB * metallic

  -- Light 0
  ~(Vec3 l0dirX l0dirY l0dirZ) <- use @(Name "lights" :.: Name "data" :.: AnIndex Word32 :.: Name "direction") 0
  l0int <- use @(Name "lights" :.: Name "data" :.: AnIndex Word32 :.: Name "intensity") 0
  ~(Vec3 l0colR l0colG l0colB) <- use @(Name "lights" :.: Name "data" :.: AnIndex Word32 :.: Name "color") 0

  let l0dirLen = sqrt (l0dirX * l0dirX + l0dirY * l0dirY + l0dirZ * l0dirZ + 0.0001)
      l0dx = l0dirX / l0dirLen
      l0dy = l0dirY / l0dirLen
      l0dz = l0dirZ / l0dirLen
      l0nDotL = max 0 (nx * l0dx + ny * l0dy + nz * l0dz)
      l0hx = l0dx + vx
      l0hy = l0dy + vy
      l0hz = l0dz + vz
      l0hlen = sqrt (l0hx * l0hx + l0hy * l0hy + l0hz * l0hz + 0.0001)
      l0hnx = l0hx / l0hlen
      l0hny = l0hy / l0hlen
      l0hnz = l0hz / l0hlen
      l0nDotH = max 0 (nx * l0hnx + ny * l0hny + nz * l0hnz)
      l0vDotH = max 0 (vx * l0hnx + vy * l0hny + vz * l0hnz)
      l0omv = 1 - l0vDotH
      l0omv2 = l0omv * l0omv
      l0omv4 = l0omv2 * l0omv2
      l0omv5 = l0omv4 * l0omv
      l0fresx = f0x + (1 - f0x) * l0omv5
      l0fresy = f0y + (1 - f0y) * l0omv5
      l0fresz = f0z + (1 - f0z) * l0omv5
      l0alpha = roughness * roughness
      l0alphaSq = l0alpha * l0alpha
      l0denom = l0nDotH * l0nDotH * (l0alphaSq - 1) + 1
      l0d = l0alphaSq / (3.14159265 * l0denom * l0denom)
      l0k = (l0alpha + 1) * (l0alpha + 1) / 8
      l0g1L = l0nDotL / (l0nDotL * (1 - l0k) + l0k)
      l0g1V = nDotV / (nDotV * (1 - l0k) + l0k)
      l0g = l0g1L * l0g1V
      l0specDenom = 4 * l0nDotL * nDotV + 0.001
      l0specx = l0d * l0fresx * l0g / l0specDenom
      l0specy = l0d * l0fresy * l0g / l0specDenom
      l0specz = l0d * l0fresz * l0g / l0specDenom
      l0diffx = albR * (1 - metallic) / 3.14159265
      l0diffy = albG * (1 - metallic) / 3.14159265
      l0diffz = albB * (1 - metallic) / 3.14159265
      l0brdfx = l0diffx + l0specx
      l0brdfy = l0diffy + l0specy
      l0brdfz = l0diffz + l0specz
      l0litx = l0brdfx * l0nDotL * l0int * l0colR
      l0lity = l0brdfy * l0nDotL * l0int * l0colG
      l0litz = l0brdfz * l0nDotL * l0int * l0colB

  -- Light 1
  ~(Vec3 l1dirX l1dirY l1dirZ) <- use @(Name "lights" :.: Name "data" :.: AnIndex Word32 :.: Name "direction") 1
  l1int <- use @(Name "lights" :.: Name "data" :.: AnIndex Word32 :.: Name "intensity") 1
  ~(Vec3 l1colR l1colG l1colB) <- use @(Name "lights" :.: Name "data" :.: AnIndex Word32 :.: Name "color") 1

  let l1dirLen = sqrt (l1dirX * l1dirX + l1dirY * l1dirY + l1dirZ * l1dirZ + 0.0001)
      l1dx = l1dirX / l1dirLen
      l1dy = l1dirY / l1dirLen
      l1dz = l1dirZ / l1dirLen
      l1nDotL = max 0 (nx * l1dx + ny * l1dy + nz * l1dz)
      l1hx = l1dx + vx
      l1hy = l1dy + vy
      l1hz = l1dz + vz
      l1hlen = sqrt (l1hx * l1hx + l1hy * l1hy + l1hz * l1hz + 0.0001)
      l1hnx = l1hx / l1hlen
      l1hny = l1hy / l1hlen
      l1hnz = l1hz / l1hlen
      l1nDotH = max 0 (nx * l1hnx + ny * l1hny + nz * l1hnz)
      l1vDotH = max 0 (vx * l1hnx + vy * l1hny + vz * l1hnz)
      l1omv = 1 - l1vDotH
      l1omv2 = l1omv * l1omv
      l1omv4 = l1omv2 * l1omv2
      l1omv5 = l1omv4 * l1omv
      l1fresx = f0x + (1 - f0x) * l1omv5
      l1fresy = f0y + (1 - f0y) * l1omv5
      l1fresz = f0z + (1 - f0z) * l1omv5
      l1alpha = roughness * roughness
      l1alphaSq = l1alpha * l1alpha
      l1denom = l1nDotH * l1nDotH * (l1alphaSq - 1) + 1
      l1d = l1alphaSq / (3.14159265 * l1denom * l1denom)
      l1k = (l1alpha + 1) * (l1alpha + 1) / 8
      l1g1L = l1nDotL / (l1nDotL * (1 - l1k) + l1k)
      l1g1V = nDotV / (nDotV * (1 - l1k) + l1k)
      l1g = l1g1L * l1g1V
      l1specDenom = 4 * l1nDotL * nDotV + 0.001
      l1specx = l1d * l1fresx * l1g / l1specDenom
      l1specy = l1d * l1fresy * l1g / l1specDenom
      l1specz = l1d * l1fresz * l1g / l1specDenom
      l1diffx = albR * (1 - metallic) / 3.14159265
      l1diffy = albG * (1 - metallic) / 3.14159265
      l1diffz = albB * (1 - metallic) / 3.14159265
      l1brdfx = l1diffx + l1specx
      l1brdfy = l1diffy + l1specy
      l1brdfz = l1diffz + l1specz
      l1litx = l1brdfx * l1nDotL * l1int * l1colR
      l1lity = l1brdfy * l1nDotL * l1int * l1colG
      l1litz = l1brdfz * l1nDotL * l1int * l1colB

  -- Light 2
  ~(Vec3 l2dirX l2dirY l2dirZ) <- use @(Name "lights" :.: Name "data" :.: AnIndex Word32 :.: Name "direction") 2
  l2int <- use @(Name "lights" :.: Name "data" :.: AnIndex Word32 :.: Name "intensity") 2
  ~(Vec3 l2colR l2colG l2colB) <- use @(Name "lights" :.: Name "data" :.: AnIndex Word32 :.: Name "color") 2

  let l2dirLen = sqrt (l2dirX * l2dirX + l2dirY * l2dirY + l2dirZ * l2dirZ + 0.0001)
      l2dx = l2dirX / l2dirLen
      l2dy = l2dirY / l2dirLen
      l2dz = l2dirZ / l2dirLen
      l2nDotL = max 0 (nx * l2dx + ny * l2dy + nz * l2dz)
      l2hx = l2dx + vx
      l2hy = l2dy + vy
      l2hz = l2dz + vz
      l2hlen = sqrt (l2hx * l2hx + l2hy * l2hy + l2hz * l2hz + 0.0001)
      l2hnx = l2hx / l2hlen
      l2hny = l2hy / l2hlen
      l2hnz = l2hz / l2hlen
      l2nDotH = max 0 (nx * l2hnx + ny * l2hny + nz * l2hnz)
      l2vDotH = max 0 (vx * l2hnx + vy * l2hny + vz * l2hnz)
      l2omv = 1 - l2vDotH
      l2omv2 = l2omv * l2omv
      l2omv4 = l2omv2 * l2omv2
      l2omv5 = l2omv4 * l2omv
      l2fresx = f0x + (1 - f0x) * l2omv5
      l2fresy = f0y + (1 - f0y) * l2omv5
      l2fresz = f0z + (1 - f0z) * l2omv5
      l2alpha = roughness * roughness
      l2alphaSq = l2alpha * l2alpha
      l2denom = l2nDotH * l2nDotH * (l2alphaSq - 1) + 1
      l2d = l2alphaSq / (3.14159265 * l2denom * l2denom)
      l2k = (l2alpha + 1) * (l2alpha + 1) / 8
      l2g1L = l2nDotL / (l2nDotL * (1 - l2k) + l2k)
      l2g1V = nDotV / (nDotV * (1 - l2k) + l2k)
      l2g = l2g1L * l2g1V
      l2specDenom = 4 * l2nDotL * nDotV + 0.001
      l2specx = l2d * l2fresx * l2g / l2specDenom
      l2specy = l2d * l2fresy * l2g / l2specDenom
      l2specz = l2d * l2fresz * l2g / l2specDenom
      l2diffx = albR * (1 - metallic) / 3.14159265
      l2diffy = albG * (1 - metallic) / 3.14159265
      l2diffz = albB * (1 - metallic) / 3.14159265
      l2brdfx = l2diffx + l2specx
      l2brdfy = l2diffy + l2specy
      l2brdfz = l2diffz + l2specz
      l2litx = l2brdfx * l2nDotL * l2int * l2colR
      l2lity = l2brdfy * l2nDotL * l2int * l2colG
      l2litz = l2brdfz * l2nDotL * l2int * l2colB

  -- Light 3
  ~(Vec3 l3dirX l3dirY l3dirZ) <- use @(Name "lights" :.: Name "data" :.: AnIndex Word32 :.: Name "direction") 3
  l3int <- use @(Name "lights" :.: Name "data" :.: AnIndex Word32 :.: Name "intensity") 3
  ~(Vec3 l3colR l3colG l3colB) <- use @(Name "lights" :.: Name "data" :.: AnIndex Word32 :.: Name "color") 3

  let l3dirLen = sqrt (l3dirX * l3dirX + l3dirY * l3dirY + l3dirZ * l3dirZ + 0.0001)
      l3dx = l3dirX / l3dirLen
      l3dy = l3dirY / l3dirLen
      l3dz = l3dirZ / l3dirLen
      l3nDotL = max 0 (nx * l3dx + ny * l3dy + nz * l3dz)
      l3hx = l3dx + vx
      l3hy = l3dy + vy
      l3hz = l3dz + vz
      l3hlen = sqrt (l3hx * l3hx + l3hy * l3hy + l3hz * l3hz + 0.0001)
      l3hnx = l3hx / l3hlen
      l3hny = l3hy / l3hlen
      l3hnz = l3hz / l3hlen
      l3nDotH = max 0 (nx * l3hnx + ny * l3hny + nz * l3hnz)
      l3vDotH = max 0 (vx * l3hnx + vy * l3hny + vz * l3hnz)
      l3omv = 1 - l3vDotH
      l3omv2 = l3omv * l3omv
      l3omv4 = l3omv2 * l3omv2
      l3omv5 = l3omv4 * l3omv
      l3fresx = f0x + (1 - f0x) * l3omv5
      l3fresy = f0y + (1 - f0y) * l3omv5
      l3fresz = f0z + (1 - f0z) * l3omv5
      l3alpha = roughness * roughness
      l3alphaSq = l3alpha * l3alpha
      l3denom = l3nDotH * l3nDotH * (l3alphaSq - 1) + 1
      l3d = l3alphaSq / (3.14159265 * l3denom * l3denom)
      l3k = (l3alpha + 1) * (l3alpha + 1) / 8
      l3g1L = l3nDotL / (l3nDotL * (1 - l3k) + l3k)
      l3g1V = nDotV / (nDotV * (1 - l3k) + l3k)
      l3g = l3g1L * l3g1V
      l3specDenom = 4 * l3nDotL * nDotV + 0.001
      l3specx = l3d * l3fresx * l3g / l3specDenom
      l3specy = l3d * l3fresy * l3g / l3specDenom
      l3specz = l3d * l3fresz * l3g / l3specDenom
      l3diffx = albR * (1 - metallic) / 3.14159265
      l3diffy = albG * (1 - metallic) / 3.14159265
      l3diffz = albB * (1 - metallic) / 3.14159265
      l3brdfx = l3diffx + l3specx
      l3brdfy = l3diffy + l3specy
      l3brdfz = l3diffz + l3specz
      l3litx = l3brdfx * l3nDotL * l3int * l3colR
      l3lity = l3brdfy * l3nDotL * l3int * l3colG
      l3litz = l3brdfz * l3nDotL * l3int * l3colB

      -- Accumulate all lights
      litx = l0litx + l1litx + l2litx + l3litx
      lity = l0lity + l1lity + l2lity + l3lity
      litz = l0litz + l1litz + l2litz + l3litz

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

  -- Sample irradiance (diffuse IBL) with rotated normal
  ~(Vec4 irrR irrG irrB _) <- use @(ImageTexel "irradiance_map") NilOps (rotateY (Vec3 nx ny nz))

  -- Sample environment map (specular IBL) with rotated reflection vector
  -- Radiance cubemap is 512px with 10 mip levels (0..9)
  let maxMipF = 9.0 :: Code Float
      lod = roughness * maxMipF
  ~(Vec4 envR envG envB _) <- use @(ImageTexel "env_map") (LOD lod NilOps) (rotateY (Vec3 rx ry rz))

  let -- IBL intensity from push constant (day/night cycle)
      envIntensity = iblIntensity

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

      -- Tinted skybox for background pixels (no geometry)
      -- Use cloud-blended sky instead of raw skybox
      tintedSkyR = cloudSkyR * skyTintR
      tintedSkyG = cloudSkyG * skyTintG
      tintedSkyB = cloudSkyB * skyTintB
      finalx = if hasGeometry then gamx else tintedSkyR
      finaly = if hasGeometry then gamy else tintedSkyG
      finalz = if hasGeometry then gamz else tintedSkyB

      -- Debug mode 12.0: raw skybox for ALL pixels
      dbgSkyR = if debugMode == 12.0 then tintedSkyR else finalx
      dbgSkyG = if debugMode == 12.0 then tintedSkyG else finaly
      dbgSkyB = if debugMode == 12.0 then tintedSkyB else finalz

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

      -- Debug output selection (debugMode is Float, compare with float literals)
      outR =
        if debugMode == 1.0
          then albR
          else
            if debugMode == 2.0
              then dbgNormX
              else
                if debugMode == 3.0
                  then roughness
                  else
                    if debugMode == 4.0
                      then metallic
                      else
                        if debugMode == 5.0
                          then dbgPosX
                          else
                            if debugMode == 6.0
                              then emissiveR
                              else
                                if debugMode == 7.0
                                  then ao
                                  else
                                    if debugMode == 8.0
                                      then l0nDotL
                                      else
                                        if debugMode == 9.0
                                          then dbgIrrX
                                          else
                                            if debugMode == 10.0
                                              then dbgSpecX
                                              else
                                                if debugMode == 11.0
                                                  then dbgFresX
                                                  else
                                                    if debugMode == 12.0
                                                      then dbgSkyR
                                                      else
                                                        if debugMode == 13.0
                                                          then dbgCloud
                                                          else
                                                            if debugMode == 14.0
                                                              then dbgHeight
                                                              else
                                                                if debugMode == 15.0
                                                                  then dbgNoise
                                                                  else
                                                                    finalx

      outG =
        if debugMode == 1.0
          then albG
          else
            if debugMode == 2.0
              then dbgNormY
              else
                if debugMode == 3.0
                  then roughness
                  else
                    if debugMode == 4.0
                      then metallic
                      else
                        if debugMode == 5.0
                          then dbgPosY
                          else
                            if debugMode == 6.0
                              then emissiveG
                              else
                                if debugMode == 7.0
                                  then ao
                                  else
                                    if debugMode == 8.0
                                      then l0nDotL
                                      else
                                        if debugMode == 9.0
                                          then dbgIrrY
                                          else
                                            if debugMode == 10.0
                                              then dbgSpecY
                                              else
                                                if debugMode == 11.0
                                                  then dbgFresY
                                                  else
                                                    if debugMode == 12.0
                                                      then dbgSkyG
                                                      else
                                                        if debugMode == 13.0
                                                          then dbgCloud
                                                          else
                                                            if debugMode == 14.0
                                                              then dbgHeight
                                                              else
                                                                if debugMode == 15.0
                                                                  then dbgNoise
                                                                  else
                                                                    finaly

      outB =
        if debugMode == 1.0
          then albB
          else
            if debugMode == 2.0
              then dbgNormZ
              else
                if debugMode == 3.0
                  then roughness
                  else
                    if debugMode == 4.0
                      then metallic
                      else
                        if debugMode == 5.0
                          then dbgPosZ
                          else
                            if debugMode == 6.0
                              then emissiveB
                              else
                                if debugMode == 7.0
                                  then ao
                                  else
                                    if debugMode == 8.0
                                      then l0nDotL
                                      else
                                        if debugMode == 9.0
                                          then dbgIrrZ
                                          else
                                            if debugMode == 10.0
                                              then dbgSpecZ
                                              else
                                                if debugMode == 11.0
                                                  then dbgFresZ
                                                  else
                                                    if debugMode == 12.0
                                                      then dbgSkyB
                                                      else
                                                        if debugMode == 13.0
                                                          then dbgCloud
                                                          else
                                                            if debugMode == 14.0
                                                              then dbgHeight
                                                              else
                                                                if debugMode == 15.0
                                                                  then dbgNoise
                                                                  else
                                                                    finalz

      -- World axes overlay: draw thin lines radiating from screen center
      -- Use pre-normalized dirX/dirY/dirZ from early in the shader
      axisThresh = 0.9995 -- cos(1.8 degrees), much tighter for thin lines

      -- Only show positive axis directions (radiate outward from center)
      onXp = dirX > axisThresh
      onXn = (-dirX) > axisThresh
      onYp = dirY > axisThresh
      onYn = (-dirY) > axisThresh
      onZp = dirZ > axisThresh
      onZn = (-dirZ) > axisThresh
      isAxis = onXp || onXn || onYp || onYn || onZp || onZn

      -- Axis colors: X=red, Y=green, Z=blue (both directions same color)
      axisR = if onXp || onXn then 1.0 else if onYp || onYn then 0.0 else if onZp || onZn then 0.0 else 0.0
      axisG = if onXp || onXn then 0.0 else if onYp || onYn then 1.0 else if onZp || onZn then 0.0 else 0.0
      axisB = if onXp || onXn then 0.0 else if onYp || onYn then 0.0 else if onZp || onZn then 1.0 else 0.0

      -- Ground plane: intersect camera ray with Y=0
      tGround = (-camY) / (dirY + 0.0001)
      groundX = camX + dirX * tGround
      groundZ = camZ + dirZ * tGround
      groundDist = sqrt (groundX * groundX + groundZ * groundZ)

      -- Simple origin crosshair for ground plane (no grid, just X=0 and Z=0 lines)
      onOriginX = abs groundX < 0.05
      onOriginZ = abs groundZ < 0.05
      isGrid = onOriginX || onOriginZ

      -- Fade with distance (max 50 units)
      groundFade = max 0.0 (1.0 - groundDist / 50.0)

      -- Grid: transparent cells with bright lines
      gridR = if isGrid then 0.4 * groundFade else 0.0
      gridG = if isGrid then 0.4 * groundFade else 0.0
      gridB = if isGrid then 0.4 * groundFade else 0.0

      -- Ground plane visible only where there's no geometry and ray points below horizon
      hasGround = tGround > 0.0 && not hasGeometry

      -- Apply overlays
      withGroundR = if hasGround && groundPlane == 1.0 then gridR else outR
      withGroundG = if hasGround && groundPlane == 1.0 then gridG else outG
      withGroundB = if hasGround && groundPlane == 1.0 then gridB else outB

      finalR = if isAxis && axisOverlay == 1.0 then axisR else withGroundR
      finalG = if isAxis && axisOverlay == 1.0 then axisG else withGroundG
      finalB = if isAxis && axisOverlay == 1.0 then axisB else withGroundB

  put @"out_colour" (Vec4 finalR finalG finalB 1)
