{-# LANGUAGE OverloadedStrings #-}
module Graphics.Haskan.Vulkan.DescriptorPool
  ( managedDescriptorPool,
    createDescriptorPool,
    managedLightingDescriptorPool,
    createLightingDescriptorPool,
    managedCloudDescriptorPool,
    createCloudDescriptorPool,
    managedGodRayDescriptorPool,
    createGodRayDescriptorPool,
    managedTerrainDescriptorPool,
    createTerrainDescriptorPool,
    managedTerrainMeshDescriptorPool,
    createTerrainMeshDescriptorPool,
    managedAPVolumeDescriptorPool,
    createAPVolumeDescriptorPool,
    managedBindlessDescriptorPool,
    createBindlessDescriptorPool,
    managedComputeDescriptorPool,
    createComputeDescriptorPool,
    managedCubemapComputeDescriptorPool,
    createCubemapComputeDescriptorPool,
    managedCloudNoiseComputeDescriptorPool,
    createCloudNoiseComputeDescriptorPool,
    managedCloudDetailNoiseComputeDescriptorPool,
    createCloudDetailNoiseComputeDescriptorPool,
    managedCloudNoiseMipGenComputeDescriptorPool,
    createCloudNoiseMipGenComputeDescriptorPool,
    managedWeatherMapComputeDescriptorPool,
    createWeatherMapComputeDescriptorPool,
    managedImGuiDescriptorPool,
    createImGuiDescriptorPool,
  )
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Vector qualified as Vector
import Data.Word (Word32)
import Graphics.Haskan.Resources (alloc)
import Vulkan qualified as Vulkan
import Vulkan.Core10 qualified as Vulkan
import Vulkan.Core10.DescriptorSet (DescriptorPoolCreateInfo (..), DescriptorPoolSize (..))
import Vulkan.Core12 qualified as Vulkan12
import Vulkan.Zero (zero)

managedDescriptorPool :: (MonadManaged m) => Vulkan.Device -> Int -> m Vulkan.DescriptorPool
managedDescriptorPool dev imageViewCount =
  alloc
    "DescriptorPool"
    (createDescriptorPool dev imageViewCount)
    (\ptr -> Vulkan.destroyDescriptorPool dev ptr Nothing)

createDescriptorPool :: (MonadIO m) => Vulkan.Device -> Int -> m Vulkan.DescriptorPool
createDescriptorPool dev numSets = do
  let poolSize =
        Vulkan.DescriptorPoolSize
          { type' = Vulkan.DESCRIPTOR_TYPE_UNIFORM_BUFFER
          , descriptorCount = fromIntegral numSets
          }
      samplerPoolSize =
        Vulkan.DescriptorPoolSize
          { type' = Vulkan.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
          , descriptorCount = fromIntegral (numSets * maxBindlessTextures)
          }
      ssboPoolSize =
        Vulkan.DescriptorPoolSize
          { type' = Vulkan.DESCRIPTOR_TYPE_STORAGE_BUFFER
          , descriptorCount = fromIntegral numSets
          }
      createInfo =
        Vulkan.DescriptorPoolCreateInfo
          { next = ()
          , flags = zero
          , maxSets = fromIntegral numSets
          , poolSizes = Vector.fromList [poolSize, samplerPoolSize, ssboPoolSize]
          }
  liftIO $ Vulkan.createDescriptorPool dev createInfo Nothing
  where
    maxBindlessTextures = 1024

managedLightingDescriptorPool :: (MonadManaged m) => Vulkan.Device -> Int -> Int -> m Vulkan.DescriptorPool
managedLightingDescriptorPool dev numSets texturesPerSet =
  alloc
    "LightingDescriptorPool"
    (createLightingDescriptorPool dev numSets texturesPerSet)
    (\ptr -> Vulkan.destroyDescriptorPool dev ptr Nothing)

createLightingDescriptorPool :: (MonadIO m) => Vulkan.Device -> Int -> Int -> m Vulkan.DescriptorPool
createLightingDescriptorPool dev numSets texturesPerSet = do
  let samplerPoolSize =
        Vulkan.DescriptorPoolSize
          { type' = Vulkan.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
          , descriptorCount = fromIntegral (numSets * texturesPerSet)
          }
      ssboPoolSize =
        Vulkan.DescriptorPoolSize
          { type' = Vulkan.DESCRIPTOR_TYPE_STORAGE_BUFFER
          , descriptorCount = fromIntegral numSets
          }
      createInfo =
        Vulkan.DescriptorPoolCreateInfo
          { next = ()
          , flags = zero
          , maxSets = fromIntegral numSets
          , poolSizes = Vector.fromList [samplerPoolSize, ssboPoolSize]
          }
  liftIO $ Vulkan.createDescriptorPool dev createInfo Nothing

managedCloudDescriptorPool :: (MonadManaged m) => Vulkan.Device -> Int -> m Vulkan.DescriptorPool
managedCloudDescriptorPool dev numSets =
  alloc
    "CloudDescriptorPool"
    (createCloudDescriptorPool dev numSets)
    (\ptr -> Vulkan.destroyDescriptorPool dev ptr Nothing)

createCloudDescriptorPool :: (MonadIO m) => Vulkan.Device -> Int -> m Vulkan.DescriptorPool
createCloudDescriptorPool dev numSets = do
  let samplerPoolSize =
        Vulkan.DescriptorPoolSize
          { type' = Vulkan.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
          , descriptorCount = fromIntegral (numSets * 5)
          }
      uboPoolSize =
        Vulkan.DescriptorPoolSize
          { type' = Vulkan.DESCRIPTOR_TYPE_UNIFORM_BUFFER
          , descriptorCount = fromIntegral numSets
          }
      createInfo =
        Vulkan.DescriptorPoolCreateInfo
          { next = ()
          , flags = zero
          , maxSets = fromIntegral numSets
          , poolSizes = Vector.fromList [samplerPoolSize, uboPoolSize]
          }
  liftIO $ Vulkan.createDescriptorPool dev createInfo Nothing

managedGodRayDescriptorPool :: (MonadManaged m) => Vulkan.Device -> Int -> m Vulkan.DescriptorPool
managedGodRayDescriptorPool dev numSets =
  alloc
    "GodRayDescriptorPool"
    (createGodRayDescriptorPool dev numSets)
    (\ptr -> Vulkan.destroyDescriptorPool dev ptr Nothing)

createGodRayDescriptorPool :: (MonadIO m) => Vulkan.Device -> Int -> m Vulkan.DescriptorPool
createGodRayDescriptorPool dev numSets = do
  let samplerPoolSize =
        Vulkan.DescriptorPoolSize
          { type' = Vulkan.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
          , descriptorCount = fromIntegral (numSets * 1)
          }
      createInfo =
        Vulkan.DescriptorPoolCreateInfo
          { next = ()
          , flags = zero
          , maxSets = fromIntegral numSets
          , poolSizes = Vector.fromList [samplerPoolSize]
          }
  liftIO $ Vulkan.createDescriptorPool dev createInfo Nothing

managedTerrainDescriptorPool :: (MonadManaged m) => Vulkan.Device -> Int -> m Vulkan.DescriptorPool
managedTerrainDescriptorPool dev numSets =
  alloc
    "TerrainDescriptorPool"
    (createTerrainDescriptorPool dev numSets)
    (\ptr -> Vulkan.destroyDescriptorPool dev ptr Nothing)

createTerrainDescriptorPool :: (MonadIO m) => Vulkan.Device -> Int -> m Vulkan.DescriptorPool
createTerrainDescriptorPool dev numSets = do
  let samplerPoolSize =
        Vulkan.DescriptorPoolSize
          { type' = Vulkan.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
          , descriptorCount = fromIntegral (numSets * 2)
          }
      uboPoolSize =
        Vulkan.DescriptorPoolSize
          { type' = Vulkan.DESCRIPTOR_TYPE_UNIFORM_BUFFER
          , descriptorCount = fromIntegral numSets
          }
      createInfo =
        Vulkan.DescriptorPoolCreateInfo
          { next = ()
          , flags = zero
          , maxSets = fromIntegral numSets
          , poolSizes = Vector.fromList [samplerPoolSize, uboPoolSize]
          }
  liftIO $ Vulkan.createDescriptorPool dev createInfo Nothing

managedTerrainMeshDescriptorPool :: (MonadManaged m) => Vulkan.Device -> Int -> m Vulkan.DescriptorPool
managedTerrainMeshDescriptorPool dev numSets =
  alloc
    "TerrainMeshDescriptorPool"
    (createTerrainMeshDescriptorPool dev numSets)
    (\ptr -> Vulkan.destroyDescriptorPool dev ptr Nothing)

createTerrainMeshDescriptorPool :: (MonadIO m) => Vulkan.Device -> Int -> m Vulkan.DescriptorPool
createTerrainMeshDescriptorPool dev numSets = do
  let ssboPoolSize =
        Vulkan.DescriptorPoolSize
          { type' = Vulkan.DESCRIPTOR_TYPE_STORAGE_BUFFER
          , descriptorCount = fromIntegral (numSets * 1)
          }
      samplerPoolSize =
        Vulkan.DescriptorPoolSize
          { type' = Vulkan.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
          , descriptorCount = fromIntegral (numSets * 2)
          }
      createInfo =
        Vulkan.DescriptorPoolCreateInfo
          { next = ()
          , flags = zero
          , maxSets = fromIntegral numSets
          , poolSizes = Vector.fromList [ssboPoolSize, samplerPoolSize]
          }
  liftIO $ Vulkan.createDescriptorPool dev createInfo Nothing

managedAPVolumeDescriptorPool :: (MonadManaged m) => Vulkan.Device -> Int -> m Vulkan.DescriptorPool
managedAPVolumeDescriptorPool dev numSets =
  alloc
    "APVolumeDescriptorPool"
    (createAPVolumeDescriptorPool dev numSets)
    (\ptr -> Vulkan.destroyDescriptorPool dev ptr Nothing)

createAPVolumeDescriptorPool :: (MonadIO m) => Vulkan.Device -> Int -> m Vulkan.DescriptorPool
createAPVolumeDescriptorPool dev numSets = do
  let storageImagePoolSize =
        Vulkan.DescriptorPoolSize
          { type' = Vulkan.DESCRIPTOR_TYPE_STORAGE_IMAGE
          , descriptorCount = fromIntegral (numSets * 1)
          }
      samplerPoolSize =
        Vulkan.DescriptorPoolSize
          { type' = Vulkan.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
          , descriptorCount = fromIntegral (numSets * 2)
          }
      uniformBufferPoolSize =
        Vulkan.DescriptorPoolSize
          { type' = Vulkan.DESCRIPTOR_TYPE_UNIFORM_BUFFER
          , descriptorCount = fromIntegral (numSets * 1)
          }
      createInfo =
        Vulkan.DescriptorPoolCreateInfo
          { next = ()
          , flags = zero
          , maxSets = fromIntegral numSets
          , poolSizes = Vector.fromList [storageImagePoolSize, samplerPoolSize, uniformBufferPoolSize]
          }
  liftIO $ Vulkan.createDescriptorPool dev createInfo Nothing

managedBindlessDescriptorPool :: (MonadManaged m) => Vulkan.Device -> Int -> m Vulkan.DescriptorPool
managedBindlessDescriptorPool dev maxTextures =
  alloc
    "BindlessDescriptorPool"
    (createBindlessDescriptorPool dev maxTextures)
    (\ptr -> Vulkan.destroyDescriptorPool dev ptr Nothing)

createBindlessDescriptorPool :: (MonadIO m) => Vulkan.Device -> Int -> m Vulkan.DescriptorPool
createBindlessDescriptorPool dev maxTextures = do
  let samplerPoolSize =
        Vulkan.DescriptorPoolSize
          { type' = Vulkan.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
          , descriptorCount = fromIntegral maxTextures
          }
      createInfo =
        Vulkan.DescriptorPoolCreateInfo
          { next = ()
          , flags = Vulkan12.DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT
          , maxSets = 1
          , poolSizes = Vector.fromList [samplerPoolSize]
          }
  liftIO $ Vulkan.createDescriptorPool dev createInfo Nothing

managedComputeDescriptorPool :: (MonadManaged m) => Vulkan.Device -> m Vulkan.DescriptorPool
managedComputeDescriptorPool dev =
  alloc
    "ComputeDescriptorPool"
    (createComputeDescriptorPool dev)
    (\ptr -> Vulkan.destroyDescriptorPool dev ptr Nothing)

createComputeDescriptorPool :: (MonadIO m) => Vulkan.Device -> m Vulkan.DescriptorPool
createComputeDescriptorPool dev = do
  let ssboPoolSize =
        Vulkan.DescriptorPoolSize
          { type' = Vulkan.DESCRIPTOR_TYPE_STORAGE_BUFFER
          , descriptorCount = 2
          }
      uboPoolSize =
        Vulkan.DescriptorPoolSize
          { type' = Vulkan.DESCRIPTOR_TYPE_UNIFORM_BUFFER
          , descriptorCount = 1
          }
      createInfo =
        Vulkan.DescriptorPoolCreateInfo
          { next = ()
          , flags = zero
          , maxSets = 1
          , poolSizes = Vector.fromList [ssboPoolSize, uboPoolSize]
          }
  liftIO $ Vulkan.createDescriptorPool dev createInfo Nothing

managedCubemapComputeDescriptorPool :: (MonadManaged m) => Vulkan.Device -> m Vulkan.DescriptorPool
managedCubemapComputeDescriptorPool dev =
  alloc
    "CubemapComputeDescriptorPool"
    (createCubemapComputeDescriptorPool dev)
    (\ptr -> Vulkan.destroyDescriptorPool dev ptr Nothing)

createCubemapComputeDescriptorPool :: (MonadIO m) => Vulkan.Device -> m Vulkan.DescriptorPool
createCubemapComputeDescriptorPool dev = do
  let storageImagePoolSize =
        Vulkan.DescriptorPoolSize
          { type' = Vulkan.DESCRIPTOR_TYPE_STORAGE_IMAGE
          , descriptorCount = 2
          }
      uboPoolSize =
        Vulkan.DescriptorPoolSize
          { type' = Vulkan.DESCRIPTOR_TYPE_UNIFORM_BUFFER
          , descriptorCount = 2
          }
      createInfo =
        Vulkan.DescriptorPoolCreateInfo
          { next = ()
          , flags = zero
          , maxSets = 2
          , poolSizes = Vector.fromList [storageImagePoolSize, uboPoolSize]
          }
  liftIO $ Vulkan.createDescriptorPool dev createInfo Nothing

managedCloudNoiseComputeDescriptorPool :: (MonadManaged m) => Vulkan.Device -> m Vulkan.DescriptorPool
managedCloudNoiseComputeDescriptorPool dev =
  alloc
    "CloudNoiseComputeDescriptorPool"
    (createCloudNoiseComputeDescriptorPool dev)
    (\ptr -> Vulkan.destroyDescriptorPool dev ptr Nothing)

createCloudNoiseComputeDescriptorPool :: (MonadIO m) => Vulkan.Device -> m Vulkan.DescriptorPool
createCloudNoiseComputeDescriptorPool dev = do
  let storageImagePoolSize =
        Vulkan.DescriptorPoolSize
          { type' = Vulkan.DESCRIPTOR_TYPE_STORAGE_IMAGE
          , descriptorCount = 1
          }
      uboPoolSize =
        Vulkan.DescriptorPoolSize
          { type' = Vulkan.DESCRIPTOR_TYPE_UNIFORM_BUFFER
          , descriptorCount = 1
          }
      createInfo =
        Vulkan.DescriptorPoolCreateInfo
          { next = ()
          , flags = zero
          , maxSets = 1
          , poolSizes = Vector.fromList [storageImagePoolSize, uboPoolSize]
          }
  liftIO $ Vulkan.createDescriptorPool dev createInfo Nothing

managedCloudDetailNoiseComputeDescriptorPool :: (MonadManaged m) => Vulkan.Device -> m Vulkan.DescriptorPool
managedCloudDetailNoiseComputeDescriptorPool dev =
  alloc
    "CloudDetailNoiseComputeDescriptorPool"
    (createCloudDetailNoiseComputeDescriptorPool dev)
    (\ptr -> Vulkan.destroyDescriptorPool dev ptr Nothing)

createCloudDetailNoiseComputeDescriptorPool :: (MonadIO m) => Vulkan.Device -> m Vulkan.DescriptorPool
createCloudDetailNoiseComputeDescriptorPool dev = do
  let storageImagePoolSize =
        Vulkan.DescriptorPoolSize
          { type' = Vulkan.DESCRIPTOR_TYPE_STORAGE_IMAGE
          , descriptorCount = 1
          }
      uboPoolSize =
        Vulkan.DescriptorPoolSize
          { type' = Vulkan.DESCRIPTOR_TYPE_UNIFORM_BUFFER
          , descriptorCount = 1
          }
      createInfo =
        Vulkan.DescriptorPoolCreateInfo
          { next = ()
          , flags = zero
          , maxSets = 1
          , poolSizes = Vector.fromList [storageImagePoolSize, uboPoolSize]
          }
  liftIO $ Vulkan.createDescriptorPool dev createInfo Nothing

managedWeatherMapComputeDescriptorPool :: (MonadManaged m) => Vulkan.Device -> m Vulkan.DescriptorPool
managedWeatherMapComputeDescriptorPool dev =
  alloc
    "WeatherMapComputeDescriptorPool"
    (createWeatherMapComputeDescriptorPool dev)
    (\ptr -> Vulkan.destroyDescriptorPool dev ptr Nothing)

createWeatherMapComputeDescriptorPool :: (MonadIO m) => Vulkan.Device -> m Vulkan.DescriptorPool
createWeatherMapComputeDescriptorPool dev = do
  let storageImagePoolSize =
        Vulkan.DescriptorPoolSize
          { type' = Vulkan.DESCRIPTOR_TYPE_STORAGE_IMAGE
          , descriptorCount = 1
          }
      uboPoolSize =
        Vulkan.DescriptorPoolSize
          { type' = Vulkan.DESCRIPTOR_TYPE_UNIFORM_BUFFER
          , descriptorCount = 1
          }
      createInfo =
        Vulkan.DescriptorPoolCreateInfo
          { next = ()
          , flags = zero
          , maxSets = 1
          , poolSizes = Vector.fromList [storageImagePoolSize, uboPoolSize]
          }
  liftIO $ Vulkan.createDescriptorPool dev createInfo Nothing

managedCloudNoiseMipGenComputeDescriptorPool :: (MonadManaged m) => Vulkan.Device -> m Vulkan.DescriptorPool
managedCloudNoiseMipGenComputeDescriptorPool dev =
  alloc
    "CloudNoiseMipGenComputeDescriptorPool"
    (createCloudNoiseMipGenComputeDescriptorPool dev)
    (\ptr -> Vulkan.destroyDescriptorPool dev ptr Nothing)

createCloudNoiseMipGenComputeDescriptorPool :: (MonadIO m) => Vulkan.Device -> m Vulkan.DescriptorPool
createCloudNoiseMipGenComputeDescriptorPool dev = do
  let storageImagePoolSize =
        Vulkan.DescriptorPoolSize
          { type' = Vulkan.DESCRIPTOR_TYPE_STORAGE_IMAGE
          , descriptorCount = 8
          }
      uboPoolSize =
        Vulkan.DescriptorPoolSize
          { type' = Vulkan.DESCRIPTOR_TYPE_UNIFORM_BUFFER
          , descriptorCount = 4
          }
      createInfo =
        Vulkan.DescriptorPoolCreateInfo
          { next = ()
          , flags = zero
          , maxSets = 4
          , poolSizes = Vector.fromList [storageImagePoolSize, uboPoolSize]
          }
  liftIO $ Vulkan.createDescriptorPool dev createInfo Nothing

managedImGuiDescriptorPool :: (MonadManaged m) => Vulkan.Device -> m Vulkan.DescriptorPool
managedImGuiDescriptorPool dev =
  alloc
    "ImGuiDescriptorPool"
    (createImGuiDescriptorPool dev)
    (\ptr -> Vulkan.destroyDescriptorPool dev ptr Nothing)

createImGuiDescriptorPool :: (MonadIO m) => Vulkan.Device -> m Vulkan.DescriptorPool
createImGuiDescriptorPool dev = do
  let poolSize t c =
        Vulkan.DescriptorPoolSize
          { type' = t
          , descriptorCount = fromIntegral c
          }
      poolSizes =
        [ poolSize Vulkan.DESCRIPTOR_TYPE_SAMPLER 1000
        , poolSize Vulkan.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER 1000
        , poolSize Vulkan.DESCRIPTOR_TYPE_SAMPLED_IMAGE 1000
        , poolSize Vulkan.DESCRIPTOR_TYPE_STORAGE_IMAGE 1000
        , poolSize Vulkan.DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER 1000
        , poolSize Vulkan.DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER 1000
        , poolSize Vulkan.DESCRIPTOR_TYPE_UNIFORM_BUFFER 1000
        , poolSize Vulkan.DESCRIPTOR_TYPE_STORAGE_BUFFER 1000
        , poolSize Vulkan.DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC 1000
        , poolSize Vulkan.DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC 1000
        , poolSize Vulkan.DESCRIPTOR_TYPE_INPUT_ATTACHMENT 1000
        ]
      createInfo =
        Vulkan.DescriptorPoolCreateInfo
          { next = ()
          , flags = Vulkan.DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT
          , maxSets = 1000
          , poolSizes = Vector.fromList poolSizes
          }
  liftIO $ Vulkan.createDescriptorPool dev createInfo Nothing
