{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Render.Deferred
  ( buildDeferredGraph,
    DeferredPassData (..),
  )
where

import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Bits ((.|.))
import Data.Foldable (for_)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word32)
import Foreign (castPtr)
import Foreign.C (CFloat)
import Foreign.Marshal.Array qualified
import Foreign.Storable (sizeOf)
import Graphics.Haskan.Render.Graph
import Graphics.Haskan.Render.RenderSystem (DrawCall (..))
import Graphics.Haskan.Vulkan.Buffer qualified as Buffer
import Graphics.Haskan.Vulkan.CommandBuffer qualified as CommandBuffer
import Graphics.Haskan.Vulkan.DescriptorSet qualified as DescriptorSet
import Graphics.Haskan.Vulkan.GraphicsPipeline qualified as GraphicsPipeline
import Graphics.Haskan.Vulkan.RenderPass qualified as RenderPass
import Graphics.Haskan.Vulkan.Resources (BufferResource (..), MeshResource (..), TextureResource (..))
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Linear.Matrix (M44)
import Linear.V3 (V3 (..))
import Linear.V4 (V4 (..))

-- | Data needed to build a deferred rendering graph.
data DeferredPassData = DeferredPassData
  { dpdExtent :: !Vulkan.VkExtent2D,
    dpdGBufferRenderPass :: !Vulkan.VkRenderPass,
    dpdGBufferFramebuffer :: !Vulkan.VkFramebuffer,
    dpdGBufferPipeline :: !Vulkan.VkPipeline,
    dpdGBufferLayout :: !Vulkan.VkPipelineLayout,
    dpdGBufferDescriptor :: !Vulkan.VkDescriptorSet,
    dpdGBufferSampler :: !Vulkan.VkSampler,
    dpdDrawList :: ![DrawCall],
    dpdDevice :: !Vulkan.VkDevice,
    dpdDrawCommandsBuffer :: !Vulkan.VkBuffer,
    dpdEntityCount :: !Word32,
    -- Lighting pass
    dpdLightingRenderPass :: !Vulkan.VkRenderPass,
    dpdLightingFramebuffer :: !Vulkan.VkFramebuffer,
    dpdLightingPipeline :: !Vulkan.VkPipeline,
    dpdLightingLayout :: !Vulkan.VkPipelineLayout,
    dpdLightingDescriptor :: !Vulkan.VkDescriptorSet,
    -- Camera position for lighting shader
    dpdCameraPos :: !(V3 Float),
    -- Skybox ray directions (one per fullscreen triangle vertex)
    dpdSkyboxRays :: !(V3 Float, V3 Float, V3 Float),
    -- Debug mode (0 = normal, 1-11 = debug views)
    dpdDebugMode :: !Word32,
    -- Overlay controls
    dpdAxisOverlay :: !Float,
    dpdGroundPlane :: !Float,
    -- Light data
    dpdLightCount :: !Word32,
    dpdLightBuffer :: !Vulkan.VkBuffer,
    -- Day/night cycle
    dpdSkyTint :: !(V3 Float),
    dpdIBLIntensity :: !Float,
    dpdSunAzimuth :: !Float,
    dpdSunScreenX :: !Float,
    dpdSunScreenY :: !Float,
    dpdSunDir :: !(V3 Float),
    dpdCloudHeight :: !Float,
    dpdTime :: !Float,
    dpdPrevViewProj :: !(M44 Float),
    dpdBlendFactor :: !Float,
    dpdWindDirX :: !Float,
    dpdWindDirZ :: !Float,
    dpdPrevTime :: !Float,
    dpdCloudCoverage :: !Float,
    dpdCloudDetail :: !Float,
    dpdCloudAbsorption :: !Float,
    dpdWeatherCoverageScale :: !Float,
    dpdWeatherTypeBias :: !Float,
    dpdStormIntensity :: !Float,
    dpdWeatherAnimSpeed :: !Float,
    dpdFrameIndex :: !Int,
    dpdCloudFrameDataMemory :: !Vulkan.VkDeviceMemory,
    -- Cloud pass
    dpdCloudRenderPass :: !Vulkan.VkRenderPass,
    dpdCloudFramebuffer :: !Vulkan.VkFramebuffer,
    dpdCloudPipeline :: !Vulkan.VkPipeline,
    dpdCloudLayout :: !Vulkan.VkPipelineLayout,
    dpdCloudDescriptor :: !Vulkan.VkDescriptorSet,
    dpdCloudExtent :: !Vulkan.VkExtent2D,
    dpdCloudImage :: !Vulkan.VkImage,
    dpdCloudHistoryImage :: !Vulkan.VkImage,
    -- God ray pass
    dpdGodRayRenderPass :: !Vulkan.VkRenderPass,
    dpdGodRayFramebuffer :: !Vulkan.VkFramebuffer,
    dpdGodRayPipeline :: !Vulkan.VkPipeline,
    dpdGodRayLayout :: !Vulkan.VkPipelineLayout,
    dpdGodRayDescriptor :: !Vulkan.VkDescriptorSet,
    dpdGodRayExtent :: !Vulkan.VkExtent2D,
    -- G-buffer images for barrier
    dpdGBufferImages :: ![Vulkan.VkImage],
    -- Wireframe overlay
    dpdWireframePipeline :: !Vulkan.VkPipeline,
    dpdWireframeLayout :: !Vulkan.VkPipelineLayout,
    dpdWireframeEnabled :: !Bool
  }

