{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Render.Deferred
  ( buildDeferredGraph,
    DeferredPassData (..),
    GBufferPassData (..),
    CloudPassData (..),
    GodRayPassData (..),
    LightingPassData (..),
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

-- | G-buffer pass resources.
data GBufferPassData = GBufferPassData
  { gbpRenderPass :: !Vulkan.VkRenderPass,
    gbpFramebuffer :: !Vulkan.VkFramebuffer,
    gbpPipeline :: !Vulkan.VkPipeline,
    gbpDoubleSidedPipeline :: !Vulkan.VkPipeline,
    gbpLayout :: !Vulkan.VkPipelineLayout,
    gbpDescriptor :: !Vulkan.VkDescriptorSet,
    gbpSampler :: !Vulkan.VkSampler,
    gbpDrawCommandsBuffer :: !Vulkan.VkBuffer,
    gbpEntityCount :: !Word32,
    gbpGBufferImages :: ![Vulkan.VkImage],
    gbpWireframePipeline :: !Vulkan.VkPipeline,
    gbpWireframeLayout :: !Vulkan.VkPipelineLayout,
    gbpWireframeEnabled :: !Bool
  }

-- | Cloud pass resources and parameters.
data CloudPassData = CloudPassData
  { cpRenderPass :: !Vulkan.VkRenderPass,
    cpFramebuffer :: !Vulkan.VkFramebuffer,
    cpPipeline :: !Vulkan.VkPipeline,
    cpLayout :: !Vulkan.VkPipelineLayout,
    cpDescriptor :: !Vulkan.VkDescriptorSet,
    cpExtent :: !Vulkan.VkExtent2D,
    cpImage :: !Vulkan.VkImage,
    cpHistoryImage :: !Vulkan.VkImage,
    cpFrameDataMemory :: !Vulkan.VkDeviceMemory,
    cpCameraPos :: !(V3 Float),
    cpSkyboxRays :: !(V3 Float, V3 Float, V3 Float),
    cpSunDir :: !(V3 Float),
    cpCloudHeight :: !Float,
    cpTime :: !Float,
    cpBlendFactor :: !Float,
    cpWindDirX :: !Float,
    cpWindDirZ :: !Float,
    cpPrevTime :: !Float,
    cpCloudCoverage :: !Float,
    cpCloudDetail :: !Float,
    cpCloudAbsorption :: !Float,
    cpWeatherCoverageScale :: !Float,
    cpWeatherTypeBias :: !Float,
    cpStormIntensity :: !Float,
    cpWeatherAnimSpeed :: !Float,
    cpFrameIndex :: !Int,
    cpDebugMode :: !Word32,
    cpPrevViewProj :: !(M44 Float)
  }

-- | God ray pass resources and parameters.
data GodRayPassData = GodRayPassData
  { grpRenderPass :: !Vulkan.VkRenderPass,
    grpFramebuffer :: !Vulkan.VkFramebuffer,
    grpPipeline :: !Vulkan.VkPipeline,
    grpLayout :: !Vulkan.VkPipelineLayout,
    grpDescriptor :: !Vulkan.VkDescriptorSet,
    grpExtent :: !Vulkan.VkExtent2D,
    grpSunScreenX :: !Float,
    grpSunScreenY :: !Float
  }

-- | Lighting pass resources and parameters.
data LightingPassData = LightingPassData
  { lpRenderPass :: !Vulkan.VkRenderPass,
    lpFramebuffer :: !Vulkan.VkFramebuffer,
    lpPipeline :: !Vulkan.VkPipeline,
    lpLayout :: !Vulkan.VkPipelineLayout,
    lpDescriptor :: !Vulkan.VkDescriptorSet,
    lpCameraPos :: !(V3 Float),
    lpSkyboxRays :: !(V3 Float, V3 Float, V3 Float),
    lpSkyTint :: !(V3 Float),
    lpIBLIntensity :: !Float,
    lpSunAzimuth :: !Float,
    lpSunScreenX :: !Float,
    lpSunScreenY :: !Float,
    lpSunDir :: !(V3 Float),
    lpCloudHeight :: !Float,
    lpTime :: !Float,
    lpDebugMode :: !Word32,
    lpAxisOverlay :: !Float,
    lpGroundPlane :: !Float,
    lpLightCount :: !Word32,
    lpLightBuffer :: !Vulkan.VkBuffer
  }

-- | Data needed to build a deferred rendering graph.
data DeferredPassData = DeferredPassData
  { dpdExtent :: !Vulkan.VkExtent2D,
    dpdDrawList :: ![DrawCall],
    dpdDevice :: !Vulkan.VkDevice,
    dpdGBuffer :: !GBufferPassData,
    dpdCloud :: !CloudPassData,
    dpdGodRay :: !GodRayPassData,
    dpdLighting :: !LightingPassData
  }

buildDeferredGraph :: DeferredPassData -> RenderGraphBuilder ()
buildDeferredGraph DeferredPassData {..} = do
  let GBufferPassData {..} = dpdGBuffer
      CloudPassData {..} = dpdCloud
      GodRayPassData {..} = dpdGodRay
      LightingPassData {..} = dpdLighting
      gbufPosOut = resourceId "gbuffer_position"
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
          RenderPass.withGBufferRenderPass commandBuffer gbpRenderPass gbpFramebuffer dpdExtent $ do
            -- Solid geometry pass: split by doubleSided flag
            let (culledDraws, doubleSidedDraws) = span (not . dcDoubleSided) dpdDrawList
                culledCount = fromIntegral (length culledDraws) :: Word32
                dsCount = fromIntegral (length doubleSidedDraws) :: Word32
            GraphicsPipeline.cmdBindPipeline commandBuffer gbpPipeline
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
            Foreign.Marshal.Array.withArray [gbpDescriptor] $ \dsPtr ->
              DescriptorSet.cmdBindDescriptorSets
                commandBuffer
                Vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS
                gbpLayout
                0
                1
                dsPtr
                0
                Vulkan.vkNullPtr
            -- Draw culled entities (backface culling enabled)
            when (culledCount > 0) $
              CommandBuffer.cmdDrawIndexedIndirect commandBuffer gbpDrawCommandsBuffer culledCount 20
            -- Draw double-sided entities (no culling)
            when (dsCount > 0) $ do
              GraphicsPipeline.cmdBindPipeline commandBuffer gbpDoubleSidedPipeline
              CommandBuffer.cmdDrawIndexedIndirectOffset commandBuffer gbpDrawCommandsBuffer (fromIntegral culledCount * 20) dsCount 20
            -- Wireframe overlay pass
            when gbpWireframeEnabled $ do
              GraphicsPipeline.cmdBindPipeline commandBuffer gbpWireframePipeline
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
              Foreign.Marshal.Array.withArray [gbpDescriptor] $ \dsPtr ->
                DescriptorSet.cmdBindDescriptorSets
                  commandBuffer
                  Vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS
                  gbpWireframeLayout
                  0
                  1
                  dsPtr
                  0
                  Vulkan.vkNullPtr
              -- Single indirect draw for wireframe too
              when (gbpEntityCount > 0) $
                CommandBuffer.cmdDrawIndexedIndirect commandBuffer gbpDrawCommandsBuffer gbpEntityCount 20
      }

  -- Cloud pass: fullscreen triangle ray marching
  addPass
    RenderPassNode
      { rpName = "clouds",
        rpInputs = [],
        rpOutputs = [cloudOut],
        rpRecord = PassRecordFunc $ \ctx -> do
          let commandBuffer = pcCommandBuffer ctx
          RenderPass.withCloudRenderPass commandBuffer cpRenderPass cpFramebuffer cpExtent $ do
            GraphicsPipeline.cmdBindPipeline commandBuffer cpPipeline
            Foreign.Marshal.Array.withArray [cpDescriptor] $ \dsPtr ->
              DescriptorSet.cmdBindDescriptorSets
                commandBuffer
                Vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS
                cpLayout
                0
                1
                dsPtr
                0
                Vulkan.vkNullPtr
            -- Write cloud frame data to UBO (std430 layout)
            let (V3 camX camY camZ) = cpCameraPos
                (V3 r0x r0y r0z, V3 r1x r1y r1z, V3 r2x r2y r2z) = cpSkyboxRays
                (V3 sunDirX sunDirY sunDirZ) = cpSunDir
                (V4 col0 col1 col2 col3) = cpPrevViewProj
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
                    realToFrac cpCloudHeight, -- 76
                    realToFrac cpTime, -- 80
                    realToFrac cpBlendFactor, -- 84
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
                    realToFrac cpWindDirX, -- 160
                    realToFrac cpWindDirZ, -- 164
                    realToFrac cpPrevTime, -- 168
                    realToFrac cpCloudCoverage, -- 172
                    realToFrac cpCloudDetail, -- 176
                    realToFrac cpCloudAbsorption, -- 180
                    realToFrac cpWeatherCoverageScale, -- 184
                    realToFrac cpWeatherTypeBias, -- 188
                    realToFrac cpStormIntensity, -- 192
                    realToFrac cpWeatherAnimSpeed, -- 196
                    realToFrac cpFrameIndex, -- 200
                    realToFrac cpDebugMode, -- 204
                    0 -- 208 pad to 208
                  ] ::
                    [CFloat]
             in liftIO $ Buffer.copyDataToDeviceMemory dpdDevice cpFrameDataMemory cloudFrameData
            Vulkan.vkCmdDraw commandBuffer 3 1 0 0
          -- Copy current cloud result to history buffer for next frame (OUTSIDE render pass)
          CommandBuffer.layerTransition commandBuffer cpImage Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL Vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
          CommandBuffer.layerTransition commandBuffer cpHistoryImage Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
          CommandBuffer.cmdCopyImage commandBuffer cpImage cpHistoryImage (Vulkan.getField @"width" cpExtent) (Vulkan.getField @"height" cpExtent)
          CommandBuffer.layerTransition commandBuffer cpImage Vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
          CommandBuffer.layerTransition commandBuffer cpHistoryImage Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
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
          RenderPass.withCloudRenderPass commandBuffer grpRenderPass grpFramebuffer grpExtent $ do
            GraphicsPipeline.cmdBindPipeline commandBuffer grpPipeline
            Foreign.Marshal.Array.withArray [grpDescriptor] $ \dsPtr ->
              DescriptorSet.cmdBindDescriptorSets
                commandBuffer
                Vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS
                grpLayout
                0
                1
                dsPtr
                0
                Vulkan.vkNullPtr
            -- Push constants for god ray parameters
            let godRayData =
                  [ realToFrac grpSunScreenX,
                    realToFrac grpSunScreenY,
                    1.0, -- intensity
                    32.0, -- numSamples
                    0.97, -- decay
                    1.0, -- density (step size + occlusion per sample)
                    0.4, -- weight
                    1.5, -- exposure
                    0,
                    0,
                    0 -- padding
                  ] ::
                    [CFloat]
             in Foreign.Marshal.Array.withArray godRayData $ Vulkan.vkCmdPushConstants commandBuffer grpLayout Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT 0 (fromIntegral (length godRayData * 4)) . Foreign.castPtr
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
          RenderPass.withLightingRenderPass commandBuffer lpRenderPass lpFramebuffer dpdExtent $ do
            GraphicsPipeline.cmdBindPipeline commandBuffer lpPipeline
            Foreign.Marshal.Array.withArray [lpDescriptor] $ \dsPtr ->
              DescriptorSet.cmdBindDescriptorSets
                commandBuffer
                Vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS
                lpLayout
                0
                1
                dsPtr
                0
                Vulkan.vkNullPtr
            -- Set camera position + debug mode + overlays + skybox rays + sun dir + cloud height push constant
            let (V3 camX camY camZ) = lpCameraPos
                (V3 r0x r0y r0z, V3 r1x r1y r1z, V3 r2x r2y r2z) = lpSkyboxRays
                (V3 tintR tintG tintB) = lpSkyTint
                (V3 sunDirX sunDirY sunDirZ) = lpSunDir
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
                    realToFrac lpDebugMode,
                    realToFrac lpAxisOverlay,
                    realToFrac lpGroundPlane,
                    realToFrac lpSunAzimuth,
                    realToFrac lpLightCount,
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
                    realToFrac lpIBLIntensity,
                    0,
                    realToFrac sunDirX,
                    realToFrac sunDirY,
                    realToFrac sunDirZ,
                    realToFrac lpCloudHeight,
                    realToFrac lpTime,
                    realToFrac lpSunScreenX,
                    realToFrac lpSunScreenY
                  ] ::
                    [CFloat]
             in Foreign.Marshal.Array.withArray camPosData $ Vulkan.vkCmdPushConstants commandBuffer lpLayout (Vulkan.VK_SHADER_STAGE_VERTEX_BIT .|. Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT) 0 124 . Foreign.castPtr
            -- Fullscreen triangle: 3 vertices, no indices
            Vulkan.vkCmdDraw commandBuffer 3 1 0 0
      }
