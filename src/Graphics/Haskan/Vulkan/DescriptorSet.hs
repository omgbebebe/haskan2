{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Vulkan.DescriptorSet where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Foreign.Marshal.Array qualified
import Graphics.Haskan.Resources (alloc, alloc_, allocaAndPeek, allocaAndPeek_, peekVkList, peekVkList_, throwVkResult)
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Ext qualified as Vulkan
import Graphics.Vulkan.Ext.VK_KHR_surface qualified as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, setListRef, setStrListRef, setVkRef, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan

-- | Configuration for updating lighting descriptor sets.
data LightingDescriptorUpdate = LightingDescriptorUpdate
  { lduDevice :: !Vulkan.VkDevice,
    lduDescriptorSet :: !Vulkan.VkDescriptorSet,
    lduSampler :: !Vulkan.VkSampler,
    lduImageViews :: ![Vulkan.VkImageView],
    lduLightBuffer :: !(Maybe Vulkan.VkBuffer),
    lduCloudResultView :: !(Maybe Vulkan.VkImageView),
    lduAPVolumeView :: !(Maybe Vulkan.VkImageView)
  }

-- | Configuration for updating procedural sky lighting descriptor sets.
data LightingProceduralDescriptorUpdate = LightingProceduralDescriptorUpdate
  { lpduDevice :: !Vulkan.VkDevice,
    lpduDescriptorSet :: !Vulkan.VkDescriptorSet,
    lpduSampler :: !Vulkan.VkSampler,
    lpduImageViews :: ![Vulkan.VkImageView],
    lpduLightBuffer :: !(Maybe Vulkan.VkBuffer),
    lpduCloudResultView :: !(Maybe Vulkan.VkImageView),
    lpduGodRayView :: !(Maybe Vulkan.VkImageView),
    lpduAPVolumeView :: !(Maybe Vulkan.VkImageView)
  }

-- | Configuration for updating cloud descriptor sets.
data CloudDescriptorUpdate = CloudDescriptorUpdate
  { clduDevice :: !Vulkan.VkDevice,
    clduDescriptorSet :: !Vulkan.VkDescriptorSet,
    clduSampler :: !Vulkan.VkSampler,
    clduNoiseSampler :: !Vulkan.VkSampler,
    clduEnvMapView :: !(Maybe Vulkan.VkImageView),
    clduCloudNoiseView :: !(Maybe Vulkan.VkImageView),
    clduCloudHistoryView :: !(Maybe Vulkan.VkImageView),
    clduBlueNoiseView :: !(Maybe Vulkan.VkImageView),
    clduWeatherMapView :: !(Maybe Vulkan.VkImageView),
    clduBlueNoiseSampler :: !Vulkan.VkSampler
  }

-- | Configuration for updating god ray descriptor sets.
data GodRayDescriptorUpdate = GodRayDescriptorUpdate
  { grduDevice :: !Vulkan.VkDevice,
    grduDescriptorSet :: !Vulkan.VkDescriptorSet,
    grduSampler :: !Vulkan.VkSampler,
    grduCloudResultView :: !Vulkan.VkImageView
  }

-- | Configuration for updating terrain overlay descriptor sets.
data TerrainDescriptorUpdate = TerrainDescriptorUpdate
  { tduDevice :: !Vulkan.VkDevice,
    tduDescriptorSet :: !Vulkan.VkDescriptorSet,
    tduSampler :: !Vulkan.VkSampler,
    tduElevationView :: !(Maybe Vulkan.VkImageView),
    tduClimateView :: !(Maybe Vulkan.VkImageView)
  }

-- | Configuration for updating terrain mesh descriptor sets.
data TerrainMeshDescriptorUpdate = TerrainMeshDescriptorUpdate
  { tmduDevice :: !Vulkan.VkDevice,
    tmduDescriptorSet :: !Vulkan.VkDescriptorSet,
    tmduNodeBuffer :: !Vulkan.VkBuffer,
    tmduSampler :: !Vulkan.VkSampler,
    tmduElevationView :: !(Maybe Vulkan.VkImageView),
    tmduClimateView :: !(Maybe Vulkan.VkImageView)
  }

-- | Configuration for updating AP volume descriptor sets.
data APVolumeDescriptorUpdate = APVolumeDescriptorUpdate
  { apduDevice :: !Vulkan.VkDevice,
    apduDescriptorSet :: !Vulkan.VkDescriptorSet,
    apduAPImageView :: !Vulkan.VkImageView,
    apduCloudNoiseView :: !(Maybe Vulkan.VkImageView),
    apduCloudNoiseSampler :: !Vulkan.VkSampler,
    apduWeatherMapView :: !(Maybe Vulkan.VkImageView),
    apduWeatherMapSampler :: !Vulkan.VkSampler,
    apduUniformBuffer :: !Vulkan.VkBuffer
  }

-- | Configuration for updating compute cull descriptor sets.
data ComputeDescriptorUpdate = ComputeDescriptorUpdate
  { cpduDevice :: !Vulkan.VkDevice,
    cpduDescriptorSet :: !Vulkan.VkDescriptorSet,
    cpduEntitiesBuffer :: !Vulkan.VkBuffer,
    cpduDrawCommandsBuffer :: !Vulkan.VkBuffer,
    cpduCullDataBuffer :: !Vulkan.VkBuffer
  }

-- | Configuration for updating bindless descriptor sets.
data BindlessDescriptorUpdate = BindlessDescriptorUpdate
  { bduDevice :: !Vulkan.VkDevice,
    bduDescriptorSet :: !Vulkan.VkDescriptorSet,
    bduBuffer :: !Vulkan.VkBuffer,
    bduRange :: !Vulkan.VkDeviceSize,
    bduSampler :: !Vulkan.VkSampler,
    bduImageViews :: ![Vulkan.VkImageView],
    bduEntityBuffer :: !Vulkan.VkBuffer
  }

allocateDescriptorSet ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkDescriptorPool ->
  [Vulkan.VkDescriptorSetLayout] ->
  m Vulkan.VkDescriptorSet
allocateDescriptorSet dev descriptorPool setLayouts = do
  let allocateInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"descriptorPool" descriptorPool
              &* set @"descriptorSetCount" (fromIntegral (length setLayouts))
              &* setListRef @"pSetLayouts" setLayouts
          )
   in liftIO $ withPtr allocateInfo (allocaAndPeek . Vulkan.vkAllocateDescriptorSets dev)

