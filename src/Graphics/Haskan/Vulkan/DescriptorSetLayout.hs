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
import Data.Word (Word32)
import Foreign (castPtr)
import Graphics.Haskan.Resources (alloc, allocaAndPeek)
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
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Core_1_2 qualified as Vulkan12
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, setListRef, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan
import Language.Haskell.TH (Exp (VarE), mkName)
import Data.Vector qualified as Vector
import Vulkan qualified as Vk26
import Vulkan.CStruct.Extends (SomeStruct (..))
import Vulkan.Core12.Enums.DescriptorBindingFlagBits qualified as V12
import Vulkan.Core10.Enums.DescriptorSetLayoutCreateFlagBits qualified as V10

maxBindlessTextures :: Int
maxBindlessTextures = 1024

-- | Helper to construct a single VkDescriptorSetLayoutBinding.
layoutBinding :: Int -> Int -> Vulkan.VkDescriptorType -> Vulkan.VkShaderStageFlags -> Vulkan.VkDescriptorSetLayoutBinding
layoutBinding binding count descriptorType stageFlags =
  Vulkan.createVk
    ( set @"binding" (fromIntegral binding)
        &* set @"descriptorType" descriptorType
        &* set @"descriptorCount" (fromIntegral count)
        &* set @"stageFlags" stageFlags
        &* set @"pImmutableSamplers" Vulkan.VK_NULL
    )

-- Descriptor type helpers (avoid pattern synonym issues in TH splices).
vkCombinedImageSampler :: Vulkan.VkDescriptorType
vkCombinedImageSampler = Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER

vkUniformBuffer :: Vulkan.VkDescriptorType
vkUniformBuffer = Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER

vkStorageBuffer :: Vulkan.VkDescriptorType
vkStorageBuffer = Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER

vkStorageImage :: Vulkan.VkDescriptorType
vkStorageImage = Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE

-- Stage flag helpers (avoid pattern synonym issues in TH splices).
vkFragmentBit :: Vulkan.VkShaderStageFlags
vkFragmentBit = Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT

vkVertexFragmentBits :: Vulkan.VkShaderStageFlags
vkVertexFragmentBits = Vulkan.VK_SHADER_STAGE_VERTEX_BIT .|. Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT

vkMeshBit :: Vulkan.VkShaderStageFlags
vkMeshBit = Data.Coerce.coerce (0x00000080 :: Word32)  -- VK_SHADER_STAGE_MESH_BIT_EXT

vkComputeBit :: Vulkan.VkShaderStageFlags
vkComputeBit = Vulkan.VK_SHADER_STAGE_COMPUTE_BIT

managedDescriptorSetLayout :: (MonadManaged m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
managedDescriptorSetLayout dev =
  alloc
    "DescriptorSetLayout"
    (createDescriptorSetLayout dev)
    (\ptr -> Vulkan.vkDestroyDescriptorSetLayout dev ptr Vulkan.vkNullPtr)

createDescriptorSetLayout :: (MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
createDescriptorSetLayout dev = do
  let viewProjBinding =
        Vulkan.createVk
          ( set @"binding" 0
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
              &* set @"descriptorCount" 1
              &* set @"stageFlags" Vulkan.VK_SHADER_STAGE_VERTEX_BIT
              &* set @"pImmutableSamplers" Vulkan.VK_NULL
          )
      textureBinding =
        Vulkan.createVk
          ( set @"binding" 1
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"descriptorCount" (fromIntegral maxBindlessTextures)
              &* set @"stageFlags" Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT
              &* set @"pImmutableSamplers" Vulkan.VK_NULL
          )
      entityBinding =
        Vulkan.createVk
          ( set @"binding" 2
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
              &* set @"descriptorCount" 1
              &* set @"stageFlags" (Vulkan.VK_SHADER_STAGE_VERTEX_BIT .|. Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT)
              &* set @"pImmutableSamplers" Vulkan.VK_NULL
          )
      -- Binding flags for binding 1: partially bound (allows unused descriptors in array)
      bindingFlags :: Vulkan12.VkDescriptorBindingFlags
      bindingFlags = Vulkan12.VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT
      bindingFlagsCreateInfo :: Vulkan12.VkDescriptorSetLayoutBindingFlagsCreateInfo
      bindingFlagsCreateInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan12.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"bindingCount" 3
              &* setListRef @"pBindingFlags" [Vulkan.VK_ZERO_FLAGS, bindingFlags, Vulkan.VK_ZERO_FLAGS] -- binding 0: no flags, binding 1: partially bound, binding 2: no flags
          )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
              &* set @"pNext" (castPtr $ Vulkan.unsafePtr bindingFlagsCreateInfo)
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"bindingCount" 3
              &* setListRef @"pBindings" [viewProjBinding, textureBinding, entityBinding]
          )
   in liftIO $ withPtr bindingFlagsCreateInfo $ \_bfcPtr ->
        withPtr createInfo $ \ciPtr ->
          allocaAndPeek (Vulkan.vkCreateDescriptorSetLayout dev ciPtr Vulkan.vkNullPtr)

