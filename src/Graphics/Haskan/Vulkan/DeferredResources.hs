{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Vulkan.DeferredResources
  ( DeferredResources (..)
  , createDeferredResources
  ) where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Bits ((.|.))
import Data.Foldable (for_)
import Data.Traversable (for)
import Foreign.Marshal.Array qualified
import Graphics.Haskan.Logger (logDebugIO, logInfoIO, showT, LogCategory (..))
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
  , drWireframePipeline    :: !Vulkan.VkPipeline
  , drWireframePipelineLayout :: !Vulkan.VkPipelineLayout
  }

createDeferredResources ::
  (MonadIO m, MonadManaged m) =>
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  RenderContext ->
  Vulkan.VkDescriptorSetLayout ->
  [Vulkan.VkPushConstantRange] ->
  Vulkan.VkShaderModule ->
  Vulkan.VkShaderModule ->
  Vulkan.VkShaderModule ->
  Vulkan.VkShaderModule ->
  Vulkan.VkShaderModule ->
  Vulkan.VkShaderModule ->
  Vulkan.VkShaderModule ->
  Maybe Vulkan.VkImageView -> -- ^ env cubemap view
  Maybe Vulkan.VkImageView -> -- ^ irradiance cubemap view
  Maybe Vulkan.VkImageView -> -- ^ brdf lut view
  Vulkan.VkSampler -> -- ^ lighting sampler
  m DeferredResources