updateDescriptorSets ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkDescriptorSet ->
  Vulkan.VkBuffer ->
  Vulkan.VkImageView ->
  Vulkan.VkSampler ->
  m ()
updateDescriptorSets dev descriptorSet buffer textureImageView textureSampler = do
  let bufferInfo :: Vulkan.VkDescriptorBufferInfo
      bufferInfo =
        Vulkan.createVk
          ( set @"buffer" buffer
              &* set @"offset" 0
              &* set @"range" (Vulkan.VkDeviceSize Vulkan.VK_WHOLE_SIZE)
          )
      textureInfo =
        Vulkan.createVk
          ( set @"imageLayout" Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
              &* set @"imageView" textureImageView
              &* set @"sampler" textureSampler
          )
      writeUpdate :: Vulkan.VkWriteDescriptorSet
      writeUpdate =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" descriptorSet
              &* set @"dstBinding" 0
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* set @"pImageInfo" Vulkan.VK_NULL
              &* setVkRef @"pBufferInfo" bufferInfo
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
      writeUpdateTexture :: Vulkan.VkWriteDescriptorSet
      writeUpdateTexture =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" descriptorSet
              &* set @"dstBinding" 1
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* setListRef @"pImageInfo" [textureInfo]
              &* setVkRef @"pBufferInfo" bufferInfo
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
  liftIO $
    Foreign.Marshal.Array.withArray [writeUpdate, writeUpdateTexture] $ \writeUpdatePtr ->
      Vulkan.vkUpdateDescriptorSets dev 2 writeUpdatePtr 0 Vulkan.vkNullPtr

updateDescriptorSetsRange ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkDescriptorSet ->
  Vulkan.VkBuffer ->
  Vulkan.VkDeviceSize ->
  Vulkan.VkImageView ->
  Vulkan.VkSampler ->
  m ()
updateDescriptorSetsRange dev descriptorSet buffer range textureImageView textureSampler = do
  let bufferInfo :: Vulkan.VkDescriptorBufferInfo
      bufferInfo =
        Vulkan.createVk
          ( set @"buffer" buffer
              &* set @"offset" 0
              &* set @"range" range
          )
      textureInfo =
        Vulkan.createVk
          ( set @"imageLayout" Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
              &* set @"imageView" textureImageView
              &* set @"sampler" textureSampler
          )
      writeUpdate :: Vulkan.VkWriteDescriptorSet
      writeUpdate =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" descriptorSet
              &* set @"dstBinding" 0
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* set @"pImageInfo" Vulkan.VK_NULL
              &* setVkRef @"pBufferInfo" bufferInfo
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
      writeUpdateTexture :: Vulkan.VkWriteDescriptorSet
      writeUpdateTexture =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" descriptorSet
              &* set @"dstBinding" 1
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* setListRef @"pImageInfo" [textureInfo]
              &* setVkRef @"pBufferInfo" bufferInfo
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
  liftIO $
    Foreign.Marshal.Array.withArray [writeUpdate, writeUpdateTexture] $ \writeUpdatePtr ->
      Vulkan.vkUpdateDescriptorSets dev 2 writeUpdatePtr 0 Vulkan.vkNullPtr

updateLightingDescriptorSets ::
  (MonadIO m) =>
  LightingDescriptorUpdate ->
  m ()
updateLightingDescriptorSets LightingDescriptorUpdate {..} = do
  let mkTextureInfo imageView =
        Vulkan.createVk
          ( set @"imageLayout" Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
              &* set @"imageView" imageView
              &* set @"sampler" lduSampler
          )
      mkWrite bindingIdx imageView =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" lduDescriptorSet
              &* set @"dstBinding" bindingIdx
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* setListRef @"pImageInfo" [mkTextureInfo imageView]
              &* set @"pBufferInfo" Vulkan.VK_NULL
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
      writes = zipWith mkWrite [0 ..] lduImageViews
      lightWrite = case lduLightBuffer of
        Nothing -> []
        Just lightBuffer ->
          let bufferInfo =
                Vulkan.createVk
                  ( set @"buffer" lightBuffer
                      &* set @"offset" 0
                      &* set @"range" (Vulkan.VkDeviceSize Vulkan.VK_WHOLE_SIZE)
                  )
           in [ Vulkan.createVk
                  ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
                      &* set @"pNext" Vulkan.VK_NULL
                      &* set @"dstSet" lduDescriptorSet
                      &* set @"dstBinding" 7
                      &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
                      &* set @"pTexelBufferView" Vulkan.VK_NULL
                      &* set @"pImageInfo" Vulkan.VK_NULL
                      &* setVkRef @"pBufferInfo" bufferInfo
                      &* set @"descriptorCount" 1
                      &* set @"dstArrayElement" 0
                  )
              ]
      cloudResultWrite = case lduCloudResultView of
        Nothing -> []
        Just cloudResultView ->
          [mkWrite 8 cloudResultView]
      apVolumeWrite = case lduAPVolumeView of
        Nothing -> []
        Just apVolumeView ->
          let apVolumeInfo =
                Vulkan.createVk
                  ( set @"imageLayout" Vulkan.VK_IMAGE_LAYOUT_GENERAL
                      &* set @"imageView" apVolumeView
                      &* set @"sampler" lduSampler
                  )
              apVolumeWriteDescriptor =
                Vulkan.createVk
                  ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
                      &* set @"pNext" Vulkan.VK_NULL
                      &* set @"dstSet" lduDescriptorSet
                      &* set @"dstBinding" 9
                      &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
                      &* set @"pBufferInfo" Vulkan.VK_NULL
                      &* set @"pTexelBufferView" Vulkan.VK_NULL
                      &* setListRef @"pImageInfo" [apVolumeInfo]
                      &* set @"descriptorCount" 1
                      &* set @"dstArrayElement" 0
                  )
           in [apVolumeWriteDescriptor]
      allWrites = writes ++ lightWrite ++ cloudResultWrite ++ apVolumeWrite
  liftIO $
    Foreign.Marshal.Array.withArray allWrites $ \writeUpdatePtr ->
      Vulkan.vkUpdateDescriptorSets lduDevice (fromIntegral (length allWrites)) writeUpdatePtr 0 Vulkan.vkNullPtr

