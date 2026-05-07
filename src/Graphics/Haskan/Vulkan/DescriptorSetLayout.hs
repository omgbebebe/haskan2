module Graphics.Haskan.Vulkan.DescriptorSetLayout where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Graphics.Haskan.Resources (alloc, allocaAndPeek)
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, setListRef, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan

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
      sampler =
        Vulkan.createVk
          ( set @"binding" 1
              &* set @"descriptorCount" 1
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"pImmutableSamplers" Vulkan.VK_NULL
              &* set @"stageFlags" Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT
          )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"bindingCount" 2
              &* setListRef @"pBindings" [binding, sampler]
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorSetLayout dev ciPtr Vulkan.vkNullPtr)
          )
