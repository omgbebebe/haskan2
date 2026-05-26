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
import Data.Vector qualified as Vector
import Data.Word (Word8)
import Foreign.Marshal.Array qualified
import Foreign.Ptr (Ptr)
import Graphics.Haskan.Logger (LogCategory (..), logDebugIO, logInfoIO, showT)
import Graphics.Haskan.Render.ShaderProgram (MeshShaderProgram (..), ShaderProgram (..))
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
import Graphics.Haskan.Vulkan.MeshPipeline qualified as MeshPipeline
import Graphics.Haskan.Vulkan.PipelineLayout qualified as PipelineLayout
import Graphics.Haskan.Vulkan.RenderPass qualified as RenderPass
import Graphics.Haskan.Vulkan.Swapchain qualified as Swapchain
import Graphics.Haskan.Vulkan.Types (RenderContext (..))
import Vulkan qualified as Vk26
import Vulkan.Zero (zero)

data DeferredShaders = DeferredShaders
  { dsGBuffer :: !ShaderProgram,
    dsLighting :: !ShaderProgram,
    dsWireframe :: !ShaderProgram,
    dsCloud :: !ShaderProgram,
    dsGodRay :: !ShaderProgram,
    dsTerrain :: !ShaderProgram,
    dsTerrainMesh :: !MeshShaderProgram,
    dsAPVolume :: !Vk26.ShaderModule,
    dsAPVolumeSpecInfo :: !(Maybe Vk26.SpecializationInfo),
    dsBindless :: !ShaderProgram
  }

data IBLResources = IBLResources
  { irRadianceView :: !(Maybe Vk26.ImageView),
    irIrradianceView :: !(Maybe Vk26.ImageView),
    irBrdfView :: !(Maybe Vk26.ImageView),
    irSampler :: !Vk26.Sampler
  }

data CloudTextures = CloudTextures
  { ctNoiseView :: !(Maybe Vk26.ImageView),
    ctBlueNoiseView :: !(Maybe Vk26.ImageView),
    ctWeatherMapView :: !(Maybe Vk26.ImageView),
    ctBlueNoiseSampler :: !Vk26.Sampler,
    ctNoiseSampler :: !Vk26.Sampler
  }

data TerrainTextures = TerrainTextures
  { ttElevationView :: !(Maybe Vk26.ImageView),
    ttClimateView :: !(Maybe Vk26.ImageView),
    ttSampler :: !Vk26.Sampler
  }

data DeferredConfig = DeferredConfig
  { dcPhysicalDevice :: !Vk26.PhysicalDevice,
    dcDevice :: !Vk26.Device,
    dcRenderContext :: !RenderContext,
    dcBindlessDescSetLayout :: !Vk26.DescriptorSetLayout,
    dcShaders :: !DeferredShaders,
    dcIBL :: !IBLResources,
    dcCloudTextures :: !CloudTextures,
    dcTerrainTextures :: !TerrainTextures,
    dcLightBuffer :: !(Maybe Vk26.Buffer),
    dcImGuiRenderPass :: !Vk26.RenderPass,
    dcProceduralSky :: !Bool,
    dcBindlessTextureArrayView :: !(Maybe Vk26.ImageView),
    dcBindlessUniformBuffers :: ![Vk26.Buffer]
  }

