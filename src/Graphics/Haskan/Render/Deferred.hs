{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Render.Deferred
  ( buildDeferredGraph
  , DeferredPassData (..)
  ) where

import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Foldable (for_)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word32)
import Foreign (castPtr)
import Foreign.Marshal.Array qualified
import Foreign.Storable (sizeOf)
import Graphics.Haskan.Render.Graph
import Graphics.Haskan.Render.RenderSystem (DrawCall (..))
import Graphics.Haskan.Vulkan.CommandBuffer qualified as CommandBuffer
import Graphics.Haskan.Vulkan.DescriptorSet qualified as DescriptorSet
import Graphics.Haskan.Vulkan.GraphicsPipeline qualified as GraphicsPipeline
import Graphics.Haskan.Vulkan.RenderPass qualified as RenderPass
import Graphics.Haskan.Vulkan.Resources (BufferResource (..), MeshResource (..), TextureResource (..))
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan


-- | Data needed to build a deferred rendering graph.
data DeferredPassData = DeferredPassData
  { dpdExtent             :: !Vulkan.VkExtent2D
  , dpdGBufferRenderPass  :: !Vulkan.VkRenderPass
  , dpdGBufferFramebuffer :: !Vulkan.VkFramebuffer
  , dpdGBufferPipeline    :: !Vulkan.VkPipeline
  , dpdGBufferLayout      :: !Vulkan.VkPipelineLayout
  , dpdGBufferDescriptor :: !Vulkan.VkDescriptorSet
  , dpdGBufferSampler     :: !Vulkan.VkSampler
  , dpdDrawList           :: ![DrawCall]
  , dpdEntityUniformSize  :: !Int
  , dpdDevice             :: !Vulkan.VkDevice
    -- Lighting pass
  , dpdLightingRenderPass  :: !Vulkan.VkRenderPass
  , dpdLightingFramebuffer :: !Vulkan.VkFramebuffer
  , dpdLightingPipeline    :: !Vulkan.VkPipeline
  , dpdLightingLayout      :: !Vulkan.VkPipelineLayout
  , dpdLightingDescriptor  :: !Vulkan.VkDescriptorSet
    -- G-buffer images for barrier
  , dpdGBufferImages      :: ![Vulkan.VkImage]
    -- Wireframe overlay
  , dpdWireframePipeline  :: !Vulkan.VkPipeline
  , dpdWireframeLayout    :: !Vulkan.VkPipelineLayout
  , dpdWireframeEnabled   :: !Bool
  }