-- | Update lighting descriptor sets for procedural sky variant.
-- Expects 7 image views: gbuf_position, gbuf_normal, gbuf_albedo, gbuf_emissive,
-- env_map, irradiance_map, brdf_lut (bindings 0-6).
updateLightingProceduralDescriptorSets ::
  (MonadIO m) =>
  LightingProceduralDescriptorUpdate ->
  m ()
updateLightingProceduralDescriptorSets LightingProceduralDescriptorUpdate {..} = do
  let mkTextureInfo imageView =
        Vulkan.createVk
          ( set @"imageLayout" Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
              &* set @"imageView" imageView
              &* set @"sampler" lpduSampler
          )
      mkWrite bindingIdx imageView =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" lpduDescriptorSet
              &* set @"dstBinding" bindingIdx
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* setListRef @"pImageInfo" [mkTextureInfo imageView]
              &* set @"pBufferInfo" Vulkan.VK_NULL
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
      -- Bindings 0-6 are the standard textures
      standardWrites = zipWith mkWrite [0 .. 6] (take 7 lpduImageViews)
      lightWrite = case lpduLightBuffer of
        Nothing -> []
        Just lightBuffer ->
          let bufferInfo =
                Vulkan.createVk
                  ( set @"buffer" lightBuffer
                      &* set @"offset" 0
                      &* set @"range" (Vulkan.VkDeviceSize Vulkan.VK_WHOLE_SIZE)
                  )
           in [ Vulkan.createVk
                  ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
                      &* set @"pNext" Vulkan.VK_NULL
                      &* set @"dstSet" lpduDescriptorSet
                      &* set @"dstBinding" 7
                      &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
                      &* set @"pTexelBufferView" Vulkan.VK_NULL
                      &* set @"pImageInfo" Vulkan.VK_NULL
                      &* setVkRef @"pBufferInfo" bufferInfo
                      &* set @"descriptorCount" 1
                      &* set @"dstArrayElement" 0
                  )
              ]
      cloudResultWrite = case lpduCloudResultView of
        Nothing -> []
        Just cloudResultView ->
          [mkWrite 8 cloudResultView]
      godRayWrite = case lpduGodRayView of
        Nothing -> []
        Just godRayView ->
          [mkWrite 9 godRayView]
      apVolumeWrite = case lpduAPVolumeView of
        Nothing -> []
        Just apVolumeView ->
          let apVolumeInfo =
                Vulkan.createVk
                  ( set @"imageLayout" Vulkan.VK_IMAGE_LAYOUT_GENERAL
                      &* set @"imageView" apVolumeView
                      &* set @"sampler" lpduSampler
                  )
              apVolumeWriteDescriptor =
                Vulkan.createVk
                  ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
                      &* set @"pNext" Vulkan.VK_NULL
                      &* set @"dstSet" lpduDescriptorSet
                      &* set @"dstBinding" 10
                      &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
                      &* set @"pBufferInfo" Vulkan.VK_NULL
                      &* set @"pTexelBufferView" Vulkan.VK_NULL
                      &* setListRef @"pImageInfo" [apVolumeInfo]
                      &* set @"descriptorCount" 1
                      &* set @"dstArrayElement" 0
                  )
           in [apVolumeWriteDescriptor]
      allWrites = standardWrites ++ lightWrite ++ cloudResultWrite ++ godRayWrite ++ apVolumeWrite
  liftIO $
    Foreign.Marshal.Array.withArray allWrites $ \writeUpdatePtr ->
      Vulkan.vkUpdateDescriptorSets lpduDevice (fromIntegral (length allWrites)) writeUpdatePtr 0 Vulkan.vkNullPtr

-- | Update only the light SSBO binding (binding 7) in a lighting descriptor set.
updateLightingLightBuffer ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkDescriptorSet ->
  Vulkan.VkBuffer ->
  m ()
updateLightingLightBuffer dev descriptorSet lightBuffer = do
  let bufferInfo =
        Vulkan.createVk
          ( set @"buffer" lightBuffer
              &* set @"offset" 0
              &* set @"range" (Vulkan.VkDeviceSize Vulkan.VK_WHOLE_SIZE)
          )
      write =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" descriptorSet
              &* set @"dstBinding" 7
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* set @"pImageInfo" Vulkan.VK_NULL
              &* setVkRef @"pBufferInfo" bufferInfo
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
  liftIO $
    Foreign.Marshal.Array.withArray [write] $ \writeUpdatePtr ->
      Vulkan.vkUpdateDescriptorSets dev 1 writeUpdatePtr 0 Vulkan.vkNullPtr

-- | Update UBO, bindless texture array, and entity SSBO in a descriptor set.
updateDescriptorSetsBindless ::
  (MonadIO m) =>
  BindlessDescriptorUpdate ->
  m ()