createDeferredResources pdev device ctx descriptorSetLayout pushConstantRanges gbufVertShader gbufFragShader litVertShader litFragShader wireVertShader wireGeomShader wireFragShader mEnvMapView mIrradianceView mBrdfView sampler = do
  let extent = rcSurfaceExtent ctx
      gbufPosFormat = Vulkan.VK_FORMAT_R16G16B16A16_SFLOAT  -- position needs negative values
      gbufColorFormat = Vulkan.VK_FORMAT_R8G8B8A8_UNORM      -- normal, albedo, emissive
      depthFormat = Vulkan.VK_FORMAT_D32_SFLOAT
      numSwapchainImages = length (rcFramebuffers ctx)

  logInfoIO LogRender $ "creating deferred resources for " <> showT numSwapchainImages <> " swapchain images"

  -- G-buffer render pass (position=SFLOAT, others=UNORM)
  gBufferRenderPass <- RenderPass.managedGBufferRenderPassEx device gbufPosFormat gbufColorFormat depthFormat
  logDebugIO LogRender "g-buffer render pass created"

  -- Lighting render pass
  let surfaceFormat = Swapchain.surfaceFormat
  lightingRenderPass <- RenderPass.managedLightingRenderPass device surfaceFormat
  logDebugIO LogRender "lighting render pass created"

  -- Create g-buffer images and views (4 per swapchain image: position=SFLOAT, normal=UNORM, albedo=UNORM, emissive=UNORM)
  gBufferImagesAndViews <- for [0..numSwapchainImages-1] $ \_ -> do
    posImage <- Swapchain.managedGBufferImage pdev device extent gbufPosFormat
    normImage <- Swapchain.managedGBufferImage pdev device extent gbufColorFormat
    albImage <- Swapchain.managedGBufferImage pdev device extent gbufColorFormat
    matImage <- Swapchain.managedGBufferImage pdev device extent gbufColorFormat
    posView <- ImageView.managedImageView device gbufPosFormat posImage
    normView <- ImageView.managedImageView device gbufColorFormat normImage
    albView <- ImageView.managedImageView device gbufColorFormat albImage
    matView <- ImageView.managedImageView device gbufColorFormat matImage
    pure ([posImage, normImage, albImage, matImage], [posView, normView, albView, matView])

  let gBufferImages = map fst gBufferImagesAndViews
      gBufferImageViews = map snd gBufferImagesAndViews
  logDebugIO LogRender $ "g-buffer images created: " <> showT (length gBufferImages) <> " sets"

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
  logDebugIO LogRender "g-buffer images transitioned to SHADER_READ_ONLY_OPTIMAL"

  -- Shared depth image for g-buffer
  depthImage <- Swapchain.managedDepthImage pdev device extent depthFormat
  depthView <- Swapchain.managedDepthView device depthImage depthFormat
  logDebugIO LogRender "g-buffer depth image created"

  -- G-buffer framebuffers
  gBufferFramebuffers <- for gBufferImageViews $ \views ->
    Framebuffer.managedGBufferFramebuffer device gBufferRenderPass extent views depthView
  logDebugIO LogRender $ "g-buffer framebuffers created: " <> showT (length gBufferFramebuffers)

  -- G-buffer pipeline layout (reuse existing descriptor set layout, with push constants)
  gBufferPipelineLayout <- PipelineLayout.managedPipelineLayoutWithPushConstants device [descriptorSetLayout] pushConstantRanges
  logDebugIO LogRender "g-buffer pipeline layout created"

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
      4
  logDebugIO LogRender "g-buffer pipeline created"

  -- Lighting pipeline layout (6 texture bindings + camera push constant)
  lightingDescriptorSetLayout <- DescriptorSetLayout.managedLightingDescriptorSetLayout device
  let cameraPushConstantRange =
        Vulkan.createVk
          ( set @"stageFlags" (Vulkan.VK_SHADER_STAGE_VERTEX_BIT .|. Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT)
              &* set @"offset" 0
              &* set @"size" 80
          )
  lightingPipelineLayout <- PipelineLayout.managedPipelineLayoutWithPushConstants device [lightingDescriptorSetLayout] [cameraPushConstantRange]
  logDebugIO LogRender "lighting pipeline layout created"

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
  logDebugIO LogRender "lighting pipeline created"

  -- Wireframe pipeline (vertex + geometry + fragment)
  wireframePipeline <-
    GraphicsPipeline.managedGraphicsPipeline
      device
      gBufferPipelineLayout
      gBufferRenderPass
      ShaderProgram
        { spVertex = wireVertShader
        , spTessControl = Nothing
        , spTessEvaluation = Nothing
        , spGeometry = Just wireGeomShader
        , spFragment = wireFragShader
        }
      extent
      Vertex.vertexFormat
      4
  logDebugIO LogRender "wireframe pipeline created"

  -- Lighting framebuffers (one per swapchain image, using swapchain image views)
  swapchainImages <- Swapchain.getSwapchainImages device (swapchain ctx)
  let surfaceFormat' = Vulkan.getField @"format" surfaceFormat
  swapchainImageViews <- for swapchainImages (ImageView.managedImageView device surfaceFormat')
  lightingFramebuffers <- for swapchainImageViews $ \view ->
    Framebuffer.managedLightingFramebuffer device lightingRenderPass extent view
  logDebugIO LogRender $ "lighting framebuffers created: " <> showT (length lightingFramebuffers)

  -- Lighting descriptor pool and sets
  lightingDescriptorPool <- DescriptorPool.managedLightingDescriptorPool device numSwapchainImages 7
  lightingDescriptorSets <- for [0..numSwapchainImages-1] $ \_ ->
    DescriptorSet.allocateDescriptorSet device lightingDescriptorPool [lightingDescriptorSetLayout]
  logDebugIO LogRender $ "lighting descriptor sets allocated: " <> showT (length lightingDescriptorSets)

  -- Update lighting descriptor sets with g-buffer views + cubemaps + brdf lut
  liftIO $ for_ (zip lightingDescriptorSets gBufferImageViews) $ \(ds, views) -> do
    let allViews = case (mEnvMapView, mIrradianceView, mBrdfView) of
                     (Just env, Just irr, Just brdf) -> views ++ [env, irr, brdf]
                     _ -> views ++ (replicate 3 Vulkan.VK_NULL_HANDLE)
    DescriptorSet.updateLightingDescriptorSets device ds sampler allViews
  logDebugIO LogRender "lighting descriptor sets updated"

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
    , drWireframePipeline = wireframePipeline
    , drWireframePipelineLayout = gBufferPipelineLayout
    }