buildDeferredGraph :: DeferredPassData -> RenderGraphBuilder ()
buildDeferredGraph DeferredPassData {..} = do
  let gbufPosOut = resourceId "gbuffer_position"
      gbufNormOut = resourceId "gbuffer_normal"
      gbufAlbedoOut = resourceId "gbuffer_albedo"
      gbufEmissiveOut = resourceId "gbuffer_emissive"
      cloudOut = resourceId "cloud_result"
      litOut = resourceId "lighting_output"
  -- G-buffer pass: render scene geometry to MRT
  addPass
    RenderPassNode
      { rpName = "gbuffer",
        rpInputs = [],
        rpOutputs = [gbufPosOut, gbufNormOut, gbufAlbedoOut, gbufEmissiveOut],
        rpRecord = PassRecordFunc $ \ctx -> do
          let commandBuffer = pcCommandBuffer ctx
          RenderPass.withGBufferRenderPass commandBuffer dpdGBufferRenderPass dpdGBufferFramebuffer dpdExtent $ do
            -- Solid geometry pass
            GraphicsPipeline.cmdBindPipeline commandBuffer dpdGBufferPipeline
            -- Bind merged vertex/index buffers once (all entities share them)
            case dpdDrawList of
              [] -> pure ()
              (firstDc : _) -> do
                let firstMesh = dcMesh firstDc
                    vertBuf = brVkBuffer (mrVertexBuffer firstMesh)
                    idxBuf = brVkBuffer (mrIndexBuffer firstMesh)
                Foreign.Marshal.Array.withArray [vertBuf] $ \bufferPtr ->
                  Foreign.Marshal.Array.withArray [0] $ Vulkan.vkCmdBindVertexBuffers commandBuffer 0 1 bufferPtr
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
                (firstDc : _) -> do
                  let firstMesh = dcMesh firstDc
                      vertBuf = brVkBuffer (mrVertexBuffer firstMesh)
                      idxBuf = brVkBuffer (mrIndexBuffer firstMesh)
                  Foreign.Marshal.Array.withArray [vertBuf] $ \bufferPtr ->
                    Foreign.Marshal.Array.withArray [0] $ Vulkan.vkCmdBindVertexBuffers commandBuffer 0 1 bufferPtr
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

  -- Cloud pass: fullscreen triangle ray marching
  addPass
    RenderPassNode
      { rpName = "clouds",
        rpInputs = [],
        rpOutputs = [cloudOut],
        rpRecord = PassRecordFunc $ \ctx -> do
          let commandBuffer = pcCommandBuffer ctx
          RenderPass.withCloudRenderPass commandBuffer dpdCloudRenderPass dpdCloudFramebuffer dpdCloudExtent $ do
            GraphicsPipeline.cmdBindPipeline commandBuffer dpdCloudPipeline
            Foreign.Marshal.Array.withArray [dpdCloudDescriptor] $ \dsPtr ->
              DescriptorSet.cmdBindDescriptorSets
                commandBuffer
                Vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS
                dpdCloudLayout
                0
                1
                dsPtr
                0
                Vulkan.vkNullPtr
            -- Write cloud frame data to UBO (std430 layout)
            let (V3 camX camY camZ) = dpdCameraPos
                (V3 r0x r0y r0z, V3 r1x r1y r1z, V3 r2x r2y r2z) = dpdSkyboxRays
                (V3 sunDirX sunDirY sunDirZ) = dpdSunDir
                (V4 col0 col1 col2 col3) = dpdPrevViewProj
                (V4 m00 m10 m20 m30) = col0
                (V4 m01 m11 m21 m31) = col1
                (V4 m02 m12 m22 m32) = col2
                (V4 m03 m13 m23 m33) = col3
                cloudFrameData =
                  [ realToFrac camX, -- 0
                    realToFrac camY, -- 4
                    realToFrac camZ, -- 8
                    0, -- 12 pad
                    realToFrac r0x, -- 16
                    realToFrac r0y, -- 20
                    realToFrac r0z, -- 24
                    0, -- 28 pad
                    realToFrac r1x, -- 32
                    realToFrac r1y, -- 36
                    realToFrac r1z, -- 40
                    0, -- 44 pad
                    realToFrac r2x, -- 48
                    realToFrac r2y, -- 52
                    realToFrac r2z, -- 56
                    0, -- 60 pad
                    realToFrac sunDirX, -- 64
                    realToFrac sunDirY, -- 68
                    realToFrac sunDirZ, -- 72
                    realToFrac dpdCloudHeight, -- 76
                    realToFrac dpdTime, -- 80
                    realToFrac dpdBlendFactor, -- 84
                    0,
                    0, -- 88-95: TWO pads for 16-align to 96
                    realToFrac m00, -- 96
                    realToFrac m10, -- 100
                    realToFrac m20, -- 104
                    realToFrac m30, -- 108
                    realToFrac m01, -- 112
                    realToFrac m11, -- 116
                    realToFrac m21, -- 120
                    realToFrac m31, -- 124
                    realToFrac m02, -- 128
                    realToFrac m12, -- 132
                    realToFrac m22, -- 136
                    realToFrac m32, -- 140
                    realToFrac m03, -- 144
                    realToFrac m13, -- 148
                    realToFrac m23, -- 152
                    realToFrac m33, -- 156
                    realToFrac dpdWindDirX, -- 160
                    realToFrac dpdWindDirZ, -- 164
                    realToFrac dpdPrevTime, -- 168
                    realToFrac dpdCloudCoverage, -- 172
                    realToFrac dpdCloudDetail, -- 176
                    realToFrac dpdCloudAbsorption, -- 180
                    realToFrac dpdWeatherCoverageScale, -- 184
                    realToFrac dpdWeatherTypeBias, -- 188
                    realToFrac dpdStormIntensity, -- 192
                     realToFrac dpdWeatherAnimSpeed, -- 196
                     realToFrac dpdFrameIndex, -- 200
                     0,
                     0 -- 204-208 pad to 208
                  ] ::
                    [CFloat]
             in liftIO $ Buffer.copyDataToDeviceMemory dpdDevice dpdCloudFrameDataMemory cloudFrameData
            Vulkan.vkCmdDraw commandBuffer 3 1 0 0
          -- Copy current cloud result to history buffer for next frame (OUTSIDE render pass)
          CommandBuffer.layerTransition commandBuffer dpdCloudImage Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL Vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
          CommandBuffer.layerTransition commandBuffer dpdCloudHistoryImage Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
          CommandBuffer.cmdCopyImage commandBuffer dpdCloudImage dpdCloudHistoryImage (Vulkan.getField @"width" dpdCloudExtent) (Vulkan.getField @"height" dpdCloudExtent)
          CommandBuffer.layerTransition commandBuffer dpdCloudImage Vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
          CommandBuffer.layerTransition commandBuffer dpdCloudHistoryImage Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
      }

  -- God ray pass: radial blur on cloud opacity
  let godRayOut = resourceId "god_ray_result"
  addPass
    RenderPassNode
      { rpName = "godrays",
        rpInputs = [cloudOut],
        rpOutputs = [godRayOut],
        rpRecord = PassRecordFunc $ \ctx -> do
          let commandBuffer = pcCommandBuffer ctx
          RenderPass.withCloudRenderPass commandBuffer dpdGodRayRenderPass dpdGodRayFramebuffer dpdGodRayExtent $ do
            GraphicsPipeline.cmdBindPipeline commandBuffer dpdGodRayPipeline
            Foreign.Marshal.Array.withArray [dpdGodRayDescriptor] $ \dsPtr ->
              DescriptorSet.cmdBindDescriptorSets
                commandBuffer
                Vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS
                dpdGodRayLayout
                0
                1
                dsPtr
                0
                Vulkan.vkNullPtr
            -- Push constants for god ray parameters
            let godRayData =
                  [ realToFrac dpdSunScreenX,
                    realToFrac dpdSunScreenY,
                    1.0,  -- intensity
                    32.0, -- numSamples
                    0.95, -- decay
                    0.02, -- density
                    0.25, -- weight
                    0.25, -- exposure
                    0, 0, 0  -- padding
                  ] ::
                    [CFloat]
             in Foreign.Marshal.Array.withArray godRayData $ Vulkan.vkCmdPushConstants commandBuffer dpdGodRayLayout Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT 0 (fromIntegral (length godRayData * 4)) . Foreign.castPtr
            Vulkan.vkCmdDraw commandBuffer 3 1 0 0
      }

  -- Lighting pass: fullscreen triangle compositing
  addPass
    RenderPassNode
      { rpName = "lighting",
        rpInputs = [gbufPosOut, gbufNormOut, gbufAlbedoOut, gbufEmissiveOut, cloudOut, godRayOut],
        rpOutputs = [litOut],
        rpRecord = PassRecordFunc $ \ctx -> do
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
                -- After cloudHeight(112) → time at 112 (scalar, no pad needed)
                -- After time(116) → sunScreenX at 116, sunScreenY at 120
                -- Total: 31 floats * 4 = 124 bytes
                camPosData =
                  [ realToFrac camX,
                    realToFrac camY,
                    realToFrac camZ,
                    realToFrac dpdDebugMode,
                    realToFrac dpdAxisOverlay,
                    realToFrac dpdGroundPlane,
                    realToFrac dpdSunAzimuth,
                    realToFrac dpdLightCount,
                    realToFrac r0x,
                    realToFrac r0y,
                    realToFrac r0z,
                    0,
                    realToFrac r1x,
                    realToFrac r1y,
                    realToFrac r1z,
                    0,
                    realToFrac r2x,
                    realToFrac r2y,
                    realToFrac r2z,
                    realToFrac tintR,
                    realToFrac tintG,
                    realToFrac tintB,
                    realToFrac dpdIBLIntensity,
                    0,
                    realToFrac sunDirX,
                    realToFrac sunDirY,
                    realToFrac sunDirZ,
                    realToFrac dpdCloudHeight,
                    realToFrac dpdTime,
                    realToFrac dpdSunScreenX,
                    realToFrac dpdSunScreenY
                  ] ::
                    [CFloat]
             in Foreign.Marshal.Array.withArray camPosData $ Vulkan.vkCmdPushConstants commandBuffer dpdLightingLayout (Vulkan.VK_SHADER_STAGE_VERTEX_BIT .|. Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT) 0 124 . Foreign.castPtr
            -- Fullscreen triangle: 3 vertices, no indices
            Vulkan.vkCmdDraw commandBuffer 3 1 0 0
      }
