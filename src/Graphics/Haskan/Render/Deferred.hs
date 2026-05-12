{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Render.Deferred
  ( buildDeferredGraph
  , DeferredPassData (..)
  ) where

import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Bits ((.|.))
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
import Foreign.C (CFloat)
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Linear.V3 (V3(..))


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
  , dpdDevice             :: !Vulkan.VkDevice
  , dpdDrawCommandsBuffer :: !Vulkan.VkBuffer
  , dpdEntityCount        :: !Word32
    -- Lighting pass
  , dpdLightingRenderPass  :: !Vulkan.VkRenderPass
  , dpdLightingFramebuffer :: !Vulkan.VkFramebuffer
  , dpdLightingPipeline    :: !Vulkan.VkPipeline
  , dpdLightingLayout      :: !Vulkan.VkPipelineLayout
  , dpdLightingDescriptor  :: !Vulkan.VkDescriptorSet
    -- Camera position for lighting shader
  , dpdCameraPos          :: !(V3 Float)
    -- Skybox ray directions (one per fullscreen triangle vertex)
  , dpdSkyboxRays         :: !(V3 Float, V3 Float, V3 Float)
    -- Debug mode (0 = normal, 1-11 = debug views)
  , dpdDebugMode          :: !Word32
    -- Overlay controls
  , dpdAxisOverlay        :: !Float
  , dpdGroundPlane        :: !Float
    -- Light data
  , dpdLightCount         :: !Word32
  , dpdLightBuffer        :: !Vulkan.VkBuffer
    -- Day/night cycle
  , dpdSkyTint            :: !(V3 Float)
  , dpdIBLIntensity       :: !Float
  , dpdSunAzimuth         :: !Float
  , dpdSunDir             :: !(V3 Float)
  , dpdCloudHeight        :: !Float
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
          -- Bind descriptor set once (no dynamic offsets)
          Foreign.Marshal.Array.withArray [dpdGBufferDescriptor] $ \dsPtr ->
            DescriptorSet.cmdBindDescriptorSets
              commandBuffer
              Vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS
              dpdGBufferLayout
              0
              1
              dsPtr
              0
              Vulkan.vkNullPtr
          -- Single indirect draw call for all entities
          when (dpdEntityCount > 0) $
            CommandBuffer.cmdDrawIndexedIndirect commandBuffer dpdDrawCommandsBuffer dpdEntityCount 20
          -- Wireframe overlay pass
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
            -- Bind descriptor set for wireframe (shares layout)
            Foreign.Marshal.Array.withArray [dpdGBufferDescriptor] $ \dsPtr ->
              DescriptorSet.cmdBindDescriptorSets
                commandBuffer
                Vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS
                dpdWireframeLayout
                0
                1
                dsPtr
                0
                Vulkan.vkNullPtr
            -- Single indirect draw for wireframe too
            when (dpdEntityCount > 0) $
              CommandBuffer.cmdDrawIndexedIndirect commandBuffer dpdDrawCommandsBuffer dpdEntityCount 20
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
          -- Set camera position + debug mode + overlays + skybox rays + sun dir + cloud height push constant
          let (V3 camX camY camZ) = dpdCameraPos
              (V3 r0x r0y r0z, V3 r1x r1y r1z, V3 r2x r2y r2z) = dpdSkyboxRays
              (V3 tintR tintG tintB) = dpdSkyTint
              (V3 sunDirX sunDirY sunDirZ) = dpdSunDir
              -- std430: vec3 has size 12 (NOT padded to 16). Pad only for next vec3 alignment.
              -- After ray2(76) → skyTintR at 76 (scalar, no pad needed)
              -- After iblInt(92) → sunDir needs 16-align → pad 1 float → sunDir at 96
              -- After sunDir(108) → cloudHeight at 108 (scalar, no pad needed)
              -- Total: 28 floats * 4 = 112 bytes
              camPosData = [ realToFrac camX, realToFrac camY, realToFrac camZ, realToFrac dpdDebugMode
                           , realToFrac dpdAxisOverlay, realToFrac dpdGroundPlane, realToFrac dpdSunAzimuth, realToFrac dpdLightCount
                           , realToFrac r0x, realToFrac r0y, realToFrac r0z, 0
                           , realToFrac r1x, realToFrac r1y, realToFrac r1z, 0
                           , realToFrac r2x, realToFrac r2y, realToFrac r2z
                           , realToFrac tintR, realToFrac tintG, realToFrac tintB, realToFrac dpdIBLIntensity
                           , 0
                           , realToFrac sunDirX, realToFrac sunDirY, realToFrac sunDirZ
                           , realToFrac dpdCloudHeight
                           ] :: [CFloat]
           in Foreign.Marshal.Array.withArray camPosData $ \camPtr ->
             Vulkan.vkCmdPushConstants commandBuffer dpdLightingLayout (Vulkan.VK_SHADER_STAGE_VERTEX_BIT .|. Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT) 0 112 (Foreign.castPtr camPtr)
          -- Fullscreen triangle: 3 vertices, no indices
          Vulkan.vkCmdDraw commandBuffer 3 1 0 0
    }
