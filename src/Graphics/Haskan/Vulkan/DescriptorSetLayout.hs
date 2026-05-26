{-# LANGUAGE TemplateHaskell #-}

module Graphics.Haskan.Vulkan.DescriptorSetLayout
  ( managedDescriptorSetLayout,
    createDescriptorSetLayout,
    managedLightingDescriptorSetLayout,
    createLightingDescriptorSetLayout,
    managedLightingProceduralDescriptorSetLayout,
    createLightingProceduralDescriptorSetLayout,
    managedCloudDescriptorSetLayout,
    createCloudDescriptorSetLayout,
    managedGodRayDescriptorSetLayout,
    createGodRayDescriptorSetLayout,
    managedTerrainDescriptorSetLayout,
    createTerrainDescriptorSetLayout,
    managedTerrainMeshDescriptorSetLayout,
    createTerrainMeshDescriptorSetLayout,
    managedBindlessDescriptorSetLayout,
    createBindlessDescriptorSetLayout,
    managedBindlessPassDescriptorSetLayout,
    createBindlessPassDescriptorSetLayout,
    managedComputeDescriptorSetLayout,
    createComputeDescriptorSetLayout,
    managedCubemapComputeDescriptorSetLayout,
    createCubemapComputeDescriptorSetLayout,
    managedCloudNoiseComputeDescriptorSetLayout,
    createCloudNoiseComputeDescriptorSetLayout,
    managedCloudDetailNoiseComputeDescriptorSetLayout,
    createCloudDetailNoiseComputeDescriptorSetLayout,
    managedCloudNoiseMipGenComputeDescriptorSetLayout,
    createCloudNoiseMipGenComputeDescriptorSetLayout,
    managedWeatherMapComputeDescriptorSetLayout,
    createWeatherMapComputeDescriptorSetLayout,
    managedAPVolumeComputeDescriptorSetLayout,
    createAPVolumeComputeDescriptorSetLayout,
    maxBindlessTextures,
    layoutBinding,
  )
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Bits ((.|.))
import Data.Coerce (coerce)
import Data.Vector qualified as Vector
import Data.Word (Word32)
import Graphics.Haskan.Resources (alloc)
import Graphics.Haskan.Vulkan.DescriptorSetLayout.TH (descriptorSetLayoutBindings)
import Graphics.Haskan.Vulkan.Shaders.Compute.APVolume qualified as APVolume
import Graphics.Haskan.Vulkan.Shaders.Compute.CloudDetailNoiseGen qualified as CloudDetailNoiseGen
import Graphics.Haskan.Vulkan.Shaders.Compute.CloudNoiseGen qualified as CloudNoiseGen
import Graphics.Haskan.Vulkan.Shaders.Compute.CloudNoiseMipGen qualified as CloudNoiseMipGen
import Graphics.Haskan.Vulkan.Shaders.Compute.Cull qualified as Cull
import Graphics.Haskan.Vulkan.Shaders.Compute.IrradianceGen qualified as IrradianceGen
import Graphics.Haskan.Vulkan.Shaders.Compute.RadianceGen qualified as RadianceGen
import Graphics.Haskan.Vulkan.Shaders.Compute.WeatherMapGen qualified as WeatherMapGen
import Graphics.Haskan.Vulkan.Shaders.Deferred.Clouds (CloudFragmentDefs)
import Graphics.Haskan.Vulkan.Shaders.Deferred.GodRays (GodRayFragmentDefs)
import Graphics.Haskan.Vulkan.Shaders.Deferred.Lighting qualified as Lighting
import Graphics.Haskan.Vulkan.Shaders.Deferred.LightingProcedural qualified as LightingProcedural
import Graphics.Haskan.Vulkan.Shaders.Deferred.TerrainOverlay (TerrainFragmentDefs)
import Language.Haskell.TH (Exp (VarE), mkName)
import Vulkan qualified as Vk26
import Vulkan.Core10.Enums.DescriptorSetLayoutCreateFlagBits qualified as V10
import Vulkan.Core12.Enums.DescriptorBindingFlagBits qualified as V12
import Vulkan.Zero (zero)

maxBindlessTextures :: Int
maxBindlessTextures = 1024

-- | Helper to construct a single VkDescriptorSetLayoutBinding.
layoutBinding :: Int -> Int -> Vk26.DescriptorType -> Vk26.ShaderStageFlags -> Vk26.DescriptorSetLayoutBinding
layoutBinding binding count descriptorType stageFlags =
  Vk26.DescriptorSetLayoutBinding
    (fromIntegral binding)
    descriptorType
    (fromIntegral count)
    stageFlags
    Vector.empty

-- Descriptor type helpers (avoid pattern synonym issues in TH splices).
vkCombinedImageSampler :: Vk26.DescriptorType
vkCombinedImageSampler = Vk26.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER

vkUniformBuffer :: Vk26.DescriptorType
vkUniformBuffer = Vk26.DESCRIPTOR_TYPE_UNIFORM_BUFFER

vkStorageBuffer :: Vk26.DescriptorType
vkStorageBuffer = Vk26.DESCRIPTOR_TYPE_STORAGE_BUFFER

vkStorageImage :: Vk26.DescriptorType
vkStorageImage = Vk26.DESCRIPTOR_TYPE_STORAGE_IMAGE

-- Stage flag helpers (avoid pattern synonym issues in TH splices).
vkFragmentBit :: Vk26.ShaderStageFlags
vkFragmentBit = Vk26.SHADER_STAGE_FRAGMENT_BIT

vkVertexFragmentBits :: Vk26.ShaderStageFlags
vkVertexFragmentBits = Vk26.SHADER_STAGE_VERTEX_BIT .|. Vk26.SHADER_STAGE_FRAGMENT_BIT

vkMeshBit :: Vk26.ShaderStageFlags
vkMeshBit = Data.Coerce.coerce (0x00000080 :: Word32) -- VK_SHADER_STAGE_MESH_BIT_EXT

vkComputeBit :: Vk26.ShaderStageFlags
vkComputeBit = Vk26.SHADER_STAGE_COMPUTE_BIT

managedDescriptorSetLayout :: (MonadManaged m) => Vk26.Device -> m Vk26.DescriptorSetLayout
managedDescriptorSetLayout dev =
  alloc
    "DescriptorSetLayout"
    (createDescriptorSetLayout dev)
    (\ptr -> Vk26.destroyDescriptorSetLayout dev ptr Nothing)

createDescriptorSetLayout :: (MonadIO m) => Vk26.Device -> m Vk26.DescriptorSetLayout
createDescriptorSetLayout dev = do
  let viewProjBinding =
        Vk26.DescriptorSetLayoutBinding
          0
          Vk26.DESCRIPTOR_TYPE_UNIFORM_BUFFER
          1
          Vk26.SHADER_STAGE_VERTEX_BIT
          Vector.empty
      textureBinding =
        Vk26.DescriptorSetLayoutBinding
          1
          Vk26.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
          (fromIntegral maxBindlessTextures)
          Vk26.SHADER_STAGE_FRAGMENT_BIT
          Vector.empty
      entityBinding =
        Vk26.DescriptorSetLayoutBinding
          2
          Vk26.DESCRIPTOR_TYPE_STORAGE_BUFFER
          1
          (Vk26.SHADER_STAGE_VERTEX_BIT .|. Vk26.SHADER_STAGE_FRAGMENT_BIT)
          Vector.empty
      bindingFlags :: Vk26.DescriptorBindingFlags
      bindingFlags = V12.DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT
      bindingFlagsCreateInfo =
        Vk26.DescriptorSetLayoutBindingFlagsCreateInfo
          (Vector.fromList [zero, bindingFlags, zero])
      createInfo =
        Vk26.DescriptorSetLayoutCreateInfo
          (bindingFlagsCreateInfo, ())
          zero
          (Vector.fromList [viewProjBinding, textureBinding, entityBinding])
  liftIO $ Vk26.createDescriptorSetLayout dev createInfo Nothing

managedLightingDescriptorSetLayout :: (MonadManaged m) => Vk26.Device -> m Vk26.DescriptorSetLayout
managedLightingDescriptorSetLayout dev =
  alloc
    "LightingDescriptorSetLayout"
    (createLightingDescriptorSetLayout dev)
    (\ptr -> Vk26.destroyDescriptorSetLayout dev ptr Nothing)

createLightingDescriptorSetLayout :: (MonadIO m) => Vk26.Device -> m Vk26.DescriptorSetLayout
createLightingDescriptorSetLayout dev = do
  let bindings = $(descriptorSetLayoutBindings (\_b -> pure (VarE (mkName "vkFragmentBit"))) Nothing ''Lighting.FragmentDefs)
      createInfo = Vk26.DescriptorSetLayoutCreateInfo () zero (Vector.fromList bindings)
  liftIO $ Vk26.createDescriptorSetLayout dev createInfo Nothing

managedLightingProceduralDescriptorSetLayout :: (MonadManaged m) => Vk26.Device -> m Vk26.DescriptorSetLayout
managedLightingProceduralDescriptorSetLayout dev =
  alloc
    "LightingProceduralDescriptorSetLayout"
    (createLightingProceduralDescriptorSetLayout dev)
    (\ptr -> Vk26.destroyDescriptorSetLayout dev ptr Nothing)

createLightingProceduralDescriptorSetLayout :: (MonadIO m) => Vk26.Device -> m Vk26.DescriptorSetLayout
createLightingProceduralDescriptorSetLayout dev = do
  let bindings = $(descriptorSetLayoutBindings (\_b -> pure (VarE (mkName "vkFragmentBit"))) Nothing ''LightingProcedural.FragmentDefs)
      createInfo = Vk26.DescriptorSetLayoutCreateInfo () zero (Vector.fromList bindings)
  liftIO $ Vk26.createDescriptorSetLayout dev createInfo Nothing

-- | Cloud descriptor set layout: env cubemap + 3D noise texture
managedCloudDescriptorSetLayout :: (MonadManaged m) => Vk26.Device -> m Vk26.DescriptorSetLayout
managedCloudDescriptorSetLayout dev =
  alloc
    "CloudDescriptorSetLayout"
    (createCloudDescriptorSetLayout dev)
    (\ptr -> Vk26.destroyDescriptorSetLayout dev ptr Nothing)

createCloudDescriptorSetLayout :: (MonadIO m) => Vk26.Device -> m Vk26.DescriptorSetLayout
createCloudDescriptorSetLayout dev = do
  let bindings = $(descriptorSetLayoutBindings (\b -> if b == 4 then pure (VarE (mkName "vkVertexFragmentBits")) else pure (VarE (mkName "vkFragmentBit"))) Nothing ''CloudFragmentDefs)
      createInfo = Vk26.DescriptorSetLayoutCreateInfo () zero (Vector.fromList bindings)
  liftIO $ Vk26.createDescriptorSetLayout dev createInfo Nothing

managedGodRayDescriptorSetLayout :: (MonadManaged m) => Vk26.Device -> m Vk26.DescriptorSetLayout
managedGodRayDescriptorSetLayout dev =
  alloc
    "GodRayDescriptorSetLayout"
    (createGodRayDescriptorSetLayout dev)
    (\ptr -> Vk26.destroyDescriptorSetLayout dev ptr Nothing)

createGodRayDescriptorSetLayout :: (MonadIO m) => Vk26.Device -> m Vk26.DescriptorSetLayout
createGodRayDescriptorSetLayout dev = do
  let bindings = $(descriptorSetLayoutBindings (\_ -> pure (VarE (mkName "vkFragmentBit"))) Nothing ''GodRayFragmentDefs)
      createInfo = Vk26.DescriptorSetLayoutCreateInfo () zero (Vector.fromList bindings)
  liftIO $ Vk26.createDescriptorSetLayout dev createInfo Nothing

managedTerrainDescriptorSetLayout :: (MonadManaged m) => Vk26.Device -> m Vk26.DescriptorSetLayout
managedTerrainDescriptorSetLayout dev =
  alloc
    "TerrainDescriptorSetLayout"
    (createTerrainDescriptorSetLayout dev)
    (\ptr -> Vk26.destroyDescriptorSetLayout dev ptr Nothing)

createTerrainDescriptorSetLayout :: (MonadIO m) => Vk26.Device -> m Vk26.DescriptorSetLayout
createTerrainDescriptorSetLayout dev = do
  let bindings = $(descriptorSetLayoutBindings (\b -> if b == 2 then pure (VarE (mkName "vkVertexFragmentBits")) else pure (VarE (mkName "vkFragmentBit"))) Nothing ''TerrainFragmentDefs)
      createInfo = Vk26.DescriptorSetLayoutCreateInfo () zero (Vector.fromList bindings)
  liftIO $ Vk26.createDescriptorSetLayout dev createInfo Nothing

-- | Mesh terrain descriptor set layout:
-- binding 0 = node SSBO (mesh stage)
-- binding 1 = heightmap texture array (mesh stage)
-- binding 2 = climate texture array (fragment stage)
managedTerrainMeshDescriptorSetLayout :: (MonadManaged m) => Vk26.Device -> m Vk26.DescriptorSetLayout
managedTerrainMeshDescriptorSetLayout dev =
  alloc
    "TerrainMeshDescriptorSetLayout"
    (createTerrainMeshDescriptorSetLayout dev)
    (\ptr -> Vk26.destroyDescriptorSetLayout dev ptr Nothing)

createTerrainMeshDescriptorSetLayout :: (MonadIO m) => Vk26.Device -> m Vk26.DescriptorSetLayout
createTerrainMeshDescriptorSetLayout dev = do
  let nodeBinding =
        Vk26.DescriptorSetLayoutBinding
          0
          Vk26.DESCRIPTOR_TYPE_STORAGE_BUFFER
          1
          vkMeshBit
          Vector.empty
      heightmapBinding =
        Vk26.DescriptorSetLayoutBinding
          1
          Vk26.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
          1
          vkMeshBit
          Vector.empty
      climateBinding =
        Vk26.DescriptorSetLayoutBinding
          2
          Vk26.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
          1
          Vk26.SHADER_STAGE_FRAGMENT_BIT
          Vector.empty
      createInfo =
        Vk26.DescriptorSetLayoutCreateInfo
          ()
          zero
          (Vector.fromList [nodeBinding, heightmapBinding, climateBinding])
  liftIO $ Vk26.createDescriptorSetLayout dev createInfo Nothing

-- | Bindless descriptor set layout: one array of textures with
-- UPDATE_AFTER_BIND + PARTIALLY_BOUND.
managedBindlessDescriptorSetLayout :: (MonadManaged m) => Vk26.Device -> m Vk26.DescriptorSetLayout
managedBindlessDescriptorSetLayout dev =
  alloc
    "BindlessDescriptorSetLayout"
    (createBindlessDescriptorSetLayout dev)
    (\ptr -> Vk26.destroyDescriptorSetLayout dev ptr Nothing)

createBindlessDescriptorSetLayout :: (MonadIO m) => Vk26.Device -> m Vk26.DescriptorSetLayout
createBindlessDescriptorSetLayout dev = do
  let textureBinding =
        Vk26.DescriptorSetLayoutBinding
          0
          Vk26.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
          (fromIntegral maxBindlessTextures)
          Vk26.SHADER_STAGE_FRAGMENT_BIT
          Vector.empty
      bindingFlags =
        V12.DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT
          .|. V12.DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT
      bindingFlagsCreateInfo =
        Vk26.DescriptorSetLayoutBindingFlagsCreateInfo
          (Vector.fromList [bindingFlags])
      createInfo ::
        Vk26.DescriptorSetLayoutCreateInfo
          '[Vk26.DescriptorSetLayoutBindingFlagsCreateInfo]
      createInfo =
        Vk26.DescriptorSetLayoutCreateInfo
          (bindingFlagsCreateInfo, ())
          V10.DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT
          (Vector.fromList [textureBinding])
  liftIO $ Vk26.createDescriptorSetLayout dev createInfo Nothing

-- | Bindless pass descriptor set layout: UBO (binding 0) + Texture2DArray (binding 1).
-- Used by the Texture2DArray bindless g-buffer pass.
managedBindlessPassDescriptorSetLayout :: (MonadManaged m) => Vk26.Device -> m Vk26.DescriptorSetLayout
managedBindlessPassDescriptorSetLayout dev =
  alloc
    "BindlessPassDescriptorSetLayout"
    (createBindlessPassDescriptorSetLayout dev)
    (\ptr -> Vk26.destroyDescriptorSetLayout dev ptr Nothing)

createBindlessPassDescriptorSetLayout :: (MonadIO m) => Vk26.Device -> m Vk26.DescriptorSetLayout
createBindlessPassDescriptorSetLayout dev = do
  let uboBinding =
        Vk26.DescriptorSetLayoutBinding
          0
          Vk26.DESCRIPTOR_TYPE_UNIFORM_BUFFER
          1
          Vk26.SHADER_STAGE_VERTEX_BIT
          Vector.empty
      textureBinding =
        Vk26.DescriptorSetLayoutBinding
          1
          Vk26.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
          1
          Vk26.SHADER_STAGE_FRAGMENT_BIT
          Vector.empty
      createInfo =
        Vk26.DescriptorSetLayoutCreateInfo
          ()
          zero
          (Vector.fromList [uboBinding, textureBinding])
  liftIO $ Vk26.createDescriptorSetLayout dev createInfo Nothing

-- | Compute culling descriptor set layout: 2 SSBOs + 1 UBO.
managedComputeDescriptorSetLayout :: (MonadManaged m) => Vk26.Device -> m Vk26.DescriptorSetLayout
managedComputeDescriptorSetLayout dev =
  alloc
    "ComputeDescriptorSetLayout"
    (createComputeDescriptorSetLayout dev)
    (\ptr -> Vk26.destroyDescriptorSetLayout dev ptr Nothing)

createComputeDescriptorSetLayout :: (MonadIO m) => Vk26.Device -> m Vk26.DescriptorSetLayout
createComputeDescriptorSetLayout dev = do
  let bindings = $(descriptorSetLayoutBindings (\_b -> pure (VarE (mkName "vkComputeBit"))) Nothing ''Cull.Defs)
      createInfo = Vk26.DescriptorSetLayoutCreateInfo () zero (Vector.fromList bindings)
  liftIO $ Vk26.createDescriptorSetLayout dev createInfo Nothing

-- | Cubemap compute descriptor set layout: StorageImage (cubemap) + Uniform (genData).
-- Shared between radiance and irradiance compute shaders.
managedCubemapComputeDescriptorSetLayout :: (MonadManaged m) => Vk26.Device -> m Vk26.DescriptorSetLayout
managedCubemapComputeDescriptorSetLayout dev =
  alloc
    "CubemapComputeDescriptorSetLayout"
    (createCubemapComputeDescriptorSetLayout dev)
    (\ptr -> Vk26.destroyDescriptorSetLayout dev ptr Nothing)

createCubemapComputeDescriptorSetLayout :: (MonadIO m) => Vk26.Device -> m Vk26.DescriptorSetLayout
createCubemapComputeDescriptorSetLayout dev = do
  let bindings = $(descriptorSetLayoutBindings (\_b -> pure (VarE (mkName "vkComputeBit"))) Nothing ''RadianceGen.Defs)
      createInfo = Vk26.DescriptorSetLayoutCreateInfo () zero (Vector.fromList bindings)
  liftIO $ Vk26.createDescriptorSetLayout dev createInfo Nothing

managedCloudNoiseComputeDescriptorSetLayout :: (MonadManaged m, MonadIO m) => Vk26.Device -> m Vk26.DescriptorSetLayout
managedCloudNoiseComputeDescriptorSetLayout dev =
  alloc
    "CloudNoiseComputeDescriptorSetLayout"
    (createCloudNoiseComputeDescriptorSetLayout dev)
    (\ptr -> Vk26.destroyDescriptorSetLayout dev ptr Nothing)

createCloudNoiseComputeDescriptorSetLayout :: (MonadIO m) => Vk26.Device -> m Vk26.DescriptorSetLayout
createCloudNoiseComputeDescriptorSetLayout dev = do
  let bindings = $(descriptorSetLayoutBindings (\_b -> pure (VarE (mkName "vkComputeBit"))) Nothing ''CloudNoiseGen.Defs)
      createInfo = Vk26.DescriptorSetLayoutCreateInfo () zero (Vector.fromList bindings)
  liftIO $ Vk26.createDescriptorSetLayout dev createInfo Nothing

managedCloudDetailNoiseComputeDescriptorSetLayout :: (MonadManaged m, MonadIO m) => Vk26.Device -> m Vk26.DescriptorSetLayout
managedCloudDetailNoiseComputeDescriptorSetLayout dev =
  alloc
    "CloudDetailNoiseComputeDescriptorSetLayout"
    (createCloudDetailNoiseComputeDescriptorSetLayout dev)
    (\ptr -> Vk26.destroyDescriptorSetLayout dev ptr Nothing)

createCloudDetailNoiseComputeDescriptorSetLayout :: (MonadIO m) => Vk26.Device -> m Vk26.DescriptorSetLayout
createCloudDetailNoiseComputeDescriptorSetLayout dev = do
  let bindings = $(descriptorSetLayoutBindings (\_b -> pure (VarE (mkName "vkComputeBit"))) Nothing ''CloudDetailNoiseGen.Defs)
      createInfo = Vk26.DescriptorSetLayoutCreateInfo () zero (Vector.fromList bindings)
  liftIO $ Vk26.createDescriptorSetLayout dev createInfo Nothing

managedCloudNoiseMipGenComputeDescriptorSetLayout :: (MonadManaged m, MonadIO m) => Vk26.Device -> m Vk26.DescriptorSetLayout
managedCloudNoiseMipGenComputeDescriptorSetLayout dev =
  alloc
    "CloudNoiseMipGenComputeDescriptorSetLayout"
    (createCloudNoiseMipGenComputeDescriptorSetLayout dev)
    (\ptr -> Vk26.destroyDescriptorSetLayout dev ptr Nothing)

createCloudNoiseMipGenComputeDescriptorSetLayout :: (MonadIO m) => Vk26.Device -> m Vk26.DescriptorSetLayout
createCloudNoiseMipGenComputeDescriptorSetLayout dev = do
  let bindings = $(descriptorSetLayoutBindings (\_b -> pure (VarE (mkName "vkComputeBit"))) Nothing ''CloudNoiseMipGen.Defs)
      createInfo = Vk26.DescriptorSetLayoutCreateInfo () zero (Vector.fromList bindings)
  liftIO $ Vk26.createDescriptorSetLayout dev createInfo Nothing

managedWeatherMapComputeDescriptorSetLayout :: (MonadManaged m, MonadIO m) => Vk26.Device -> m Vk26.DescriptorSetLayout
managedWeatherMapComputeDescriptorSetLayout dev =
  alloc
    "WeatherMapComputeDescriptorSetLayout"
    (createWeatherMapComputeDescriptorSetLayout dev)
    (\ptr -> Vk26.destroyDescriptorSetLayout dev ptr Nothing)

createWeatherMapComputeDescriptorSetLayout :: (MonadIO m) => Vk26.Device -> m Vk26.DescriptorSetLayout
createWeatherMapComputeDescriptorSetLayout dev = do
  let bindings = $(descriptorSetLayoutBindings (\_b -> pure (VarE (mkName "vkComputeBit"))) Nothing ''WeatherMapGen.Defs)
      createInfo = Vk26.DescriptorSetLayoutCreateInfo () zero (Vector.fromList bindings)
  liftIO $ Vk26.createDescriptorSetLayout dev createInfo Nothing

-- | AP volume compute descriptor set layout: StorageImage (3D) + Texture3D + Uniform.
managedAPVolumeComputeDescriptorSetLayout :: (MonadManaged m, MonadIO m) => Vk26.Device -> m Vk26.DescriptorSetLayout
managedAPVolumeComputeDescriptorSetLayout dev =
  alloc
    "APVolumeComputeDescriptorSetLayout"
    (createAPVolumeComputeDescriptorSetLayout dev)
    (\ptr -> Vk26.destroyDescriptorSetLayout dev ptr Nothing)

createAPVolumeComputeDescriptorSetLayout :: (MonadIO m) => Vk26.Device -> m Vk26.DescriptorSetLayout
createAPVolumeComputeDescriptorSetLayout dev = do
  let bindings = $(descriptorSetLayoutBindings (\_b -> pure (VarE (mkName "vkComputeBit"))) Nothing ''APVolume.Defs)
      createInfo = Vk26.DescriptorSetLayoutCreateInfo () zero (Vector.fromList bindings)
  liftIO $ Vk26.createDescriptorSetLayout dev createInfo Nothing