buildDeferredGraph :: DeferredPassData -> RenderGraphBuilder ()
buildDeferredGraph DeferredPassData {..} = do
  -- G-buffer pass: render scene geometry to MRT
  addPass RenderPassNode
    { rpName    = "gbuffer"
    , rpInputs  = []
    , rpOutputs = []
    , rpRecord  = PassRecordFunc $ \ctx -> do
        let commandBuffer = pcCommandBuffer ctx
        RenderPass.withGBufferRenderPass commandBuffer dpdGBufferRenderPass dpdGBufferFramebuffer dpdExtent $ do
          -- Solid geometry pass
          GraphicsPipeline.cmdBindPipeline commandBuffer dpdGBufferPipeline
          -- Bind merged vertex/index buffers once (all entities share them)
          case dpdDrawList of
            [] -> pure ()
            (firstDc:_) -> do
              let firstMesh = dcMesh firstDc
                  vertBuf = brVkBuffer (mrVertexBuffer firstMesh)
                  idxBuf  = brVkBuffer (mrIndexBuffer firstMesh)
              Foreign.Marshal.Array.withArray [vertBuf] $ \bufferPtr ->
                Foreign.Marshal.Array.withArray [0] $ \offsetPtr ->
                  Vulkan.vkCmdBindVertexBuffers commandBuffer 0 1 bufferPtr offsetPtr
              Vulkan.vkCmdBindIndexBuffer commandBuffer idxBuf 0 Vulkan.VK_INDEX_TYPE_UINT32
          -- Draw each entity with its own offset/count/material
          for_ (zip [0..] dpdDrawList) $ \(entityIdx, dc) -> do
            let mesh = dcMesh dc
                idxCnt  = fromIntegral (mrIndexCount mesh)
                firstIdx = fromIntegral (mrFirstIndex mesh)
                vertOff = fromIntegral (mrVertexOffset mesh)
                dynamicOffset = fromIntegral (entityIdx * dpdEntityUniformSize)
                matIdx = dcMaterialIndex dc
            -- Push material index
            liftIO $ Foreign.Marshal.Array.withArray [matIdx] $ \pushPtr ->
              Vulkan.vkCmdPushConstants
                commandBuffer
                dpdGBufferLayout
                Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT
                0
                (fromIntegral (sizeOf matIdx))
                (castPtr pushPtr)
            Foreign.Marshal.Array.withArray [dpdGBufferDescriptor] $ \dsPtr ->
              Foreign.Marshal.Array.withArray [dynamicOffset] $ \dynOffsetPtr ->
                DescriptorSet.cmdBindDescriptorSets
                  commandBuffer
                  Vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS
                  dpdGBufferLayout
                  0
                  1
                  dsPtr
                  1
                  dynOffsetPtr
            CommandBuffer.cmdDraw commandBuffer idxCnt vertOff (fromIntegral entityIdx)
          -- Wireframe overlay pass (same geometry, wireframe pipeline)
          when dpdWireframeEnabled $ do
            GraphicsPipeline.cmdBindPipeline commandBuffer dpdWireframePipeline
            case dpdDrawList of
              [] -> pure ()
              (firstDc:_) -> do
                let firstMesh = dcMesh firstDc
                    vertBuf = brVkBuffer (mrVertexBuffer firstMesh)
                    idxBuf  = brVkBuffer (mrIndexBuffer firstMesh)
                Foreign.Marshal.Array.withArray [vertBuf] $ \bufferPtr ->
                  Foreign.Marshal.Array.withArray [0] $ \offsetPtr ->
                    Vulkan.vkCmdBindVertexBuffers commandBuffer 0 1 bufferPtr offsetPtr
                Vulkan.vkCmdBindIndexBuffer commandBuffer idxBuf 0 Vulkan.VK_INDEX_TYPE_UINT32
            for_ (zip [0..] dpdDrawList) $ \(entityIdx, dc) -> do
              let mesh = dcMesh dc
                  idxCnt  = fromIntegral (mrIndexCount mesh)
                  firstIdx = fromIntegral (mrFirstIndex mesh)
                  vertOff = fromIntegral (mrVertexOffset mesh)
                  dynamicOffset = fromIntegral (entityIdx * dpdEntityUniformSize)
                  matIdx = dcMaterialIndex dc
              -- Push material index for wireframe pass too
              liftIO $ Foreign.Marshal.Array.withArray [matIdx] $ \pushPtr ->
                Vulkan.vkCmdPushConstants
                  commandBuffer
                  dpdWireframeLayout
                  Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT
                  0
                  (fromIntegral (sizeOf matIdx))
                  (castPtr pushPtr)
              Foreign.Marshal.Array.withArray [dpdGBufferDescriptor] $ \dsPtr ->
                Foreign.Marshal.Array.withArray [dynamicOffset] $ \dynOffsetPtr ->
                  DescriptorSet.cmdBindDescriptorSets
                    commandBuffer
                    Vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS
                    dpdWireframeLayout
                    0
                    1
                    dsPtr
                    1
                    dynOffsetPtr
              CommandBuffer.cmdDraw commandBuffer idxCnt vertOff (fromIntegral entityIdx)
    }

  -- Lighting pass: fullscreen triangle compositing
  addPass RenderPassNode
    { rpName    = "lighting"
    , rpInputs  = []
    , rpOutputs = []
    , rpRecord  = PassRecordFunc $ \ctx -> do
        let commandBuffer = pcCommandBuffer ctx
        RenderPass.withLightingRenderPass commandBuffer dpdLightingRenderPass dpdLightingFramebuffer dpdExtent $ do
          GraphicsPipeline.cmdBindPipeline commandBuffer dpdLightingPipeline
          Foreign.Marshal.Array.withArray [dpdLightingDescriptor] $ \dsPtr ->
            DescriptorSet.cmdBindDescriptorSets
              commandBuffer
              Vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS
              dpdLightingLayout
              0
              1
              dsPtr
              0
              Vulkan.vkNullPtr
          -- Fullscreen triangle: 3 vertices, no indices
          Vulkan.vkCmdDraw commandBuffer 3 1 0 0
    }
