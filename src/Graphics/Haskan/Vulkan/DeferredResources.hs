module Graphics.Haskan.Vulkan.DeferredResources
  ( DeferredResources (..),
    createDeferredResources,
  )
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Bits ((.|.))
import Data.Foldable (for_)
import Data.Traversable (for)
import Data.Word (Word8)
import Foreign.Marshal.Array qualified
import Graphics.Haskan.Logger (LogCategory (..), logDebugIO, logInfoIO, showT)
import Graphics.Haskan.Render.ShaderProgram (ShaderProgram (..))
import Graphics.Haskan.Resources (alloc, allocaAndPeek)
import Graphics.Haskan.Vertex (Vertex)
import Graphics.Haskan.Vertex qualified as Vertex
import Graphics.Haskan.Vulkan.Buffer qualified as Buffer
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
  { drGBufferRenderPass :: !Vulkan.VkRenderPass,
    drGBufferPipeline :: !Vulkan.VkPipeline,
    drGBufferPipelineLayout :: !Vulkan.VkPipelineLayout,
    drGBufferFramebuffers :: ![Vulkan.VkFramebuffer],
    drLightingRenderPass :: !Vulkan.VkRenderPass,
    drLightingPipeline :: !Vulkan.VkPipeline,
    drLightingPipelineLayout :: !Vulkan.VkPipelineLayout,
    drLightingFramebuffers :: ![Vulkan.VkFramebuffer],
    drLightingDescriptorSets :: ![Vulkan.VkDescriptorSet],
    drCloudRenderPass :: !Vulkan.VkRenderPass,
    drCloudPipeline :: !Vulkan.VkPipeline,
    drCloudPipelineLayout :: !Vulkan.VkPipelineLayout,
    drCloudFramebuffers :: ![Vulkan.VkFramebuffer],
    drCloudDescriptorSets :: ![Vulkan.VkDescriptorSet],
    drCloudFrameDataBuffer :: !Vulkan.VkBuffer,
    drCloudFrameDataMemory :: !Vulkan.VkDeviceMemory,
    drCloudImages :: ![Vulkan.VkImage],
    drCloudImageViews :: ![Vulkan.VkImageView],
    drCloudHistoryImages :: ![Vulkan.VkImage],
    drCloudHistoryImageViews :: ![Vulkan.VkImageView],
    drCloudExtent :: !Vulkan.VkExtent2D,
    drGBufferImages :: ![[Vulkan.VkImage]],
    drGBufferImageViews :: ![[Vulkan.VkImageView]],
    drSampler :: !Vulkan.VkSampler,
    drWireframePipeline :: !Vulkan.VkPipeline,
    drWireframePipelineLayout :: !Vulkan.VkPipelineLayout
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
  Vulkan.VkShaderModule ->
  Vulkan.VkShaderModule ->
  Maybe Vulkan.VkImageView ->
  Maybe Vulkan.VkImageView ->
  Maybe Vulkan.VkImageView ->
  Vulkan.VkSampler ->
  Maybe Vulkan.VkImageView ->
  Maybe Vulkan.VkImageView ->
  Vulkan.VkSampler ->
  m DeferredResources
createDeferredResources pdev device ctx descriptorSetLayout pushConstantRanges gbufVertShader gbufFragShader litVertShader litFragShader wireVertShader wireGeomShader wireFragShader cloudVertShader cloudFragShader mEnvMapView mIrradianceView mBrdfView sampler mCloudNoiseView mBlueNoiseView blueNoiseSampler = do
  let extent = rcSurfaceExtent ctx
      cloudExtent =
        Vulkan.createVk
          ( set @"width" (Vulkan.getField @"width" extent `div` 2)
              &* set @"height" (Vulkan.getField @"height" extent `div` 2)
          )
      gbufPosFormat = Vulkan.VK_FORMAT_R16G16B16A16_SFLOAT
      gbufColorFormat = Vulkan.VK_FORMAT_R8G8B8A8_UNORM
      depthFormat = Vulkan.VK_FORMAT_D32_SFLOAT
      numSwapchainImages = length (rcFramebuffers ctx)

  logInfoIO LogRender $ "creating deferred resources for " <> showT numSwapchainImages <> " swapchain images"

  -- G-buffer render pass
  gBufferRenderPass <- RenderPass.managedGBufferRenderPassEx device gbufPosFormat gbufColorFormat depthFormat
  logDebugIO LogRender "g-buffer render pass created"

  -- Lighting render pass
  let surfaceFormat = Swapchain.surfaceFormat
  lightingRenderPass <- RenderPass.managedLightingRenderPass device surfaceFormat
  logDebugIO LogRender "lighting render pass created"

  -- Cloud render pass (RGBA16F intermediate texture)
  cloudRenderPass <- RenderPass.managedCloudRenderPass device
  logDebugIO LogRender "cloud render pass created"

  -- Create g-buffer images and views
  gBufferImagesAndViews <- for [0 .. numSwapchainImages - 1] $ \_ -> do
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

  -- Create cloud images and views (RGBA16F, quarter resolution)
  let cloudFormat = Vulkan.VK_FORMAT_R16G16B16A16_SFLOAT
  cloudImagesAndViews <- for [0 .. numSwapchainImages - 1] $ \_ -> do
    cloudImage <- Swapchain.managedGBufferImage pdev device cloudExtent cloudFormat
    cloudView <- ImageView.managedImageView device cloudFormat cloudImage
    pure (cloudImage, cloudView)
  let cloudImages = map fst cloudImagesAndViews
      cloudImageViews = map snd cloudImagesAndViews
  logDebugIO LogRender $ "cloud images created: " <> showT (length cloudImages) <> " sets"

  -- Create cloud history images and views (same format/size)
  cloudHistoryImagesAndViews <- for [0 .. numSwapchainImages - 1] $ \_ -> do
    histImage <- Swapchain.managedGBufferImage pdev device cloudExtent cloudFormat
    histView <- ImageView.managedImageView device cloudFormat histImage
    pure (histImage, histView)
  let cloudHistoryImages = map fst cloudHistoryImagesAndViews
      cloudHistoryImageViews = map snd cloudHistoryImagesAndViews
  logDebugIO LogRender $ "cloud history images created: " <> showT (length cloudHistoryImages) <> " sets"

  -- Initial layout transition for g-buffer images and cloud history images
  tempCmdBuf <- CommandBuffer.createCommandBuffer device (rcGraphicsCommandPool ctx)
  CommandBuffer.withCommandBufferOneTime
    (graphicsQueueHandler ctx)
    tempCmdBuf
    ( do
        for_ (concat gBufferImages) $ \img ->
          CommandBuffer.layerTransition tempCmdBuf img Vulkan.VK_IMAGE_LAYOUT_UNDEFINED Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
        for_ cloudHistoryImages $ \img ->
          CommandBuffer.layerTransition tempCmdBuf img Vulkan.VK_IMAGE_LAYOUT_UNDEFINED Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
    )
  liftIO $ Foreign.Marshal.Array.withArray [tempCmdBuf] $ Vulkan.vkFreeCommandBuffers device (rcGraphicsCommandPool ctx) 1
  logDebugIO LogRender "g-buffer and cloud history images transitioned to SHADER_READ_ONLY_OPTIMAL"

  -- Shared depth image for g-buffer
  depthImage <- Swapchain.managedDepthImage pdev device extent depthFormat
  depthView <- Swapchain.managedDepthView device depthImage depthFormat
  logDebugIO LogRender "g-buffer depth image created"

  -- G-buffer framebuffers
  gBufferFramebuffers <- for gBufferImageViews $ \views ->
    Framebuffer.managedGBufferFramebuffer device gBufferRenderPass extent views depthView
  logDebugIO LogRender $ "g-buffer framebuffers created: " <> showT (length gBufferFramebuffers)

  -- Cloud framebuffers (one per swapchain image, quarter resolution)
  cloudFramebuffers <- for cloudImageViews $ \view ->
    Framebuffer.managedLightingFramebuffer device cloudRenderPass cloudExtent view
  logDebugIO LogRender $ "cloud framebuffers created: " <> showT (length cloudFramebuffers)

  -- G-buffer pipeline layout
  gBufferPipelineLayout <- PipelineLayout.managedPipelineLayoutWithPushConstants device [descriptorSetLayout] pushConstantRanges
  logDebugIO LogRender "g-buffer pipeline layout created"

  -- G-buffer pipeline
  gBufferPipeline <-
    GraphicsPipeline.managedGraphicsPipeline
      device
      gBufferPipelineLayout
      gBufferRenderPass
      ShaderProgram
        { spVertex = gbufVertShader,
          spTessControl = Nothing,
          spTessEvaluation = Nothing,
          spGeometry = Nothing,
          spFragment = gbufFragShader
        }
      extent
      Vertex.vertexFormat
      4
  logDebugIO LogRender "g-buffer pipeline created"

  -- Lighting pipeline layout
  lightingDescriptorSetLayout <- DescriptorSetLayout.managedLightingDescriptorSetLayout device
  let cameraPushConstantRange =
        Vulkan.createVk
          ( set @"stageFlags" (Vulkan.VK_SHADER_STAGE_VERTEX_BIT .|. Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT)
              &* set @"offset" 0
              &* set @"size" 116
          )
  lightingPipelineLayout <- PipelineLayout.managedPipelineLayoutWithPushConstants device [lightingDescriptorSetLayout] [cameraPushConstantRange]
  logDebugIO LogRender "lighting pipeline layout created"

  -- Lighting pipeline
  lightingPipeline <-
    GraphicsPipeline.managedFullscreenPipeline
      device
      lightingPipelineLayout
      lightingRenderPass
      ShaderProgram
        { spVertex = litVertShader,
          spTessControl = Nothing,
          spTessEvaluation = Nothing,
          spGeometry = Nothing,
          spFragment = litFragShader
        }
      extent
  logDebugIO LogRender "lighting pipeline created"

  -- Cloud pipeline layout (no push constant — all data in UBO)
  cloudDescriptorSetLayout <- DescriptorSetLayout.managedCloudDescriptorSetLayout device
  cloudPipelineLayout <- PipelineLayout.managedPipelineLayoutWithPushConstants device [cloudDescriptorSetLayout] []
  logDebugIO LogRender "cloud pipeline layout created"

  -- Cloud pipeline
  cloudPipeline <-
    GraphicsPipeline.managedFullscreenPipeline
      device
      cloudPipelineLayout
      cloudRenderPass
      ShaderProgram
        { spVertex = cloudVertShader,
          spTessControl = Nothing,
          spTessEvaluation = Nothing,
          spGeometry = Nothing,
          spFragment = cloudFragShader
        }
      cloudExtent
  logDebugIO LogRender "cloud pipeline created"

  -- Wireframe pipeline
  wireframePipeline <-
    GraphicsPipeline.managedGraphicsPipeline
      device
      gBufferPipelineLayout
      gBufferRenderPass
      ShaderProgram
        { spVertex = wireVertShader,
          spTessControl = Nothing,
          spTessEvaluation = Nothing,
          spGeometry = Just wireGeomShader,
          spFragment = wireFragShader
        }
      extent
      Vertex.vertexFormat
      4
  logDebugIO LogRender "wireframe pipeline created"

  -- Lighting framebuffers
  swapchainImages <- Swapchain.getSwapchainImages device (swapchain ctx)
  let surfaceFormat' = Vulkan.getField @"format" surfaceFormat
  swapchainImageViews <- for swapchainImages (ImageView.managedImageView device surfaceFormat')
  lightingFramebuffers <- for swapchainImageViews $ Framebuffer.managedLightingFramebuffer device lightingRenderPass extent
  logDebugIO LogRender $ "lighting framebuffers created: " <> showT (length lightingFramebuffers)

  -- Lighting descriptor pool and sets
  lightingDescriptorPool <- DescriptorPool.managedLightingDescriptorPool device numSwapchainImages 7
  lightingDescriptorSets <- for [0 .. numSwapchainImages - 1] $ \_ ->
    DescriptorSet.allocateDescriptorSet device lightingDescriptorPool [lightingDescriptorSetLayout]
  logDebugIO LogRender $ "lighting descriptor sets allocated: " <> showT (length lightingDescriptorSets)

  -- Update lighting descriptor sets
  liftIO $ for_ (zip3 lightingDescriptorSets gBufferImageViews cloudImageViews) $ \(ds, views, cloudView) -> do
    let allViews = case (mEnvMapView, mIrradianceView, mBrdfView) of
          (Just env, Just irr, Just brdf) -> views ++ [env, irr, brdf]
          _ -> views ++ replicate 3 Vulkan.VK_NULL_HANDLE
    DescriptorSet.updateLightingDescriptorSets device ds sampler allViews Nothing (Just cloudView)
  logDebugIO LogRender "lighting descriptor sets updated"

  -- Create cloud frame data UBO (256 bytes, minimum UBO alignment)
  let cloudFrameDataSize = 256
  (cloudFrameDataBuffer, cloudFrameDataMemoryRequirement) <-
    Buffer.managedBuffer device (replicate cloudFrameDataSize (0 :: Word8)) (Vulkan.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT)
  cloudFrameDataMemory <- Buffer.managedBufferMemory pdev device cloudFrameDataMemoryRequirement
  liftIO $ Buffer.bindBufferMemory device cloudFrameDataBuffer cloudFrameDataMemory (replicate cloudFrameDataSize (0 :: Word8))
  logDebugIO LogRender "cloud frame data UBO created"

  -- Cloud descriptor pool and sets
  cloudDescriptorPool <- DescriptorPool.managedCloudDescriptorPool device numSwapchainImages
  cloudDescriptorSets <- for [0 .. numSwapchainImages - 1] $ \_ ->
    DescriptorSet.allocateDescriptorSet device cloudDescriptorPool [cloudDescriptorSetLayout]
  logDebugIO LogRender $ "cloud descriptor sets allocated: " <> showT (length cloudDescriptorSets)

  -- Update cloud descriptor sets
  liftIO $ for_ (zip cloudDescriptorSets cloudHistoryImageViews) $ \(ds, histView) -> do
    DescriptorSet.updateCloudDescriptorSets device ds sampler mEnvMapView mCloudNoiseView (Just histView) mBlueNoiseView blueNoiseSampler
    DescriptorSet.updateCloudFrameDataBuffer device ds cloudFrameDataBuffer
  logDebugIO LogRender "cloud descriptor sets updated"

  pure
    DeferredResources
      { drGBufferRenderPass = gBufferRenderPass,
        drGBufferPipeline = gBufferPipeline,
        drGBufferPipelineLayout = gBufferPipelineLayout,
        drGBufferFramebuffers = gBufferFramebuffers,
        drLightingRenderPass = lightingRenderPass,
        drLightingPipeline = lightingPipeline,
        drLightingPipelineLayout = lightingPipelineLayout,
        drLightingFramebuffers = lightingFramebuffers,
        drLightingDescriptorSets = lightingDescriptorSets,
        drCloudRenderPass = cloudRenderPass,
        drCloudPipeline = cloudPipeline,
        drCloudPipelineLayout = cloudPipelineLayout,
        drCloudFramebuffers = cloudFramebuffers,
        drCloudDescriptorSets = cloudDescriptorSets,
        drCloudFrameDataBuffer = cloudFrameDataBuffer,
        drCloudFrameDataMemory = cloudFrameDataMemory,
        drCloudImages = cloudImages,
        drCloudImageViews = cloudImageViews,
        drCloudHistoryImages = cloudHistoryImages,
        drCloudHistoryImageViews = cloudHistoryImageViews,
        drCloudExtent = cloudExtent,
        drGBufferImages = gBufferImages,
        drGBufferImageViews = gBufferImageViews,
        drSampler = sampler,
        drWireframePipeline = wireframePipeline,
        drWireframePipelineLayout = gBufferPipelineLayout
      }
