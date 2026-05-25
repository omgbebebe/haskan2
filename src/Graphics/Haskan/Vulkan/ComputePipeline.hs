{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
module Graphics.Haskan.Vulkan.ComputePipeline
  ( managedComputePipeline,
    managedComputePipelineWithSpec,
    createComputePipeline,
    createComputePipelineWithSpec,
  )
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.ByteString.Char8 qualified as BC
import Data.Vector qualified as Vector
import Graphics.Haskan.Resources (alloc)
import Vulkan qualified as Vk26
import Vulkan.Core10 qualified as Vk26
import Vulkan.Core10.Pipeline (ComputePipelineCreateInfo (..), PipelineShaderStageCreateInfo (..))
import Vulkan.CStruct.Extends (SomeStruct (..))
import Vulkan.Zero (zero)

managedComputePipeline ::
  (MonadManaged m) =>
  Vk26.Device ->
  Vk26.PipelineLayout ->
  Vk26.ShaderModule ->
  m Vk26.Pipeline
managedComputePipeline dev layout shaderModule =
  alloc
    "ComputePipeline"
    (createComputePipeline dev layout shaderModule)
    (\ptr -> Vk26.destroyPipeline dev ptr Nothing)

managedComputePipelineWithSpec ::
  (MonadManaged m) =>
  Vk26.Device ->
  Vk26.PipelineLayout ->
  Vk26.ShaderModule ->
  Maybe Vk26.SpecializationInfo ->
  m Vk26.Pipeline
managedComputePipelineWithSpec dev layout shaderModule specInfo =
  alloc
    "ComputePipeline"
    (createComputePipelineWithSpec dev layout shaderModule specInfo)
    (\ptr -> Vk26.destroyPipeline dev ptr Nothing)

createComputePipeline ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.PipelineLayout ->
  Vk26.ShaderModule ->
  m Vk26.Pipeline
createComputePipeline dev layout shaderModule =
  createComputePipelineWithSpec dev layout shaderModule Nothing

createComputePipelineWithSpec ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.PipelineLayout ->
  Vk26.ShaderModule ->
  Maybe Vk26.SpecializationInfo ->
  m Vk26.Pipeline
createComputePipelineWithSpec dev layout shaderModule specInfo = do
  let stageCreateInfo :: Vk26.PipelineShaderStageCreateInfo '[]
      stageCreateInfo =
        Vk26.PipelineShaderStageCreateInfo
          { next = ()
          , flags = zero
          , stage = Vk26.SHADER_STAGE_COMPUTE_BIT
          , module' = shaderModule
          , name = BC.pack "main"
          , specializationInfo = specInfo
          }
      createInfo :: Vk26.ComputePipelineCreateInfo '[]
      createInfo =
        Vk26.ComputePipelineCreateInfo
          { next = ()
          , flags = zero
          , stage = SomeStruct stageCreateInfo
          , layout = layout
          , basePipelineHandle = zero
          , basePipelineIndex = 0
          }
  (_, pipelines) <- liftIO $ Vk26.createComputePipelines dev (Vk26.PipelineCache 0) (Vector.fromList [SomeStruct createInfo]) Nothing
  case Vector.toList pipelines of
    [pipeline] -> pure pipeline
    _ -> error "Expected 1 compute pipeline"
