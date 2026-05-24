{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Vulkan.DeferredResources
  ( DeferredResources (..),
    DeferredConfig (..),
    DeferredShaders (..),
    IBLResources (..),
    CloudTextures (..),
    TerrainTextures (..),
    createDeferredResources,
  )
where

import Control.Monad (replicateM)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Bits ((.|.))
import Data.Foldable (for_)
import Data.Traversable (for)
import Data.Word (Word8)
import Foreign.Marshal.Array qualified
import Foreign.Ptr (Ptr, nullPtr)
import Graphics.Haskan.Logger (LogCategory (..), logDebugIO, logInfoIO, showT)
import Graphics.Haskan.Render.ShaderProgram (ShaderProgram (..))
import Graphics.Haskan.Resources (alloc, allocaAndPeek, allocaAndPeek_, throwVkResult)
import Graphics.Haskan.Vertex (Vertex)
import Graphics.Haskan.Vertex qualified as Vertex
import Graphics.Haskan.Vulkan.Buffer qualified as Buffer
import Graphics.Haskan.Vulkan.CommandBuffer qualified as CommandBuffer
import Graphics.Haskan.Vulkan.ComputePipeline qualified as ComputePipeline
import Graphics.Haskan.Vulkan.DescriptorPool qualified as DescriptorPool
import Graphics.Haskan.Vulkan.DescriptorSet qualified as DescriptorSet
import Graphics.Haskan.Vulkan.DescriptorSetLayout qualified as DescriptorSetLayout
import Graphics.Haskan.Vulkan.Framebuffer qualified as Framebuffer
import Graphics.Haskan.Vulkan.GraphicsPipeline qualified as GraphicsPipeline
import Graphics.Haskan.Vulkan.ImageView qualified as ImageView
import Graphics.Haskan.Vulkan.Memory qualified as Memory
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

data DeferredShaders = DeferredShaders
  { dsGBuffer :: !ShaderProgram,
    dsLighting :: !ShaderProgram,
    dsWireframe :: !ShaderProgram,
    dsCloud :: !ShaderProgram,
    dsGodRay :: !ShaderProgram,
    dsTerrain :: !ShaderProgram,
    dsAPVolume :: !Vulkan.VkShaderModule,
    dsAPVolumeSpecInfo :: !(Maybe (Ptr Vulkan.VkSpecializationInfo)),
    dsBindless :: !ShaderProgram
  }

data IBLResources = IBLResources
  { irRadianceView :: !(Maybe Vulkan.VkImageView),
    irIrradianceView :: !(Maybe Vulkan.VkImageView),
    irBrdfView :: !(Maybe Vulkan.VkImageView),
    irSampler :: !Vulkan.VkSampler
  }

data CloudTextures = CloudTextures
  { ctNoiseView :: !(Maybe Vulkan.VkImageView),
    ctBlueNoiseView :: !(Maybe Vulkan.VkImageView),
    ctWeatherMapView :: !(Maybe Vulkan.VkImageView),
    ctBlueNoiseSampler :: !Vulkan.VkSampler,
    ctNoiseSampler :: !Vulkan.VkSampler
  }

data TerrainTextures = TerrainTextures
  { ttElevationView :: !(Maybe Vulkan.VkImageView),
    ttClimateView :: !(Maybe Vulkan.VkImageView),
    ttSampler :: !Vulkan.VkSampler
  }

data DeferredConfig = DeferredConfig
  { dcPhysicalDevice :: !Vulkan.VkPhysicalDevice,
    dcDevice :: !Vulkan.VkDevice,
    dcRenderContext :: !RenderContext,
    dcBindlessDescSetLayout :: !Vulkan.VkDescriptorSetLayout,
    dcShaders :: !DeferredShaders,
    dcIBL :: !IBLResources,
    dcCloudTextures :: !CloudTextures,
    dcTerrainTextures :: !TerrainTextures,
    dcLightBuffer :: !(Maybe Vulkan.VkBuffer),
    dcImGuiRenderPass :: !Vulkan.VkRenderPass,
    dcProceduralSky :: !Bool,
    dcBindlessTextureArrayView :: !(Maybe Vulkan.VkImageView),
    dcBindlessUniformBuffers :: ![Vulkan.VkBuffer]
  }

data DeferredResources = DeferredResources
  { drGBufferRenderPass :: !Vulkan.VkRenderPass,
    drGBufferPipeline :: !Vulkan.VkPipeline,
    drGBufferDoubleSidedPipeline :: !Vulkan.VkPipeline,
    drGBufferPipelineLayout :: !Vulkan.VkPipelineLayout,
    drGBufferFramebuffers :: ![Vulkan.VkFramebuffer],
    drBindlessRenderPass :: !Vulkan.VkRenderPass,
    drBindlessPipeline :: !Vulkan.VkPipeline,
    drBindlessPipelineLayout :: !Vulkan.VkPipelineLayout,
    drBindlessDescriptorPool :: !Vulkan.VkDescriptorPool,
    drBindlessDescriptorSets :: ![Vulkan.VkDescriptorSet],
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
    drGodRayImages :: ![Vulkan.VkImage],
    drGodRayImageViews :: ![Vulkan.VkImageView],
    drGodRayRenderPass :: !Vulkan.VkRenderPass,
    drGodRayPipeline :: !Vulkan.VkPipeline,
    drGodRayPipelineLayout :: !Vulkan.VkPipelineLayout,
    drGodRayFramebuffers :: ![Vulkan.VkFramebuffer],
    drGodRayDescriptorSets :: ![Vulkan.VkDescriptorSet],
    drTerrainRenderPass :: !Vulkan.VkRenderPass,
    drTerrainPipeline :: !Vulkan.VkPipeline,
    drTerrainPipelineLayout :: !Vulkan.VkPipelineLayout,
    drTerrainFramebuffers :: ![Vulkan.VkFramebuffer],
    drTerrainDescriptorSets :: ![Vulkan.VkDescriptorSet],
    drTerrainFrameDataBuffer :: !Vulkan.VkBuffer,
    drTerrainFrameDataMemory :: !Vulkan.VkDeviceMemory,
    drSwapchainImages :: ![Vulkan.VkImage],
    drAPVolumeImage :: !Vulkan.VkImage,
    drAPVolumeImageView :: !Vulkan.VkImageView,
    drAPVolumeMemory :: !Vulkan.VkDeviceMemory,
    drAPVolumePipeline :: !Vulkan.VkPipeline,
    drAPVolumePipelineLayout :: !Vulkan.VkPipelineLayout,
    drAPVolumeDescriptorPool :: !Vulkan.VkDescriptorPool,
    drAPVolumeDescriptorSets :: ![Vulkan.VkDescriptorSet],
    drAPVolumeUniformBuffer :: !Vulkan.VkBuffer,
    drAPVolumeUniformMemory :: !Vulkan.VkDeviceMemory,
    drGBufferImages :: ![[Vulkan.VkImage]],
    drGBufferImageViews :: ![[Vulkan.VkImageView]],
    drSampler :: !Vulkan.VkSampler,
    drWireframePipeline :: !Vulkan.VkPipeline,
    drWireframePipelineLayout :: !Vulkan.VkPipelineLayout,
    drImGuiFramebuffers :: ![Vulkan.VkFramebuffer],
    drImGuiRenderPass :: !Vulkan.VkRenderPass
  }

createDeferredResources ::
  (MonadIO m, MonadManaged m) =>
  DeferredConfig ->
  m DeferredResources
createDeferredResources DeferredConfig {..} = do
  let pdev = dcPhysicalDevice
      device = dcDevice
      ctx = dcRenderContext
      DeferredShaders {..} = dcShaders
      IBLResources {..} = dcIBL
      CloudTextures {..} = dcCloudTextures
      TerrainTextures {..} = dcTerrainTextures
      mEnvMapView = irRadianceView
      mIrradianceView = irIrradianceView
      mBrdfView = irBrdfView
      sampler = irSampler
      mCloudNoiseView = ctNoiseView
      mBlueNoiseView = ctBlueNoiseView
      mWeatherMapView = ctWeatherMapView
      blueNoiseSampler = ctBlueNoiseSampler
      noiseSampler = ctNoiseSampler
      mLightBuffer = dcLightBuffer
      imGuiRenderPass = dcImGuiRenderPass
      proceduralSkyEnabled = dcProceduralSky
      descriptorSetLayout = dcBindlessDescSetLayout
      pushConstantRanges = []
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

  -- Bindless render pass (reuses g-buffer attachments with LOAD_OP_LOAD)
  bindlessRenderPass <- RenderPass.managedBindlessRenderPass device gbufPosFormat gbufColorFormat depthFormat
  logDebugIO LogRender "bindless render pass created"

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

  -- Initial layout transition for g-buffer images
  tempCmdBufGbuf <- CommandBuffer.createCommandBuffer device (rcGraphicsCommandPool ctx)
  CommandBuffer.withCommandBufferOneTime
    (graphicsQueueHandler ctx)
    tempCmdBufGbuf
    ( do
        for_ (concat gBufferImages) $ \img ->
          CommandBuffer.layerTransition tempCmdBufGbuf img Vulkan.VK_IMAGE_LAYOUT_UNDEFINED Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
    )
  liftIO $ Foreign.Marshal.Array.withArray [tempCmdBufGbuf] $ Vulkan.vkFreeCommandBuffers device (rcGraphicsCommandPool ctx) 1
  logDebugIO LogRender "g-buffer images transitioned to SHADER_READ_ONLY_OPTIMAL"

  -- Create cloud images and views (RGBA16F, quarter resolution)
  let cloudFormat = Vulkan.VK_FORMAT_R16G16B16A16_SFLOAT
  cloudImagesAndViews <- for [0 .. numSwapchainImages - 1] $ \_ -> do
    cloudImage <- Swapchain.managedGBufferImage pdev device cloudExtent cloudFormat
    cloudView <- ImageView.managedImageView device cloudFormat cloudImage
    pure (cloudImage, cloudView)
  let cloudImages = map fst cloudImagesAndViews
      cloudImageViews = map snd cloudImagesAndViews
  logDebugIO LogRender $ "cloud images created: " <> showT (length cloudImages) <> " sets"

  -- Initial layout transition for cloud images
  tempCmdBufCloud <- CommandBuffer.createCommandBuffer device (rcGraphicsCommandPool ctx)
  CommandBuffer.withCommandBufferOneTime
    (graphicsQueueHandler ctx)
    tempCmdBufCloud
    ( do
        for_ cloudImages $ \img ->
          CommandBuffer.layerTransition tempCmdBufCloud img Vulkan.VK_IMAGE_LAYOUT_UNDEFINED Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
    )
  liftIO $ Foreign.Marshal.Array.withArray [tempCmdBufCloud] $ Vulkan.vkFreeCommandBuffers device (rcGraphicsCommandPool ctx) 1
  logDebugIO LogRender "cloud images transitioned to SHADER_READ_ONLY_OPTIMAL"

  -- Create cloud history images and views (same format/size)
  cloudHistoryImagesAndViews <- for [0 .. numSwapchainImages - 1] $ \_ -> do
    histImage <- Swapchain.managedGBufferImage pdev device cloudExtent cloudFormat
    histView <- ImageView.managedImageView device cloudFormat histImage
    pure (histImage, histView)
  let cloudHistoryImages = map fst cloudHistoryImagesAndViews
      cloudHistoryImageViews = map snd cloudHistoryImagesAndViews
  logDebugIO LogRender $ "cloud history images created: " <> showT (length cloudHistoryImages) <> " sets"

  -- Initial layout transition for cloud history images (sampled in cloud pass)
  tempCmdBufHist <- CommandBuffer.createCommandBuffer device (rcGraphicsCommandPool ctx)
  CommandBuffer.withCommandBufferOneTime
    (graphicsQueueHandler ctx)
    tempCmdBufHist
    ( do
        for_ cloudHistoryImages $ \img ->
          CommandBuffer.layerTransition tempCmdBufHist img Vulkan.VK_IMAGE_LAYOUT_UNDEFINED Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
    )
  liftIO $ Foreign.Marshal.Array.withArray [tempCmdBufHist] $ Vulkan.vkFreeCommandBuffers device (rcGraphicsCommandPool ctx) 1
  logDebugIO LogRender "cloud history images transitioned to SHADER_READ_ONLY_OPTIMAL"

  -- Create god ray images and views (RGBA16F, half resolution)
  godRayImagesAndViews <- for [0 .. numSwapchainImages - 1] $ \_ -> do
    godRayImage <- Swapchain.managedGBufferImage pdev device cloudExtent cloudFormat
    godRayView <- ImageView.managedImageView device cloudFormat godRayImage
    pure (godRayImage, godRayView)
  let godRayImages = map fst godRayImagesAndViews
      godRayImageViews = map snd godRayImagesAndViews
  logDebugIO LogRender $ "god ray images created: " <> showT (length godRayImages) <> " sets"

  -- Initial layout transition for god ray images
  tempCmdBuf2 <- CommandBuffer.createCommandBuffer device (rcGraphicsCommandPool ctx)
  CommandBuffer.withCommandBufferOneTime
    (graphicsQueueHandler ctx)
    tempCmdBuf2
    ( do
        for_ godRayImages $ \img ->
          CommandBuffer.layerTransition tempCmdBuf2 img Vulkan.VK_IMAGE_LAYOUT_UNDEFINED Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
    )
  liftIO $ Foreign.Marshal.Array.withArray [tempCmdBuf2] $ Vulkan.vkFreeCommandBuffers device (rcGraphicsCommandPool ctx) 1
  logDebugIO LogRender "god ray images transitioned to SHADER_READ_ONLY_OPTIMAL"

  -- Create AP volume 3D image (RGBA16F, 64x32x64) for compute writes + fragment sampling
  let apFormat = Vulkan.VK_FORMAT_R16G16B16A16_SFLOAT
      apWidth = 64
      apHeight = 32
      apDepth = 64
      apExtent =
        Vulkan.createVk
          ( set @"width" (fromIntegral apWidth)
              &* set @"height" (fromIntegral apHeight)
              &* set @"depth" (fromIntegral apDepth)
          )
      apCreateInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"imageType" Vulkan.VK_IMAGE_TYPE_3D
              &* set @"extent" apExtent
              &* set @"mipLevels" 1
              &* set @"arrayLayers" 1
              &* set @"format" apFormat
              &* set @"tiling" Vulkan.VK_IMAGE_TILING_OPTIMAL
              &* set @"initialLayout" Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
              &* set @"usage" (Vulkan.VK_IMAGE_USAGE_STORAGE_BIT .|. Vulkan.VK_IMAGE_USAGE_SAMPLED_BIT)
              &* set @"sharingMode" Vulkan.VK_SHARING_MODE_EXCLUSIVE
              &* set @"samples" Vulkan.VK_SAMPLE_COUNT_1_BIT
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"queueFamilyIndexCount" 0
              &* set @"pQueueFamilyIndices" Vulkan.VK_NULL
          )
  apImage <- liftIO $ withPtr apCreateInfo (\ciPtr -> allocaAndPeek (Vulkan.vkCreateImage device ciPtr Vulkan.vkNullPtr))
  apMemoryRequirements <- allocaAndPeek_ (Vulkan.vkGetImageMemoryRequirements device apImage)
  apMemory <- Memory.allocateMemoryFor pdev device apMemoryRequirements [Vulkan.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT]
  liftIO $ Vulkan.vkBindImageMemory device apImage apMemory 0 >>= throwVkResult
  apImageView <- ImageView.managedImageView3D device apFormat apImage
  -- Transition to GENERAL for compute writes
  tempCmdBufAP <- CommandBuffer.createCommandBuffer device (rcGraphicsCommandPool ctx)
  CommandBuffer.withCommandBufferOneTime
    (graphicsQueueHandler ctx)
    tempCmdBufAP
    (CommandBuffer.layerTransition tempCmdBufAP apImage Vulkan.VK_IMAGE_LAYOUT_UNDEFINED Vulkan.VK_IMAGE_LAYOUT_GENERAL)
  liftIO $ Foreign.Marshal.Array.withArray [tempCmdBufAP] $ Vulkan.vkFreeCommandBuffers device (rcGraphicsCommandPool ctx) 1
  logDebugIO LogRender $ "AP volume 3D image created: " <> showT apWidth <> "x" <> showT apHeight <> "x" <> showT apDepth

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
      dsGBuffer
      extent
      Vertex.vertexFormat
      4
  logDebugIO LogRender "g-buffer pipeline created"

  -- G-buffer double-sided pipeline (no backface culling)
  gBufferDoubleSidedPipeline <-
    GraphicsPipeline.managedGraphicsPipelineWithCull
      device
      gBufferPipelineLayout
      gBufferRenderPass
      dsGBuffer
      extent
      Vertex.vertexFormat
      4
      Vulkan.VK_CULL_MODE_NONE
  logDebugIO LogRender "g-buffer double-sided pipeline created"

  -- Lighting pipeline layout
  lightingDescriptorSetLayout <-
    if proceduralSkyEnabled
      then DescriptorSetLayout.managedLightingProceduralDescriptorSetLayout device
      else DescriptorSetLayout.managedLightingDescriptorSetLayout device
  let cameraPushConstantRange =
        Vulkan.createVk
          ( set @"stageFlags" (Vulkan.VK_SHADER_STAGE_VERTEX_BIT .|. Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT)
              &* set @"offset" 0
              &* set @"size" 124
          )
  lightingPipelineLayout <- PipelineLayout.managedPipelineLayoutWithPushConstants device [lightingDescriptorSetLayout] [cameraPushConstantRange]
  logDebugIO LogRender "lighting pipeline layout created"

  -- Lighting pipeline
  lightingPipeline <-
    GraphicsPipeline.managedFullscreenPipeline
      device
      lightingPipelineLayout
      lightingRenderPass
      dsLighting
      extent
  logDebugIO LogRender "lighting pipeline created"

  -- Cloud pipeline layout (no push constant — all data in UBO)
  cloudDescriptorSetLayout <- DescriptorSetLayout.managedCloudDescriptorSetLayout device
  cloudPipelineLayout <- PipelineLayout.managedPipelineLayoutWithPushConstants device [cloudDescriptorSetLayout] []
  logDebugIO LogRender "cloud pipeline layout created"

  -- God ray descriptor set layout
  godRayDescriptorSetLayout <- DescriptorSetLayout.managedGodRayDescriptorSetLayout device
  logDebugIO LogRender "god ray descriptor set layout created"

  -- Cloud pipeline
  cloudPipeline <-
    GraphicsPipeline.managedFullscreenPipeline
      device
      cloudPipelineLayout
      cloudRenderPass
      dsCloud
      cloudExtent
  logDebugIO LogRender "cloud pipeline created"

  -- Wireframe pipeline
  wireframePipeline <-
    GraphicsPipeline.managedGraphicsPipeline
      device
      gBufferPipelineLayout
      gBufferRenderPass
      dsWireframe
      extent
      Vertex.vertexFormat
      4
  logDebugIO LogRender "wireframe pipeline created"

  -- God ray pipeline (reuses cloud render pass since same format)
  let godRayPushConstantRange =
        Vulkan.createVk
          ( set @"stageFlags" Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT
              &* set @"offset" 0
              &* set @"size" 44
          )
  godRayPipelineLayout <- PipelineLayout.managedPipelineLayoutWithPushConstants device [godRayDescriptorSetLayout] [godRayPushConstantRange]
  logDebugIO LogRender "god ray pipeline layout created"

  godRayPipeline <-
    GraphicsPipeline.managedFullscreenPipeline
      device
      godRayPipelineLayout
      cloudRenderPass
      dsGodRay
      cloudExtent
  logDebugIO LogRender "god ray pipeline created"

  -- God ray framebuffers (one per swapchain image, half resolution)
  godRayFramebuffers <- for godRayImageViews $ \view ->
    Framebuffer.managedLightingFramebuffer device cloudRenderPass cloudExtent view
  logDebugIO LogRender $ "god ray framebuffers created: " <> showT (length godRayFramebuffers) <> " sets"

  -- Lighting framebuffers
  swapchainImages <- Swapchain.getSwapchainImages device (swapchain ctx)
  let surfaceFormat' = Vulkan.getField @"format" surfaceFormat
  swapchainImageViews <- for swapchainImages (ImageView.managedImageView device surfaceFormat')
  lightingFramebuffers <- for swapchainImageViews $ Framebuffer.managedLightingFramebuffer device lightingRenderPass extent
  logDebugIO LogRender $ "lighting framebuffers created: " <> showT (length lightingFramebuffers)

  -- ImGui framebuffers (swapchain images, no depth)
  imGuiFramebuffers <- for swapchainImageViews $ Framebuffer.managedLightingFramebuffer device imGuiRenderPass extent
  logDebugIO LogRender $ "ImGui framebuffers created: " <> showT (length imGuiFramebuffers)

  -- Lighting descriptor pool and sets
  let lightingTexturesPerSet = 10
  lightingDescriptorPool <- DescriptorPool.managedLightingDescriptorPool device numSwapchainImages lightingTexturesPerSet
  lightingDescriptorSets <- for [0 .. numSwapchainImages - 1] $ \_ ->
    DescriptorSet.allocateDescriptorSet device lightingDescriptorPool [lightingDescriptorSetLayout]
  logDebugIO LogRender $ "lighting descriptor sets allocated: " <> showT (length lightingDescriptorSets)

  -- Update lighting descriptor sets
  liftIO $ for_ (zip (zip lightingDescriptorSets gBufferImageViews) (zip cloudImageViews godRayImageViews)) $ \((ds, views), (cloudView, godRayView)) -> do
    let baseViews = case (mEnvMapView, mIrradianceView, mBrdfView) of
          (Just env, Just irr, Just brdf) -> views ++ [env, irr, brdf]
          _ -> views ++ replicate 3 Vulkan.VK_NULL_HANDLE
    if proceduralSkyEnabled
      then do
        DescriptorSet.updateLightingProceduralDescriptorSets $
          DescriptorSet.LightingProceduralDescriptorUpdate
            { lpduDevice = device,
              lpduDescriptorSet = ds,
              lpduSampler = sampler,
              lpduImageViews = baseViews,
              lpduLightBuffer = mLightBuffer,
              lpduCloudResultView = Just cloudView,
              lpduGodRayView = Just godRayView,
              lpduAPVolumeView = Just apImageView
            }
      else do
        DescriptorSet.updateLightingDescriptorSets $
          DescriptorSet.LightingDescriptorUpdate
            { lduDevice = device,
              lduDescriptorSet = ds,
              lduSampler = sampler,
              lduImageViews = baseViews,
              lduLightBuffer = mLightBuffer,
              lduCloudResultView = Just cloudView,
              lduAPVolumeView = Just apImageView
            }
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
    DescriptorSet.updateCloudDescriptorSets $
      DescriptorSet.CloudDescriptorUpdate
        { clduDevice = device,
          clduDescriptorSet = ds,
          clduSampler = sampler,
          clduNoiseSampler = noiseSampler,
          clduEnvMapView = mEnvMapView,
          clduCloudNoiseView = mCloudNoiseView,
          clduCloudHistoryView = Just histView,
          clduBlueNoiseView = mBlueNoiseView,
          clduWeatherMapView = mWeatherMapView,
          clduBlueNoiseSampler = blueNoiseSampler
        }
    DescriptorSet.updateCloudFrameDataBuffer device ds cloudFrameDataBuffer
  logDebugIO LogRender "cloud descriptor sets updated"

  -- God ray descriptor pool and sets
  godRayDescriptorPool <- DescriptorPool.managedGodRayDescriptorPool device numSwapchainImages
  godRayDescriptorSets <- for [0 .. numSwapchainImages - 1] $ \_ ->
    DescriptorSet.allocateDescriptorSet device godRayDescriptorPool [godRayDescriptorSetLayout]
  logDebugIO LogRender $ "god ray descriptor sets allocated: " <> showT (length godRayDescriptorSets)

  -- Update god ray descriptor sets (only need cloud_result)
  liftIO $ for_ (zip godRayDescriptorSets cloudImageViews) $ \(ds, cloudView) -> do
    DescriptorSet.updateGodRayDescriptorSets $
      DescriptorSet.GodRayDescriptorUpdate
        { grduDevice = device,
          grduDescriptorSet = ds,
          grduSampler = sampler,
          grduCloudResultView = cloudView
        }
  logDebugIO LogRender "god ray descriptor sets updated"

  -- Terrain overlay render pass (loads existing framebuffer content)
  terrainOverlayRenderPass <- RenderPass.managedTerrainOverlayRenderPass device surfaceFormat
  logDebugIO LogRender "terrain overlay render pass created"

  -- Terrain descriptor set layout
  terrainDescriptorSetLayout <- DescriptorSetLayout.managedTerrainDescriptorSetLayout device
  logDebugIO LogRender "terrain descriptor set layout created"

  -- Terrain pipeline layout (no push constants — all data in UBO)
  terrainPipelineLayout <- PipelineLayout.managedPipelineLayoutWithPushConstants device [terrainDescriptorSetLayout] []
  logDebugIO LogRender "terrain pipeline layout created"

  -- Terrain pipeline with alpha blending
  terrainPipeline <-
    GraphicsPipeline.managedFullscreenPipelineWithBlending
      device
      terrainPipelineLayout
      terrainOverlayRenderPass
      dsTerrain
      extent
  logDebugIO LogRender "terrain pipeline with blending created"

  -- Terrain framebuffers (one per swapchain image)
  terrainFramebuffers <- for swapchainImageViews $ \view ->
    Framebuffer.managedLightingFramebuffer device terrainOverlayRenderPass extent view
  logDebugIO LogRender $ "terrain framebuffers created: " <> showT (length terrainFramebuffers)

  -- Terrain frame data UBO (128 bytes)
  let terrainFrameDataSize = 128
  (terrainFrameDataBuffer, terrainFrameDataMemoryRequirement) <-
    Buffer.managedBuffer device (replicate terrainFrameDataSize (0 :: Word8)) (Vulkan.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT)
  terrainFrameDataMemory <- Buffer.managedBufferMemory pdev device terrainFrameDataMemoryRequirement
  liftIO $ Buffer.bindBufferMemory device terrainFrameDataBuffer terrainFrameDataMemory (replicate terrainFrameDataSize (0 :: Word8))
  logDebugIO LogRender "terrain frame data UBO created"

  -- Terrain descriptor pool and sets
  terrainDescriptorPool <- DescriptorPool.managedTerrainDescriptorPool device numSwapchainImages
  terrainDescriptorSets <- for [0 .. numSwapchainImages - 1] $ \_ ->
    DescriptorSet.allocateDescriptorSet device terrainDescriptorPool [terrainDescriptorSetLayout]
  logDebugIO LogRender $ "terrain descriptor sets allocated: " <> showT (length terrainDescriptorSets)

  -- Update terrain descriptor sets
  liftIO $ for_ terrainDescriptorSets $ \ds -> do
    DescriptorSet.updateTerrainDescriptorSets $
      DescriptorSet.TerrainDescriptorUpdate
        { tduDevice = device,
          tduDescriptorSet = ds,
          tduSampler = ttSampler,
          tduElevationView = ttElevationView,
          tduClimateView = ttClimateView
        }
    DescriptorSet.updateTerrainFrameDataBuffer device ds terrainFrameDataBuffer
  logDebugIO LogRender "terrain descriptor sets updated"

  -- AP volume compute pipeline
  apVolumeDescriptorSetLayout <- DescriptorSetLayout.managedAPVolumeComputeDescriptorSetLayout device
  logDebugIO LogRender "AP volume descriptor set layout created"
  apVolumePipelineLayout <- PipelineLayout.managedPipelineLayoutWithPushConstants device [apVolumeDescriptorSetLayout] []
  logDebugIO LogRender "AP volume pipeline layout created"
  apVolumePipeline <- ComputePipeline.managedComputePipelineWithSpec device apVolumePipelineLayout dsAPVolume (maybe nullPtr id dsAPVolumeSpecInfo)
  logDebugIO LogRender "AP volume compute pipeline created"

  -- AP volume descriptor pool and sets
  apVolumeDescriptorPool <- DescriptorPool.managedAPVolumeDescriptorPool device numSwapchainImages
  apVolumeDescriptorSets <- for [0 .. numSwapchainImages - 1] $ \_ ->
    DescriptorSet.allocateDescriptorSet device apVolumeDescriptorPool [apVolumeDescriptorSetLayout]
  logDebugIO LogRender $ "AP volume descriptor sets allocated: " <> showT (length apVolumeDescriptorSets)

  -- AP volume uniform buffer (256 bytes, std140 aligned)
  let apUniformSize = 256
  (apUniformBuffer, apUniformMemoryRequirement) <-
    Buffer.managedBuffer device (replicate apUniformSize (0 :: Word8)) (Vulkan.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT)
  apUniformMemory <- Buffer.managedBufferMemory pdev device apUniformMemoryRequirement
  liftIO $ Buffer.bindBufferMemory device apUniformBuffer apUniformMemory (replicate apUniformSize (0 :: Word8))
  logDebugIO LogRender "AP volume uniform buffer created"

  -- Update AP volume descriptor sets
  liftIO $ for_ apVolumeDescriptorSets $ \ds -> do
    DescriptorSet.updateAPVolumeDescriptorSets $
      DescriptorSet.APVolumeDescriptorUpdate
        { apduDevice = device,
          apduDescriptorSet = ds,
          apduAPImageView = apImageView,
          apduCloudNoiseView = mCloudNoiseView,
          apduCloudNoiseSampler = noiseSampler,
          apduWeatherMapView = mWeatherMapView,
          apduWeatherMapSampler = noiseSampler,
          apduUniformBuffer = apUniformBuffer
        }
  logDebugIO LogRender "AP volume descriptor sets updated"

  -- Bindless pass descriptor set layout (must match shader bindings)
  bindlessPassDescriptorSetLayout <- DescriptorSetLayout.managedBindlessPassDescriptorSetLayout device
  logDebugIO LogRender "bindless pass descriptor set layout created"

  -- Bindless pipeline layout (UBO + texture array + push constants)
  let bindlessPushConstantRange =
        Vulkan.createVk
          ( set @"stageFlags" (Vulkan.VK_SHADER_STAGE_VERTEX_BIT .|. Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT)
              &* set @"offset" 0
              &* set @"size" 68
          )
  bindlessPipelineLayout <- PipelineLayout.managedPipelineLayoutWithPushConstants device [bindlessPassDescriptorSetLayout] [bindlessPushConstantRange]
  logDebugIO LogRender "bindless pipeline layout created"

  -- Bindless pipeline (reuses g-buffer render pass since same output format)
  bindlessPipeline <-
    GraphicsPipeline.managedGraphicsPipelineWithCull
      device
      bindlessPipelineLayout
      bindlessRenderPass
      dsBindless
      extent
      Vertex.vertexFormat
      4
      Vulkan.VK_CULL_MODE_NONE
  logDebugIO LogRender "bindless pipeline created"

  -- Bindless descriptor pool and sets (one per frame-in-flight UBO)
  let numBindlessSets = length dcBindlessUniformBuffers
  bindlessDescriptorPool <- DescriptorPool.managedDescriptorPool device numBindlessSets
  logDebugIO LogRender "bindless descriptor pool created"

  bindlessDescriptorSets <- replicateM numBindlessSets (DescriptorSet.allocateDescriptorSet device bindlessDescriptorPool [bindlessPassDescriptorSetLayout])
  logDebugIO LogRender $ "bindless descriptor sets allocated: " <> showT (length bindlessDescriptorSets)

  -- Update bindless descriptor sets with texture array and UBO (if provided)
  case dcBindlessTextureArrayView of
    Nothing -> logDebugIO LogRender "no bindless texture array, skipping descriptor update"
    Just texArrayView -> do
      for_ (zip bindlessDescriptorSets dcBindlessUniformBuffers) $ \(ds, uboBuf) -> do
        DescriptorSet.updateBindlessPassDescriptorSet
          device
          ds
          uboBuf
          128
          texArrayView
          sampler
      logDebugIO LogRender "bindless descriptor sets updated with texture array and UBO"

  pure
    DeferredResources
      { drGBufferRenderPass = gBufferRenderPass,
        drGBufferPipeline = gBufferPipeline,
        drGBufferDoubleSidedPipeline = gBufferDoubleSidedPipeline,
        drGBufferPipelineLayout = gBufferPipelineLayout,
        drGBufferFramebuffers = gBufferFramebuffers,
        drBindlessRenderPass = bindlessRenderPass,
        drBindlessPipeline = bindlessPipeline,
        drBindlessPipelineLayout = bindlessPipelineLayout,
        drBindlessDescriptorPool = bindlessDescriptorPool,
        drBindlessDescriptorSets = bindlessDescriptorSets,
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
        drGodRayImages = godRayImages,
        drGodRayImageViews = godRayImageViews,
        drGodRayRenderPass = cloudRenderPass,
        drGodRayPipeline = godRayPipeline,
        drGodRayPipelineLayout = godRayPipelineLayout,
        drGodRayFramebuffers = godRayFramebuffers,
        drGodRayDescriptorSets = godRayDescriptorSets,
        drTerrainRenderPass = terrainOverlayRenderPass,
        drTerrainPipeline = terrainPipeline,
        drTerrainPipelineLayout = terrainPipelineLayout,
        drTerrainFramebuffers = terrainFramebuffers,
        drTerrainDescriptorSets = terrainDescriptorSets,
        drTerrainFrameDataBuffer = terrainFrameDataBuffer,
        drTerrainFrameDataMemory = terrainFrameDataMemory,
        drSwapchainImages = swapchainImages,
        drAPVolumeImage = apImage,
        drAPVolumeImageView = apImageView,
        drAPVolumeMemory = apMemory,
        drAPVolumePipeline = apVolumePipeline,
        drAPVolumePipelineLayout = apVolumePipelineLayout,
        drAPVolumeDescriptorPool = apVolumeDescriptorPool,
        drAPVolumeDescriptorSets = apVolumeDescriptorSets,
        drAPVolumeUniformBuffer = apUniformBuffer,
        drAPVolumeUniformMemory = apUniformMemory,
        drGBufferImages = gBufferImages,
        drGBufferImageViews = gBufferImageViews,
        drSampler = sampler,
        drWireframePipeline = wireframePipeline,
        drWireframePipelineLayout = gBufferPipelineLayout,
        drImGuiFramebuffers = imGuiFramebuffers,
        drImGuiRenderPass = imGuiRenderPass
      }
