module Graphics.Haskan.Vulkan.DescriptorSetLayout where

-- base
import Control.Monad.IO.Class (MonadIO, liftIO)

-- managed
import Control.Monad.Managed (MonadManaged)

-- vulkan-api
import qualified Graphics.Vulkan as Vulkan
import qualified Graphics.Vulkan.Core_1_0 as Vulkan
import qualified Graphics.Vulkan.Marshal.Create as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, setListRef, (&*))

-- haskan
import Graphics.Haskan.Resources (alloc, allocaAndPeek)

managedDescriptorSetLayout :: MonadManaged m => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
managedDescriptorSetLayout dev = alloc "DescriptorSetLayout"
  (createDescriptorSetLayout dev)
  (\ptr -> Vulkan.vkDestroyDescriptorSetLayout dev ptr Vulkan.vkNullPtr)

createDescriptorSetLayout :: MonadIO m => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
createDescriptorSetLayout dev = do
  let
    binding = Vulkan.createVk
      (  set @"binding" 0
      &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
      &* set @"descriptorCount" 1
      &* set @"stageFlags" Vulkan.VK_SHADER_STAGE_VERTEX_BIT
      &* set @"pImmutableSamplers" Vulkan.VK_NULL
      )
    sampler = Vulkan.createVk
      (  set @"binding" 1
      &* set @"descriptorCount" 1
      &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
      &* set @"pImmutableSamplers" Vulkan.VK_NULL
      &* set @"stageFlags" Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT
      )
    createInfo = Vulkan.createVk
      (  set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
      &* set @"pNext" Vulkan.VK_NULL
      &* set @"flags" Vulkan.VK_ZERO_FLAGS
      &* set @"bindingCount" 2
      &* setListRef @"pBindings" [ binding, sampler ]
      )
    in liftIO $ withPtr createInfo
       (\ciPtr ->
          allocaAndPeek (Vulkan.vkCreateDescriptorSetLayout dev ciPtr Vulkan.vkNullPtr)
       )
