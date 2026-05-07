{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Vulkan.DeferredResources
  ( DeferredResources (..)
  , createDeferredResources
  ) where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Foldable (for_)
import Data.Traversable (for)
import Foreign.Marshal.Array qualified
import Graphics.Haskan.Logger (logDebug, logInfo, showT, LogCategory (..))
import Graphics.Haskan.Resources (alloc, allocaAndPeek)
import Graphics.Haskan.Render.ShaderProgram (ShaderProgram (..))
import Graphics.Haskan.Vertex (Vertex)
import Graphics.Haskan.Vertex qualified as Vertex
import Graphics.Haskan.Vulkan.CommandBuffer qualified as CommandBuffer
import Graphics.Haskan.Vulkan.DescriptorPool qualified as DescriptorPool
import Graphics.Haskan.Vulkan.DescriptorSet qualified as DescriptorSet
import Graphics.Haskan.Vulkan.DescriptorSetLayout qualified as DescriptorSetLayout
import Graphics.Haskan.Vulkan.Framebuffer qualified as Framebuffer
import Graphics.Haskan.Vulkan.GraphicsPipeline qualified as GraphicsPipeline
import Graphics.Haskan.Vulkan.ImageView qualified as ImageView
import Graphics.Haskan.Vulkan.PipelineLayout qualified as PipelineLayout
import Graphics.Haskan.Vulkan.RenderPass qualified as RenderPass
import Graphics.Haskan.Vulkan.Swapchain qualified as Swapchain
import Graphics.Haskan.Vulkan.Types (RenderContext (..))
import Graphics.Haskan.Vulkan.VertexFormat qualified as VertexFormat
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan

data DeferredResources = DeferredResources
  { drGBufferRenderPass    :: !Vulkan.VkRenderPass
  , drGBufferPipeline      :: !Vulkan.VkPipeline
  , drGBufferPipelineLayout :: !Vulkan.VkPipelineLayout
  , drGBufferFramebuffers  :: ![Vulkan.VkFramebuffer]
  , drLightingRenderPass   :: !Vulkan.VkRenderPass
  , drLightingPipeline     :: !Vulkan.VkPipeline
  , drLightingPipelineLayout :: !Vulkan.VkPipelineLayout
  , drLightingFramebuffers :: ![Vulkan.VkFramebuffer]
  , drLightingDescriptorSets :: ![Vulkan.VkDescriptorSet]
  , drGBufferImages        :: ![[Vulkan.VkImage]]
  , drGBufferImageViews    :: ![[Vulkan.VkImageView]]
  , drSampler              :: !Vulkan.VkSampler
  }

createDeferredResources ::
  (MonadIO m, MonadManaged m) =>
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  RenderContext ->
  Vulkan.VkDescriptorSetLayout ->
  Vulkan.VkShaderModule ->
  Vulkan.VkShaderModule ->
  Vulkan.VkShaderModule ->
  Vulkan.VkShaderModule ->
  m DeferredResources
createDeferredResources pdev device ctx descriptorSetLayout gbufVertShader gbufFragShader litVertShader litFragShader = do
  let extent = rcSurfaceExtent ctx
      gbufColorFormat = Vulkan.VK_FORMAT_R8G8B8A8_UNORM
      depthFormat = Vulkan.VK_FORMAT_D16_UNORM
      numSwapchainImages = length (rcFramebuffers ctx)

  logInfo LogRender $ "creating deferred resources for " <> showT numSwapchainImages <> " swapchain images"

  -- G-buffer render pass
  gBufferRenderPass <- RenderPass.managedGBufferRenderPass device gbufColorFormat depthFormat
  logDebug LogRender "g-buffer render pass created"

  -- Lighting render pass
  let surfaceFormat = Swapchain.surfaceFormat
  lightingRenderPass <- RenderPass.managedLightingRenderPass device surfaceFormat
  logDebug LogRender "lighting render pass created"

  -- Create g-buffer images and views (3 per swapchain image)
  gBufferImagesAndViews <- for [0..numSwapchainImages-1] $ \_ -> do
    posImage <- Swapchain.managedGBufferImage pdev device extent gbufColorFormat
    normImage <- Swapchain.managedGBufferImage pdev device extent gbufColorFormat
    albImage <- Swapchain.managedGBufferImage pdev device extent gbufColorFormat
    posView <- ImageView.managedImageView device gbufColorFormat posImage
    normView <- ImageView.managedImageView device gbufColorFormat normImage
    albView <- ImageView.managedImageView device gbufColorFormat albImage
    pure ([posImage, normImage, albImage], [posView, normView, albView])

  let gBufferImages = map fst gBufferImagesAndViews
      gBufferImageViews = map snd gBufferImagesAndViews
  logDebug LogRender $ "g-buffer images created: " <> showT (length gBufferImages) <> " sets"

  -- Initial layout transition: UNDEFINED → SHADER_READ_ONLY_OPTIMAL
  -- so that initialLayout in g-buffer render pass matches actual layout.
  tempCmdBuf <- CommandBuffer.createCommandBuffer device (rcGraphicsCommandPool ctx)
  CommandBuffer.withCommandBufferOneTime
    (graphicsQueueHandler ctx)
    tempCmdBuf
    (for_ (concat gBufferImages) $ \img ->
      CommandBuffer.layerTransition tempCmdBuf img Vulkan.VK_IMAGE_LAYOUT_UNDEFINED Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
  liftIO $ Foreign.Marshal.Array.withArray [tempCmdBuf] $ \ptr ->
    Vulkan.vkFreeCommandBuffers device (rcGraphicsCommandPool ctx) 1 ptr
  logDebug LogRender "g-buffer images transitioned to SHADER_READ_ONLY_OPTIMAL"

  -- Shared depth image for g-buffer
  depthImage <- Swapchain.managedDepthImage pdev device extent depthFormat
  depthView <- Swapchain.managedDepthView device depthImage depthFormat
  logDebug LogRender "g-buffer depth image created"

  -- G-buffer framebuffers
  gBufferFramebuffers <- for gBufferImageViews $ \views ->
    Framebuffer.managedGBufferFramebuffer device gBufferRenderPass extent views depthView
  logDebug LogRender $ "g-buffer framebuffers created: " <> showT (length gBufferFramebuffers)

  -- G-buffer pipeline layout (reuse existing descriptor set layout)
  gBufferPipelineLayout <- PipelineLayout.managedPipelineLayout device [descriptorSetLayout]
  logDebug LogRender "g-buffer pipeline layout created"

  -- G-buffer pipeline
  gBufferPipeline <-
    GraphicsPipeline.managedGraphicsPipeline
      device
      gBufferPipelineLayout
      gBufferRenderPass
      ShaderProgram
        { spVertex = gbufVertShader
        , spTessControl = Nothing
        , spTessEvaluation = Nothing
        , spGeometry = Nothing
        , spFragment = gbufFragShader
        }
      extent
      Vertex.vertexFormat
      3
  logDebug LogRender "g-buffer pipeline created"

  -- Lighting pipeline layout (3 texture bindings)
  lightingDescriptorSetLayout <- DescriptorSetLayout.managedLightingDescriptorSetLayout device
  lightingPipelineLayout <- PipelineLayout.managedPipelineLayout device [lightingDescriptorSetLayout]
  logDebug LogRender "lighting pipeline layout created"

  -- Lighting pipeline (fullscreen triangle, no vertex input)
  lightingPipeline <-
    GraphicsPipeline.managedFullscreenPipeline
      device
      lightingPipelineLayout
      lightingRenderPass
      ShaderProgram
        { spVertex = litVertShader
        , spTessControl = Nothing
        , spTessEvaluation = Nothing
        , spGeometry = Nothing
        , spFragment = litFragShader
        }
      extent
  logDebug LogRender "lighting pipeline created"

  -- Lighting framebuffers (one per swapchain image, using swapchain image views)
  swapchainImages <- Swapchain.getSwapchainImages device (swapchain ctx)
  let surfaceFormat' = Vulkan.getField @"format" surfaceFormat
  swapchainImageViews <- for swapchainImages (ImageView.managedImageView device surfaceFormat')
  lightingFramebuffers <- for swapchainImageViews $ \view ->
    Framebuffer.managedLightingFramebuffer device lightingRenderPass extent view
  logDebug LogRender $ "lighting framebuffers created: " <> showT (length lightingFramebuffers)

  -- Lighting descriptor pool and sets
  lightingDescriptorPool <- DescriptorPool.managedLightingDescriptorPool device numSwapchainImages 3
  lightingDescriptorSets <- for [0..numSwapchainImages-1] $ \_ ->
    DescriptorSet.allocateDescriptorSet device lightingDescriptorPool [lightingDescriptorSetLayout]
  logDebug LogRender $ "lighting descriptor sets allocated: " <> showT (length lightingDescriptorSets)

  -- Sampler for lighting pass
  sampler <- createSampler device
  logDebug LogRender "lighting sampler created"

  -- Update lighting descriptor sets with g-buffer views
  liftIO $ for_ (zip lightingDescriptorSets gBufferImageViews) $ \(ds, views) -> do
    DescriptorSet.updateLightingDescriptorSets device ds sampler views
  logDebug LogRender "lighting descriptor sets updated"

  pure DeferredResources
    { drGBufferRenderPass = gBufferRenderPass
    , drGBufferPipeline = gBufferPipeline
    , drGBufferPipelineLayout = gBufferPipelineLayout
    , drGBufferFramebuffers = gBufferFramebuffers
    , drLightingRenderPass = lightingRenderPass
    , drLightingPipeline = lightingPipeline
    , drLightingPipelineLayout = lightingPipelineLayout
    , drLightingFramebuffers = lightingFramebuffers
    , drLightingDescriptorSets = lightingDescriptorSets
    , drGBufferImages = gBufferImages
    , drGBufferImageViews = gBufferImageViews
    , drSampler = sampler
    }

createSampler :: MonadManaged m => Vulkan.VkDevice -> m Vulkan.VkSampler
createSampler dev =
  let createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"magFilter" Vulkan.VK_FILTER_LINEAR
              &* set @"minFilter" Vulkan.VK_FILTER_LINEAR
              &* set @"mipmapMode" Vulkan.VK_SAMPLER_MIPMAP_MODE_LINEAR
              &* set @"addressModeU" Vulkan.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
              &* set @"addressModeV" Vulkan.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
              &* set @"addressModeW" Vulkan.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
              &* set @"mipLodBias" 0.0
              &* set @"anisotropyEnable" Vulkan.VK_FALSE
              &* set @"maxAnisotropy" 1.0
              &* set @"compareEnable" Vulkan.VK_FALSE
              &* set @"compareOp" Vulkan.VK_COMPARE_OP_ALWAYS
              &* set @"minLod" 0.0
              &* set @"maxLod" 0.0
              &* set @"borderColor" Vulkan.VK_BORDER_COLOR_INT_OPAQUE_BLACK
              &* set @"unnormalizedCoordinates" Vulkan.VK_FALSE
          )
   in alloc
        "Sampler"
        (liftIO $ withPtr createInfo (\ciPtr -> allocaAndPeek (Vulkan.vkCreateSampler dev ciPtr Vulkan.vkNullPtr)))
        (\ptr -> Vulkan.vkDestroySampler dev ptr Vulkan.vkNullPtr)