managedLightingDescriptorSetLayout :: (MonadManaged m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
managedLightingDescriptorSetLayout dev =
  alloc
    "LightingDescriptorSetLayout"
    (createLightingDescriptorSetLayout dev)
    (\ptr -> Vulkan.vkDestroyDescriptorSetLayout dev ptr Vulkan.vkNullPtr)

createLightingDescriptorSetLayout :: (MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
createLightingDescriptorSetLayout dev = do
  let bindings = $(descriptorSetLayoutBindings (\_b -> pure (VarE (mkName "vkFragmentBit"))) Nothing ''Lighting.FragmentDefs)
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"bindingCount" (fromIntegral (length bindings))
              &* setListRef @"pBindings" bindings
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorSetLayout dev ciPtr Vulkan.vkNullPtr)
          )

managedLightingProceduralDescriptorSetLayout :: (MonadManaged m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
managedLightingProceduralDescriptorSetLayout dev =
  alloc
    "LightingProceduralDescriptorSetLayout"
    (createLightingProceduralDescriptorSetLayout dev)
    (\ptr -> Vulkan.vkDestroyDescriptorSetLayout dev ptr Vulkan.vkNullPtr)

createLightingProceduralDescriptorSetLayout :: (MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
createLightingProceduralDescriptorSetLayout dev = do
  let bindings = $(descriptorSetLayoutBindings (\_b -> pure (VarE (mkName "vkFragmentBit"))) Nothing ''LightingProcedural.FragmentDefs)
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"bindingCount" (fromIntegral (length bindings))
              &* setListRef @"pBindings" bindings
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorSetLayout dev ciPtr Vulkan.vkNullPtr)
          )

-- | Cloud descriptor set layout: env cubemap + 3D noise texture
managedCloudDescriptorSetLayout :: (MonadManaged m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
managedCloudDescriptorSetLayout dev =
  alloc
    "CloudDescriptorSetLayout"
    (createCloudDescriptorSetLayout dev)
    (\ptr -> Vulkan.vkDestroyDescriptorSetLayout dev ptr Vulkan.vkNullPtr)

createCloudDescriptorSetLayout :: (MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
createCloudDescriptorSetLayout dev = do
  let bindings = $(descriptorSetLayoutBindings (\b -> if b == 4 then pure (VarE (mkName "vkVertexFragmentBits")) else pure (VarE (mkName "vkFragmentBit"))) Nothing ''CloudFragmentDefs)
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"bindingCount" (fromIntegral (length bindings))
              &* setListRef @"pBindings" bindings
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorSetLayout dev ciPtr Vulkan.vkNullPtr)
          )

managedGodRayDescriptorSetLayout :: (MonadManaged m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
managedGodRayDescriptorSetLayout dev =
  alloc
    "GodRayDescriptorSetLayout"
    (createGodRayDescriptorSetLayout dev)
    (\ptr -> Vulkan.vkDestroyDescriptorSetLayout dev ptr Vulkan.vkNullPtr)

createGodRayDescriptorSetLayout :: (MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
createGodRayDescriptorSetLayout dev = do
  let bindings = $(descriptorSetLayoutBindings (\_ -> pure (VarE (mkName "vkFragmentBit"))) Nothing ''GodRayFragmentDefs)
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"bindingCount" (fromIntegral (length bindings))
              &* setListRef @"pBindings" bindings
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorSetLayout dev ciPtr Vulkan.vkNullPtr)
          )

