module Graphics.Haskan.Vulkan.DescriptorSetLayout
  ( managedDescriptorSetLayout,
    createDescriptorSetLayout,
    managedLightingDescriptorSetLayout,
    createLightingDescriptorSetLayout,
    managedBindlessDescriptorSetLayout,
    createBindlessDescriptorSetLayout,
    maxBindlessTextures,
  )
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Bits ((.|.))
import Foreign (castPtr)
import Graphics.Haskan.Resources (alloc, allocaAndPeek)
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Core_1_2 qualified as Vulkan12
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, setListRef, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan

maxBindlessTextures :: Int
maxBindlessTextures = 1024

managedDescriptorSetLayout :: MonadManaged m => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
managedDescriptorSetLayout dev =
  alloc
    "DescriptorSetLayout"
    (createDescriptorSetLayout dev)
    (\ptr -> Vulkan.vkDestroyDescriptorSetLayout dev ptr Vulkan.vkNullPtr)

createDescriptorSetLayout :: MonadIO m => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
createDescriptorSetLayout dev = do
  let binding =
        Vulkan.createVk
          ( set @"binding" 0
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC
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
      -- Binding flags for binding 1: partially bound (allows unused descriptors in array)
      bindingFlags :: Vulkan12.VkDescriptorBindingFlags
      bindingFlags = Vulkan12.VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT
      bindingFlagsCreateInfo :: Vulkan12.VkDescriptorSetLayoutBindingFlagsCreateInfo
      bindingFlagsCreateInfo = Vulkan.createVk
        ( set @"sType" Vulkan12.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO
            &* set @"pNext" Vulkan.VK_NULL
            &* set @"bindingCount" 2
            &* setListRef @"pBindingFlags" [Vulkan.VK_ZERO_FLAGS, bindingFlags]  -- binding 0: no flags, binding 1: partially bound
        )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
              &* set @"pNext" (castPtr $ Vulkan.unsafePtr bindingFlagsCreateInfo)
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"bindingCount" 2
              &* setListRef @"pBindings" [binding, textureBinding]
          )
   in liftIO $ withPtr bindingFlagsCreateInfo $ \_bfcPtr ->
        withPtr createInfo $ \ciPtr ->
          allocaAndPeek (Vulkan.vkCreateDescriptorSetLayout dev ciPtr Vulkan.vkNullPtr)

managedLightingDescriptorSetLayout :: MonadManaged m => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
managedLightingDescriptorSetLayout dev =
  alloc
    "LightingDescriptorSetLayout"
    (createLightingDescriptorSetLayout dev)
    (\ptr -> Vulkan.vkDestroyDescriptorSetLayout dev ptr Vulkan.vkNullPtr)

createLightingDescriptorSetLayout :: MonadIO m => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
createLightingDescriptorSetLayout dev = do
  let mkSamplerBinding bindingIdx =
        Vulkan.createVk
          ( set @"binding" bindingIdx
              &* set @"descriptorCount" 1
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"pImmutableSamplers" Vulkan.VK_NULL
              &* set @"stageFlags" Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT
          )
      bindings = map mkSamplerBinding [0, 1, 2]
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

-- | Bindless descriptor set layout: one array of textures with
-- UPDATE_AFTER_BIND + PARTIALLY_BOUND.
managedBindlessDescriptorSetLayout :: MonadManaged m => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
managedBindlessDescriptorSetLayout dev =
  alloc
    "BindlessDescriptorSetLayout"
    (createBindlessDescriptorSetLayout dev)
    (\ptr -> Vulkan.vkDestroyDescriptorSetLayout dev ptr Vulkan.vkNullPtr)

createBindlessDescriptorSetLayout :: MonadIO m => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
createBindlessDescriptorSetLayout dev = do
  let textureBinding =
        Vulkan.createVk
          ( set @"binding" 0
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"descriptorCount" (fromIntegral maxBindlessTextures)
              &* set @"stageFlags" Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT
              &* set @"pImmutableSamplers" Vulkan.VK_NULL
          )
      -- Binding flags: partially bound + update after bind
      bindingFlags :: Vulkan12.VkDescriptorBindingFlags
      bindingFlags = Vulkan12.VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT
                     .|. Vulkan12.VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT
      bindingFlagsCreateInfo :: Vulkan12.VkDescriptorSetLayoutBindingFlagsCreateInfo
      bindingFlagsCreateInfo = Vulkan.createVk
        ( set @"sType" Vulkan12.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO
            &* set @"pNext" Vulkan.VK_NULL
            &* set @"bindingCount" 1
            &* setListRef @"pBindingFlags" [bindingFlags]
        )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
              &* set @"pNext" (castPtr $ Vulkan.unsafePtr bindingFlagsCreateInfo)
              &* set @"flags" Vulkan12.VK_DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT
              &* set @"bindingCount" 1
              &* setListRef @"pBindings" [textureBinding]
          )
   in liftIO $ withPtr bindingFlagsCreateInfo $ \_bfcPtr ->
        withPtr createInfo $ \ciPtr ->
          allocaAndPeek (Vulkan.vkCreateDescriptorSetLayout dev ciPtr Vulkan.vkNullPtr)
