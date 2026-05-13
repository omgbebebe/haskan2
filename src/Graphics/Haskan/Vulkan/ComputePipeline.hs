module Graphics.Haskan.Vulkan.ComputePipeline
  ( managedComputePipeline,
    createComputePipeline,
  )
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Graphics.Haskan.Resources (alloc, allocaAndPeek)
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, setStrRef, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan

managedComputePipeline ::
  (MonadManaged m) =>
  Vulkan.VkDevice ->
  Vulkan.VkPipelineLayout ->
  Vulkan.VkShaderModule ->
  m Vulkan.VkPipeline
managedComputePipeline dev layout shaderModule =
  alloc
    "ComputePipeline"
    (createComputePipeline dev layout shaderModule)
    (\ptr -> Vulkan.vkDestroyPipeline dev ptr Vulkan.vkNullPtr)

createComputePipeline ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkPipelineLayout ->
  Vulkan.VkShaderModule ->
  m Vulkan.VkPipeline
createComputePipeline dev layout shaderModule = do
  let stageCreateInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"stage" Vulkan.VK_SHADER_STAGE_COMPUTE_BIT
              &* set @"module" shaderModule
              &* setStrRef @"pName" "main"
              &* set @"pSpecializationInfo" Vulkan.VK_NULL
          )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"stage" stageCreateInfo
              &* set @"layout" layout
              &* set @"basePipelineHandle" Vulkan.VK_NULL_HANDLE
              &* set @"basePipelineIndex" 0
          )
  liftIO $
    withPtr
      createInfo
      ( \ciPtr ->
          allocaAndPeek (Vulkan.vkCreateComputePipelines dev Vulkan.VK_NULL_HANDLE 1 ciPtr Vulkan.vkNullPtr)
      )