data DeferredResources = DeferredResources
  { drGBufferRenderPass :: !Vk26.RenderPass,
    drGBufferPipeline :: !Vk26.Pipeline,
    drGBufferDoubleSidedPipeline :: !Vk26.Pipeline,
    drGBufferPipelineLayout :: !Vk26.PipelineLayout,
    drGBufferFramebuffers :: ![Vk26.Framebuffer],
    drBindlessRenderPass :: !Vk26.RenderPass,
    drBindlessPipeline :: !Vk26.Pipeline,
    drBindlessPipelineLayout :: !Vk26.PipelineLayout,
    drBindlessDescriptorPool :: !Vk26.DescriptorPool,
    drBindlessDescriptorSets :: ![Vk26.DescriptorSet],
    drLightingRenderPass :: !Vk26.RenderPass,
    drLightingPipeline :: !Vk26.Pipeline,
    drLightingPipelineLayout :: !Vk26.PipelineLayout,
    drLightingFramebuffers :: ![Vk26.Framebuffer],
    drLightingDescriptorSets :: ![Vk26.DescriptorSet],
    drCloudRenderPass :: !Vk26.RenderPass,
    drCloudPipeline :: !Vk26.Pipeline,
    drCloudPipelineLayout :: !Vk26.PipelineLayout,
    drCloudFramebuffers :: ![Vk26.Framebuffer],
    drCloudDescriptorSets :: ![Vk26.DescriptorSet],
    drCloudFrameDataBuffer :: !Vk26.Buffer,
    drCloudFrameDataMemory :: !Vk26.DeviceMemory,
    drCloudImages :: ![Vk26.Image],
    drCloudImageViews :: ![Vk26.ImageView],
    drCloudHistoryImages :: ![Vk26.Image],
    drCloudHistoryImageViews :: ![Vk26.ImageView],
    drCloudExtent :: !Vk26.Extent2D,
    drGodRayImages :: ![Vk26.Image],
    drGodRayImageViews :: ![Vk26.ImageView],
    drGodRayRenderPass :: !Vk26.RenderPass,
    drGodRayPipeline :: !Vk26.Pipeline,
    drGodRayPipelineLayout :: !Vk26.PipelineLayout,
    drGodRayFramebuffers :: ![Vk26.Framebuffer],
    drGodRayDescriptorSets :: ![Vk26.DescriptorSet],
    drTerrainRenderPass :: !Vk26.RenderPass,
    drTerrainPipeline :: !Vk26.Pipeline,
    drTerrainPipelineLayout :: !Vk26.PipelineLayout,
    drTerrainFramebuffers :: ![Vk26.Framebuffer],
    drTerrainDescriptorSets :: ![Vk26.DescriptorSet],
    drTerrainFrameDataBuffer :: !Vk26.Buffer,
    drTerrainFrameDataMemory :: !Vk26.DeviceMemory,
    drTerrainMeshPipeline :: !Vk26.Pipeline,
    drTerrainMeshPipelineLayout :: !Vk26.PipelineLayout,
    drTerrainMeshDescriptorSets :: ![Vk26.DescriptorSet],
    drTerrainMeshNodeBuffer :: !Vk26.Buffer,
    drTerrainMeshNodeMemory :: !Vk26.DeviceMemory,
    drSwapchainImages :: ![Vk26.Image],
    drAPVolumeImage :: !Vk26.Image,
    drAPVolumeImageView :: !Vk26.ImageView,
    drAPVolumeMemory :: !Vk26.DeviceMemory,
    drAPVolumePipeline :: !Vk26.Pipeline,
    drAPVolumePipelineLayout :: !Vk26.PipelineLayout,
    drAPVolumeDescriptorPool :: !Vk26.DescriptorPool,
    drAPVolumeDescriptorSets :: ![Vk26.DescriptorSet],
    drAPVolumeUniformBuffer :: !Vk26.Buffer,
    drAPVolumeUniformMemory :: !Vk26.DeviceMemory,
    drGBufferImages :: ![[Vk26.Image]],
    drGBufferImageViews :: ![[Vk26.ImageView]],
    drSampler :: !Vk26.Sampler,
    drWireframePipeline :: !Vk26.Pipeline,
    drWireframePipelineLayout :: !Vk26.PipelineLayout,
    drImGuiFramebuffers :: ![Vk26.Framebuffer],
    drImGuiRenderPass :: !Vk26.RenderPass
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
        let Vk26.Extent2D w h = extent
        in Vk26.Extent2D (w `div` 2) (h `div` 2)
      gbufPosFormat = Vk26.FORMAT_R16G16B16A16_SFLOAT
      gbufColorFormat = Vk26.FORMAT_R8G8B8A8_UNORM
      depthFormat = Vk26.FORMAT_D32_SFLOAT
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
          CommandBuffer.layerTransition tempCmdBufGbuf img Vk26.IMAGE_LAYOUT_UNDEFINED Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
    )
  liftIO $ Vk26.freeCommandBuffers device (rcGraphicsCommandPool ctx) (Vector.fromList [tempCmdBufGbuf])
  logDebugIO LogRender "g-buffer images transitioned to SHADER_READ_ONLY_OPTIMAL"

  -- Create cloud images and views (RGBA16F, quarter resolution)
  let cloudFormat = Vk26.FORMAT_R16G16B16A16_SFLOAT
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
          CommandBuffer.layerTransition tempCmdBufCloud img Vk26.IMAGE_LAYOUT_UNDEFINED Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
    )
  liftIO $ Vk26.freeCommandBuffers device (rcGraphicsCommandPool ctx) (Vector.fromList [tempCmdBufCloud])
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
          CommandBuffer.layerTransition tempCmdBufHist img Vk26.IMAGE_LAYOUT_UNDEFINED Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
    )
  liftIO $ Vk26.freeCommandBuffers device (rcGraphicsCommandPool ctx) (Vector.fromList [tempCmdBufHist])
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
          CommandBuffer.layerTransition tempCmdBuf2 img Vk26.IMAGE_LAYOUT_UNDEFINED Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
    )
  liftIO $ Vk26.freeCommandBuffers device (rcGraphicsCommandPool ctx) (Vector.fromList [tempCmdBuf2])
  logDebugIO LogRender "god ray images transitioned to SHADER_READ_ONLY_OPTIMAL"

  -- Create AP volume 3D image (RGBA16F, 64x32x64) for compute writes + fragment sampling
  let apFormat = Vk26.FORMAT_R16G16B16A16_SFLOAT
      apWidth = 64
      apHeight = 32
      apDepth = 64
      apExtent =
        Vk26.Extent3D (fromIntegral apWidth) (fromIntegral apHeight) (fromIntegral apDepth)
      apCreateInfo =
        Vk26.ImageCreateInfo
          { next = ()
          , imageType = Vk26.IMAGE_TYPE_3D
          , extent = apExtent
          , mipLevels = 1
          , arrayLayers = 1
          , format = apFormat
          , tiling = Vk26.IMAGE_TILING_OPTIMAL
          , initialLayout = Vk26.IMAGE_LAYOUT_UNDEFINED
          , usage = (Vk26.IMAGE_USAGE_STORAGE_BIT .|. Vk26.IMAGE_USAGE_SAMPLED_BIT)
          , sharingMode = Vk26.SHARING_MODE_EXCLUSIVE
          , samples = Vk26.SAMPLE_COUNT_1_BIT
          , flags = zero
          , queueFamilyIndices = Vector.empty
          }
  apImage <- alloc "APVolumeImage" (liftIO $ Vk26.createImage device apCreateInfo Nothing) (\ptr -> liftIO $ Vk26.destroyImage device ptr Nothing)
  apMemoryRequirements <- liftIO $ Vk26.getImageMemoryRequirements device apImage
  apMemory <- alloc "APVolumeMemory" (Memory.allocateMemoryFor pdev device apMemoryRequirements [Vk26.MEMORY_PROPERTY_DEVICE_LOCAL_BIT]) (\ptr -> liftIO $ Vk26.freeMemory device ptr Nothing)
  liftIO $ Vk26.bindImageMemory device apImage apMemory 0
  apImageView <- ImageView.managedImageView3D device apFormat apImage
  -- Transition to GENERAL for compute writes
  tempCmdBufAP <- CommandBuffer.createCommandBuffer device (rcGraphicsCommandPool ctx)
  CommandBuffer.withCommandBufferOneTime
    (graphicsQueueHandler ctx)
    tempCmdBufAP
    (CommandBuffer.layerTransition tempCmdBufAP apImage Vk26.IMAGE_LAYOUT_UNDEFINED Vk26.IMAGE_LAYOUT_GENERAL)
  liftIO $ Vk26.freeCommandBuffers device (rcGraphicsCommandPool ctx) (Vector.fromList [tempCmdBufAP])
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
      Vk26.CULL_MODE_NONE
  logDebugIO LogRender "g-buffer double-sided pipeline created"

  -- Lighting pipeline layout
  lightingDescriptorSetLayout <-
    if proceduralSkyEnabled
      then DescriptorSetLayout.managedLightingProceduralDescriptorSetLayout device
      else DescriptorSetLayout.managedLightingDescriptorSetLayout device
  let cameraPushConstantRange =
        Vk26.PushConstantRange
          (Vk26.SHADER_STAGE_VERTEX_BIT .|. Vk26.SHADER_STAGE_FRAGMENT_BIT)
          0
          124
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
        Vk26.PushConstantRange
          Vk26.SHADER_STAGE_FRAGMENT_BIT
          0
          44
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
  let Vk26.SurfaceFormatKHR surfaceFormat' _ = surfaceFormat
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
          _ -> views ++ replicate 3 zero
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
    Buffer.managedBuffer device (replicate cloudFrameDataSize (0 :: Word8)) (Vk26.BUFFER_USAGE_UNIFORM_BUFFER_BIT)
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
    Buffer.managedBuffer device (replicate terrainFrameDataSize (0 :: Word8)) (Vk26.BUFFER_USAGE_UNIFORM_BUFFER_BIT)
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

  -- Terrain mesh descriptor set layout
  terrainMeshDescriptorSetLayout <- DescriptorSetLayout.managedTerrainMeshDescriptorSetLayout device
  logDebugIO LogRender "terrain mesh descriptor set layout created"

  -- Terrain mesh pipeline layout
  terrainMeshPipelineLayout <- PipelineLayout.managedPipelineLayoutWithPushConstants device [terrainMeshDescriptorSetLayout] []
  logDebugIO LogRender "terrain mesh pipeline layout created"

  -- Terrain mesh pipeline with alpha blending
  terrainMeshPipeline <-
    MeshPipeline.managedMeshPipelineWithBlending
      device
      terrainMeshPipelineLayout
      terrainOverlayRenderPass
      dsTerrainMesh
      extent
      1
  logDebugIO LogRender "terrain mesh pipeline with blending created"

  -- Terrain mesh descriptor pool and sets
  terrainMeshDescriptorPool <- DescriptorPool.managedTerrainMeshDescriptorPool device numSwapchainImages
  terrainMeshDescriptorSets <- for [0 .. numSwapchainImages - 1] $ \_ ->
    DescriptorSet.allocateDescriptorSet device terrainMeshDescriptorPool [terrainMeshDescriptorSetLayout]
  logDebugIO LogRender $ "terrain mesh descriptor sets allocated: " <> showT (length terrainMeshDescriptorSets)

  -- Terrain mesh node SSBO (1024 nodes * 32 bytes = 32KB)
  let terrainNodeSSBOSize = 1024 * 32
  (terrainMeshNodeBuffer, terrainMeshNodeMemoryRequirement) <-
    Buffer.managedBuffer device (replicate terrainNodeSSBOSize (0 :: Word8)) (Vk26.BUFFER_USAGE_STORAGE_BUFFER_BIT)
  terrainMeshNodeMemory <- Buffer.managedBufferMemory pdev device terrainMeshNodeMemoryRequirement
  liftIO $ Buffer.bindBufferMemory device terrainMeshNodeBuffer terrainMeshNodeMemory (replicate terrainNodeSSBOSize (0 :: Word8))
  logDebugIO LogRender "terrain mesh node SSBO created"

  -- Update terrain mesh descriptor sets with textures (node buffer updated per-frame)
  liftIO $ for_ terrainMeshDescriptorSets $ \ds -> do
    DescriptorSet.updateTerrainMeshDescriptorSets $
      DescriptorSet.TerrainMeshDescriptorUpdate
        { tmduDevice = device,
          tmduDescriptorSet = ds,
          tmduNodeBuffer = terrainMeshNodeBuffer,
          tmduSampler = ttSampler,
          tmduElevationView = ttElevationView,
          tmduClimateView = ttClimateView
        }
  logDebugIO LogRender "terrain mesh descriptor sets updated with textures"

  -- AP volume compute pipeline
  apVolumeDescriptorSetLayout <- DescriptorSetLayout.managedAPVolumeComputeDescriptorSetLayout device
  logDebugIO LogRender "AP volume descriptor set layout created"
  apVolumePipelineLayout <- PipelineLayout.managedPipelineLayoutWithPushConstants device [apVolumeDescriptorSetLayout] []
  logDebugIO LogRender "AP volume pipeline layout created"
  apVolumePipeline <- ComputePipeline.managedComputePipelineWithSpec device apVolumePipelineLayout dsAPVolume dsAPVolumeSpecInfo
  logDebugIO LogRender "AP volume compute pipeline created"

  -- AP volume descriptor pool and sets
  apVolumeDescriptorPool <- DescriptorPool.managedAPVolumeDescriptorPool device numSwapchainImages
  apVolumeDescriptorSets <- for [0 .. numSwapchainImages - 1] $ \_ ->
    DescriptorSet.allocateDescriptorSet device apVolumeDescriptorPool [apVolumeDescriptorSetLayout]
  logDebugIO LogRender $ "AP volume descriptor sets allocated: " <> showT (length apVolumeDescriptorSets)

  -- AP volume uniform buffer (256 bytes, std140 aligned)
  let apUniformSize = 256
  (apUniformBuffer, apUniformMemoryRequirement) <-
    Buffer.managedBuffer device (replicate apUniformSize (0 :: Word8)) (Vk26.BUFFER_USAGE_UNIFORM_BUFFER_BIT)
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
        Vk26.PushConstantRange
          (Vk26.SHADER_STAGE_VERTEX_BIT .|. Vk26.SHADER_STAGE_FRAGMENT_BIT)
          0
          68
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
      Vk26.CULL_MODE_NONE
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
        drTerrainMeshPipeline = terrainMeshPipeline,
        drTerrainMeshPipelineLayout = terrainMeshPipelineLayout,
        drTerrainMeshDescriptorSets = terrainMeshDescriptorSets,
        drTerrainMeshNodeBuffer = terrainMeshNodeBuffer,
        drTerrainMeshNodeMemory = terrainMeshNodeMemory,
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
