{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Vulkan.DescriptorSet where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Vector qualified as Vector
import Data.Word (Word32)
import Graphics.Haskan.Resources (alloc)
import Vulkan.CStruct.Extends (SomeStruct(..))
import Vulkan.Zero (zero)
import Vulkan qualified as Vk26

-- | Configuration for updating lighting descriptor sets.
data LightingDescriptorUpdate = LightingDescriptorUpdate
  { lduDevice :: !Vk26.Device,
    lduDescriptorSet :: !Vk26.DescriptorSet,
    lduSampler :: !Vk26.Sampler,
    lduImageViews :: ![Vk26.ImageView],
    lduLightBuffer :: !(Maybe Vk26.Buffer),
    lduCloudResultView :: !(Maybe Vk26.ImageView),
    lduAPVolumeView :: !(Maybe Vk26.ImageView)
  }

-- | Configuration for updating procedural sky lighting descriptor sets.
data LightingProceduralDescriptorUpdate = LightingProceduralDescriptorUpdate
  { lpduDevice :: !Vk26.Device,
    lpduDescriptorSet :: !Vk26.DescriptorSet,
    lpduSampler :: !Vk26.Sampler,
    lpduImageViews :: ![Vk26.ImageView],
    lpduLightBuffer :: !(Maybe Vk26.Buffer),
    lpduCloudResultView :: !(Maybe Vk26.ImageView),
    lpduGodRayView :: !(Maybe Vk26.ImageView),
    lpduAPVolumeView :: !(Maybe Vk26.ImageView)
  }

-- | Configuration for updating cloud descriptor sets.
data CloudDescriptorUpdate = CloudDescriptorUpdate
  { clduDevice :: !Vk26.Device,
    clduDescriptorSet :: !Vk26.DescriptorSet,
    clduSampler :: !Vk26.Sampler,
    clduNoiseSampler :: !Vk26.Sampler,
    clduEnvMapView :: !(Maybe Vk26.ImageView),
    clduCloudNoiseView :: !(Maybe Vk26.ImageView),
    clduCloudHistoryView :: !(Maybe Vk26.ImageView),
    clduBlueNoiseView :: !(Maybe Vk26.ImageView),
    clduWeatherMapView :: !(Maybe Vk26.ImageView),
    clduBlueNoiseSampler :: !Vk26.Sampler
  }

-- | Configuration for updating god ray descriptor sets.
data GodRayDescriptorUpdate = GodRayDescriptorUpdate
  { grduDevice :: !Vk26.Device,
    grduDescriptorSet :: !Vk26.DescriptorSet,
    grduSampler :: !Vk26.Sampler,
    grduCloudResultView :: !Vk26.ImageView
  }

-- | Configuration for updating terrain overlay descriptor sets.
data TerrainDescriptorUpdate = TerrainDescriptorUpdate
  { tduDevice :: !Vk26.Device,
    tduDescriptorSet :: !Vk26.DescriptorSet,
    tduSampler :: !Vk26.Sampler,
    tduElevationView :: !(Maybe Vk26.ImageView),
    tduClimateView :: !(Maybe Vk26.ImageView)
  }

-- | Configuration for updating terrain mesh descriptor sets.
data TerrainMeshDescriptorUpdate = TerrainMeshDescriptorUpdate
  { tmduDevice :: !Vk26.Device,
    tmduDescriptorSet :: !Vk26.DescriptorSet,
    tmduNodeBuffer :: !Vk26.Buffer,
    tmduSampler :: !Vk26.Sampler,
    tmduElevationView :: !(Maybe Vk26.ImageView),
    tmduClimateView :: !(Maybe Vk26.ImageView)
  }

-- | Configuration for updating AP volume descriptor sets.
data APVolumeDescriptorUpdate = APVolumeDescriptorUpdate
  { apduDevice :: !Vk26.Device,
    apduDescriptorSet :: !Vk26.DescriptorSet,
    apduAPImageView :: !Vk26.ImageView,
    apduCloudNoiseView :: !(Maybe Vk26.ImageView),
    apduCloudNoiseSampler :: !Vk26.Sampler,
    apduWeatherMapView :: !(Maybe Vk26.ImageView),
    apduWeatherMapSampler :: !Vk26.Sampler,
    apduUniformBuffer :: !Vk26.Buffer
  }

-- | Configuration for updating compute cull descriptor sets.
data ComputeDescriptorUpdate = ComputeDescriptorUpdate
  { cpduDevice :: !Vk26.Device,
    cpduDescriptorSet :: !Vk26.DescriptorSet,
    cpduEntitiesBuffer :: !Vk26.Buffer,
    cpduDrawCommandsBuffer :: !Vk26.Buffer,
    cpduCullDataBuffer :: !Vk26.Buffer
  }

-- | Configuration for updating bindless descriptor sets.
data BindlessDescriptorUpdate = BindlessDescriptorUpdate
  { bduDevice :: !Vk26.Device,
    bduDescriptorSet :: !Vk26.DescriptorSet,
    bduBuffer :: !Vk26.Buffer,
    bduRange :: !Vk26.DeviceSize,
    bduSampler :: !Vk26.Sampler,
    bduImageViews :: ![Vk26.ImageView],
    bduEntityBuffer :: !Vk26.Buffer
  }

allocateDescriptorSet ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.DescriptorPool ->
  [Vk26.DescriptorSetLayout] ->
  m Vk26.DescriptorSet
allocateDescriptorSet dev descriptorPool setLayouts = do
  let allocateInfo = Vk26.DescriptorSetAllocateInfo () descriptorPool (Vector.fromList setLayouts)
  sets <- liftIO $ Vk26.allocateDescriptorSets dev allocateInfo
  pure (Vector.head sets)

updateDescriptorSets ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.DescriptorSet ->
  Vk26.Buffer ->
  Vk26.ImageView ->
  Vk26.Sampler ->
  m ()
updateDescriptorSets dev descriptorSet buffer textureImageView textureSampler = do
  let bufferInfo = Vk26.DescriptorBufferInfo buffer 0 Vk26.WHOLE_SIZE
      textureInfo = Vk26.DescriptorImageInfo textureSampler textureImageView Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
      writeUpdate = Vk26.WriteDescriptorSet () descriptorSet 0 0 1 Vk26.DESCRIPTOR_TYPE_UNIFORM_BUFFER Vector.empty (Vector.fromList [bufferInfo]) Vector.empty
      writeUpdateTexture = Vk26.WriteDescriptorSet () descriptorSet 1 0 1 Vk26.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER (Vector.fromList [textureInfo]) Vector.empty Vector.empty
  liftIO $ Vk26.updateDescriptorSets dev (Vector.fromList [SomeStruct writeUpdate, SomeStruct writeUpdateTexture]) Vector.empty

updateDescriptorSetsRange ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.DescriptorSet ->
  Vk26.Buffer ->
  Vk26.DeviceSize ->
  Vk26.ImageView ->
  Vk26.Sampler ->
  m ()
updateDescriptorSetsRange dev descriptorSet buffer range textureImageView textureSampler = do
  let bufferInfo = Vk26.DescriptorBufferInfo buffer 0 range
      textureInfo = Vk26.DescriptorImageInfo textureSampler textureImageView Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
      writeUpdate = Vk26.WriteDescriptorSet () descriptorSet 0 0 1 Vk26.DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC Vector.empty (Vector.fromList [bufferInfo]) Vector.empty
      writeUpdateTexture = Vk26.WriteDescriptorSet () descriptorSet 1 0 1 Vk26.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER (Vector.fromList [textureInfo]) Vector.empty Vector.empty
  liftIO $ Vk26.updateDescriptorSets dev (Vector.fromList [SomeStruct writeUpdate, SomeStruct writeUpdateTexture]) Vector.empty

updateLightingDescriptorSets ::
  (MonadIO m) =>
  LightingDescriptorUpdate ->
  m ()
updateLightingDescriptorSets LightingDescriptorUpdate {..} = do
  let mkTextureInfo imageView = Vk26.DescriptorImageInfo lduSampler imageView Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
      mkWrite bindingIdx imageView = Vk26.WriteDescriptorSet () lduDescriptorSet bindingIdx 0 1 Vk26.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER (Vector.fromList [mkTextureInfo imageView]) Vector.empty Vector.empty
      writes = zipWith mkWrite [0 ..] lduImageViews
      lightWrite = case lduLightBuffer of
        Nothing -> []
        Just lightBuffer ->
          let bufferInfo = Vk26.DescriptorBufferInfo lightBuffer 0 Vk26.WHOLE_SIZE
           in [Vk26.WriteDescriptorSet () lduDescriptorSet 7 0 1 Vk26.DESCRIPTOR_TYPE_STORAGE_BUFFER Vector.empty (Vector.fromList [bufferInfo]) Vector.empty]
      cloudResultWrite = case lduCloudResultView of
        Nothing -> []
        Just cloudResultView -> [mkWrite 8 cloudResultView]
      apVolumeWrite = case lduAPVolumeView of
        Nothing -> []
        Just apVolumeView ->
          let apVolumeInfo = Vk26.DescriptorImageInfo lduSampler apVolumeView Vk26.IMAGE_LAYOUT_GENERAL
           in [Vk26.WriteDescriptorSet () lduDescriptorSet 9 0 1 Vk26.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER (Vector.fromList [apVolumeInfo]) Vector.empty Vector.empty]
      allWrites = writes ++ lightWrite ++ cloudResultWrite ++ apVolumeWrite
  liftIO $ Vk26.updateDescriptorSets lduDevice (Vector.fromList (map SomeStruct allWrites)) Vector.empty

updateLightingProceduralDescriptorSets ::
  (MonadIO m) =>
  LightingProceduralDescriptorUpdate ->
  m ()
updateLightingProceduralDescriptorSets LightingProceduralDescriptorUpdate {..} = do
  let mkTextureInfo imageView = Vk26.DescriptorImageInfo lpduSampler imageView Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
      mkWrite bindingIdx imageView = Vk26.WriteDescriptorSet () lpduDescriptorSet bindingIdx 0 1 Vk26.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER (Vector.fromList [mkTextureInfo imageView]) Vector.empty Vector.empty
      standardWrites = zipWith mkWrite [0 .. 6] (take 7 lpduImageViews)
      lightWrite = case lpduLightBuffer of
        Nothing -> []
        Just lightBuffer ->
          let bufferInfo = Vk26.DescriptorBufferInfo lightBuffer 0 Vk26.WHOLE_SIZE
           in [Vk26.WriteDescriptorSet () lpduDescriptorSet 7 0 1 Vk26.DESCRIPTOR_TYPE_STORAGE_BUFFER Vector.empty (Vector.fromList [bufferInfo]) Vector.empty]
      cloudResultWrite = case lpduCloudResultView of
        Nothing -> []
        Just cloudResultView -> [mkWrite 8 cloudResultView]
      godRayWrite = case lpduGodRayView of
        Nothing -> []
        Just godRayView -> [mkWrite 9 godRayView]
      apVolumeWrite = case lpduAPVolumeView of
        Nothing -> []
        Just apVolumeView ->
          let apVolumeInfo = Vk26.DescriptorImageInfo lpduSampler apVolumeView Vk26.IMAGE_LAYOUT_GENERAL
           in [Vk26.WriteDescriptorSet () lpduDescriptorSet 10 0 1 Vk26.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER (Vector.fromList [apVolumeInfo]) Vector.empty Vector.empty]
      allWrites = standardWrites ++ lightWrite ++ cloudResultWrite ++ godRayWrite ++ apVolumeWrite
  liftIO $ Vk26.updateDescriptorSets lpduDevice (Vector.fromList (map SomeStruct allWrites)) Vector.empty

updateLightingLightBuffer ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.DescriptorSet ->
  Vk26.Buffer ->
  m ()
updateLightingLightBuffer dev descriptorSet lightBuffer = do
  let bufferInfo = Vk26.DescriptorBufferInfo lightBuffer 0 Vk26.WHOLE_SIZE
      write = Vk26.WriteDescriptorSet () descriptorSet 7 0 1 Vk26.DESCRIPTOR_TYPE_STORAGE_BUFFER Vector.empty (Vector.fromList [bufferInfo]) Vector.empty
  liftIO $ Vk26.updateDescriptorSets dev (Vector.fromList [SomeStruct write]) Vector.empty

updateDescriptorSetsBindless ::
  (MonadIO m) =>
  BindlessDescriptorUpdate ->
  m ()
updateDescriptorSetsBindless BindlessDescriptorUpdate {..} = do
  let bufferInfo = Vk26.DescriptorBufferInfo bduBuffer 0 bduRange
      textureInfos = map (\imageView -> Vk26.DescriptorImageInfo bduSampler imageView Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) bduImageViews
      writeUpdate = Vk26.WriteDescriptorSet () bduDescriptorSet 0 0 1 Vk26.DESCRIPTOR_TYPE_UNIFORM_BUFFER Vector.empty (Vector.fromList [bufferInfo]) Vector.empty
      writeUpdateTexture = Vk26.WriteDescriptorSet () bduDescriptorSet 1 0 (fromIntegral (length bduImageViews)) Vk26.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER (Vector.fromList textureInfos) Vector.empty Vector.empty
      entityBufferInfo = Vk26.DescriptorBufferInfo bduEntityBuffer 0 Vk26.WHOLE_SIZE
      writeEntity = Vk26.WriteDescriptorSet () bduDescriptorSet 2 0 1 Vk26.DESCRIPTOR_TYPE_STORAGE_BUFFER Vector.empty (Vector.fromList [entityBufferInfo]) Vector.empty
  liftIO $ Vk26.updateDescriptorSets bduDevice (Vector.fromList (map SomeStruct [writeUpdate, writeUpdateTexture, writeEntity])) Vector.empty

updateTextureBinding ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.DescriptorSet ->
  Vk26.Sampler ->
  Vk26.ImageView ->
  Word32 -> -- binding index
  m ()
updateTextureBinding dev descriptorSet sampler imageView bindingIdx = do
  let textureInfo = Vk26.DescriptorImageInfo sampler imageView Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
      write = Vk26.WriteDescriptorSet () descriptorSet bindingIdx 0 1 Vk26.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER (Vector.fromList [textureInfo]) Vector.empty Vector.empty
  liftIO $ Vk26.updateDescriptorSets dev (Vector.fromList [SomeStruct write]) Vector.empty

updateBindlessTexture ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.DescriptorSet ->
  Vk26.Sampler ->
  Vk26.ImageView ->
  Word32 -> -- array index
  m ()
updateBindlessTexture dev descriptorSet sampler imageView arrayIndex = do
  let textureInfo = Vk26.DescriptorImageInfo sampler imageView Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
      write = Vk26.WriteDescriptorSet () descriptorSet 0 arrayIndex 1 Vk26.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER (Vector.fromList [textureInfo]) Vector.empty Vector.empty
  liftIO $ Vk26.updateDescriptorSets dev (Vector.fromList [SomeStruct write]) Vector.empty

updateBindlessPassDescriptorSet ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.DescriptorSet ->
  -- | UBO buffer
  Vk26.Buffer ->
  -- | UBO range
  Vk26.DeviceSize ->
  -- | Texture2DArray image view
  Vk26.ImageView ->
  -- | Sampler
  Vk26.Sampler ->
  m ()
updateBindlessPassDescriptorSet dev descriptorSet buffer bufferRange imageView sampler = do
  let bufferInfo = Vk26.DescriptorBufferInfo buffer 0 bufferRange
      textureInfo = Vk26.DescriptorImageInfo sampler imageView Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
      uboWrite = Vk26.WriteDescriptorSet () descriptorSet 0 0 1 Vk26.DESCRIPTOR_TYPE_UNIFORM_BUFFER Vector.empty (Vector.fromList [bufferInfo]) Vector.empty
      texWrite = Vk26.WriteDescriptorSet () descriptorSet 1 0 1 Vk26.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER (Vector.fromList [textureInfo]) Vector.empty Vector.empty
  liftIO $ Vk26.updateDescriptorSets dev (Vector.fromList [SomeStruct uboWrite, SomeStruct texWrite]) Vector.empty

cmdBindDescriptorSets ::
  (MonadIO m) =>
  Vk26.CommandBuffer ->
  Vk26.PipelineBindPoint ->
  Vk26.PipelineLayout ->
  Word32 ->
  Vector.Vector Vk26.DescriptorSet ->
  Vector.Vector Word32 ->
  m ()
cmdBindDescriptorSets commandBuffer pipelineBindPoint layout firstSet descriptorSets dynamicOffsets =
  liftIO $ Vk26.cmdBindDescriptorSets commandBuffer pipelineBindPoint layout firstSet descriptorSets dynamicOffsets

updateComputeDescriptorSets ::
  (MonadIO m) =>
  ComputeDescriptorUpdate ->
  m ()
updateComputeDescriptorSets ComputeDescriptorUpdate {..} = do
  let entitiesBufferInfo = Vk26.DescriptorBufferInfo cpduEntitiesBuffer 0 Vk26.WHOLE_SIZE
      drawCommandsBufferInfo = Vk26.DescriptorBufferInfo cpduDrawCommandsBuffer 0 Vk26.WHOLE_SIZE
      cullDataBufferInfo = Vk26.DescriptorBufferInfo cpduCullDataBuffer 0 Vk26.WHOLE_SIZE
      writeEntities = Vk26.WriteDescriptorSet () cpduDescriptorSet 0 0 1 Vk26.DESCRIPTOR_TYPE_STORAGE_BUFFER Vector.empty (Vector.fromList [entitiesBufferInfo]) Vector.empty
      writeDrawCommands = Vk26.WriteDescriptorSet () cpduDescriptorSet 1 0 1 Vk26.DESCRIPTOR_TYPE_STORAGE_BUFFER Vector.empty (Vector.fromList [drawCommandsBufferInfo]) Vector.empty
      writeCullData = Vk26.WriteDescriptorSet () cpduDescriptorSet 2 0 1 Vk26.DESCRIPTOR_TYPE_UNIFORM_BUFFER Vector.empty (Vector.fromList [cullDataBufferInfo]) Vector.empty
  liftIO $ Vk26.updateDescriptorSets cpduDevice (Vector.fromList (map SomeStruct [writeEntities, writeDrawCommands, writeCullData])) Vector.empty

updateCloudDescriptorSets ::
  (MonadIO m) =>
  CloudDescriptorUpdate ->
  m ()
updateCloudDescriptorSets CloudDescriptorUpdate {..} = do
  let mkTextureInfo imageView s = Vk26.DescriptorImageInfo s imageView Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
      mkWrite bindingIdx imageView s = Vk26.WriteDescriptorSet () clduDescriptorSet bindingIdx 0 1 Vk26.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER (Vector.fromList [mkTextureInfo imageView s]) Vector.empty Vector.empty
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
  liftIO $ Vk26.updateDescriptorSets clduDevice (Vector.fromList (map SomeStruct allWrites)) Vector.empty

updateCloudFrameDataBuffer ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.DescriptorSet ->
  Vk26.Buffer ->
  m ()
updateCloudFrameDataBuffer dev descriptorSet buffer = do
  let bufferInfo = Vk26.DescriptorBufferInfo buffer 0 Vk26.WHOLE_SIZE
      write = Vk26.WriteDescriptorSet () descriptorSet 4 0 1 Vk26.DESCRIPTOR_TYPE_UNIFORM_BUFFER Vector.empty (Vector.fromList [bufferInfo]) Vector.empty
  liftIO $ Vk26.updateDescriptorSets dev (Vector.fromList [SomeStruct write]) Vector.empty

updateGodRayDescriptorSets ::
  (MonadIO m) =>
  GodRayDescriptorUpdate ->
  m ()
updateGodRayDescriptorSets GodRayDescriptorUpdate {..} = do
  let imageInfo = Vk26.DescriptorImageInfo grduSampler grduCloudResultView Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
      write = Vk26.WriteDescriptorSet () grduDescriptorSet 0 0 1 Vk26.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER (Vector.fromList [imageInfo]) Vector.empty Vector.empty
  liftIO $ Vk26.updateDescriptorSets grduDevice (Vector.fromList [SomeStruct write]) Vector.empty

updateTerrainDescriptorSets ::
  (MonadIO m) =>
  TerrainDescriptorUpdate ->
  m ()
updateTerrainDescriptorSets TerrainDescriptorUpdate {..} = do
  let mkTextureInfo imageView s = Vk26.DescriptorImageInfo s imageView Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
      mkWrite bindingIdx imageView s = Vk26.WriteDescriptorSet () tduDescriptorSet bindingIdx 0 1 Vk26.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER (Vector.fromList [mkTextureInfo imageView s]) Vector.empty Vector.empty
      elevWrite = case tduElevationView of
        Just elevView -> [mkWrite 0 elevView tduSampler]
        Nothing -> []
      climateWrite = case tduClimateView of
        Just climateView -> [mkWrite 1 climateView tduSampler]
        Nothing -> []
      allWrites = elevWrite ++ climateWrite
  liftIO $ Vk26.updateDescriptorSets tduDevice (Vector.fromList (map SomeStruct allWrites)) Vector.empty

updateTerrainFrameDataBuffer ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.DescriptorSet ->
  Vk26.Buffer ->
  m ()
updateTerrainFrameDataBuffer dev descriptorSet buffer = do
  let bufferInfo = Vk26.DescriptorBufferInfo buffer 0 Vk26.WHOLE_SIZE
      write = Vk26.WriteDescriptorSet () descriptorSet 2 0 1 Vk26.DESCRIPTOR_TYPE_UNIFORM_BUFFER Vector.empty (Vector.fromList [bufferInfo]) Vector.empty
  liftIO $ Vk26.updateDescriptorSets dev (Vector.fromList [SomeStruct write]) Vector.empty

updateTerrainMeshDescriptorSets ::
  (MonadIO m) =>
  TerrainMeshDescriptorUpdate ->
  m ()
updateTerrainMeshDescriptorSets TerrainMeshDescriptorUpdate {..} = do
  let nodeBufferInfo = Vk26.DescriptorBufferInfo tmduNodeBuffer 0 Vk26.WHOLE_SIZE
      mkTextureInfo imageView s = Vk26.DescriptorImageInfo s imageView Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
      nodeWrite = Vk26.WriteDescriptorSet () tmduDescriptorSet 0 0 1 Vk26.DESCRIPTOR_TYPE_STORAGE_BUFFER Vector.empty (Vector.fromList [nodeBufferInfo]) Vector.empty
      elevWrite = case tmduElevationView of
        Just elevView -> [Vk26.WriteDescriptorSet () tmduDescriptorSet 1 0 1 Vk26.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER (Vector.fromList [mkTextureInfo elevView tmduSampler]) Vector.empty Vector.empty]
        Nothing -> []
      climateWrite = case tmduClimateView of
        Just climateView -> [Vk26.WriteDescriptorSet () tmduDescriptorSet 2 0 1 Vk26.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER (Vector.fromList [mkTextureInfo climateView tmduSampler]) Vector.empty Vector.empty]
        Nothing -> []
      allWrites = nodeWrite : elevWrite ++ climateWrite
  liftIO $ Vk26.updateDescriptorSets tmduDevice (Vector.fromList (map SomeStruct allWrites)) Vector.empty

updateAPVolumeDescriptorSets ::
  (MonadIO m) =>
  APVolumeDescriptorUpdate ->
  m ()
updateAPVolumeDescriptorSets APVolumeDescriptorUpdate {..} = do
  let imageInfo = Vk26.DescriptorImageInfo zero apduAPImageView Vk26.IMAGE_LAYOUT_GENERAL
      bufferInfo = Vk26.DescriptorBufferInfo apduUniformBuffer 0 Vk26.WHOLE_SIZE
      writeImage = Vk26.WriteDescriptorSet () apduDescriptorSet 0 0 1 Vk26.DESCRIPTOR_TYPE_STORAGE_IMAGE (Vector.fromList [imageInfo]) Vector.empty Vector.empty
      writeUniform = Vk26.WriteDescriptorSet () apduDescriptorSet 2 0 1 Vk26.DESCRIPTOR_TYPE_UNIFORM_BUFFER Vector.empty (Vector.fromList [bufferInfo]) Vector.empty
      noiseWrite = case apduCloudNoiseView of
        Just noiseView ->
          let noiseInfo = Vk26.DescriptorImageInfo apduCloudNoiseSampler noiseView Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
           in [Vk26.WriteDescriptorSet () apduDescriptorSet 1 0 1 Vk26.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER (Vector.fromList [noiseInfo]) Vector.empty Vector.empty]
        Nothing -> []
      weatherMapWrite = case apduWeatherMapView of
        Just weatherMapView ->
          let weatherMapInfo = Vk26.DescriptorImageInfo apduWeatherMapSampler weatherMapView Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
           in [Vk26.WriteDescriptorSet () apduDescriptorSet 3 0 1 Vk26.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER (Vector.fromList [weatherMapInfo]) Vector.empty Vector.empty]
        Nothing -> []
      allWrites = [writeImage, writeUniform] ++ noiseWrite ++ weatherMapWrite
  liftIO $ Vk26.updateDescriptorSets apduDevice (Vector.fromList (map SomeStruct allWrites)) Vector.empty

updateCubemapComputeDescriptorSets ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.DescriptorSet ->
  Vk26.ImageView -> -- cubemap storage image
  Vk26.Buffer -> -- genData UBO
  m ()
updateCubemapComputeDescriptorSets dev descriptorSet cubemapView genDataBuffer = do
  let imageInfo = Vk26.DescriptorImageInfo zero cubemapView Vk26.IMAGE_LAYOUT_GENERAL
      bufferInfo = Vk26.DescriptorBufferInfo genDataBuffer 0 Vk26.WHOLE_SIZE
      writeImage = Vk26.WriteDescriptorSet () descriptorSet 0 0 1 Vk26.DESCRIPTOR_TYPE_STORAGE_IMAGE (Vector.fromList [imageInfo]) Vector.empty Vector.empty
      writeBuffer = Vk26.WriteDescriptorSet () descriptorSet 1 0 1 Vk26.DESCRIPTOR_TYPE_UNIFORM_BUFFER Vector.empty (Vector.fromList [bufferInfo]) Vector.empty
  liftIO $ Vk26.updateDescriptorSets dev (Vector.fromList (map SomeStruct [writeImage, writeBuffer])) Vector.empty

updateCloudNoiseComputeDescriptorSets ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.DescriptorSet ->
  Vk26.ImageView -> -- 3D storage image
  Vk26.Buffer -> -- noise params UBO
  m ()
updateCloudNoiseComputeDescriptorSets dev descriptorSet noiseView noiseParamsBuffer = do
  let imageInfo = Vk26.DescriptorImageInfo zero noiseView Vk26.IMAGE_LAYOUT_GENERAL
      bufferInfo = Vk26.DescriptorBufferInfo noiseParamsBuffer 0 Vk26.WHOLE_SIZE
      writeImage = Vk26.WriteDescriptorSet () descriptorSet 0 0 1 Vk26.DESCRIPTOR_TYPE_STORAGE_IMAGE (Vector.fromList [imageInfo]) Vector.empty Vector.empty
      writeBuffer = Vk26.WriteDescriptorSet () descriptorSet 1 0 1 Vk26.DESCRIPTOR_TYPE_UNIFORM_BUFFER Vector.empty (Vector.fromList [bufferInfo]) Vector.empty
  liftIO $ Vk26.updateDescriptorSets dev (Vector.fromList (map SomeStruct [writeImage, writeBuffer])) Vector.empty

updateCloudDetailNoiseComputeDescriptorSets ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.DescriptorSet ->
  Vk26.ImageView -> -- 3D storage image
  Vk26.Buffer -> -- noise params UBO
  m ()
updateCloudDetailNoiseComputeDescriptorSets dev descriptorSet noiseView noiseParamsBuffer = do
  let imageInfo = Vk26.DescriptorImageInfo zero noiseView Vk26.IMAGE_LAYOUT_GENERAL
      bufferInfo = Vk26.DescriptorBufferInfo noiseParamsBuffer 0 Vk26.WHOLE_SIZE
      writeImage = Vk26.WriteDescriptorSet () descriptorSet 0 0 1 Vk26.DESCRIPTOR_TYPE_STORAGE_IMAGE (Vector.fromList [imageInfo]) Vector.empty Vector.empty
      writeBuffer = Vk26.WriteDescriptorSet () descriptorSet 1 0 1 Vk26.DESCRIPTOR_TYPE_UNIFORM_BUFFER Vector.empty (Vector.fromList [bufferInfo]) Vector.empty
  liftIO $ Vk26.updateDescriptorSets dev (Vector.fromList (map SomeStruct [writeImage, writeBuffer])) Vector.empty

updateCloudNoiseMipGenComputeDescriptorSets ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.DescriptorSet ->
  Vk26.ImageView -> -- src 3D storage image view (single mip)
  Vk26.ImageView -> -- dst 3D storage image view (single mip)
  Vk26.Buffer -> -- mip params UBO
  m ()
updateCloudNoiseMipGenComputeDescriptorSets dev descriptorSet srcView dstView mipParamsBuffer = do
  let srcImageInfo = Vk26.DescriptorImageInfo zero srcView Vk26.IMAGE_LAYOUT_GENERAL
      dstImageInfo = Vk26.DescriptorImageInfo zero dstView Vk26.IMAGE_LAYOUT_GENERAL
      bufferInfo = Vk26.DescriptorBufferInfo mipParamsBuffer 0 Vk26.WHOLE_SIZE
      writeSrcImage = Vk26.WriteDescriptorSet () descriptorSet 0 0 1 Vk26.DESCRIPTOR_TYPE_STORAGE_IMAGE (Vector.fromList [srcImageInfo]) Vector.empty Vector.empty
      writeDstImage = Vk26.WriteDescriptorSet () descriptorSet 1 0 1 Vk26.DESCRIPTOR_TYPE_STORAGE_IMAGE (Vector.fromList [dstImageInfo]) Vector.empty Vector.empty
      writeBuffer = Vk26.WriteDescriptorSet () descriptorSet 2 0 1 Vk26.DESCRIPTOR_TYPE_UNIFORM_BUFFER Vector.empty (Vector.fromList [bufferInfo]) Vector.empty
  liftIO $ Vk26.updateDescriptorSets dev (Vector.fromList (map SomeStruct [writeSrcImage, writeDstImage, writeBuffer])) Vector.empty

updateWeatherMapComputeDescriptorSets ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.DescriptorSet ->
  Vk26.ImageView -> -- 2D storage image
  Vk26.Buffer -> -- weather params UBO
  m ()
updateWeatherMapComputeDescriptorSets dev descriptorSet weatherView weatherParamsBuffer = do
  let imageInfo = Vk26.DescriptorImageInfo zero weatherView Vk26.IMAGE_LAYOUT_GENERAL
      bufferInfo = Vk26.DescriptorBufferInfo weatherParamsBuffer 0 Vk26.WHOLE_SIZE
      writeImage = Vk26.WriteDescriptorSet () descriptorSet 0 0 1 Vk26.DESCRIPTOR_TYPE_STORAGE_IMAGE (Vector.fromList [imageInfo]) Vector.empty Vector.empty
      writeBuffer = Vk26.WriteDescriptorSet () descriptorSet 1 0 1 Vk26.DESCRIPTOR_TYPE_UNIFORM_BUFFER Vector.empty (Vector.fromList [bufferInfo]) Vector.empty
  liftIO $ Vk26.updateDescriptorSets dev (Vector.fromList (map SomeStruct [writeImage, writeBuffer])) Vector.empty
