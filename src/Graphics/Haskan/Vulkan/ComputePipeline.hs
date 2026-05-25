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
import Vulkan qualified as Vulkan
import Vulkan.Core10 qualified as Vulkan
import Vulkan.Core10.Pipeline (ComputePipelineCreateInfo (..), PipelineShaderStageCreateInfo (..))
import Vulkan.CStruct.Extends (SomeStruct (..))
import Vulkan.Zero (zero)

managedComputePipeline ::
  (MonadManaged m) =>
  Vulkan.Device ->
  Vulkan.PipelineLayout ->
  Vulkan.ShaderModule ->
  m Vulkan.Pipeline
managedComputePipeline dev layout shaderModule =
  alloc
    "ComputePipeline"
    (createComputePipeline dev layout shaderModule)
    (\ptr -> Vulkan.destroyPipeline dev ptr Nothing)

managedComputePipelineWithSpec ::
  (MonadManaged m) =>
  Vulkan.Device ->
  Vulkan.PipelineLayout ->
  Vulkan.ShaderModule ->
  Maybe Vulkan.SpecializationInfo ->
  m Vulkan.Pipeline
managedComputePipelineWithSpec dev layout shaderModule specInfo =
  alloc
    "ComputePipeline"
    (createComputePipelineWithSpec dev layout shaderModule specInfo)
    (\ptr -> Vulkan.destroyPipeline dev ptr Nothing)

createComputePipeline ::
  (MonadIO m) =>
  Vulkan.Device ->
  Vulkan.PipelineLayout ->
  Vulkan.ShaderModule ->
  m Vulkan.Pipeline
createComputePipeline dev layout shaderModule =
  createComputePipelineWithSpec dev layout shaderModule Nothing

createComputePipelineWithSpec ::
  (MonadIO m) =>
  Vulkan.Device ->
  Vulkan.PipelineLayout ->
  Vulkan.ShaderModule ->
  Maybe Vulkan.SpecializationInfo ->
  m Vulkan.Pipeline
createComputePipelineWithSpec dev layout shaderModule specInfo = do
  let stageCreateInfo :: Vulkan.PipelineShaderStageCreateInfo '[]
      stageCreateInfo =
        Vulkan.PipelineShaderStageCreateInfo
          { next = ()
          , flags = zero
          , stage = Vulkan.SHADER_STAGE_COMPUTE_BIT
          , module' = shaderModule
          , name = BC.pack "main"
          , specializationInfo = specInfo
          }
      createInfo :: Vulkan.ComputePipelineCreateInfo '[]
      createInfo =
        Vulkan.ComputePipelineCreateInfo
          { next = ()
          , flags = zero
          , stage = SomeStruct stageCreateInfo
          , layout = layout
          , basePipelineHandle = zero
          , basePipelineIndex = 0
          }
  (_, pipelines) <- liftIO $ Vulkan.createComputePipelines dev (Vulkan.PipelineCache 0) (Vector.fromList [SomeStruct createInfo]) Nothing
  case Vector.toList pipelines of
    [pipeline] -> pure pipeline
    _ -> error "Expected 1 compute pipeline"
