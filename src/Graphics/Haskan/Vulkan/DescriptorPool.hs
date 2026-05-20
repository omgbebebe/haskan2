module Graphics.Haskan.Vulkan.DescriptorPool
  ( managedDescriptorPool,
    createDescriptorPool,
    managedLightingDescriptorPool,
    createLightingDescriptorPool,
    managedCloudDescriptorPool,
    createCloudDescriptorPool,
    managedGodRayDescriptorPool,
    createGodRayDescriptorPool,
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
    managedWeatherMapComputeDescriptorPool,
    createWeatherMapComputeDescriptorPool,
    managedImGuiDescriptorPool,
    createImGuiDescriptorPool,
  )
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Graphics.Haskan.Resources (alloc, allocaAndPeek)
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Core_1_2 qualified as Vulkan12
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, setListRef, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan

managedDescriptorPool :: (MonadManaged m) => Vulkan.VkDevice -> Int -> m Vulkan.VkDescriptorPool
managedDescriptorPool dev imageViewCount =
  alloc
    "DescriptorPool"
    (createDescriptorPool dev imageViewCount)
    (\ptr -> Vulkan.vkDestroyDescriptorPool dev ptr Vulkan.vkNullPtr)

createDescriptorPool :: (MonadIO m) => Vulkan.VkDevice -> Int -> m Vulkan.VkDescriptorPool
createDescriptorPool dev numSets = do
  let poolSize =
        Vulkan.createVk
          ( set @"type" Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
              &* set @"descriptorCount" (fromIntegral numSets)
          )
      samplerPoolSize =
        Vulkan.createVk
          ( set @"type" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"descriptorCount" (fromIntegral (numSets * maxBindlessTextures))
          )
      ssboPoolSize =
        Vulkan.createVk
          ( set @"type" Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
              &* set @"descriptorCount" (fromIntegral numSets)
          )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"poolSizeCount" 3
              &* setListRef @"pPoolSizes" [poolSize, samplerPoolSize, ssboPoolSize]
              &* set @"maxSets" (fromIntegral numSets)
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorPool dev ciPtr Vulkan.vkNullPtr)
          )
  where
    maxBindlessTextures = 1024

managedLightingDescriptorPool :: (MonadManaged m) => Vulkan.VkDevice -> Int -> Int -> m Vulkan.VkDescriptorPool
managedLightingDescriptorPool dev numSets texturesPerSet =
  alloc
    "LightingDescriptorPool"
    (createLightingDescriptorPool dev numSets texturesPerSet)
    (\ptr -> Vulkan.vkDestroyDescriptorPool dev ptr Vulkan.vkNullPtr)

createLightingDescriptorPool :: (MonadIO m) => Vulkan.VkDevice -> Int -> Int -> m Vulkan.VkDescriptorPool
createLightingDescriptorPool dev numSets texturesPerSet = do
  let samplerPoolSize =
        Vulkan.createVk
          ( set @"type" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"descriptorCount" (fromIntegral (numSets * texturesPerSet))
          )
      ssboPoolSize =
        Vulkan.createVk
          ( set @"type" Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
              &* set @"descriptorCount" (fromIntegral numSets)
          )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"poolSizeCount" 2
              &* setListRef @"pPoolSizes" [samplerPoolSize, ssboPoolSize]
              &* set @"maxSets" (fromIntegral numSets)
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorPool dev ciPtr Vulkan.vkNullPtr)
          )

managedCloudDescriptorPool :: (MonadManaged m) => Vulkan.VkDevice -> Int -> m Vulkan.VkDescriptorPool
managedCloudDescriptorPool dev numSets =
  alloc
    "CloudDescriptorPool"
    (createCloudDescriptorPool dev numSets)
    (\ptr -> Vulkan.vkDestroyDescriptorPool dev ptr Vulkan.vkNullPtr)

createCloudDescriptorPool :: (MonadIO m) => Vulkan.VkDevice -> Int -> m Vulkan.VkDescriptorPool
createCloudDescriptorPool dev numSets = do
  let samplerPoolSize =
        Vulkan.createVk
          ( set @"type" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"descriptorCount" (fromIntegral (numSets * 5))
          )
      uboPoolSize =
        Vulkan.createVk
          ( set @"type" Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
              &* set @"descriptorCount" (fromIntegral numSets)
          )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"poolSizeCount" 2
              &* setListRef @"pPoolSizes" [samplerPoolSize, uboPoolSize]
              &* set @"maxSets" (fromIntegral numSets)
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorPool dev ciPtr Vulkan.vkNullPtr)
          )

