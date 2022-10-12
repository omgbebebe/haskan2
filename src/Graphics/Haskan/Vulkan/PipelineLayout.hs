module Graphics.Haskan.Vulkan.PipelineLayout where

-- base
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Traversable (for)
import qualified Foreign.Ptr
-- managed
import Control.Monad.Managed (MonadManaged)

-- pretty-simple
import Text.Pretty.Simple

-- vulkan-api
import qualified Graphics.Vulkan as Vulkan
import qualified Graphics.Vulkan.Core_1_0 as Vulkan
import qualified Graphics.Vulkan.Ext as Vulkan
import qualified Graphics.Vulkan.Ext.VK_KHR_surface as Vulkan
import qualified Graphics.Vulkan.Marshal.Create as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, setListRef, setStrListRef, (&*))

-- haskan
import Graphics.Haskan.Resources (alloc, alloc_, allocaAndPeek, allocaAndPeek_, peekVkList, peekVkList_)

managedPipelineLayout :: MonadManaged m => Vulkan.VkDevice -> [Vulkan.VkDescriptorSetLayout] -> m Vulkan.VkPipelineLayout
managedPipelineLayout dev descriptorSetLayouts = alloc "PipelineLayout"
  (createPipelineLayout dev descriptorSetLayouts)
  (\ptr -> Vulkan.vkDestroyPipelineLayout dev ptr Vulkan.vkNullPtr)

createPipelineLayout :: MonadIO m => Vulkan.VkDevice -> [Vulkan.VkDescriptorSetLayout] -> m Vulkan.VkPipelineLayout
createPipelineLayout dev descriptorSetLayouts =
  let
    createInfo = Vulkan.createVk
      (  set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
      &* set @"pNext" Vulkan.VK_NULL
      &* set @"flags" Vulkan.VK_ZERO_FLAGS
      &* set @"setLayoutCount" (fromIntegral (length descriptorSetLayouts))
      &* setListRef @"pSetLayouts" descriptorSetLayouts
      &* set @"pushConstantRangeCount" 0
      &* set @"pPushConstantRanges" Vulkan.VK_NULL
      )
  in liftIO $ withPtr createInfo (\ciPtr -> allocaAndPeek $ Vulkan.vkCreatePipelineLayout dev ciPtr Vulkan.VK_NULL)