updateDescriptorSetsBindless BindlessDescriptorUpdate {..} = do
  let bufferInfo :: Vulkan.VkDescriptorBufferInfo
      bufferInfo =
        Vulkan.createVk
          ( set @"buffer" bduBuffer
              &* set @"offset" 0
              &* set @"range" bduRange
          )
      textureInfos =
        map
          ( \imageView ->
              Vulkan.createVk
                ( set @"imageLayout" Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
                    &* set @"imageView" imageView
                    &* set @"sampler" bduSampler
                )
          )
          bduImageViews
      writeUpdate :: Vulkan.VkWriteDescriptorSet
      writeUpdate =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" bduDescriptorSet
              &* set @"dstBinding" 0
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* set @"pImageInfo" Vulkan.VK_NULL
              &* setVkRef @"pBufferInfo" bufferInfo
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
      writeUpdateTexture :: Vulkan.VkWriteDescriptorSet
      writeUpdateTexture =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" bduDescriptorSet
              &* set @"dstBinding" 1
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* setListRef @"pImageInfo" textureInfos
              &* set @"pBufferInfo" Vulkan.VK_NULL
              &* set @"descriptorCount" (fromIntegral (length bduImageViews))
              &* set @"dstArrayElement" 0
          )
      entityBufferInfo :: Vulkan.VkDescriptorBufferInfo
      entityBufferInfo =
        Vulkan.createVk
          ( set @"buffer" bduEntityBuffer
              &* set @"offset" 0
              &* set @"range" (Vulkan.VkDeviceSize Vulkan.VK_WHOLE_SIZE)
          )
      writeEntity :: Vulkan.VkWriteDescriptorSet
      writeEntity =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" bduDescriptorSet
              &* set @"dstBinding" 2
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* set @"pImageInfo" Vulkan.VK_NULL
              &* setVkRef @"pBufferInfo" entityBufferInfo
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
  liftIO $
    Foreign.Marshal.Array.withArray [writeUpdate, writeUpdateTexture, writeEntity] $ \writeUpdatePtr ->
      Vulkan.vkUpdateDescriptorSets bduDevice 3 writeUpdatePtr 0 Vulkan.vkNullPtr

-- | Update a single combined image sampler binding in a descriptor set.
updateTextureBinding ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkDescriptorSet ->
  Vulkan.VkSampler ->
  Vulkan.VkImageView ->
  Vulkan.Word32 -> -- binding index
  m ()
updateTextureBinding dev descriptorSet sampler imageView bindingIdx = do
  let textureInfo =
        Vulkan.createVk
          ( set @"imageLayout" Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
              &* set @"imageView" imageView
              &* set @"sampler" sampler
          )
      write =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" descriptorSet
              &* set @"dstBinding" bindingIdx
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* setListRef @"pImageInfo" [textureInfo]
              &* set @"pBufferInfo" Vulkan.VK_NULL
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
  liftIO $
    Foreign.Marshal.Array.withArray [write] $ \writePtr ->
      Vulkan.vkUpdateDescriptorSets dev 1 writePtr 0 Vulkan.vkNullPtr

-- | Update a single texture in a bindless descriptor array.
-- dstArrayElement is the index in the texture array.
updateBindlessTexture ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkDescriptorSet ->
  Vulkan.VkSampler ->
  Vulkan.VkImageView ->
  Vulkan.Word32 -> -- array index
  m ()
updateBindlessTexture dev descriptorSet sampler imageView arrayIndex = do
  let textureInfo =
        Vulkan.createVk
          ( set @"imageLayout" Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
              &* set @"imageView" imageView
              &* set @"sampler" sampler
          )
      write =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" descriptorSet
              &* set @"dstBinding" 0
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* setListRef @"pImageInfo" [textureInfo]
              &* set @"pBufferInfo" Vulkan.VK_NULL
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" arrayIndex
          )
  liftIO $
    Foreign.Marshal.Array.withArray [write] $ \writePtr ->
      Vulkan.vkUpdateDescriptorSets dev 1 writePtr 0 Vulkan.vkNullPtr

-- | Update bindless pass descriptor set: UBO (binding 0) + Texture2DArray (binding 1).
updateBindlessPassDescriptorSet ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkDescriptorSet ->
  -- | UBO buffer
  Vulkan.VkBuffer ->
  -- | UBO range
  Vulkan.VkDeviceSize ->
  -- | Texture2DArray image view
  Vulkan.VkImageView ->
  -- | Sampler
  Vulkan.VkSampler ->
  m ()
updateBindlessPassDescriptorSet dev descriptorSet buffer bufferRange imageView sampler = do
  let bufferInfo =
        Vulkan.createVk
          ( set @"buffer" buffer
              &* set @"offset" 0
              &* set @"range" bufferRange
          )
      textureInfo =
        Vulkan.createVk
          ( set @"imageLayout" Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
              &* set @"imageView" imageView
              &* set @"sampler" sampler
          )
  liftIO $ do
    Foreign.Marshal.Array.withArray [bufferInfo] $ \bufferInfoPtr ->
      Foreign.Marshal.Array.withArray [textureInfo] $ \textureInfoPtr -> do
        let uboWrite =
              Vulkan.createVk
                ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
                    &* set @"pNext" Vulkan.VK_NULL
                    &* set @"dstSet" descriptorSet
                    &* set @"dstBinding" 0
                    &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
                    &* set @"pTexelBufferView" Vulkan.VK_NULL
                    &* set @"pImageInfo" Vulkan.VK_NULL
                    &* set @"pBufferInfo" bufferInfoPtr
                    &* set @"descriptorCount" 1
                    &* set @"dstArrayElement" 0
                )
            texWrite =
              Vulkan.createVk
                ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
                    &* set @"pNext" Vulkan.VK_NULL
                    &* set @"dstSet" descriptorSet
                    &* set @"dstBinding" 1
                    &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
                    &* set @"pTexelBufferView" Vulkan.VK_NULL
                    &* set @"pImageInfo" textureInfoPtr
                    &* set @"pBufferInfo" Vulkan.VK_NULL
                    &* set @"descriptorCount" 1
                    &* set @"dstArrayElement" 0
                )
        Foreign.Marshal.Array.withArray [uboWrite, texWrite] $ \writePtr ->
          Vulkan.vkUpdateDescriptorSets dev 2 writePtr 0 Vulkan.vkNullPtr