managedTerrainDescriptorSetLayout :: (MonadManaged m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
managedTerrainDescriptorSetLayout dev =
  alloc
    "TerrainDescriptorSetLayout"
    (createTerrainDescriptorSetLayout dev)
    (\ptr -> Vulkan.vkDestroyDescriptorSetLayout dev ptr Vulkan.vkNullPtr)

createTerrainDescriptorSetLayout :: (MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
createTerrainDescriptorSetLayout dev = do
  let bindings = $(descriptorSetLayoutBindings (\b -> if b == 2 then pure (VarE (mkName "vkVertexFragmentBits")) else pure (VarE (mkName "vkFragmentBit"))) Nothing ''TerrainFragmentDefs)
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"bindingCount" (fromIntegral (length bindings))
              &* setListRef @"pBindings" bindings
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
           allocaAndPeek (Vulkan.vkCreateDescriptorSetLayout dev ciPtr Vulkan.vkNullPtr)
           )

-- | Mesh terrain descriptor set layout:
-- binding 0 = node SSBO (mesh stage)
-- binding 1 = heightmap texture array (mesh stage)
-- binding 2 = climate texture array (fragment stage)
managedTerrainMeshDescriptorSetLayout :: (MonadManaged m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
managedTerrainMeshDescriptorSetLayout dev =
  alloc
    "TerrainMeshDescriptorSetLayout"
    (createTerrainMeshDescriptorSetLayout dev)
    (\ptr -> Vulkan.vkDestroyDescriptorSetLayout dev ptr Vulkan.vkNullPtr)

createTerrainMeshDescriptorSetLayout :: (MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
createTerrainMeshDescriptorSetLayout dev = do
  let nodeBinding =
        Vulkan.createVk
          ( set @"binding" 0
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
              &* set @"descriptorCount" 1
              &* set @"stageFlags" vkMeshBit
              &* set @"pImmutableSamplers" Vulkan.VK_NULL
          )
      heightmapBinding =
        Vulkan.createVk
          ( set @"binding" 1
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"descriptorCount" 1
              &* set @"stageFlags" vkMeshBit
              &* set @"pImmutableSamplers" Vulkan.VK_NULL
          )
      climateBinding =
        Vulkan.createVk
          ( set @"binding" 2
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"descriptorCount" 1
              &* set @"stageFlags" Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT
              &* set @"pImmutableSamplers" Vulkan.VK_NULL
          )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"bindingCount" 3
              &* setListRef @"pBindings" [nodeBinding, heightmapBinding, climateBinding]
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorSetLayout dev ciPtr Vulkan.vkNullPtr)
          )

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
managedBindlessPassDescriptorSetLayout :: (MonadManaged m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
managedBindlessPassDescriptorSetLayout dev =
  alloc
    "BindlessPassDescriptorSetLayout"
    (createBindlessPassDescriptorSetLayout dev)
    (\ptr -> Vulkan.vkDestroyDescriptorSetLayout dev ptr Vulkan.vkNullPtr)

createBindlessPassDescriptorSetLayout :: (MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
createBindlessPassDescriptorSetLayout dev = do
  let uboBinding =
        Vulkan.createVk
          ( set @"binding" 0
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
              &* set @"descriptorCount" 1
              &* set @"stageFlags" Vulkan.VK_SHADER_STAGE_VERTEX_BIT
              &* set @"pImmutableSamplers" Vulkan.VK_NULL
          )
      textureBinding =
        Vulkan.createVk
          ( set @"binding" 1
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"descriptorCount" 1
              &* set @"stageFlags" Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT
              &* set @"pImmutableSamplers" Vulkan.VK_NULL
          )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"bindingCount" 2
              &* setListRef @"pBindings" [uboBinding, textureBinding]
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorSetLayout dev ciPtr Vulkan.vkNullPtr)
          )

-- | Compute culling descriptor set layout: 2 SSBOs + 1 UBO.
managedComputeDescriptorSetLayout :: (MonadManaged m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
managedComputeDescriptorSetLayout dev =
  alloc
    "ComputeDescriptorSetLayout"
    (createComputeDescriptorSetLayout dev)
    (\ptr -> Vulkan.vkDestroyDescriptorSetLayout dev ptr Vulkan.vkNullPtr)

createComputeDescriptorSetLayout :: (MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
createComputeDescriptorSetLayout dev = do
  let bindings = $(descriptorSetLayoutBindings (\_b -> pure (VarE (mkName "vkComputeBit"))) Nothing ''Cull.Defs)
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"bindingCount" (fromIntegral (length bindings))
              &* setListRef @"pBindings" bindings
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorSetLayout dev ciPtr Vulkan.vkNullPtr)
          )

-- | Cubemap compute descriptor set layout: StorageImage (cubemap) + Uniform (genData).
-- Shared between radiance and irradiance compute shaders.
managedCubemapComputeDescriptorSetLayout :: (MonadManaged m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
managedCubemapComputeDescriptorSetLayout dev =
  alloc
    "CubemapComputeDescriptorSetLayout"
    (createCubemapComputeDescriptorSetLayout dev)
    (\ptr -> Vulkan.vkDestroyDescriptorSetLayout dev ptr Vulkan.vkNullPtr)

createCubemapComputeDescriptorSetLayout :: (MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
createCubemapComputeDescriptorSetLayout dev = do
  let bindings = $(descriptorSetLayoutBindings (\_b -> pure (VarE (mkName "vkComputeBit"))) Nothing ''RadianceGen.Defs)
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"bindingCount" (fromIntegral (length bindings))
              &* setListRef @"pBindings" bindings
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorSetLayout dev ciPtr Vulkan.vkNullPtr)
          )

managedCloudNoiseComputeDescriptorSetLayout :: (MonadManaged m, MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
managedCloudNoiseComputeDescriptorSetLayout dev =
  alloc
    "CloudNoiseComputeDescriptorSetLayout"
    (createCloudNoiseComputeDescriptorSetLayout dev)
    (\ptr -> Vulkan.vkDestroyDescriptorSetLayout dev ptr Vulkan.vkNullPtr)

createCloudNoiseComputeDescriptorSetLayout :: (MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
createCloudNoiseComputeDescriptorSetLayout dev = do
  let bindings = $(descriptorSetLayoutBindings (\_b -> pure (VarE (mkName "vkComputeBit"))) Nothing ''CloudNoiseGen.Defs)
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"bindingCount" (fromIntegral (length bindings))
              &* setListRef @"pBindings" bindings
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorSetLayout dev ciPtr Vulkan.vkNullPtr)
          )

managedCloudDetailNoiseComputeDescriptorSetLayout :: (MonadManaged m, MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
managedCloudDetailNoiseComputeDescriptorSetLayout dev =
  alloc
    "CloudDetailNoiseComputeDescriptorSetLayout"
    (createCloudDetailNoiseComputeDescriptorSetLayout dev)
    (\ptr -> Vulkan.vkDestroyDescriptorSetLayout dev ptr Vulkan.vkNullPtr)

createCloudDetailNoiseComputeDescriptorSetLayout :: (MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
createCloudDetailNoiseComputeDescriptorSetLayout dev = do
  let bindings = $(descriptorSetLayoutBindings (\_b -> pure (VarE (mkName "vkComputeBit"))) Nothing ''CloudDetailNoiseGen.Defs)
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"bindingCount" (fromIntegral (length bindings))
              &* setListRef @"pBindings" bindings
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorSetLayout dev ciPtr Vulkan.vkNullPtr)
          )

managedCloudNoiseMipGenComputeDescriptorSetLayout :: (MonadManaged m, MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
managedCloudNoiseMipGenComputeDescriptorSetLayout dev =
  alloc
    "CloudNoiseMipGenComputeDescriptorSetLayout"
    (createCloudNoiseMipGenComputeDescriptorSetLayout dev)
    (\ptr -> Vulkan.vkDestroyDescriptorSetLayout dev ptr Vulkan.vkNullPtr)

createCloudNoiseMipGenComputeDescriptorSetLayout :: (MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
createCloudNoiseMipGenComputeDescriptorSetLayout dev = do
  let bindings = $(descriptorSetLayoutBindings (\_b -> pure (VarE (mkName "vkComputeBit"))) Nothing ''CloudNoiseMipGen.Defs)
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"bindingCount" (fromIntegral (length bindings))
              &* setListRef @"pBindings" bindings
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorSetLayout dev ciPtr Vulkan.vkNullPtr)
          )

managedWeatherMapComputeDescriptorSetLayout :: (MonadManaged m, MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
managedWeatherMapComputeDescriptorSetLayout dev =
  alloc
    "WeatherMapComputeDescriptorSetLayout"
    (createWeatherMapComputeDescriptorSetLayout dev)
    (\ptr -> Vulkan.vkDestroyDescriptorSetLayout dev ptr Vulkan.vkNullPtr)

createWeatherMapComputeDescriptorSetLayout :: (MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
createWeatherMapComputeDescriptorSetLayout dev = do
  let bindings = $(descriptorSetLayoutBindings (\_b -> pure (VarE (mkName "vkComputeBit"))) Nothing ''WeatherMapGen.Defs)
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"bindingCount" (fromIntegral (length bindings))
              &* setListRef @"pBindings" bindings
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorSetLayout dev ciPtr Vulkan.vkNullPtr)
          )

-- | AP volume compute descriptor set layout: StorageImage (3D) + Texture3D + Uniform.
managedAPVolumeComputeDescriptorSetLayout :: (MonadManaged m, MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
managedAPVolumeComputeDescriptorSetLayout dev =
  alloc
    "APVolumeComputeDescriptorSetLayout"
    (createAPVolumeComputeDescriptorSetLayout dev)
    (\ptr -> Vulkan.vkDestroyDescriptorSetLayout dev ptr Vulkan.vkNullPtr)

createAPVolumeComputeDescriptorSetLayout :: (MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
createAPVolumeComputeDescriptorSetLayout dev = do
  let bindings = $(descriptorSetLayoutBindings (\_b -> pure (VarE (mkName "vkComputeBit"))) Nothing ''APVolume.Defs)
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"bindingCount" (fromIntegral (length bindings))
              &* setListRef @"pBindings" bindings
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorSetLayout dev ciPtr Vulkan.vkNullPtr)
          )