managedGodRayDescriptorPool :: (MonadManaged m) => Vulkan.VkDevice -> Int -> m Vulkan.VkDescriptorPool
managedGodRayDescriptorPool dev numSets =
  alloc
    "GodRayDescriptorPool"
    (createGodRayDescriptorPool dev numSets)
    (\ptr -> Vulkan.vkDestroyDescriptorPool dev ptr Vulkan.vkNullPtr)

createGodRayDescriptorPool :: (MonadIO m) => Vulkan.VkDevice -> Int -> m Vulkan.VkDescriptorPool
createGodRayDescriptorPool dev numSets = do
  let samplerPoolSize =
        Vulkan.createVk
          ( set @"type" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"descriptorCount" (fromIntegral (numSets * 1))
          )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"poolSizeCount" 1
              &* setListRef @"pPoolSizes" [samplerPoolSize]
              &* set @"maxSets" (fromIntegral numSets)
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorPool dev ciPtr Vulkan.vkNullPtr)
          )

managedAPVolumeDescriptorPool :: (MonadManaged m) => Vulkan.VkDevice -> Int -> m Vulkan.VkDescriptorPool
managedAPVolumeDescriptorPool dev numSets =
  alloc
    "APVolumeDescriptorPool"
    (createAPVolumeDescriptorPool dev numSets)
    (\ptr -> Vulkan.vkDestroyDescriptorPool dev ptr Vulkan.vkNullPtr)

createAPVolumeDescriptorPool :: (MonadIO m) => Vulkan.VkDevice -> Int -> m Vulkan.VkDescriptorPool
createAPVolumeDescriptorPool dev numSets = do
  let storageImagePoolSize =
        Vulkan.createVk
          ( set @"type" Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE
              &* set @"descriptorCount" (fromIntegral (numSets * 1))
          )
      samplerPoolSize =
        Vulkan.createVk
          ( set @"type" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"descriptorCount" (fromIntegral (numSets * 2))
          )
      uniformBufferPoolSize =
        Vulkan.createVk
          ( set @"type" Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
              &* set @"descriptorCount" (fromIntegral (numSets * 1))
          )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"poolSizeCount" 3
              &* setListRef @"pPoolSizes" [storageImagePoolSize, samplerPoolSize, uniformBufferPoolSize]
              &* set @"maxSets" (fromIntegral numSets)
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorPool dev ciPtr Vulkan.vkNullPtr)
          )

managedBindlessDescriptorPool :: (MonadManaged m) => Vulkan.VkDevice -> Int -> m Vulkan.VkDescriptorPool
managedBindlessDescriptorPool dev maxTextures =
  alloc
    "BindlessDescriptorPool"
    (createBindlessDescriptorPool dev maxTextures)
    (\ptr -> Vulkan.vkDestroyDescriptorPool dev ptr Vulkan.vkNullPtr)

createBindlessDescriptorPool :: (MonadIO m) => Vulkan.VkDevice -> Int -> m Vulkan.VkDescriptorPool
createBindlessDescriptorPool dev maxTextures = do
  let samplerPoolSize =
        Vulkan.createVk
          ( set @"type" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"descriptorCount" (fromIntegral maxTextures)
          )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan12.VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT
              &* set @"poolSizeCount" 1
              &* setListRef @"pPoolSizes" [samplerPoolSize]
              &* set @"maxSets" 1
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorPool dev ciPtr Vulkan.vkNullPtr)
          )

managedComputeDescriptorPool :: (MonadManaged m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorPool
managedComputeDescriptorPool dev =
  alloc
    "ComputeDescriptorPool"
    (createComputeDescriptorPool dev)
    (\ptr -> Vulkan.vkDestroyDescriptorPool dev ptr Vulkan.vkNullPtr)

createComputeDescriptorPool :: (MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorPool
createComputeDescriptorPool dev = do
  let ssboPoolSize =
        Vulkan.createVk
          ( set @"type" Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
              &* set @"descriptorCount" 2
          )
      uboPoolSize =
        Vulkan.createVk
          ( set @"type" Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
              &* set @"descriptorCount" 1
          )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"poolSizeCount" 2
              &* setListRef @"pPoolSizes" [ssboPoolSize, uboPoolSize]
              &* set @"maxSets" 1
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorPool dev ciPtr Vulkan.vkNullPtr)
          )

managedCubemapComputeDescriptorPool :: (MonadManaged m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorPool
managedCubemapComputeDescriptorPool dev =
  alloc
    "CubemapComputeDescriptorPool"
    (createCubemapComputeDescriptorPool dev)
    (\ptr -> Vulkan.vkDestroyDescriptorPool dev ptr Vulkan.vkNullPtr)

createCubemapComputeDescriptorPool :: (MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorPool
createCubemapComputeDescriptorPool dev = do
  let storageImagePoolSize =
        Vulkan.createVk
          ( set @"type" Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE
              &* set @"descriptorCount" 2
          )
      uboPoolSize =
        Vulkan.createVk
          ( set @"type" Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
              &* set @"descriptorCount" 2
          )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"poolSizeCount" 2
              &* setListRef @"pPoolSizes" [storageImagePoolSize, uboPoolSize]
              &* set @"maxSets" 2
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorPool dev ciPtr Vulkan.vkNullPtr)
          )