cmdBindDescriptorSets ::
  (MonadIO m) =>
  Vulkan.VkCommandBuffer ->
  Vulkan.VkPipelineBindPoint ->
  Vulkan.VkPipelineLayout ->
  Vulkan.Word32 ->
  Vulkan.Word32 ->
  Vulkan.Ptr Vulkan.VkDescriptorSet ->
  Vulkan.Word32 ->
  Vulkan.Ptr Vulkan.Word32 ->
  m ()
cmdBindDescriptorSets commandBuffer pipelineBindPoint layout firstSet descriptorSetCount pDescriptorSets dynamicOffsetCount pDynamicOffsets =
  liftIO $
    Vulkan.vkCmdBindDescriptorSets
      commandBuffer
      pipelineBindPoint
      layout
      firstSet
      descriptorSetCount
      pDescriptorSets
      dynamicOffsetCount
      pDynamicOffsets

-- | Update compute culling descriptor set with SSBOs and UBO.
updateComputeDescriptorSets ::
  (MonadIO m) =>
  ComputeDescriptorUpdate ->
  m ()
updateComputeDescriptorSets ComputeDescriptorUpdate {..} = do
  let entitiesBufferInfo =
        Vulkan.createVk
          ( set @"buffer" cpduEntitiesBuffer
              &* set @"offset" 0
              &* set @"range" (Vulkan.VkDeviceSize Vulkan.VK_WHOLE_SIZE)
          )
      drawCommandsBufferInfo =
        Vulkan.createVk
          ( set @"buffer" cpduDrawCommandsBuffer
              &* set @"offset" 0
              &* set @"range" (Vulkan.VkDeviceSize Vulkan.VK_WHOLE_SIZE)
          )
      cullDataBufferInfo =
        Vulkan.createVk
          ( set @"buffer" cpduCullDataBuffer
              &* set @"offset" 0
              &* set @"range" (Vulkan.VkDeviceSize Vulkan.VK_WHOLE_SIZE)
          )
      writeEntities =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" cpduDescriptorSet
              &* set @"dstBinding" 0
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* set @"pImageInfo" Vulkan.VK_NULL
              &* setVkRef @"pBufferInfo" entitiesBufferInfo
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
      writeDrawCommands =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" cpduDescriptorSet
              &* set @"dstBinding" 1
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* set @"pImageInfo" Vulkan.VK_NULL
              &* setVkRef @"pBufferInfo" drawCommandsBufferInfo
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
      writeCullData =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" cpduDescriptorSet
              &* set @"dstBinding" 2
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* set @"pImageInfo" Vulkan.VK_NULL
              &* setVkRef @"pBufferInfo" cullDataBufferInfo
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
  liftIO $
    Foreign.Marshal.Array.withArray [writeEntities, writeDrawCommands, writeCullData] $ \writePtr ->
      Vulkan.vkUpdateDescriptorSets cpduDevice 3 writePtr 0 Vulkan.vkNullPtr

-- | Update cloud descriptor set: env cubemap + 3D noise texture
updateCloudDescriptorSets ::
  (MonadIO m) =>
  CloudDescriptorUpdate ->
  m ()
updateCloudDescriptorSets CloudDescriptorUpdate {..} = do
  let mkTextureInfo imageView s =
        Vulkan.createVk
          ( set @"imageLayout" Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
              &* set @"imageView" imageView
              &* set @"sampler" s
          )
      mkWrite bindingIdx imageView s =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" clduDescriptorSet
              &* set @"dstBinding" bindingIdx
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"pBufferInfo" Vulkan.VK_NULL
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* setVkRef @"pImageInfo" (mkTextureInfo imageView s)
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
      envWrite = case clduEnvMapView of
        Just envView -> [mkWrite 0 envView clduSampler]
        Nothing -> []
      noiseWrite = case clduCloudNoiseView of
        Just noiseView -> [mkWrite 1 noiseView clduNoiseSampler]
        Nothing -> []
      historyWrite = case clduCloudHistoryView of
        Just historyView -> [mkWrite 2 historyView clduSampler]
        Nothing -> []
      blueNoiseWrite = case clduBlueNoiseView of
        Just blueView -> [mkWrite 3 blueView clduBlueNoiseSampler]
        Nothing -> []
      weatherMapWrite = case clduWeatherMapView of
        Just weatherView -> [mkWrite 5 weatherView clduSampler]
        Nothing -> []
      allWrites = envWrite ++ noiseWrite ++ historyWrite ++ blueNoiseWrite ++ weatherMapWrite
  liftIO $
    Foreign.Marshal.Array.withArray allWrites $ \writePtr ->
      Vulkan.vkUpdateDescriptorSets clduDevice (fromIntegral (length allWrites)) writePtr 0 Vulkan.vkNullPtr

updateCloudFrameDataBuffer ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkDescriptorSet ->
  Vulkan.VkBuffer ->
  m ()
