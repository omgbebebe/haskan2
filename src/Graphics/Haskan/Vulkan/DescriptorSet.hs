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
  Vulkan.VkDevice ->
  Vulkan.VkDescriptorSet ->
  Vulkan.VkSampler ->
  -- | 7 image views: gbuf_position, gbuf_normal, gbuf_albedo, gbuf_emissive, env_cubemap, irradiance_cubemap, brdf_lut
  [Vulkan.VkImageView] ->
  -- | light SSBO (optional)
  Maybe Vulkan.VkBuffer ->
  -- | cloud result texture (optional)
  Maybe Vulkan.VkImageView ->
  m ()
updateLightingDescriptorSets dev descriptorSet sampler imageViews mLightBuffer mCloudResultView = do
  let mkTextureInfo imageView =
        Vulkan.createVk
          ( set @"imageLayout" Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
              &* set @"imageView" imageView
              &* set @"sampler" sampler
          )
      mkWrite bindingIdx imageView =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" descriptorSet
              &* set @"dstBinding" bindingIdx
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* setListRef @"pImageInfo" [mkTextureInfo imageView]
              &* set @"pBufferInfo" Vulkan.VK_NULL
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
      writes = zipWith mkWrite [0 ..] imageViews
      lightWrite = case mLightBuffer of
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
                      &* set @"dstSet" descriptorSet
                      &* set @"dstBinding" 7
                      &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
                      &* set @"pTexelBufferView" Vulkan.VK_NULL
                      &* set @"pImageInfo" Vulkan.VK_NULL
                      &* setVkRef @"pBufferInfo" bufferInfo
                      &* set @"descriptorCount" 1
                      &* set @"dstArrayElement" 0
                  )
              ]
      cloudResultWrite = case mCloudResultView of
        Nothing -> []
        Just cloudResultView ->
          [mkWrite 8 cloudResultView]
      allWrites = writes ++ lightWrite ++ cloudResultWrite
  liftIO $
    Foreign.Marshal.Array.withArray allWrites $ \writeUpdatePtr ->
      Vulkan.vkUpdateDescriptorSets dev (fromIntegral (length allWrites)) writeUpdatePtr 0 Vulkan.vkNullPtr

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
  Vulkan.VkDevice ->
  Vulkan.VkDescriptorSet ->
  Vulkan.VkBuffer -> -- view+proj UBO
  Vulkan.VkDeviceSize ->
  Vulkan.VkSampler ->
  [Vulkan.VkImageView] ->
  Vulkan.VkBuffer -> -- entity SSBO
  m ()
updateDescriptorSetsBindless dev descriptorSet buffer range sampler imageViews entityBuffer = do
  let bufferInfo :: Vulkan.VkDescriptorBufferInfo
      bufferInfo =
        Vulkan.createVk
          ( set @"buffer" buffer
              &* set @"offset" 0
              &* set @"range" range
          )
      textureInfos =
        map
          ( \imageView ->
              Vulkan.createVk
                ( set @"imageLayout" Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
                    &* set @"imageView" imageView
                    &* set @"sampler" sampler
                )
          )
          imageViews
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
              &* setListRef @"pImageInfo" textureInfos
              &* set @"pBufferInfo" Vulkan.VK_NULL
              &* set @"descriptorCount" (fromIntegral (length imageViews))
              &* set @"dstArrayElement" 0
          )
      entityBufferInfo :: Vulkan.VkDescriptorBufferInfo
      entityBufferInfo =
        Vulkan.createVk
          ( set @"buffer" entityBuffer
              &* set @"offset" 0
              &* set @"range" (Vulkan.VkDeviceSize Vulkan.VK_WHOLE_SIZE)
          )
      writeEntity :: Vulkan.VkWriteDescriptorSet
      writeEntity =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" descriptorSet
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
      Vulkan.vkUpdateDescriptorSets dev 3 writeUpdatePtr 0 Vulkan.vkNullPtr

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
  Vulkan.VkDevice ->
  Vulkan.VkDescriptorSet ->
  Vulkan.VkBuffer -> -- entities SSBO
  Vulkan.VkBuffer -> -- drawCommands SSBO
  Vulkan.VkBuffer -> -- cullData UBO
  m ()
updateComputeDescriptorSets dev descriptorSet entitiesBuffer drawCommandsBuffer cullDataBuffer = do
  let entitiesBufferInfo =
        Vulkan.createVk
          ( set @"buffer" entitiesBuffer
              &* set @"offset" 0
              &* set @"range" (Vulkan.VkDeviceSize Vulkan.VK_WHOLE_SIZE)
          )
      drawCommandsBufferInfo =
        Vulkan.createVk
          ( set @"buffer" drawCommandsBuffer
              &* set @"offset" 0
              &* set @"range" (Vulkan.VkDeviceSize Vulkan.VK_WHOLE_SIZE)
          )
      cullDataBufferInfo =
        Vulkan.createVk
          ( set @"buffer" cullDataBuffer
              &* set @"offset" 0
              &* set @"range" (Vulkan.VkDeviceSize Vulkan.VK_WHOLE_SIZE)
          )
      writeEntities =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" descriptorSet
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
              &* set @"dstSet" descriptorSet
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
              &* set @"dstSet" descriptorSet
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
      Vulkan.vkUpdateDescriptorSets dev 3 writePtr 0 Vulkan.vkNullPtr

-- | Update cloud descriptor set: env cubemap + 3D noise texture
updateCloudDescriptorSets ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkDescriptorSet ->
  Vulkan.VkSampler ->
  -- | env cubemap view
  Maybe Vulkan.VkImageView ->
  -- | 3D cloud noise texture view
  Maybe Vulkan.VkImageView ->
  -- | history texture view
  Maybe Vulkan.VkImageView ->
  -- | blue noise texture view
  Maybe Vulkan.VkImageView ->
  m ()
updateCloudDescriptorSets dev descriptorSet sampler mEnvMapView mCloudNoiseView mCloudHistoryView mBlueNoiseView = do
  let mkTextureInfo imageView =
        Vulkan.createVk
          ( set @"imageLayout" Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
              &* set @"imageView" imageView
              &* set @"sampler" sampler
          )
      mkWrite bindingIdx imageView =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"dstSet" descriptorSet
              &* set @"dstBinding" bindingIdx
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"pBufferInfo" Vulkan.VK_NULL
              &* set @"pTexelBufferView" Vulkan.VK_NULL
              &* setVkRef @"pImageInfo" (mkTextureInfo imageView)
              &* set @"descriptorCount" 1
              &* set @"dstArrayElement" 0
          )
      envWrite = case mEnvMapView of
        Just envView -> [mkWrite 0 envView]
        Nothing -> []
      noiseWrite = case mCloudNoiseView of
        Just noiseView -> [mkWrite 1 noiseView]
        Nothing -> []
      historyWrite = case mCloudHistoryView of
        Just historyView -> [mkWrite 2 historyView]
        Nothing -> []
      blueNoiseWrite = case mBlueNoiseView of
        Just blueView -> [mkWrite 3 blueView]
        Nothing -> []
      allWrites = envWrite ++ noiseWrite ++ historyWrite ++ blueNoiseWrite
  liftIO $
    Foreign.Marshal.Array.withArray allWrites $ \writePtr ->
      Vulkan.vkUpdateDescriptorSets dev (fromIntegral (length allWrites)) writePtr 0 Vulkan.vkNullPtr

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
