{-# LANGUAGE DuplicateRecordFields #-}

module Graphics.Haskan.Vulkan.PipelineLayout where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Vector qualified as Vector
import Graphics.Haskan.Resources (alloc, alloc_)
import Vulkan qualified
import Vulkan.Zero (zero)

managedPipelineLayout :: (MonadManaged m) => Vulkan.Device -> [Vulkan.DescriptorSetLayout] -> m Vulkan.PipelineLayout
managedPipelineLayout dev descriptorSetLayouts =
  managedPipelineLayoutWithPushConstants dev descriptorSetLayouts []

managedPipelineLayoutWithPushConstants :: (MonadManaged m) => Vulkan.Device -> [Vulkan.DescriptorSetLayout] -> [Vulkan.PushConstantRange] -> m Vulkan.PipelineLayout
managedPipelineLayoutWithPushConstants dev descriptorSetLayouts pushConstantRanges =
  alloc
    "PipelineLayout"
    (createPipelineLayoutWithPushConstants dev descriptorSetLayouts pushConstantRanges)
    (\ptr -> Vulkan.destroyPipelineLayout dev ptr Nothing)

createPipelineLayout :: (MonadIO m) => Vulkan.Device -> [Vulkan.DescriptorSetLayout] -> m Vulkan.PipelineLayout
createPipelineLayout dev descriptorSetLayouts =
  createPipelineLayoutWithPushConstants dev descriptorSetLayouts []

createPipelineLayoutWithPushConstants :: (MonadIO m) => Vulkan.Device -> [Vulkan.DescriptorSetLayout] -> [Vulkan.PushConstantRange] -> m Vulkan.PipelineLayout
createPipelineLayoutWithPushConstants dev descriptorSetLayouts pushConstantRanges =
  let createInfo =
        Vulkan.PipelineLayoutCreateInfo
          { flags = zero
          , setLayouts = Vector.fromList descriptorSetLayouts
          , pushConstantRanges = Vector.fromList pushConstantRanges
          }
   in liftIO $ Vulkan.createPipelineLayout dev createInfo Nothing