updateCloudFrameDataBuffer dev descriptorSet buffer = do
  let bufferInfo =
        Vulkan.createVk
          ( set @"buffer" buffer
              &* set @"offset" 0
              &* set @"range" (Vulkan.VkDeviceSize Vulkan.VK_WHOLE_SIZE)
          )
      write =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" descriptorSet
              &* set @"dstBinding" 4
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* set @"pImageInfo" Vulkan.VK_NULL
              &* setVkRef @"pBufferInfo" bufferInfo
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
  liftIO $
    Foreign.Marshal.Array.withArray [write] $ \writeUpdatePtr ->
      Vulkan.vkUpdateDescriptorSets dev 1 writeUpdatePtr 0 Vulkan.vkNullPtr

updateGodRayDescriptorSets ::
  (MonadIO m) =>
  GodRayDescriptorUpdate ->
  m ()
updateGodRayDescriptorSets GodRayDescriptorUpdate {..} = do
  let imageInfo =
        Vulkan.createVk
          ( set @"imageLayout" Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
              &* set @"imageView" grduCloudResultView
              &* set @"sampler" grduSampler
          )
      write =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" grduDescriptorSet
              &* set @"dstBinding" 0
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"pBufferInfo" Vulkan.VK_NULL
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* setVkRef @"pImageInfo" imageInfo
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
  liftIO $
    Foreign.Marshal.Array.withArray [write] $ \writePtr ->
      Vulkan.vkUpdateDescriptorSets grduDevice 1 writePtr 0 Vulkan.vkNullPtr

-- | Update terrain overlay descriptor set with elevation and climate textures.
updateTerrainDescriptorSets ::
  (MonadIO m) =>
  TerrainDescriptorUpdate ->
  m ()
updateTerrainDescriptorSets TerrainDescriptorUpdate {..} = do
  let mkTextureInfo imageView s =
        Vulkan.createVk
          ( set @"imageLayout" Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
              &* set @"imageView" imageView
              &* set @"sampler" s
          )
      mkWrite bindingIdx imageView s =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" tduDescriptorSet
              &* set @"dstBinding" bindingIdx
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"pBufferInfo" Vulkan.VK_NULL
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* setVkRef @"pImageInfo" (mkTextureInfo imageView s)
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
      elevWrite = case tduElevationView of
        Just elevView -> [mkWrite 0 elevView tduSampler]
        Nothing -> []
      climateWrite = case tduClimateView of
        Just climateView -> [mkWrite 1 climateView tduSampler]
        Nothing -> []
      allWrites = elevWrite ++ climateWrite
  liftIO $
    Foreign.Marshal.Array.withArray allWrites $ \writePtr ->
      Vulkan.vkUpdateDescriptorSets tduDevice (fromIntegral (length allWrites)) writePtr 0 Vulkan.vkNullPtr

-- | Update terrain overlay frame data UBO binding (binding 2).
updateTerrainFrameDataBuffer ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkDescriptorSet ->
  Vulkan.VkBuffer ->
  m ()
updateTerrainFrameDataBuffer dev descriptorSet buffer = do
  let bufferInfo =
        Vulkan.createVk
          ( set @"buffer" buffer
              &* set @"offset" 0
              &* set @"range" (Vulkan.VkDeviceSize Vulkan.VK_WHOLE_SIZE)
          )
      write =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" descriptorSet
              &* set @"dstBinding" 2
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* set @"pImageInfo" Vulkan.VK_NULL
              &* setVkRef @"pBufferInfo" bufferInfo
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
  liftIO $
    Foreign.Marshal.Array.withArray [write] $ \writeUpdatePtr ->
      Vulkan.vkUpdateDescriptorSets dev 1 writeUpdatePtr 0 Vulkan.vkNullPtr

-- | Update terrain mesh descriptor set with node SSBO, heightmap, and climate textures.
updateTerrainMeshDescriptorSets ::
  (MonadIO m) =>
  TerrainMeshDescriptorUpdate ->
  m ()
updateTerrainMeshDescriptorSets TerrainMeshDescriptorUpdate {..} = do
  let nodeBufferInfo =
        Vulkan.createVk
          ( set @"buffer" tmduNodeBuffer
              &* set @"offset" 0
              &* set @"range" (Vulkan.VkDeviceSize Vulkan.VK_WHOLE_SIZE)
          )
      mkTextureInfo imageView s =
        Vulkan.createVk
          ( set @"imageLayout" Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
              &* set @"imageView" imageView
              &* set @"sampler" s
          )
      mkWrite bindingIdx descriptorType pBufferInfo pImageInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" tmduDescriptorSet
              &* set @"dstBinding" bindingIdx
              &* set @"descriptorType" descriptorType
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* set @"pBufferInfo" pBufferInfo
              &* set @"pImageInfo" pImageInfo
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
      nodeWrite =
        mkWrite
          0
          Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
          (Vulkan.unsafePtr nodeBufferInfo)
          Vulkan.VK_NULL
      elevWrite = case tmduElevationView of
        Just elevView ->
          [ mkWrite
              1
              Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              Vulkan.VK_NULL
              (Vulkan.unsafePtr $ mkTextureInfo elevView tmduSampler)
          ]
        Nothing -> []
      climateWrite = case tmduClimateView of
        Just climateView ->
          [ mkWrite
              2
              Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              Vulkan.VK_NULL
              (Vulkan.unsafePtr $ mkTextureInfo climateView tmduSampler)
          ]
        Nothing -> []
      allWrites = nodeWrite : elevWrite ++ climateWrite
  liftIO $
    Foreign.Marshal.Array.withArray allWrites $ \writePtr ->
      Vulkan.vkUpdateDescriptorSets tmduDevice (fromIntegral (length allWrites)) writePtr 0 Vulkan.vkNullPtr

-- | Update AP volume compute descriptor set with storage image, cloud noise, and UBO.
updateAPVolumeDescriptorSets ::
  (MonadIO m) =>
  APVolumeDescriptorUpdate ->
  m ()