managedCloudNoiseComputeDescriptorPool :: (MonadManaged m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorPool
managedCloudNoiseComputeDescriptorPool dev =
  alloc
    "CloudNoiseComputeDescriptorPool"
    (createCloudNoiseComputeDescriptorPool dev)
    (\ptr -> Vulkan.vkDestroyDescriptorPool dev ptr Vulkan.vkNullPtr)

createCloudNoiseComputeDescriptorPool :: (MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorPool
createCloudNoiseComputeDescriptorPool dev = do
  let storageImagePoolSize =
        Vulkan.createVk
          ( set @"type" Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE
              &* set @"descriptorCount" 1
          )
      uboPoolSize =
        Vulkan.createVk
          ( set @"type" Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
              &* set @"descriptorCount" 1
          )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"poolSizeCount" 2
              &* setListRef @"pPoolSizes" [storageImagePoolSize, uboPoolSize]
              &* set @"maxSets" 1
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorPool dev ciPtr Vulkan.vkNullPtr)
          )

managedCloudDetailNoiseComputeDescriptorPool :: (MonadManaged m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorPool
managedCloudDetailNoiseComputeDescriptorPool dev =
  alloc
    "CloudDetailNoiseComputeDescriptorPool"
    (createCloudDetailNoiseComputeDescriptorPool dev)
    (\ptr -> Vulkan.vkDestroyDescriptorPool dev ptr Vulkan.vkNullPtr)

createCloudDetailNoiseComputeDescriptorPool :: (MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorPool
createCloudDetailNoiseComputeDescriptorPool dev = do
  let storageImagePoolSize =
        Vulkan.createVk
          ( set @"type" Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE
              &* set @"descriptorCount" 1
          )
      uboPoolSize =
        Vulkan.createVk
          ( set @"type" Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
              &* set @"descriptorCount" 1
          )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"poolSizeCount" 2
              &* setListRef @"pPoolSizes" [storageImagePoolSize, uboPoolSize]
              &* set @"maxSets" 1
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorPool dev ciPtr Vulkan.vkNullPtr)
          )

managedWeatherMapComputeDescriptorPool :: (MonadManaged m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorPool
managedWeatherMapComputeDescriptorPool dev =
  alloc
    "WeatherMapComputeDescriptorPool"
    (createWeatherMapComputeDescriptorPool dev)
    (\ptr -> Vulkan.vkDestroyDescriptorPool dev ptr Vulkan.vkNullPtr)

createWeatherMapComputeDescriptorPool :: (MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorPool
createWeatherMapComputeDescriptorPool dev = do
  let storageImagePoolSize =
        Vulkan.createVk
          ( set @"type" Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE
              &* set @"descriptorCount" 1
          )
      uboPoolSize =
        Vulkan.createVk
          ( set @"type" Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
              &* set @"descriptorCount" 1
          )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"poolSizeCount" 2
              &* setListRef @"pPoolSizes" [storageImagePoolSize, uboPoolSize]
              &* set @"maxSets" 1
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorPool dev ciPtr Vulkan.vkNullPtr)
          )

managedImGuiDescriptorPool :: (MonadManaged m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorPool
managedImGuiDescriptorPool dev =
  alloc
    "ImGuiDescriptorPool"
    (createImGuiDescriptorPool dev)
    (\ptr -> Vulkan.vkDestroyDescriptorPool dev ptr Vulkan.vkNullPtr)

createImGuiDescriptorPool :: (MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorPool
createImGuiDescriptorPool dev = do
  let poolSize t c =
        Vulkan.createVk
          ( set @"type" t
              &* set @"descriptorCount" c
          )
      poolSizes =
        [ poolSize Vulkan.VK_DESCRIPTOR_TYPE_SAMPLER 1000,
          poolSize Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER 1000,
          poolSize Vulkan.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE 1000,
          poolSize Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE 1000,
          poolSize Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER 1000,
          poolSize Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER 1000,
          poolSize Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER 1000,
          poolSize Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER 1000,
          poolSize Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC 1000,
          poolSize Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC 1000,
          poolSize Vulkan.VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT 1000
        ]
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT
              &* set @"poolSizeCount" (fromIntegral (length poolSizes))
              &* setListRef @"pPoolSizes" poolSizes
              &* set @"maxSets" 1000
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorPool dev ciPtr Vulkan.vkNullPtr)
          )
