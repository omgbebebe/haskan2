module Graphics.Haskan.Vulkan.DescriptorPool
  ( managedDescriptorPool,
    createDescriptorPool,
    managedLightingDescriptorPool,
    createLightingDescriptorPool,
    managedBindlessDescriptorPool,
    createBindlessDescriptorPool,
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

managedDescriptorPool :: MonadManaged m => Vulkan.VkDevice -> Int -> m Vulkan.VkDescriptorPool
managedDescriptorPool dev imageViewCount =
  alloc
    "DescriptorPool"
    (createDescriptorPool dev imageViewCount)
    (\ptr -> Vulkan.vkDestroyDescriptorPool dev ptr Vulkan.vkNullPtr)

createDescriptorPool :: MonadIO m => Vulkan.VkDevice -> Int -> m Vulkan.VkDescriptorPool
createDescriptorPool dev imageViewCount = do
  let poolSize =
        Vulkan.createVk
          ( set @"type" Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC
              &* set @"descriptorCount" (fromIntegral imageViewCount)
          )
      samplerPoolSize =
        Vulkan.createVk
          ( set @"type" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"descriptorCount" (fromIntegral imageViewCount)
          )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"poolSizeCount" 2
              &* setListRef @"pPoolSizes" [poolSize, samplerPoolSize]
              &* set @"maxSets" (fromIntegral imageViewCount)
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorPool dev ciPtr Vulkan.vkNullPtr)
          )

managedLightingDescriptorPool :: MonadManaged m => Vulkan.VkDevice -> Int -> Int -> m Vulkan.VkDescriptorPool
managedLightingDescriptorPool dev numSets texturesPerSet =
  alloc
    "LightingDescriptorPool"
    (createLightingDescriptorPool dev numSets texturesPerSet)
    (\ptr -> Vulkan.vkDestroyDescriptorPool dev ptr Vulkan.vkNullPtr)

createLightingDescriptorPool :: MonadIO m => Vulkan.VkDevice -> Int -> Int -> m Vulkan.VkDescriptorPool
createLightingDescriptorPool dev numSets texturesPerSet = do
  let samplerPoolSize =
        Vulkan.createVk
          ( set @"type" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"descriptorCount" (fromIntegral (numSets * texturesPerSet))
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

managedBindlessDescriptorPool :: MonadManaged m => Vulkan.VkDevice -> Int -> m Vulkan.VkDescriptorPool
managedBindlessDescriptorPool dev maxTextures =
  alloc
    "BindlessDescriptorPool"
    (createBindlessDescriptorPool dev maxTextures)
    (\ptr -> Vulkan.vkDestroyDescriptorPool dev ptr Vulkan.vkNullPtr)

createBindlessDescriptorPool :: MonadIO m => Vulkan.VkDevice -> Int -> m Vulkan.VkDescriptorPool
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