updateAPVolumeDescriptorSets APVolumeDescriptorUpdate {..} = do
  let imageInfo =
        Vulkan.createVk
          ( set @"imageLayout" Vulkan.VK_IMAGE_LAYOUT_GENERAL
              &* set @"imageView" apduAPImageView
              &* set @"sampler" Vulkan.VK_NULL_HANDLE
          )
      bufferInfo =
        Vulkan.createVk
          ( set @"buffer" apduUniformBuffer
              &* set @"offset" 0
              &* set @"range" (Vulkan.VkDeviceSize Vulkan.VK_WHOLE_SIZE)
          )
      writeImage =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" apduDescriptorSet
              &* set @"dstBinding" 0
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE
              &* set @"pBufferInfo" Vulkan.VK_NULL
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* setVkRef @"pImageInfo" imageInfo
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
      writeUniform =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" apduDescriptorSet
              &* set @"dstBinding" 2
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
              &* setVkRef @"pBufferInfo" bufferInfo
              &* set @"pImageInfo" Vulkan.VK_NULL
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
      noiseWrite = case apduCloudNoiseView of
        Just noiseView ->
          let noiseInfo =
                Vulkan.createVk
                  ( set @"imageLayout" Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
                      &* set @"imageView" noiseView
                      &* set @"sampler" apduCloudNoiseSampler
                  )
              noiseWriteDescriptor =
                Vulkan.createVk
                  ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
                      &* set @"pNext" Vulkan.VK_NULL
                      &* set @"dstSet" apduDescriptorSet
                      &* set @"dstBinding" 1
                      &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
                      &* set @"pBufferInfo" Vulkan.VK_NULL
                      &* set @"pTexelBufferView" Vulkan.VK_NULL
                      &* setVkRef @"pImageInfo" noiseInfo
                      &* set @"descriptorCount" 1
                      &* set @"dstArrayElement" 0
                  )
           in [noiseWriteDescriptor]
        Nothing -> []
      weatherMapWrite = case apduWeatherMapView of
        Just weatherMapView ->
          let weatherMapInfo =
                Vulkan.createVk
                  ( set @"imageLayout" Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
                      &* set @"imageView" weatherMapView
                      &* set @"sampler" apduWeatherMapSampler
                  )
              weatherMapWriteDescriptor =
                Vulkan.createVk
                  ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
                      &* set @"pNext" Vulkan.VK_NULL
                      &* set @"dstSet" apduDescriptorSet
                      &* set @"dstBinding" 3
                      &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
                      &* set @"pBufferInfo" Vulkan.VK_NULL
                      &* set @"pTexelBufferView" Vulkan.VK_NULL
                      &* setVkRef @"pImageInfo" weatherMapInfo
                      &* set @"descriptorCount" 1
                      &* set @"dstArrayElement" 0
                  )
           in [weatherMapWriteDescriptor]
        Nothing -> []
      allWrites = [writeImage, writeUniform] ++ noiseWrite ++ weatherMapWrite
  liftIO $
    Foreign.Marshal.Array.withArray allWrites $ \writePtr ->
      Vulkan.vkUpdateDescriptorSets apduDevice (fromIntegral (length allWrites)) writePtr 0 Vulkan.vkNullPtr

-- | Update cubemap compute descriptor set with storage image and UBO.
updateCubemapComputeDescriptorSets ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkDescriptorSet ->
  Vulkan.VkImageView -> -- cubemap storage image
  Vulkan.VkBuffer -> -- genData UBO
  m ()
updateCubemapComputeDescriptorSets dev descriptorSet cubemapView genDataBuffer = do
  let imageInfo =
        Vulkan.createVk
          ( set @"imageLayout" Vulkan.VK_IMAGE_LAYOUT_GENERAL
              &* set @"imageView" cubemapView
              &* set @"sampler" Vulkan.VK_NULL_HANDLE
          )
      bufferInfo =
        Vulkan.createVk
          ( set @"buffer" genDataBuffer
              &* set @"offset" 0
              &* set @"range" (Vulkan.VkDeviceSize Vulkan.VK_WHOLE_SIZE)
          )
      writeImage =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" descriptorSet
              &* set @"dstBinding" 0
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* set @"pBufferInfo" Vulkan.VK_NULL
              &* setVkRef @"pImageInfo" imageInfo
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
      writeBuffer =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" descriptorSet
              &* set @"dstBinding" 1
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* set @"pImageInfo" Vulkan.VK_NULL
              &* setVkRef @"pBufferInfo" bufferInfo
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
  liftIO $
    Foreign.Marshal.Array.withArray [writeImage, writeBuffer] $ \writePtr ->
      Vulkan.vkUpdateDescriptorSets dev 2 writePtr 0 Vulkan.vkNullPtr

-- | Update cloud noise compute descriptor set with 3D storage image and UBO.
updateCloudNoiseComputeDescriptorSets ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkDescriptorSet ->
  Vulkan.VkImageView -> -- 3D storage image
  Vulkan.VkBuffer -> -- noise params UBO
  m ()
updateCloudNoiseComputeDescriptorSets dev descriptorSet noiseView noiseParamsBuffer = do
  let imageInfo =
        Vulkan.createVk
          ( set @"imageLayout" Vulkan.VK_IMAGE_LAYOUT_GENERAL
              &* set @"imageView" noiseView
              &* set @"sampler" Vulkan.VK_NULL_HANDLE
          )
      bufferInfo =
        Vulkan.createVk
          ( set @"buffer" noiseParamsBuffer
              &* set @"offset" 0
              &* set @"range" (Vulkan.VkDeviceSize Vulkan.VK_WHOLE_SIZE)
          )
      writeImage =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" descriptorSet
              &* set @"dstBinding" 0
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* set @"pBufferInfo" Vulkan.VK_NULL
              &* setVkRef @"pImageInfo" imageInfo
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
      writeBuffer =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" descriptorSet
              &* set @"dstBinding" 1
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* set @"pImageInfo" Vulkan.VK_NULL
              &* setVkRef @"pBufferInfo" bufferInfo
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
  liftIO $
    Foreign.Marshal.Array.withArray [writeImage, writeBuffer] $ \writePtr ->
      Vulkan.vkUpdateDescriptorSets dev 2 writePtr 0 Vulkan.vkNullPtr

