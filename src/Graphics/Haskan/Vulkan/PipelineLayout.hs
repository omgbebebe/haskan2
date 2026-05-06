module Graphics.Haskan.Vulkan.PipelineLayout where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Traversable (for)
import Foreign.Ptr qualified
import Graphics.Haskan.Resources (alloc, alloc_, allocaAndPeek, allocaAndPeek_, peekVkList, peekVkList_)
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Ext qualified as Vulkan
import Graphics.Vulkan.Ext.VK_KHR_surface qualified as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, setListRef, setStrListRef, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan

managedPipelineLayout :: MonadManaged m => Vulkan.VkDevice -> [Vulkan.VkDescriptorSetLayout] -> m Vulkan.VkPipelineLayout
managedPipelineLayout dev descriptorSetLayouts =
  alloc
    "PipelineLayout"
    (createPipelineLayout dev descriptorSetLayouts)
    (\ptr -> Vulkan.vkDestroyPipelineLayout dev ptr Vulkan.vkNullPtr)

createPipelineLayout :: MonadIO m => Vulkan.VkDevice -> [Vulkan.VkDescriptorSetLayout] -> m Vulkan.VkPipelineLayout
createPipelineLayout dev descriptorSetLayouts =
  let createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"setLayoutCount" (fromIntegral (length descriptorSetLayouts))
              &* setListRef @"pSetLayouts" descriptorSetLayouts
              &* set @"pushConstantRangeCount" 0
              &* set @"pPushConstantRanges" Vulkan.VK_NULL
          )
   in liftIO $ withPtr createInfo (\ciPtr -> allocaAndPeek $ Vulkan.vkCreatePipelineLayout dev ciPtr Vulkan.VK_NULL)
