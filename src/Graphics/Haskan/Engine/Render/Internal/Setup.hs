{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Engine.Render.Internal.Setup
  ( compileAllShaders,
    createShaderModules,
    ShaderModules (..),
    loadIBLTextures,
    IBLTextures (..),
    SceneLoadResult (..),
    loadScene,
    dispatchProceduralSkyGeneration,
    dispatchCloudNoiseGeneration,
    dispatchCloudDetailNoiseGeneration,
    dispatchWeatherMapGeneration,
  )
where

import Control.Monad (forM, forM_, replicateM, unless, when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Bits (shiftR)
import Data.ByteString qualified as BS
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.List (nub)
import Data.Maybe (catMaybes, fromMaybe, listToMaybe)
import Data.Text qualified as Text
import Data.Vector.Storable (Vector, fromList)
import Data.Vector.Storable qualified as VS
import Data.Word (Word16, Word32, Word8)
import FIR qualified
import Foreign.C qualified
import Foreign.Marshal.Array qualified
import Graphics.Haskan.Assets.Cache (AssetCache)
import Graphics.Haskan.BoundingBox (BBox (..), emptyBBox, fromPoints)
import Graphics.Haskan.Camera (AnyCamera, Camera (..))
import Graphics.Haskan.Camera qualified as Camera
import Graphics.Haskan.DayNight (computeSunState, defaultDayNightConfig)
import Graphics.Haskan.DayNight qualified as DayNight
import Graphics.Haskan.Engine.Capabilities.Log (MonadLog (..), logInfo)
import Graphics.Haskan.Engine.Scene (adjustCameraForScene, computeMeshBounds, computeSceneBounds, computeSkyboxRays, computeWorldSpaceBounds, drawCallToSnapshot, makeProjectionMatrix)
import Graphics.Haskan.Engine.Types (ComputeCullData (..), ComputeCullResources (..), ComputeEntityData (..), ControlMessage (..), DrawIndexedIndirectCommand (..), EngineConfig (..), EntityDebugInfo (..), FrameStats (..), FrameTime (..), GameState (..), InputBuffer (..), LightData (..), NoiseGenUniforms (..), PhysicsBodySpec (..), RenderDebugInfo (..), SkyGenUniforms (..), WeatherMapUniforms (..), WorldState (..), emptyFrameStats, extractFrustumPlanes, filterVisible, flushInputBuffer, forkIOWithHandler, newInputBuffer, toListOfV4, transformAABB, updateFrameStats, writeInputBuffer)
import Graphics.Haskan.HosekWilkie (HWCoeffs (..), computeHWCoeffs, hwCoeffsToList)
import Graphics.Haskan.Input (Action (..), ActionEvent, payloadToActionEvent)
import Graphics.Haskan.Logger (LogCategory (..), logInfoIO, showT)
import Graphics.Haskan.Mesh qualified as Mesh
import Graphics.Haskan.Model qualified as Model
import Graphics.Haskan.Physics.Jolt.Types (BodyType (..))
import Graphics.Haskan.Render.Deferred (DeferredPassData (..), buildDeferredGraph)
import Graphics.Haskan.Render.Forward (ForwardPassData (..), buildForwardGraph)
import Graphics.Haskan.Render.Graph (PassContext (..), PassRecordFunc (..), RenderPassNode (..))
import Graphics.Haskan.Render.Graph qualified as Graph
import Graphics.Haskan.Render.RenderSystem (DrawCall (..), extractDrawList)
import Graphics.Haskan.Resources (allocaAndPeek, throwVkResult)
import Graphics.Haskan.Scene.ECS qualified as ECS
import Graphics.Haskan.Scene.GLTF (GLTFImportResult (..), importGLTF)
import Graphics.Haskan.Scene.Transform (Transform (..), defaultTransform, tPosition)
import Graphics.Haskan.Scene.Transform qualified as Transform
import Graphics.Haskan.Utils.ObjLoader qualified as ObjLoader
import Graphics.Haskan.Vertex (Vertex (..))
import Graphics.Haskan.Vulkan.BRDF qualified as BRDF
import Graphics.Haskan.Vulkan.Buffer qualified as Buffer
import Graphics.Haskan.Vulkan.CommandBuffer qualified as CommandBuffer
import Graphics.Haskan.Vulkan.CommandPool qualified as CommandPool
import Graphics.Haskan.Vulkan.ComputePipeline qualified as ComputePipeline
import Graphics.Haskan.Vulkan.DeferredResources qualified as Deferred
import Graphics.Haskan.Vulkan.DescriptorPool qualified as DescriptorPool
import Graphics.Haskan.Vulkan.DescriptorSet qualified as DescriptorSet
import Graphics.Haskan.Vulkan.DescriptorSetLayout qualified as DescriptorSetLayout
import Graphics.Haskan.Vulkan.Device qualified as Device
import Graphics.Haskan.Vulkan.DeviceCapabilities (DeviceCapabilities (..), queryDeviceCapabilities)
import Graphics.Haskan.Vulkan.Fence qualified as Fence
import Graphics.Haskan.Vulkan.GraphicsPipeline qualified as GraphicsPipeline
import Graphics.Haskan.Vulkan.Instance qualified as Instance
import Graphics.Haskan.Vulkan.PhysicalDevice qualified as PhysicalDevice
import Graphics.Haskan.Vulkan.PipelineLayout qualified as PipelineLayout
import Graphics.Haskan.Vulkan.Render (drawFrame, presentFrame, runRenderM)
import Graphics.Haskan.Vulkan.Render qualified as Render
import Graphics.Haskan.Vulkan.RenderPass qualified as RenderPass
import Graphics.Haskan.Vulkan.Resources
import Graphics.Haskan.Vulkan.Resources (ResourceManager, TextureHandle (..), TextureResource (..), lookupTexture)
import Graphics.Haskan.Vulkan.Semaphore qualified as Semaphore
import Graphics.Haskan.Vulkan.ShaderModule qualified as ShaderModule
import Graphics.Haskan.Vulkan.Shaders.Compile () -- forces TH shader compilation at build time
import Graphics.Haskan.Vulkan.Shaders.Compute.APVolume qualified as APVolumeShaders
import Graphics.Haskan.Vulkan.Shaders.Compute.CloudDetailNoiseGen qualified as CloudDetailNoiseGenShaders
import Graphics.Haskan.Vulkan.Shaders.Compute.CloudNoiseGen qualified as CloudNoiseGenShaders
import Graphics.Haskan.Vulkan.Shaders.Compute.Cull qualified as CullShaders
import Graphics.Haskan.Vulkan.Shaders.Compute.IrradianceGen qualified as IrradianceGenShaders
import Graphics.Haskan.Vulkan.Shaders.Compute.RadianceGen qualified as RadianceGenShaders
import Graphics.Haskan.Vulkan.Shaders.Compute.WeatherMapGen qualified as WeatherMapGenShaders
import Graphics.Haskan.Vulkan.Shaders.Deferred.Clouds qualified as CloudShaders
import Graphics.Haskan.Vulkan.Shaders.Deferred.GBuffer qualified as GBufferShaders
import Graphics.Haskan.Vulkan.Shaders.Deferred.GodRays qualified as GodRayShaders
import Graphics.Haskan.Vulkan.Shaders.Deferred.Lighting qualified as LightingShaders
import Graphics.Haskan.Vulkan.Shaders.Deferred.LightingProcedural qualified as LightingProceduralShaders
import Graphics.Haskan.Vulkan.Shaders.Texture qualified as Shaders
import Graphics.Haskan.Vulkan.Shaders.Wireframe qualified as WireframeShaders
import Graphics.Haskan.Vulkan.Texture qualified as Texture
import Graphics.Haskan.Vulkan.Types (RenderContext (..))
import Graphics.Haskan.Window qualified as Window
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Ext qualified as Vulkan
import Graphics.Vulkan.Marshal.Create qualified as Vulkan
import Linear (M44, V2 (..), V3 (..), V4 (..), normalize, (*^), (^+^), (^-^))
import Linear.Matrix (identity, inv33, inv44, transpose, (!*), (!*!))
import Linear.Projection qualified
import Linear.Quaternion (Quaternion (..))
import Linear.V3 (_x, _y, _z)
import Linear.V4 (_w)
import System.Clock (TimeSpec, toNanoSecs)
import System.Directory (doesFileExist)

-- | Compile all FIR shaders to SPIR-V
compileAllShaders :: (MonadLog m, MonadIO m) => m ()
compileAllShaders = do
  logInfo LogGeneral "compiling shaders..."
  liftIO $ FIR.compileTo "data/shaders/fir/vert.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] Shaders.vertex
  logInfo LogGeneral "  vert.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/frag.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] Shaders.fragment
  logInfo LogGeneral "  frag.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/gbuf_vert.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] GBufferShaders.vertex
  logInfo LogGeneral "  gbuf_vert.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/gbuf_frag.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] GBufferShaders.fragment
  logInfo LogGeneral "  gbuf_frag.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/light_vert.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] LightingShaders.vertex
  logInfo LogGeneral "  light_vert.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/light_frag.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] LightingShaders.fragment
  logInfo LogGeneral "  light_frag.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/light_procedural_frag.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] LightingProceduralShaders.fragment
  logInfo LogGeneral "  light_procedural_frag.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/wire_vert.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] WireframeShaders.vertex
  logInfo LogGeneral "  wire_vert.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/wire_geom.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] WireframeShaders.geometry
  logInfo LogGeneral "  wire_geom.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/wire_frag.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] WireframeShaders.fragment
  logInfo LogGeneral "  wire_frag.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/cull_comp.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] CullShaders.program
  logInfo LogGeneral "  cull_comp.spv done"
  cnResult <- liftIO $ FIR.compileTo "data/shaders/fir/cloud_noise_comp.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] CloudNoiseGenShaders.program
  case cnResult of
    Left err -> logInfo LogGeneral $ "  cloud_noise_comp.spv FAILED: " <> showT err
    Right _ -> logInfo LogGeneral "  cloud_noise_comp.spv done"
  cdResult <- liftIO $ FIR.compileTo "data/shaders/fir/cloud_detail_noise_comp.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] CloudDetailNoiseGenShaders.program
  case cdResult of
    Left err -> logInfo LogGeneral $ "  cloud_detail_noise_comp.spv FAILED: " <> showT err
    Right _ -> logInfo LogGeneral "  cloud_detail_noise_comp.spv done"
  wmResult <- liftIO $ FIR.compileTo "data/shaders/fir/weather_map_comp.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] WeatherMapGenShaders.program
  case wmResult of
    Left err -> logInfo LogGeneral $ "  weather_map_comp.spv FAILED: " <> showT err
    Right _ -> logInfo LogGeneral "  weather_map_comp.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/radiance_comp.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] RadianceGenShaders.program
  logInfo LogGeneral "  radiance_comp.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/irradiance_comp.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] IrradianceGenShaders.program
  logInfo LogGeneral "  irradiance_comp.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/cloud_vert.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] CloudShaders.cloudVertex
  logInfo LogGeneral "  cloud_vert.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/cloud_frag.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] CloudShaders.cloudFragment
  logInfo LogGeneral "  cloud_frag.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/godray_vert.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] GodRayShaders.vertex
  logInfo LogGeneral "  godray_vert.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/godray_frag.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] GodRayShaders.fragment
  logInfo LogGeneral "  godray_frag.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/ap_volume_comp.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] APVolumeShaders.program
  logInfo LogGeneral "  ap_volume_comp.spv done"

-- | Create all shader modules from compiled SPIR-V
data ShaderModules = ShaderModules
  { smForwardVert :: !Vulkan.VkShaderModule,
    smForwardFrag :: !Vulkan.VkShaderModule,
    smGbufVert :: !Vulkan.VkShaderModule,
    smGbufFrag :: !Vulkan.VkShaderModule,
    smLightVert :: !Vulkan.VkShaderModule,
    smLightFrag :: !Vulkan.VkShaderModule,
    smLightProcFrag :: !Vulkan.VkShaderModule,
    smWireVert :: !Vulkan.VkShaderModule,
    smWireGeom :: !Vulkan.VkShaderModule,
    smWireFrag :: !Vulkan.VkShaderModule,
    smCull :: !Vulkan.VkShaderModule,
    smCloudVert :: !Vulkan.VkShaderModule,
    smCloudFrag :: !Vulkan.VkShaderModule,
    smGodrayVert :: !Vulkan.VkShaderModule,
    smGodrayFrag :: !Vulkan.VkShaderModule,
    smAPVolume :: !Vulkan.VkShaderModule
  }

createShaderModules ::
  (MonadManaged m, MonadIO m) =>
  Vulkan.VkDevice ->
  m ShaderModules
createShaderModules device = do
  smForwardVert <- ShaderModule.managedShaderModule device "data/shaders/fir/vert.spv"
  smForwardFrag <- ShaderModule.managedShaderModule device "data/shaders/fir/frag.spv"
  smGbufVert <- ShaderModule.managedShaderModule device "data/shaders/fir/gbuf_vert.spv"
  smGbufFrag <- ShaderModule.managedShaderModule device "data/shaders/fir/gbuf_frag.spv"
  smLightVert <- ShaderModule.managedShaderModule device "data/shaders/fir/light_vert.spv"
  smLightFrag <- ShaderModule.managedShaderModule device "data/shaders/fir/light_frag.spv"
  smLightProcFrag <- ShaderModule.managedShaderModule device "data/shaders/fir/light_procedural_frag.spv"
  smWireVert <- ShaderModule.managedShaderModule device "data/shaders/fir/wire_vert.spv"
  smWireGeom <- ShaderModule.managedShaderModule device "data/shaders/fir/wire_geom.spv"
  smWireFrag <- ShaderModule.managedShaderModule device "data/shaders/fir/wire_frag.spv"
  smCull <- ShaderModule.managedShaderModule device "data/shaders/fir/cull_comp.spv"
  smCloudVert <- ShaderModule.managedShaderModule device "data/shaders/fir/cloud_vert.spv"
  smCloudFrag <- ShaderModule.managedShaderModule device "data/shaders/fir/cloud_frag.spv"
  smGodrayVert <- ShaderModule.managedShaderModule device "data/shaders/fir/godray_vert.spv"
  smGodrayFrag <- ShaderModule.managedShaderModule device "data/shaders/fir/godray_frag.spv"
  smAPVolume <- ShaderModule.managedShaderModule device "data/shaders/fir/ap_volume_comp.spv"
  pure ShaderModules {..}

data IBLTextures = IBLTextures
  { iblRadianceCubemap :: !TextureHandle,
    iblIrradianceCubemap :: !TextureHandle,
    iblRadianceView :: !(Maybe Vulkan.VkImageView),
    iblIrradianceView :: !(Maybe Vulkan.VkImageView),
    iblSampler :: !Vulkan.VkSampler,
    iblBrdfView :: !(Maybe Vulkan.VkImageView),
    iblCloudNoiseHandle :: !TextureHandle,
    iblCloudNoiseView :: !(Maybe Vulkan.VkImageView),
    iblCloudDetailNoiseView :: !(Maybe Vulkan.VkImageView),
    iblBlueNoiseView :: !(Maybe Vulkan.VkImageView),
    iblBlueNoiseSampler :: !Vulkan.VkSampler,
    iblNoiseSampler :: !Vulkan.VkSampler,
    iblWeatherMapView :: !(Maybe Vulkan.VkImageView)
  }

-- | Load IBL cubemaps, BRDF LUT, and cloud noise texture
loadIBLTextures ::
  (MonadManaged m, MonadIO m, MonadLog m) =>
  ResourceManager ->
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  Vulkan.VkQueue ->
  Vulkan.VkCommandBuffer ->
  String ->
  Bool ->
  m IBLTextures
loadIBLTextures rm physicalDevice device graphicsQueueHandler textureCommandBuffer envMapDir proceduralSkyEnabled = do
  lightingSampler <- Texture.createSamplerWithLod device 0
  logInfo LogGeneral "lighting sampler created"

  if proceduralSkyEnabled
    then do
      logInfo LogGeneral "procedural sky enabled: creating storage images..."
      -- Create storage images for compute shader output
      radianceHandle <- Texture.createStorageImageCube rm physicalDevice device 512 Vulkan.VK_FORMAT_R16G16B16A16_SFLOAT graphicsQueueHandler textureCommandBuffer
      irradianceHandle <- Texture.createStorageImageCube rm physicalDevice device 64 Vulkan.VK_FORMAT_R16G16B16A16_SFLOAT graphicsQueueHandler textureCommandBuffer
      mRadianceView <- Texture.textureImageView rm radianceHandle
      mIrradianceView <- Texture.textureImageView rm irradianceHandle
      logInfo LogGeneral "procedural sky storage images created"

      -- Transition radiance/irradiance to SHADER_READ_ONLY_OPTIMAL so fragment
      -- shaders can sample them before the first procedural sky compute dispatch
      mRadianceTex <- liftIO $ lookupTexture rm radianceHandle
      mIrradianceTex <- liftIO $ lookupTexture rm irradianceHandle
      CommandBuffer.withCommandBufferOneTime graphicsQueueHandler textureCommandBuffer $ do
        case mRadianceTex of
          Just tex -> Texture.transitionStorageImageToShaderRead textureCommandBuffer (trImage tex) 6
          Nothing -> pure ()
        case mIrradianceTex of
          Just tex -> Texture.transitionStorageImageToShaderRead textureCommandBuffer (trImage tex) 6
          Nothing -> pure ()

      -- BRDF LUT (shared)
      let brdfPixels = BRDF.generateBRDFLUT 256 256
      brdfTexHandle <- Texture.createTextureFromData rm physicalDevice device 256 256 brdfPixels graphicsQueueHandler textureCommandBuffer
      mBrdfView <- Texture.textureImageView rm brdfTexHandle
      logInfo LogGeneral "BRDF LUT generated"

      -- Cloud textures (shared)
      logInfo LogGeneral "creating 3D cloud noise storage image..."
      cloudNoiseHandle <- Texture.createStorageImage3D rm physicalDevice device 256 256 256 5 Vulkan.VK_FORMAT_R8G8B8A8_UNORM graphicsQueueHandler textureCommandBuffer
      dispatchCloudNoiseGeneration device physicalDevice graphicsQueueHandler textureCommandBuffer rm cloudNoiseHandle 42.0 2.0 0.5
      cloudNoiseView <- Texture.textureImageView rm cloudNoiseHandle
      logInfo LogGeneral "3D cloud noise texture generated"

      logInfo LogGeneral "creating 3D cloud detail noise storage image..."
      cloudDetailNoiseHandle <- Texture.createStorageImage3D rm physicalDevice device 64 64 64 1 Vulkan.VK_FORMAT_R8G8B8A8_UNORM graphicsQueueHandler textureCommandBuffer
      dispatchCloudDetailNoiseGeneration device physicalDevice graphicsQueueHandler textureCommandBuffer rm cloudDetailNoiseHandle
      cloudDetailNoiseView <- Texture.textureImageView rm cloudDetailNoiseHandle
      logInfo LogGeneral "3D cloud detail noise texture generated"

      logInfo LogGeneral "loading blue noise texture..."
      blueNoiseRaw <- liftIO $ BS.readFile "data/textures/blue_noise/blue_noise_64.raw"
      let blueNoisePixels = Data.Vector.Storable.fromList (BS.unpack blueNoiseRaw)
      blueNoiseHandle <- Texture.createTextureFromData rm physicalDevice device 64 64 blueNoisePixels graphicsQueueHandler textureCommandBuffer
      mBlueNoiseView <- Texture.textureImageView rm blueNoiseHandle
      blueNoiseSampler <- Texture.managedSamplerNearest device
      noiseSampler <- Texture.managedSamplerWithLod device 4.0
      logInfo LogGeneral "blue noise texture loaded"

      logInfo LogGeneral "creating weather map storage image..."
      weatherMapHandle <- Texture.createStorageImage2D rm physicalDevice device 512 512 Vulkan.VK_FORMAT_R8G8B8A8_UNORM graphicsQueueHandler textureCommandBuffer
      dispatchWeatherMapGeneration device physicalDevice graphicsQueueHandler textureCommandBuffer rm weatherMapHandle
      weatherMapView <- Texture.textureImageView rm weatherMapHandle
      logInfo LogGeneral "weather map texture generated"

      -- Dispatch compute shaders to fill storage images
      let V3 dirX dirY dirZ = V3 0.0 0.3 (-1.0)
          defaultSunElevation = pi / 6.0
          defaultSunIntensity = 50.0
      dispatchProceduralSkyGeneration device physicalDevice graphicsQueueHandler textureCommandBuffer rm radianceHandle irradianceHandle (V3 dirX dirY dirZ) defaultSunElevation defaultSunIntensity

      pure
        IBLTextures
          { iblRadianceCubemap = radianceHandle,
            iblIrradianceCubemap = irradianceHandle,
            iblRadianceView = mRadianceView,
            iblIrradianceView = mIrradianceView,
            iblSampler = lightingSampler,
            iblBrdfView = mBrdfView,
            iblCloudNoiseHandle = cloudNoiseHandle,
            iblCloudNoiseView = cloudNoiseView,
            iblCloudDetailNoiseView = cloudDetailNoiseView,
            iblBlueNoiseView = mBlueNoiseView,
            iblBlueNoiseSampler = blueNoiseSampler,
            iblNoiseSampler = noiseSampler,
            iblWeatherMapView = weatherMapView
          }
    else do
      -- Photo-based cubemap loading
      let envDir = "data/textures/cubemaps/" ++ envMapDir ++ "/"
          radianceFacePaths = map (envDir ++) ["posx.png", "negx.png", "posy.png", "negy.png", "posz.png", "negz.png"]
          irradianceFacePaths = map (envDir ++) ["posx.png", "negx.png", "posy.png", "negy.png", "posz.png", "negz.png"]
      logInfo LogGeneral "loading IBL cubemaps..."
      radianceFaceDatas <- liftIO $ mapM Texture.readImageFromFile radianceFacePaths
      irradianceFaceDatas <- liftIO $ mapM Texture.readImageFromFile irradianceFacePaths
      let (radDatas, radWidths, _) = unzip3 radianceFaceDatas
          (irrDatas, irrWidths, _) = unzip3 irradianceFaceDatas
          radSize = fromMaybe 0 (listToMaybe radWidths)
          irrSize = fromMaybe 0 (listToMaybe irrWidths)
          radMipLevels = floor (logBase 2 (fromIntegral radSize :: Double)) + 1
      radianceCubemap <- Texture.createCubemapMips rm physicalDevice device radSize radDatas graphicsQueueHandler textureCommandBuffer
      irradianceCubemap <- Texture.createCubemap rm physicalDevice device irrSize irrDatas graphicsQueueHandler textureCommandBuffer
      mRadianceView <- Texture.textureImageView rm radianceCubemap
      mIrradianceView <- Texture.textureImageView rm irradianceCubemap
      logInfo LogGeneral $ "IBL cubemaps loaded: radiance=" <> showT radSize <> "px irradiance=" <> showT irrSize <> "px mipLevels=" <> showT radMipLevels

      let brdfPixels = BRDF.generateBRDFLUT 256 256
      brdfTexHandle <- Texture.createTextureFromData rm physicalDevice device 256 256 brdfPixels graphicsQueueHandler textureCommandBuffer
      mBrdfView <- Texture.textureImageView rm brdfTexHandle
      logInfo LogGeneral "BRDF LUT generated"

      logInfo LogGeneral "creating 3D cloud noise storage image..."
      cloudNoiseHandle <- Texture.createStorageImage3D rm physicalDevice device 256 256 256 5 Vulkan.VK_FORMAT_R8G8B8A8_UNORM graphicsQueueHandler textureCommandBuffer
      dispatchCloudNoiseGeneration device physicalDevice graphicsQueueHandler textureCommandBuffer rm cloudNoiseHandle 42.0 2.0 0.5
      cloudNoiseView <- Texture.textureImageView rm cloudNoiseHandle
      logInfo LogGeneral "3D cloud noise texture generated"

      logInfo LogGeneral "creating 3D cloud detail noise storage image..."
      cloudDetailNoiseHandle <- Texture.createStorageImage3D rm physicalDevice device 64 64 64 1 Vulkan.VK_FORMAT_R8G8B8A8_UNORM graphicsQueueHandler textureCommandBuffer
      dispatchCloudDetailNoiseGeneration device physicalDevice graphicsQueueHandler textureCommandBuffer rm cloudDetailNoiseHandle
      cloudDetailNoiseView <- Texture.textureImageView rm cloudDetailNoiseHandle
      logInfo LogGeneral "3D cloud detail noise texture generated"

      logInfo LogGeneral "loading blue noise texture..."
      blueNoiseRaw <- liftIO $ BS.readFile "data/textures/blue_noise/blue_noise_64.raw"
      let blueNoisePixels = Data.Vector.Storable.fromList (BS.unpack blueNoiseRaw)
      blueNoiseHandle <- Texture.createTextureFromData rm physicalDevice device 64 64 blueNoisePixels graphicsQueueHandler textureCommandBuffer
      mBlueNoiseView <- Texture.textureImageView rm blueNoiseHandle
      blueNoiseSampler <- Texture.managedSamplerNearest device
      noiseSampler <- Texture.managedSamplerWithLod device 4.0
      logInfo LogGeneral "blue noise texture loaded"

      logInfo LogGeneral "creating weather map storage image..."
      weatherMapHandle <- Texture.createStorageImage2D rm physicalDevice device 512 512 Vulkan.VK_FORMAT_R8G8B8A8_UNORM graphicsQueueHandler textureCommandBuffer
      dispatchWeatherMapGeneration device physicalDevice graphicsQueueHandler textureCommandBuffer rm weatherMapHandle
      weatherMapView <- Texture.textureImageView rm weatherMapHandle
      logInfo LogGeneral "weather map texture generated"

      pure
        IBLTextures
          { iblRadianceCubemap = radianceCubemap,
            iblIrradianceCubemap = irradianceCubemap,
            iblRadianceView = mRadianceView,
            iblIrradianceView = mIrradianceView,
            iblSampler = lightingSampler,
            iblBrdfView = mBrdfView,
            iblCloudNoiseHandle = cloudNoiseHandle,
            iblCloudNoiseView = cloudNoiseView,
            iblCloudDetailNoiseView = cloudDetailNoiseView,
            iblBlueNoiseView = mBlueNoiseView,
            iblBlueNoiseSampler = blueNoiseSampler,
            iblNoiseSampler = noiseSampler,
            iblWeatherMapView = weatherMapView
          }

data SceneLoadResult = SceneLoadResult
  { slrECSWorld :: !ECS.World,
    slrNumEntities :: !Int,
    slrSceneBounds :: !BBox,
    slrTexturePixelMap :: !(IntMap (Int, Int, Vector Word8)),
    slrPhysicsSpecs :: ![PhysicsBodySpec]
  }

-- | Load scene based on mode (UV check, stress test, GLTF, or OBJ)
loadScene ::
  (MonadFail m, MonadIO m, MonadLog m, MonadManaged m) =>
  ResourceManager ->
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  Vulkan.VkQueue ->
  Vulkan.VkCommandBuffer ->
  AssetCache ->
  String ->
  Maybe String ->
  m SceneLoadResult
loadScene rm physicalDevice device graphicsQueueHandler textureCommandBuffer assetCache meshName uvCheckMode = do
  let isGLTF = ".gltf" `Text.isSuffixOf` Text.pack meshName || ".glb" `Text.isSuffixOf` Text.pack meshName
      isStressTest = meshName == "stress_test"
  case uvCheckMode of
    Just mode -> do
      world <- ECS.createWorld
      let uvCheckerPath = "data/textures/uv_checker.png"
      uvTexHandle <-
        liftIO (doesFileExist uvCheckerPath) >>= \exists ->
          if exists
            then do
              (pixelData, tw, th) <- Texture.readImageFromFile uvCheckerPath
              Texture.createTextureFromData rm physicalDevice device tw th pixelData graphicsQueueHandler textureCommandBuffer
            else do
              let checkerTexData = Texture.generateCheckerboardTexture 256 256 32
              Texture.createTextureFromData rm physicalDevice device 256 256 checkerTexData graphicsQueueHandler textureCommandBuffer

      let testMesh = case mode of
            "cube" -> Mesh.unitCube
            "sphere" -> Mesh.uvSphere 32 16 1.0
            _ -> Mesh.uvPlane 1.0
      testMeshHandle <- Buffer.createMeshResource rm physicalDevice device (Mesh.vertices testMesh) (Mesh.indices testMesh)
      testEntity <- ECS.spawnEntity world
      ECS.setTransform world testEntity (Transform (V3 0 0 0) (Quaternion 1 (V3 0 0 0)) (V3 1 1 1))
      ECS.setMesh world testEntity testMeshHandle
      ECS.setMaterial world testEntity uvTexHandle
      ECS.setMetallicFactor world testEntity 0.0
      ECS.setRoughnessFactor world testEntity 0.5

      let sceneBbox = BBox (V3 (-1) (-1) (-1)) (V3 1 1 1)
          uvCheckSpecs = [PhysicsBodySpec (BoxBody (V3 0.5 0.5 0.5) 10.0) (V3 0 0 0) testEntity]
      pure $ SceneLoadResult world 1 sceneBbox IntMap.empty uvCheckSpecs
    Nothing ->
      if isStressTest
        then do
          world <- ECS.createWorld
          let cubeMesh = Mesh.unitCube
          meshHandle <- Buffer.createMeshResource rm physicalDevice device (Mesh.vertices cubeMesh) (Mesh.indices cubeMesh)

          let whiteTexData = Texture.generateGridTexture 2 2 1
          whiteTexHandle <- Texture.createTextureFromData rm physicalDevice device 2 2 whiteTexData graphicsQueueHandler textureCommandBuffer

          logInfo LogGeneral "spawning 10000 stress test entities"
          forM_ [0 .. 9999] $ \i -> do
            let x = fromIntegral (i `mod` 100) * 1.0 - 50.0
                z = fromIntegral (i `div` 100) * 1.0 - 50.0
                y = sin (fromIntegral i * 0.1) * 1.0
            entity <- ECS.spawnEntity world
            ECS.setTransform world entity (Transform (V3 x y z) (Quaternion 1 (V3 0 0 0)) (V3 0.5 0.5 0.5))
            ECS.setMesh world entity meshHandle
            ECS.setMaterial world entity whiteTexHandle
            ECS.setMetallicFactor world entity 0.0
            ECS.setRoughnessFactor world entity 0.5

          let sceneBbox = BBox (V3 (-50) (-2) (-50)) (V3 50 2 50)
          logInfo LogGeneral $ "stress test scene bounds: " <> showT sceneBbox
          pure $ SceneLoadResult world 10000 sceneBbox IntMap.empty []
        else
          if isGLTF
            then do
              result <- importGLTF rm physicalDevice device graphicsQueueHandler textureCommandBuffer assetCache meshName
              let world = girWorld result
                  textures = girTextures result
                  textureData = girTextureData result
                  pixelMap =
                    IntMap.fromList $
                      zipWith (\t (w, h, v) -> (fromIntegral (unTextureHandle t), (w, h, v))) textures textureData

              sceneBbox <- liftIO $ computeWorldSpaceBounds world rm
              logInfo LogGeneral $ "scene bounds: " <> showT sceneBbox

              pure $ SceneLoadResult world (length (girMeshes result)) sceneBbox pixelMap (girPhysicsSpecs result)
            else do
              world <- ECS.createWorld
              (mesh, _) <- Model.fromObj <$> ObjLoader.parseObj meshName
              meshHandle <- Buffer.createMeshResource rm physicalDevice device (Mesh.vertices mesh) (Mesh.indices mesh)

              let objBounds = computeMeshBounds mesh
              logInfo LogGeneral $ "OBJ mesh bounds: " <> showT objBounds

              entity1 <- ECS.spawnEntity world
              ECS.setTransform world entity1 (Transform (V3 0 0 0) (Quaternion 1 (V3 0 0 0)) (V3 1 1 1))
              ECS.setMesh world entity1 meshHandle
              ECS.setMetallicFactor world entity1 0.0
              ECS.setRoughnessFactor world entity1 0.5

              entity2 <- ECS.spawnEntity world
              ECS.setTransform world entity2 (Transform (V3 2 0 0) (Quaternion 1 (V3 0 0 0)) (V3 1 1 1))
              ECS.setMesh world entity2 meshHandle
              ECS.setMetallicFactor world entity2 0.0
              ECS.setRoughnessFactor world entity2 0.5

              entity3 <- ECS.spawnEntity world
              ECS.setTransform world entity3 (Transform (V3 (-2) 0 0) (Quaternion 1 (V3 0 0 0)) (V3 1 1 1))
              ECS.setMesh world entity3 meshHandle
              ECS.setMetallicFactor world entity3 0.0
              ECS.setRoughnessFactor world entity3 0.5

              let groundMesh = Mesh.groundPlaneMesh 50.0
              groundMeshHandle <- Buffer.createMeshResource rm physicalDevice device (Mesh.vertices groundMesh) (Mesh.indices groundMesh)
              let checkerTexData = Texture.generateCheckerboardTexture 256 256 32
              checkerTexHandle <- Texture.createTextureFromData rm physicalDevice device 256 256 checkerTexData graphicsQueueHandler textureCommandBuffer
              groundEntity <- ECS.spawnEntity world
              ECS.setTransform world groundEntity (Transform (V3 0 (-0.5) 0) (Quaternion 1 (V3 0 0 0)) (V3 1 1 1))
              ECS.setMesh world groundEntity groundMeshHandle
              ECS.setMaterial world groundEntity checkerTexHandle
              ECS.setMetallicFactor world groundEntity 0.0
              ECS.setRoughnessFactor world groundEntity 1.0

              sceneBbox <- liftIO $ computeWorldSpaceBounds world rm
              logInfo LogGeneral $ "scene bounds: " <> showT sceneBbox

              pure $ SceneLoadResult world 1 sceneBbox IntMap.empty []

-- | Dispatch compute shaders to generate procedural sky content.
-- Creates temporary pipelines, dispatches, transitions images, and cleans up.
dispatchProceduralSkyGeneration ::
  (MonadManaged m, MonadIO m, MonadLog m) =>
  Vulkan.VkDevice ->
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkQueue ->
  Vulkan.VkCommandBuffer ->
  ResourceManager ->
  TextureHandle -> -- radiance
  TextureHandle -> -- irradiance
  V3 Float -> -- sun direction
  Float -> -- sun elevation (for HW coeffs)
  Float -> -- sun intensity
  m ()
dispatchProceduralSkyGeneration device physicalDevice graphicsQueueHandler textureCommandBuffer rm radianceHandle irradianceHandle sunDir sunElevation sunIntensity = do
  logInfo LogGeneral "dispatching procedural sky compute shaders..."

  -- Load compute shader modules
  radianceShader <- ShaderModule.managedShaderModule device "data/shaders/fir/radiance_comp.spv"
  irradianceShader <- ShaderModule.managedShaderModule device "data/shaders/fir/irradiance_comp.spv"

  -- Create descriptor set layout
  cubemapLayout <- DescriptorSetLayout.managedCubemapComputeDescriptorSetLayout device

  -- Create pipeline layout
  cubemapPipelineLayout <- PipelineLayout.managedPipelineLayout device [cubemapLayout]

  -- Create pipelines
  radiancePipeline <- ComputePipeline.managedComputePipeline device cubemapPipelineLayout radianceShader
  irradiancePipeline <- ComputePipeline.managedComputePipeline device cubemapPipelineLayout irradianceShader

  -- Create descriptor pool
  cubemapPool <- DescriptorPool.managedCubemapComputeDescriptorPool device

  -- Allocate descriptor sets
  radianceDescriptorSet <- DescriptorSet.allocateDescriptorSet device cubemapPool [cubemapLayout]
  irradianceDescriptorSet <- DescriptorSet.allocateDescriptorSet device cubemapPool [cubemapLayout]

  -- Create UBO with dynamic sky params
  let hwCoeffs = computeHWCoeffs 2.0 0.3 (max 0.0 sunElevation)
      [ hwAR,
        hwAG,
        hwAB,
        hwBR,
        hwBG,
        hwBB,
        hwCR,
        hwCG,
        hwCB,
        hwDR,
        hwDG,
        hwDB,
        hwER,
        hwEG,
        hwEB,
        hwFR,
        hwFG,
        hwFB,
        hwGR,
        hwGG,
        hwGB,
        hwHR,
        hwHG,
        hwHB,
        hwIR,
        hwIG,
        hwIB
        ] = hwCoeffsToList hwCoeffs
      (V3 dirX dirY dirZ) = sunDir
      skyParams =
        SkyGenUniforms
          { sgSunDirX = dirX,
            sgSunDirY = dirY,
            sgSunDirZ = dirZ,
            sgSunIntensity = sunIntensity,
            sgHwAR = hwAR,
            sgHwAG = hwAG,
            sgHwAB = hwAB,
            sgHwBR = hwBR,
            sgHwBG = hwBG,
            sgHwBB = hwBB,
            sgHwCR = hwCR,
            sgHwCG = hwCG,
            sgHwCB = hwCB,
            sgHwDR = hwDR,
            sgHwDG = hwDG,
            sgHwDB = hwDB,
            sgHwER = hwER,
            sgHwEG = hwEG,
            sgHwEB = hwEB,
            sgHwFR = hwFR,
            sgHwFG = hwFG,
            sgHwFB = hwFB,
            sgHwGR = hwGR,
            sgHwGG = hwGG,
            sgHwGB = hwGB,
            sgHwHR = hwHR,
            sgHwHG = hwHG,
            sgHwHB = hwHB,
            sgHwIR = hwIR,
            sgHwIG = hwIG,
            sgHwIB = hwIB
          }
  (skyGenDataBuffer, skyGenDataMemory) <- Buffer.managedUniformBuffer physicalDevice device [skyParams]

  -- Get image views
  mRadianceView <- Texture.textureImageView rm radianceHandle
  mIrradianceView <- Texture.textureImageView rm irradianceHandle

  -- Update descriptor sets
  case mRadianceView of
    Just radianceView -> DescriptorSet.updateCubemapComputeDescriptorSets device radianceDescriptorSet radianceView skyGenDataBuffer
    Nothing -> logInfo LogGeneral "warning: radiance view not found"
  case mIrradianceView of
    Just irradianceView -> DescriptorSet.updateCubemapComputeDescriptorSets device irradianceDescriptorSet irradianceView skyGenDataBuffer
    Nothing -> logInfo LogGeneral "warning: irradiance view not found"

  -- Get VkImage handles for transition
  mRadianceTex <- liftIO $ lookupTexture rm radianceHandle
  mIrradianceTex <- liftIO $ lookupTexture rm irradianceHandle

  -- Dispatch compute shaders
  CommandBuffer.withCommandBufferOneTime graphicsQueueHandler textureCommandBuffer $ do
    -- Transition cubemaps to GENERAL for compute writes
    -- Using UNDEFINED as oldLayout is valid per spec regardless of actual layout
    case mRadianceTex of
      Just tex ->
        CommandBuffer.layerTransitionAll
          textureCommandBuffer
          (trImage tex)
          Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
          Vulkan.VK_IMAGE_LAYOUT_GENERAL
          6
      Nothing -> pure ()
    case mIrradianceTex of
      Just tex ->
        CommandBuffer.layerTransitionAll
          textureCommandBuffer
          (trImage tex)
          Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
          Vulkan.VK_IMAGE_LAYOUT_GENERAL
          6
      Nothing -> pure ()

    -- Radiance: 512x512x6 / 8x8 = 64x64x6 workgroups
    liftIO $ Vulkan.vkCmdBindPipeline textureCommandBuffer Vulkan.VK_PIPELINE_BIND_POINT_COMPUTE radiancePipeline
    liftIO $ Foreign.Marshal.Array.withArray [radianceDescriptorSet] $ \dsPtr ->
      Vulkan.vkCmdBindDescriptorSets
        textureCommandBuffer
        Vulkan.VK_PIPELINE_BIND_POINT_COMPUTE
        cubemapPipelineLayout
        0
        1
        dsPtr
        0
        Vulkan.vkNullPtr
    CommandBuffer.cmdDispatch textureCommandBuffer 64 64 6

    -- Irradiance: 64x64x6 / 8x8 = 8x8x6 workgroups
    liftIO $ Vulkan.vkCmdBindPipeline textureCommandBuffer Vulkan.VK_PIPELINE_BIND_POINT_COMPUTE irradiancePipeline
    liftIO $ Foreign.Marshal.Array.withArray [irradianceDescriptorSet] $ \dsPtr ->
      Vulkan.vkCmdBindDescriptorSets
        textureCommandBuffer
        Vulkan.VK_PIPELINE_BIND_POINT_COMPUTE
        cubemapPipelineLayout
        0
        1
        dsPtr
        0
        Vulkan.vkNullPtr
    CommandBuffer.cmdDispatch textureCommandBuffer 8 8 6

    -- Transition storage images to SHADER_READ_ONLY_OPTIMAL
    case mRadianceTex of
      Just tex -> Texture.transitionStorageImageToShaderRead textureCommandBuffer (trImage tex) 6
      Nothing -> pure ()
    case mIrradianceTex of
      Just tex -> Texture.transitionStorageImageToShaderRead textureCommandBuffer (trImage tex) 6
      Nothing -> pure ()

  logInfo LogGeneral "procedural sky compute dispatch complete"

-- | Dispatch cloud noise generation compute shader to fill a 3D storage image.
dispatchCloudNoiseGeneration ::
  (MonadManaged m, MonadIO m, MonadLog m) =>
  Vulkan.VkDevice ->
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkQueue ->
  Vulkan.VkCommandBuffer ->
  ResourceManager ->
  TextureHandle -> -- 3D noise storage image
  Float -> -- seed
  Float -> -- frequency
  Float -> -- persistence
  m ()
dispatchCloudNoiseGeneration device physicalDevice graphicsQueueHandler textureCommandBuffer rm noiseHandle seed freq persist = do
  logInfo LogGeneral "dispatching cloud noise compute shader..."

  -- Load compute shader module
  noiseShader <- ShaderModule.managedShaderModule device "data/shaders/fir/cloud_noise_comp.spv"

  -- Create descriptor set layout
  noiseLayout <- DescriptorSetLayout.managedCloudNoiseComputeDescriptorSetLayout device

  -- Create pipeline layout
  noisePipelineLayout <- PipelineLayout.managedPipelineLayout device [noiseLayout]

  -- Create pipeline
  noisePipeline <- ComputePipeline.managedComputePipeline device noisePipelineLayout noiseShader

  -- Create descriptor pool
  noisePool <- DescriptorPool.managedCloudNoiseComputeDescriptorPool device

  -- Allocate descriptor set
  noiseDescriptorSet <- DescriptorSet.allocateDescriptorSet device noisePool [noiseLayout]

  -- Create UBO with noise params
  let noiseParams =
        NoiseGenUniforms
          { ngSeed = seed,
            ngFrequency = freq,
            ngPersistence = persist,
            ngZSlice = 0.0
          }
  (noiseParamsBuffer, _noiseParamsMemory) <- Buffer.managedUniformBuffer physicalDevice device [noiseParams]

  -- Get image view
  mNoiseView <- Texture.textureImageView rm noiseHandle

  -- Update descriptor set
  case mNoiseView of
    Just noiseView -> DescriptorSet.updateCloudNoiseComputeDescriptorSets device noiseDescriptorSet noiseView noiseParamsBuffer
    Nothing -> logInfo LogGeneral "warning: cloud noise view not found"

  -- Get VkImage handle and dimensions for transition/mipgen
  mNoiseTex <- liftIO $ lookupTexture rm noiseHandle
  let (noiseImage, noiseW, noiseH) = case mNoiseTex of
        Just tex -> (trImage tex, trWidth tex, trHeight tex)
        Nothing -> (Vulkan.vkNullPtr, 0, 0)
      noiseD = noiseW -- 3D texture, depth == width (256)
      mipLevels = 5

  -- Dispatch compute shader + generate mipmaps
  CommandBuffer.withCommandBufferOneTime graphicsQueueHandler textureCommandBuffer $ do
    -- Transition all mips from SHADER_READ_ONLY (or whatever) to GENERAL for compute write
    when (noiseImage /= Vulkan.vkNullPtr) $
      CommandBuffer.mipLayerTransition
        textureCommandBuffer
        noiseImage
        Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
        Vulkan.VK_IMAGE_LAYOUT_GENERAL
        0
        (fromIntegral mipLevels)
        1
    -- 256x256x256 / 8x8x4 = 32x32x64 workgroups
    liftIO $ Vulkan.vkCmdBindPipeline textureCommandBuffer Vulkan.VK_PIPELINE_BIND_POINT_COMPUTE noisePipeline
    liftIO $ Foreign.Marshal.Array.withArray [noiseDescriptorSet] $ \dsPtr ->
      Vulkan.vkCmdBindDescriptorSets
        textureCommandBuffer
        Vulkan.VK_PIPELINE_BIND_POINT_COMPUTE
        noisePipelineLayout
        0
        1
        dsPtr
        0
        Vulkan.vkNullPtr
    CommandBuffer.cmdDispatch textureCommandBuffer 32 32 64

    -- Transition mip 0 from GENERAL to TRANSFER_SRC for blitting
    when (noiseImage /= Vulkan.vkNullPtr) $ do
      CommandBuffer.mipLayerTransition
        textureCommandBuffer
        noiseImage
        Vulkan.VK_IMAGE_LAYOUT_GENERAL
        Vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
        0
        1
        1

      -- Generate mipmaps 1..4
      forM_ [1 .. mipLevels - 1] $ \mip -> do
        let srcMip = fromIntegral (mip - 1)
            dstMip = fromIntegral mip
            srcW = fromIntegral (noiseW `div` (2 ^ (mip - 1)))
            srcH = fromIntegral (noiseH `div` (2 ^ (mip - 1)))
            srcD = fromIntegral (noiseD `div` (2 ^ (mip - 1)))
            dstW = fromIntegral (noiseW `div` (2 ^ mip))
            dstH = fromIntegral (noiseH `div` (2 ^ mip))
            dstD = fromIntegral (noiseD `div` (2 ^ mip))

        CommandBuffer.mipLayerTransition
          textureCommandBuffer
          noiseImage
          Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
          Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
          dstMip
          1
          1

        CommandBuffer.cmdBlitImage3DMip
          textureCommandBuffer
          noiseImage
          srcMip
          dstMip
          srcW
          srcH
          srcD
          dstW
          dstH
          dstD

        CommandBuffer.mipLayerTransition
          textureCommandBuffer
          noiseImage
          Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
          Vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
          dstMip
          1
          1

      -- Transition all mips to SHADER_READ_ONLY_OPTIMAL
      CommandBuffer.mipLayerTransition
        textureCommandBuffer
        noiseImage
        Vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
        Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
        0
        (fromIntegral mipLevels)
        1

  logInfo LogGeneral "cloud noise compute dispatch + mipgen complete"

-- | Dispatch cloud detail noise generation compute shader to fill a 64^3 3D storage image.
dispatchCloudDetailNoiseGeneration ::
  (MonadManaged m, MonadIO m, MonadLog m) =>
  Vulkan.VkDevice ->
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkQueue ->
  Vulkan.VkCommandBuffer ->
  ResourceManager ->
  TextureHandle -> -- 3D detail noise storage image
  m ()
dispatchCloudDetailNoiseGeneration device physicalDevice graphicsQueueHandler textureCommandBuffer rm noiseHandle = do
  logInfo LogGeneral "dispatching cloud detail noise compute shader..."

  noiseShader <- ShaderModule.managedShaderModule device "data/shaders/fir/cloud_detail_noise_comp.spv"
  noiseLayout <- DescriptorSetLayout.managedCloudDetailNoiseComputeDescriptorSetLayout device
  noisePipelineLayout <- PipelineLayout.managedPipelineLayout device [noiseLayout]
  noisePipeline <- ComputePipeline.managedComputePipeline device noisePipelineLayout noiseShader
  noisePool <- DescriptorPool.managedCloudDetailNoiseComputeDescriptorPool device
  noiseDescriptorSet <- DescriptorSet.allocateDescriptorSet device noisePool [noiseLayout]

  let noiseParams =
        NoiseGenUniforms
          { ngSeed = 123.0,
            ngFrequency = 4.0,
            ngPersistence = 0.5,
            ngZSlice = 0.0
          }
  (noiseParamsBuffer, _noiseParamsMemory) <- Buffer.managedUniformBuffer physicalDevice device [noiseParams]

  mNoiseView <- Texture.textureImageView rm noiseHandle
  case mNoiseView of
    Just noiseView -> DescriptorSet.updateCloudDetailNoiseComputeDescriptorSets device noiseDescriptorSet noiseView noiseParamsBuffer
    Nothing -> logInfo LogGeneral "warning: cloud detail noise view not found"

  mNoiseTex <- liftIO $ lookupTexture rm noiseHandle
  let (noiseImage, _) = case mNoiseTex of
        Just tex -> (trImage tex, trWidth tex)
        Nothing -> (Vulkan.vkNullPtr, 0)

  CommandBuffer.withCommandBufferOneTime graphicsQueueHandler textureCommandBuffer $ do
    -- 64x64x64 / 8x8x8 = 8x8x8 workgroups
    liftIO $ Vulkan.vkCmdBindPipeline textureCommandBuffer Vulkan.VK_PIPELINE_BIND_POINT_COMPUTE noisePipeline
    liftIO $ Foreign.Marshal.Array.withArray [noiseDescriptorSet] $ \dsPtr ->
      Vulkan.vkCmdBindDescriptorSets
        textureCommandBuffer
        Vulkan.VK_PIPELINE_BIND_POINT_COMPUTE
        noisePipelineLayout
        0
        1
        dsPtr
        0
        Vulkan.vkNullPtr
    CommandBuffer.cmdDispatch textureCommandBuffer 8 8 8

    -- Transition to SHADER_READ_ONLY_OPTIMAL
    when (noiseImage /= Vulkan.vkNullPtr) $ do
      CommandBuffer.mipLayerTransition
        textureCommandBuffer
        noiseImage
        Vulkan.VK_IMAGE_LAYOUT_GENERAL
        Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
        0
        1
        1

  logInfo LogGeneral "cloud detail noise compute dispatch complete"

-- | Dispatch weather map generation compute shader to fill a 512^2 2D storage image.
dispatchWeatherMapGeneration ::
  (MonadManaged m, MonadIO m, MonadLog m) =>
  Vulkan.VkDevice ->
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkQueue ->
  Vulkan.VkCommandBuffer ->
  ResourceManager ->
  TextureHandle -> -- 2D weather map storage image
  m ()
dispatchWeatherMapGeneration device physicalDevice graphicsQueueHandler textureCommandBuffer rm weatherHandle = do
  logInfo LogGeneral "dispatching weather map compute shader..."

  weatherShader <- ShaderModule.managedShaderModule device "data/shaders/fir/weather_map_comp.spv"
  weatherLayout <- DescriptorSetLayout.managedWeatherMapComputeDescriptorSetLayout device
  weatherPipelineLayout <- PipelineLayout.managedPipelineLayout device [weatherLayout]
  weatherPipeline <- ComputePipeline.managedComputePipeline device weatherPipelineLayout weatherShader
  weatherPool <- DescriptorPool.managedWeatherMapComputeDescriptorPool device
  weatherDescriptorSet <- DescriptorSet.allocateDescriptorSet device weatherPool [weatherLayout]

  let weatherParams =
        WeatherMapUniforms
          { wmSeed = 42.0,
            wmCoverageScale = 3.0,
            wmTypeScale = 5.0,
            wmHeightScale = 2.0
          }
  (weatherParamsBuffer, _weatherParamsMemory) <- Buffer.managedUniformBuffer physicalDevice device [weatherParams]

  mWeatherView <- Texture.textureImageView rm weatherHandle
  case mWeatherView of
    Just weatherView -> DescriptorSet.updateWeatherMapComputeDescriptorSets device weatherDescriptorSet weatherView weatherParamsBuffer
    Nothing -> logInfo LogGeneral "warning: weather map view not found"

  mWeatherTex <- liftIO $ lookupTexture rm weatherHandle
  let (weatherImage, _) = case mWeatherTex of
        Just tex -> (trImage tex, trWidth tex)
        Nothing -> (Vulkan.vkNullPtr, 0)

  CommandBuffer.withCommandBufferOneTime graphicsQueueHandler textureCommandBuffer $ do
    -- 512x512 / 8x8 = 64x64x1 workgroups
    liftIO $ Vulkan.vkCmdBindPipeline textureCommandBuffer Vulkan.VK_PIPELINE_BIND_POINT_COMPUTE weatherPipeline
    liftIO $ Foreign.Marshal.Array.withArray [weatherDescriptorSet] $ \dsPtr ->
      Vulkan.vkCmdBindDescriptorSets
        textureCommandBuffer
        Vulkan.VK_PIPELINE_BIND_POINT_COMPUTE
        weatherPipelineLayout
        0
        1
        dsPtr
        0
        Vulkan.vkNullPtr
    CommandBuffer.cmdDispatch textureCommandBuffer 64 64 1

    -- Transition to SHADER_READ_ONLY_OPTIMAL
    when (weatherImage /= Vulkan.vkNullPtr) $ do
      CommandBuffer.mipLayerTransition
        textureCommandBuffer
        weatherImage
        Vulkan.VK_IMAGE_LAYOUT_GENERAL
        Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
        0
        1
        1

  logInfo LogGeneral "weather map compute dispatch complete"