-- | Update cloud detail noise compute descriptor set with 3D storage image and UBO.
updateCloudDetailNoiseComputeDescriptorSets ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkDescriptorSet ->
  Vulkan.VkImageView -> -- 3D storage image
  Vulkan.VkBuffer -> -- noise params UBO
  m ()
updateCloudDetailNoiseComputeDescriptorSets dev descriptorSet noiseView noiseParamsBuffer = do
  let imageInfo =
        Vulkan.createVk
          ( set @"imageLayout" Vulkan.VK_IMAGE_LAYOUT_GENERAL
              &* set @"imageView" noiseView
              &* set @"sampler" Vulkan.VK_NULL_HANDLE
          )
      bufferInfo =
        Vulkan.createVk
          ( set @"buffer" noiseParamsBuffer
              &* set @"offset" 0
              &* set @"range" (Vulkan.VkDeviceSize Vulkan.VK_WHOLE_SIZE)
          )
      writeImage =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" descriptorSet
              &* set @"dstBinding" 0
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* set @"pBufferInfo" Vulkan.VK_NULL
              &* setVkRef @"pImageInfo" imageInfo
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
      writeBuffer =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" descriptorSet
              &* set @"dstBinding" 1
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* set @"pImageInfo" Vulkan.VK_NULL
              &* setVkRef @"pBufferInfo" bufferInfo
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
  liftIO $
    Foreign.Marshal.Array.withArray [writeImage, writeBuffer] $ \writePtr ->
      Vulkan.vkUpdateDescriptorSets dev 2 writePtr 0 Vulkan.vkNullPtr

-- | Update cloud noise mipgen compute descriptor set with src/dst 3D storage images and UBO.
updateCloudNoiseMipGenComputeDescriptorSets ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkDescriptorSet ->
  Vulkan.VkImageView -> -- src 3D storage image view (single mip)
  Vulkan.VkImageView -> -- dst 3D storage image view (single mip)
  Vulkan.VkBuffer -> -- mip params UBO
  m ()
updateCloudNoiseMipGenComputeDescriptorSets dev descriptorSet srcView dstView mipParamsBuffer = do
  let srcImageInfo =
        Vulkan.createVk
          ( set @"imageLayout" Vulkan.VK_IMAGE_LAYOUT_GENERAL
              &* set @"imageView" srcView
              &* set @"sampler" Vulkan.VK_NULL_HANDLE
          )
      dstImageInfo =
        Vulkan.createVk
          ( set @"imageLayout" Vulkan.VK_IMAGE_LAYOUT_GENERAL
              &* set @"imageView" dstView
              &* set @"sampler" Vulkan.VK_NULL_HANDLE
          )
      bufferInfo =
        Vulkan.createVk
          ( set @"buffer" mipParamsBuffer
              &* set @"offset" 0
              &* set @"range" (Vulkan.VkDeviceSize Vulkan.VK_WHOLE_SIZE)
          )
      writeSrcImage =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" descriptorSet
              &* set @"dstBinding" 0
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* set @"pBufferInfo" Vulkan.VK_NULL
              &* setVkRef @"pImageInfo" srcImageInfo
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
      writeDstImage =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" descriptorSet
              &* set @"dstBinding" 1
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* set @"pBufferInfo" Vulkan.VK_NULL
              &* setVkRef @"pImageInfo" dstImageInfo
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
      writeBuffer =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" descriptorSet
              &* set @"dstBinding" 2
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* set @"pImageInfo" Vulkan.VK_NULL
              &* setVkRef @"pBufferInfo" bufferInfo
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
  liftIO $
    Foreign.Marshal.Array.withArray [writeSrcImage, writeDstImage, writeBuffer] $ \writePtr ->
      Vulkan.vkUpdateDescriptorSets dev 3 writePtr 0 Vulkan.vkNullPtr

-- | Update weather map compute descriptor set with 2D storage image and UBO.
updateWeatherMapComputeDescriptorSets ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkDescriptorSet ->
  Vulkan.VkImageView -> -- 2D storage image
  Vulkan.VkBuffer -> -- weather params UBO
  m ()
updateWeatherMapComputeDescriptorSets dev descriptorSet weatherView weatherParamsBuffer = do
  let imageInfo =
        Vulkan.createVk
          ( set @"imageLayout" Vulkan.VK_IMAGE_LAYOUT_GENERAL
              &* set @"imageView" weatherView
              &* set @"sampler" Vulkan.VK_NULL_HANDLE
          )
      bufferInfo =
        Vulkan.createVk
          ( set @"buffer" weatherParamsBuffer
              &* set @"offset" 0
              &* set @"range" (Vulkan.VkDeviceSize Vulkan.VK_WHOLE_SIZE)
          )
      writeImage =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" descriptorSet
              &* set @"dstBinding" 0
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* set @"pBufferInfo" Vulkan.VK_NULL
              &* setVkRef @"pImageInfo" imageInfo
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
      writeBuffer =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" descriptorSet
              &* set @"dstBinding" 1
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* set @"pImageInfo" Vulkan.VK_NULL
              &* setVkRef @"pBufferInfo" bufferInfo
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
  liftIO $
    Foreign.Marshal.Array.withArray [writeImage, writeBuffer] $ \writePtr ->
      Vulkan.vkUpdateDescriptorSets dev 2 writePtr 0 Vulkan.vkNullPtr
