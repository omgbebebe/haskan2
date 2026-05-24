{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Engine.Render.Internal.Setup
  ( compileAllShaders,
    createShaderModules,
    ShaderModules (..),
    ShaderPair (..),
    WireframeShaders (..),
    VulkanContext (..),
    NoiseParams (..),
    Cubemap (..),
    loadIBLTextures,
    IBLTextures (..),
    SceneLoadResult (..),
    loadScene,
    dispatchProceduralSkyGeneration,
    dispatchCloudNoiseGeneration,
    dispatchCloudDetailNoiseGeneration,
    dispatchWeatherMapGeneration,
    TerrainTextures (..),
    loadTerrainTextures,
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
import Graphics.Haskan.Engine.Types (ComputeCullData (..), ComputeCullResources (..), ComputeEntityData (..), ControlMessage (..), DrawIndexedIndirectCommand (..), EngineConfig (..), EntityDebugInfo (..), FrameStats (..), FrameTime (..), GameState (..), InputBuffer (..), LightData (..), NoiseGenUniforms (..), PhysicsBodySpec (..), RenderDebugInfo (..), SkyGenUniforms (..), UVCheckMode (..), WeatherMapUniforms (..), WorldState (..), emptyFrameStats, extractFrustumPlanes, filterVisible, flushInputBuffer, forkIOWithHandler, newInputBuffer, toListOfV4, transformAABB, updateFrameStats, writeInputBuffer)
import Graphics.Haskan.HosekWilkie (HWCoeffs (..), SkyConfig (..), computeHWCoeffs, hwCoeffsToList)
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
import Graphics.Haskan.Render.ShaderProgram (MeshShaderProgram (..))
import Graphics.Haskan.Resources (allocaAndPeek, throwVkResult)
import Graphics.Haskan.Scene.ECS qualified as ECS
import Graphics.Haskan.Scene.GLTF (GLTFImportResult (..), importGLTF)
import Graphics.Haskan.Scene.Transform (Transform (..), defaultTransform, tPosition)
import Graphics.Haskan.Scene.Transform qualified as Transform
import Graphics.Haskan.Terrain.Texture qualified as Terrain
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
import Graphics.Haskan.Vulkan.ImageView qualified as ImageView
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
import Graphics.Haskan.Vulkan.Shaders.Compile ()
-- forces TH shader compilation at build time
import Graphics.Haskan.Vulkan.Shaders.Compute.APVolume qualified as APVolumeShaders
import Graphics.Haskan.Vulkan.Shaders.Compute.CloudDetailNoiseGen qualified as CloudDetailNoiseGenShaders
import Graphics.Haskan.Vulkan.Shaders.Compute.CloudNoiseGen qualified as CloudNoiseGenShaders
import Graphics.Haskan.Vulkan.Shaders.Compute.CloudNoiseMipGen qualified as CloudNoiseMipGenShaders
import Graphics.Haskan.Vulkan.Shaders.Compute.Cull qualified as CullShaders
import Graphics.Haskan.Vulkan.Shaders.Compute.IrradianceGen qualified as IrradianceGenShaders
import Graphics.Haskan.Vulkan.Shaders.Compute.RadianceGen qualified as RadianceGenShaders
import Graphics.Haskan.Vulkan.Shaders.Compute.WeatherMapGen qualified as WeatherMapGenShaders
import Graphics.Haskan.Vulkan.Shaders.Constants qualified as Const
import Graphics.Haskan.Vulkan.Shaders.Deferred.Clouds qualified as CloudShaders
import Graphics.Haskan.Vulkan.Shaders.Deferred.GBuffer qualified as GBufferShaders
import Graphics.Haskan.Vulkan.Shaders.Deferred.GodRays qualified as GodRayShaders
import Graphics.Haskan.Vulkan.Shaders.Deferred.Lighting qualified as LightingShaders
import Graphics.Haskan.Vulkan.Shaders.Deferred.LightingProcedural qualified as LightingProceduralShaders
import Graphics.Haskan.Vulkan.Shaders.Deferred.TerrainMesh qualified as TerrainMeshShaders
import Graphics.Haskan.Vulkan.Shaders.Deferred.TerrainOverlay qualified as TerrainOverlayShaders
import Graphics.Haskan.Vulkan.Shaders.Texture qualified as Shaders
import Graphics.Haskan.Vulkan.Shaders.Wireframe qualified as WireframeShaders
import Graphics.Haskan.Vulkan.Texture qualified as Texture
import Graphics.Haskan.Vulkan.Types (RenderContext (..), VulkanContext (..))
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
  liftIO $ FIR.compileTo "data/shaders/fir/terrain_vert.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] TerrainOverlayShaders.terrainVertex
  logInfo LogGeneral "  terrain_vert.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/terrain_frag.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] TerrainOverlayShaders.terrainFragment
  logInfo LogGeneral "  terrain_frag.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/terrain_mesh.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] TerrainMeshShaders.terrainMesh
  logInfo LogGeneral "  terrain_mesh.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/terrain_mesh_frag.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] TerrainMeshShaders.terrainFragment
  logInfo LogGeneral "  terrain_mesh_frag.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/ap_volume_comp.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] APVolumeShaders.program
  logInfo LogGeneral "  ap_volume_comp.spv done"

-- | A pair of vertex and fragment shader modules.
data ShaderPair = ShaderPair
  { shpVertex :: !Vulkan.VkShaderModule,
    shpFragment :: !Vulkan.VkShaderModule
  }

-- | Wireframe shaders include an optional geometry shader.
data WireframeShaders = WireframeShaders
  { wsVertex :: !Vulkan.VkShaderModule,
    wsGeometry :: !(Maybe Vulkan.VkShaderModule),
    wsFragment :: !Vulkan.VkShaderModule
  }

-- | Parameters for cloud noise generation compute dispatch.
data NoiseParams = NoiseParams
  { npSeed :: !Float,
    npFrequency :: !Float,
    npPersistence :: !Float
  }

-- | Reusable cubemap texture + view pair.
data Cubemap = Cubemap
  { cmHandle :: !TextureHandle,
    cmView :: !(Maybe Vulkan.VkImageView)
  }

-- | Create all shader modules from compiled SPIR-V
data ShaderModules = ShaderModules
  { smForward :: !ShaderPair,
    smGBuffer :: !ShaderPair,
    smLighting :: !ShaderPair,
    smLightingProcedural :: !Vulkan.VkShaderModule,
    smWireframe :: !WireframeShaders,
    smCull :: !Vulkan.VkShaderModule,
    smCloud :: !ShaderPair,
    smGodRay :: !ShaderPair,
    smTerrain :: !ShaderPair,
    smTerrainMesh :: !MeshShaderProgram,
    smAPVolume :: !Vulkan.VkShaderModule,
    smSimpleForward :: !ShaderPair,
    smBindless :: !ShaderPair
  }

createShaderModules ::
  (MonadManaged m, MonadIO m) =>
  Vulkan.VkDevice ->
  m ShaderModules
createShaderModules device = do
  forwardVert <- ShaderModule.managedShaderModule device "data/shaders/fir/vert.spv"
  forwardFrag <- ShaderModule.managedShaderModule device "data/shaders/fir/frag.spv"
  gbufVert <- ShaderModule.managedShaderModule device "data/shaders/fir/gbuf_vert.spv"
  gbufFrag <- ShaderModule.managedShaderModule device "data/shaders/fir/gbuf_frag.spv"
  lightVert <- ShaderModule.managedShaderModule device "data/shaders/fir/light_vert.spv"
  lightFrag <- ShaderModule.managedShaderModule device "data/shaders/fir/light_frag.spv"
  lightProcFrag <- ShaderModule.managedShaderModule device "data/shaders/fir/light_procedural_frag.spv"
  wireVert <- ShaderModule.managedShaderModule device "data/shaders/fir/wire_vert.spv"
  wireGeom <- ShaderModule.managedShaderModule device "data/shaders/fir/wire_geom.spv"
  wireFrag <- ShaderModule.managedShaderModule device "data/shaders/fir/wire_frag.spv"
  cull <- ShaderModule.managedShaderModule device "data/shaders/fir/cull_comp.spv"
  cloudVert <- ShaderModule.managedShaderModule device "data/shaders/fir/cloud_vert.spv"
  cloudFrag <- ShaderModule.managedShaderModule device "data/shaders/fir/cloud_frag.spv"
  godrayVert <- ShaderModule.managedShaderModule device "data/shaders/fir/godray_vert.spv"
  godrayFrag <- ShaderModule.managedShaderModule device "data/shaders/fir/godray_frag.spv"
  terrainVert <- ShaderModule.managedShaderModule device "data/shaders/fir/terrain_vert.spv"
  terrainFrag <- ShaderModule.managedShaderModule device "data/shaders/fir/terrain_frag.spv"
  terrainMesh <- ShaderModule.managedShaderModule device "data/shaders/fir/terrain_mesh.spv"
  terrainMeshFrag <- ShaderModule.managedShaderModule device "data/shaders/fir/terrain_mesh_frag.spv"
  apVolume <- ShaderModule.managedShaderModule device "data/shaders/fir/ap_volume_comp.spv"
  simpleForwardVert <- ShaderModule.managedShaderModule device "data/shaders/fir/simple_forward_vert.spv"
  simpleForwardFrag <- ShaderModule.managedShaderModule device "data/shaders/fir/simple_forward_frag.spv"
  bindlessVert <- ShaderModule.managedShaderModule device "data/shaders/fir/bindless_vert.spv"
  bindlessFrag <- ShaderModule.managedShaderModule device "data/shaders/fir/bindless_frag.spv"
  pure
    ShaderModules
      { smForward = ShaderPair forwardVert forwardFrag,
        smGBuffer = ShaderPair gbufVert gbufFrag,
        smLighting = ShaderPair lightVert lightFrag,
        smLightingProcedural = lightProcFrag,
        smWireframe = WireframeShaders wireVert (Just wireGeom) wireFrag,
        smCull = cull,
        smCloud = ShaderPair cloudVert cloudFrag,
        smGodRay = ShaderPair godrayVert godrayFrag,
        smTerrain = ShaderPair terrainVert terrainFrag,
        smTerrainMesh = MeshShaderProgram Nothing terrainMesh terrainMeshFrag,
        smAPVolume = apVolume,
        smSimpleForward = ShaderPair simpleForwardVert simpleForwardFrag,
        smBindless = ShaderPair bindlessVert bindlessFrag
      }

data IBLTextures = IBLTextures
  { iblRadiance :: !Cubemap,
    iblIrradiance :: !Cubemap,
    iblSampler :: !Vulkan.VkSampler,
    iblBrdfView :: !(Maybe Vulkan.VkImageView),
    iblCloudNoise :: !Cubemap,
    iblCloudDetailNoiseView :: !(Maybe Vulkan.VkImageView),
    iblBlueNoiseView :: !(Maybe Vulkan.VkImageView),
    iblBlueNoiseSampler :: !Vulkan.VkSampler,
    iblNoiseSampler :: !Vulkan.VkSampler,
    iblWeatherMapView :: !(Maybe Vulkan.VkImageView)
  }

-- | Load IBL cubemaps, BRDF LUT, and cloud noise texture
loadIBLTextures ::
  (MonadManaged m, MonadIO m, MonadLog m) =>
  VulkanContext ->
  ResourceManager ->
  String ->
  Bool ->
  m IBLTextures
loadIBLTextures vc@VulkanContext {..} rm envMapDir proceduralSkyEnabled = do
  lightingSampler <- Texture.createSamplerWithLod vcDevice 0
  logInfo LogGeneral "lighting sampler created"

  if proceduralSkyEnabled
    then do
      logInfo LogGeneral "procedural sky enabled: creating storage images..."
      -- Create storage images for compute shader output
      radianceHandle <- Texture.createStorageImageCube rm vc 512 Vulkan.VK_FORMAT_R16G16B16A16_SFLOAT
      irradianceHandle <- Texture.createStorageImageCube rm vc 64 Vulkan.VK_FORMAT_R16G16B16A16_SFLOAT
      mRadianceView <- Texture.textureImageView rm radianceHandle
      mIrradianceView <- Texture.textureImageView rm irradianceHandle
      logInfo LogGeneral "procedural sky storage images created"

      -- Transition radiance/irradiance to SHADER_READ_ONLY_OPTIMAL so fragment
      -- shaders can sample them before the first procedural sky compute dispatch
      mRadianceTex <- liftIO $ lookupTexture rm radianceHandle
      mIrradianceTex <- liftIO $ lookupTexture rm irradianceHandle
      CommandBuffer.withCommandBufferOneTime vcQueue vcCommandBuffer $ do
        case mRadianceTex of
          Just tex -> Texture.transitionStorageImageToShaderRead vcCommandBuffer (trImage tex) 6
          Nothing -> pure ()
        case mIrradianceTex of
          Just tex -> Texture.transitionStorageImageToShaderRead vcCommandBuffer (trImage tex) 6
          Nothing -> pure ()

      -- BRDF LUT (shared)
      let brdfPixels = BRDF.generateBRDFLUT 256 256
      brdfTexHandle <- Texture.createTextureFromData rm vc 256 256 brdfPixels
      mBrdfView <- Texture.textureImageView rm brdfTexHandle
      logInfo LogGeneral "BRDF LUT generated"

      -- Cloud textures (shared)
      logInfo LogGeneral "creating 3D cloud noise storage image..."
      cloudNoiseHandle <- Texture.createStorageImage3D rm vc 256 256 256 5 Vulkan.VK_FORMAT_R8G8B8A8_UNORM
      dispatchCloudNoiseGeneration vc rm cloudNoiseHandle (NoiseParams 42.0 2.0 0.5)
      cloudNoiseView <- Texture.textureImageView rm cloudNoiseHandle
      logInfo LogGeneral "3D cloud noise texture generated"

      logInfo LogGeneral "creating 3D cloud detail noise storage image..."
      cloudDetailNoiseHandle <- Texture.createStorageImage3D rm vc 64 64 64 1 Vulkan.VK_FORMAT_R8G8B8A8_UNORM
      dispatchCloudDetailNoiseGeneration vc rm cloudDetailNoiseHandle
      cloudDetailNoiseView <- Texture.textureImageView rm cloudDetailNoiseHandle
      logInfo LogGeneral "3D cloud detail noise texture generated"

      logInfo LogGeneral "loading blue noise texture..."
      blueNoiseRaw <- liftIO $ BS.readFile "data/textures/blue_noise/blue_noise_64.raw"
      let blueNoisePixels = Data.Vector.Storable.fromList (BS.unpack blueNoiseRaw)
      blueNoiseHandle <- Texture.createTextureFromData rm vc 64 64 blueNoisePixels
      mBlueNoiseView <- Texture.textureImageView rm blueNoiseHandle
      blueNoiseSampler <- Texture.managedSamplerNearest vcDevice
      noiseSampler <- Texture.managedSamplerWithLod vcDevice 4.0
      logInfo LogGeneral "blue noise texture loaded"

      logInfo LogGeneral "creating weather map storage image..."
      weatherMapHandle <- Texture.createStorageImage2D rm vc Const.weatherMapSize Const.weatherMapSize Vulkan.VK_FORMAT_R8G8B8A8_UNORM
      dispatchWeatherMapGeneration vc rm weatherMapHandle
      weatherMapView <- Texture.textureImageView rm weatherMapHandle
      logInfo LogGeneral "weather map texture generated"

      -- Dispatch compute shaders to fill storage images
      let V3 dirX dirY dirZ = V3 0.0 0.3 (-1.0)
          defaultSunElevation = pi / 6.0
          defaultSunIntensity = 50.0
      dispatchProceduralSkyGeneration vc rm radianceHandle irradianceHandle (V3 dirX dirY dirZ) defaultSunElevation defaultSunIntensity

      pure
        IBLTextures
          { iblRadiance = Cubemap radianceHandle mRadianceView,
            iblIrradiance = Cubemap irradianceHandle mIrradianceView,
            iblSampler = lightingSampler,
            iblBrdfView = mBrdfView,
            iblCloudNoise = Cubemap cloudNoiseHandle cloudNoiseView,
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
      radianceCubemap <- Texture.createCubemapMips rm vc radSize radDatas
      irradianceCubemap <- Texture.createCubemap rm vc irrSize irrDatas
      mRadianceView <- Texture.textureImageView rm radianceCubemap
      mIrradianceView <- Texture.textureImageView rm irradianceCubemap
      logInfo LogGeneral $ "IBL cubemaps loaded: radiance=" <> showT radSize <> "px irradiance=" <> showT irrSize <> "px mipLevels=" <> showT radMipLevels

      let brdfPixels = BRDF.generateBRDFLUT 256 256
      brdfTexHandle <- Texture.createTextureFromData rm vc 256 256 brdfPixels
      mBrdfView <- Texture.textureImageView rm brdfTexHandle
      logInfo LogGeneral "BRDF LUT generated"

      logInfo LogGeneral "creating 3D cloud noise storage image..."
      cloudNoiseHandle <- Texture.createStorageImage3D rm vc 256 256 256 5 Vulkan.VK_FORMAT_R8G8B8A8_UNORM
      dispatchCloudNoiseGeneration vc rm cloudNoiseHandle (NoiseParams 42.0 2.0 0.5)
      cloudNoiseView <- Texture.textureImageView rm cloudNoiseHandle
      logInfo LogGeneral "3D cloud noise texture generated"

      logInfo LogGeneral "creating 3D cloud detail noise storage image..."
      cloudDetailNoiseHandle <- Texture.createStorageImage3D rm vc 64 64 64 1 Vulkan.VK_FORMAT_R8G8B8A8_UNORM
      dispatchCloudDetailNoiseGeneration vc rm cloudDetailNoiseHandle
      cloudDetailNoiseView <- Texture.textureImageView rm cloudDetailNoiseHandle
      logInfo LogGeneral "3D cloud detail noise texture generated"

      logInfo LogGeneral "loading blue noise texture..."
      blueNoiseRaw <- liftIO $ BS.readFile "data/textures/blue_noise/blue_noise_64.raw"
      let blueNoisePixels = Data.Vector.Storable.fromList (BS.unpack blueNoiseRaw)
      blueNoiseHandle <- Texture.createTextureFromData rm vc 64 64 blueNoisePixels
      mBlueNoiseView <- Texture.textureImageView rm blueNoiseHandle
      blueNoiseSampler <- Texture.managedSamplerNearest vcDevice
      noiseSampler <- Texture.managedSamplerWithLod vcDevice 4.0
      logInfo LogGeneral "blue noise texture loaded"

      logInfo LogGeneral "creating weather map storage image..."
      weatherMapHandle <- Texture.createStorageImage2D rm vc Const.weatherMapSize Const.weatherMapSize Vulkan.VK_FORMAT_R8G8B8A8_UNORM
      dispatchWeatherMapGeneration vc rm weatherMapHandle
      weatherMapView <- Texture.textureImageView rm weatherMapHandle
      logInfo LogGeneral "weather map texture generated"

      pure
        IBLTextures
          { iblRadiance = Cubemap radianceCubemap mRadianceView,
            iblIrradiance = Cubemap irradianceCubemap mIrradianceView,
            iblSampler = lightingSampler,
            iblBrdfView = mBrdfView,
            iblCloudNoise = Cubemap cloudNoiseHandle cloudNoiseView,
            iblCloudDetailNoiseView = cloudDetailNoiseView,
            iblBlueNoiseView = mBlueNoiseView,
            iblBlueNoiseSampler = blueNoiseSampler,
            iblNoiseSampler = noiseSampler,
            iblWeatherMapView = weatherMapView
          }

data TerrainTextures = TerrainTextures
  { ttElevationHandle :: !(Maybe TextureHandle),
    ttClimateHandle :: !(Maybe TextureHandle),
    ttElevationView :: !(Maybe Vulkan.VkImageView),
    ttClimateView :: !(Maybe Vulkan.VkImageView)
  }

-- | Load terrain tile from inference API and upload to GPU textures.
loadTerrainTextures ::
  (MonadManaged m, MonadIO m, MonadLog m) =>
  VulkanContext ->
  ResourceManager ->
  String ->
  m TerrainTextures
loadTerrainTextures vc rm host = do
  logInfo LogGeneral "loading terrain tile from API..."
  result <- Terrain.fetchAndUploadTerrainTile rm vc host 0 0 256 256 1
  case result of
    Left err -> do
      logInfo LogGeneral $ "terrain load failed: " <> Text.pack (show err)
      pure
        TerrainTextures
          { ttElevationHandle = Nothing,
            ttClimateHandle = Nothing,
            ttElevationView = Nothing,
            ttClimateView = Nothing
          }
    Right (elevHandle, climateHandle) -> do
      mElevView <- Texture.textureImageView rm elevHandle
      mClimateView <- Texture.textureImageView rm climateHandle
      logInfo LogGeneral "terrain tile loaded and uploaded to GPU"
      pure
        TerrainTextures
          { ttElevationHandle = Just elevHandle,
            ttClimateHandle = Just climateHandle,
            ttElevationView = mElevView,
            ttClimateView = mClimateView
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
  (MonadManaged m, MonadIO m, MonadLog m) =>
  VulkanContext ->
  ResourceManager ->
  AssetCache ->
  String ->
  Maybe UVCheckMode ->
  Maybe Mesh.Mesh ->
  Bool -> -- ^ mesh terrain enabled
  m SceneLoadResult
loadScene vc@VulkanContext {..} rm assetCache meshName uvCheckMode mSimpleMesh meshTerrainEnabled = do
  let isGLTF = ".gltf" `Text.isSuffixOf` Text.pack meshName || ".glb" `Text.isSuffixOf` Text.pack meshName
      isStressTest = meshName == "stress_test"
  case mSimpleMesh of
    Just mesh -> loadSimpleMesh vc rm mesh
    Nothing ->
      case uvCheckMode of
        Just mode -> do
          world <- ECS.createWorld
          let uvCheckerPath = "data/textures/uv_checker.png"
          (tw, th, pixelData) <-
            liftIO (doesFileExist uvCheckerPath) >>= \exists ->
              if exists
                then do
                  (pixelData, tw, th) <- Texture.readImageFromFile uvCheckerPath
                  pure (tw, th, pixelData)
                else do
                  let checkerTexData = Texture.generateCheckerboardTexture 256 256 32
                  pure (256, 256, checkerTexData)
          let testMesh = case mode of
                UVCheckCube -> Mesh.unitCube
                UVCheckSphere -> Mesh.uvSphere 32 16 1.0
                UVCheckPlane -> Mesh.uvPlane 1.0
          uvTexHandle <- Texture.createTextureFromData rm vc tw th pixelData
          testMeshHandle <- Buffer.createMeshResource rm vcPhysicalDevice vcDevice (Mesh.vertices testMesh) (Mesh.indices testMesh)
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
              meshHandle <- Buffer.createMeshResource rm vcPhysicalDevice vcDevice (Mesh.vertices cubeMesh) (Mesh.indices cubeMesh)

              let whiteTexData = Texture.generateGridTexture 2 2 1
              whiteTexHandle <- Texture.createTextureFromData rm vc 2 2 whiteTexData

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
                  result <- importGLTF rm vcPhysicalDevice vcDevice vcQueue vcCommandBuffer assetCache meshName
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
                  meshHandle <- Buffer.createMeshResource rm vcPhysicalDevice vcDevice (Mesh.vertices mesh) (Mesh.indices mesh)

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

                  unless meshTerrainEnabled $ do
                    let groundMesh = Mesh.groundPlaneMesh 50.0
                    groundMeshHandle <- Buffer.createMeshResource rm vcPhysicalDevice vcDevice (Mesh.vertices groundMesh) (Mesh.indices groundMesh)
                    let checkerTexData = Texture.generateCheckerboardTexture 256 256 32
                    checkerTexHandle <- Texture.createTextureFromData rm vc 256 256 checkerTexData
                    groundEntity <- ECS.spawnEntity world
                    ECS.setTransform world groundEntity (Transform (V3 0 (-0.5) 0) (Quaternion 1 (V3 0 0 0)) (V3 1 1 1))
                    ECS.setMesh world groundEntity groundMeshHandle
                    ECS.setMaterial world groundEntity checkerTexHandle
                    ECS.setMetallicFactor world groundEntity 0.0
                    ECS.setRoughnessFactor world groundEntity 1.0

                  sceneBbox <- liftIO $ computeWorldSpaceBounds world rm
                  logInfo LogGeneral $ "scene bounds: " <> showT sceneBbox

                  pure $ SceneLoadResult world 1 sceneBbox IntMap.empty []

-- | Load a single user-provided mesh with a white texture fallback.
-- Used by the 'runSimple' API for minimal primitive rendering.
loadSimpleMesh ::
  (MonadManaged m, MonadIO m, MonadLog m) =>
  VulkanContext ->
  ResourceManager ->
  Mesh.Mesh ->
  m SceneLoadResult
loadSimpleMesh vc@VulkanContext {..} rm mesh = do
  world <- ECS.createWorld
  let whiteTexData = Texture.generateGridTexture 2 2 1
  whiteTexHandle <- Texture.createTextureFromData rm vc 2 2 whiteTexData
  meshHandle <- Buffer.createMeshResource rm vcPhysicalDevice vcDevice (Mesh.vertices mesh) (Mesh.indices mesh)
  entity <- ECS.spawnEntity world
  ECS.setTransform world entity (Transform (V3 0 0 0) (Quaternion 1 (V3 0 0 0)) (V3 1 1 1))
  ECS.setMesh world entity meshHandle
  ECS.setMaterial world entity whiteTexHandle
  ECS.setMetallicFactor world entity 0.0
  ECS.setRoughnessFactor world entity 0.5
  let sceneBbox = BBox (V3 (-1) (-1) (-1)) (V3 1 1 1)
  pure $ SceneLoadResult world 1 sceneBbox IntMap.empty []

-- | Dispatch compute shaders to generate procedural sky content.
-- Creates temporary pipelines, dispatches, transitions images, and cleans up.
dispatchProceduralSkyGeneration ::
  (MonadManaged m, MonadIO m, MonadLog m) =>
  VulkanContext ->
  ResourceManager ->
  TextureHandle -> -- radiance
  TextureHandle -> -- irradiance
  V3 Float -> -- sun direction
  Float -> -- sun elevation (for HW coeffs)
  Float -> -- sun intensity
  m ()
dispatchProceduralSkyGeneration VulkanContext {..} rm radianceHandle irradianceHandle sunDir sunElevation sunIntensity = do
  logInfo LogGeneral "dispatching procedural sky compute shaders..."

  -- Load compute shader modules
  radianceShader <- ShaderModule.managedShaderModule vcDevice "data/shaders/fir/radiance_comp.spv"
  irradianceShader <- ShaderModule.managedShaderModule vcDevice "data/shaders/fir/irradiance_comp.spv"

  -- Create descriptor set layout
  cubemapLayout <- DescriptorSetLayout.managedCubemapComputeDescriptorSetLayout vcDevice

  -- Create pipeline layout
  cubemapPipelineLayout <- PipelineLayout.managedPipelineLayout vcDevice [cubemapLayout]

  -- Create pipelines
  radiancePipeline <- ComputePipeline.managedComputePipeline vcDevice cubemapPipelineLayout radianceShader
  irradiancePipeline <- ComputePipeline.managedComputePipeline vcDevice cubemapPipelineLayout irradianceShader

  -- Create descriptor pool
  cubemapPool <- DescriptorPool.managedCubemapComputeDescriptorPool vcDevice

  -- Allocate descriptor sets
  radianceDescriptorSet <- DescriptorSet.allocateDescriptorSet vcDevice cubemapPool [cubemapLayout]
  irradianceDescriptorSet <- DescriptorSet.allocateDescriptorSet vcDevice cubemapPool [cubemapLayout]

  -- Create UBO with dynamic sky params
  let hwCoeffs = computeHWCoeffs $ SkyConfig 2.0 0.3 (max 0.0 sunElevation)
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
  (skyParamsBuffer, _skyParamsMemory) <- Buffer.managedUniformBuffer vcPhysicalDevice vcDevice [skyParams]

  -- Get image views
  mRadianceView <- Texture.textureImageView rm radianceHandle
  mIrradianceView <- Texture.textureImageView rm irradianceHandle

  -- Update descriptor sets
  case (mRadianceView, mIrradianceView) of
    (Just radianceView, Just irradianceView) -> do
      DescriptorSet.updateCubemapComputeDescriptorSets vcDevice radianceDescriptorSet radianceView skyParamsBuffer
      DescriptorSet.updateCubemapComputeDescriptorSets vcDevice irradianceDescriptorSet irradianceView skyParamsBuffer
    _ -> logInfo LogGeneral "warning: cubemap views not found"

  mRadianceTex <- liftIO $ lookupTexture rm radianceHandle
  mIrradianceTex <- liftIO $ lookupTexture rm irradianceHandle

  CommandBuffer.withCommandBufferOneTime vcQueue vcCommandBuffer $ do
    -- Transition storage images to GENERAL for compute write
    case mRadianceTex of
      Just tex ->
        CommandBuffer.mipLayerTransition
          vcCommandBuffer
          (trImage tex)
          Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
          Vulkan.VK_IMAGE_LAYOUT_GENERAL
          0
          1
          6
      Nothing -> pure ()
    case mIrradianceTex of
      Just tex ->
        CommandBuffer.mipLayerTransition
          vcCommandBuffer
          (trImage tex)
          Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
          Vulkan.VK_IMAGE_LAYOUT_GENERAL
          0
          1
          6
      Nothing -> pure ()

    -- Radiance: 512x512x6 / 8x8 = 64x64x6 workgroups
    liftIO $ Vulkan.vkCmdBindPipeline vcCommandBuffer Vulkan.VK_PIPELINE_BIND_POINT_COMPUTE radiancePipeline
    liftIO $ Foreign.Marshal.Array.withArray [radianceDescriptorSet] $ \dsPtr ->
      Vulkan.vkCmdBindDescriptorSets
        vcCommandBuffer
        Vulkan.VK_PIPELINE_BIND_POINT_COMPUTE
        cubemapPipelineLayout
        0
        1
        dsPtr
        0
        Vulkan.vkNullPtr
    CommandBuffer.cmdDispatch vcCommandBuffer 64 64 6

    -- Irradiance: 64x64x6 / 8x8 = 8x8x6 workgroups
    liftIO $ Vulkan.vkCmdBindPipeline vcCommandBuffer Vulkan.VK_PIPELINE_BIND_POINT_COMPUTE irradiancePipeline
    liftIO $ Foreign.Marshal.Array.withArray [irradianceDescriptorSet] $ \dsPtr ->
      Vulkan.vkCmdBindDescriptorSets
        vcCommandBuffer
        Vulkan.VK_PIPELINE_BIND_POINT_COMPUTE
        cubemapPipelineLayout
        0
        1
        dsPtr
        0
        Vulkan.vkNullPtr
    CommandBuffer.cmdDispatch vcCommandBuffer 8 8 6

    -- Transition storage images to SHADER_READ_ONLY_OPTIMAL
    case mRadianceTex of
      Just tex -> Texture.transitionStorageImageToShaderRead vcCommandBuffer (trImage tex) 6
      Nothing -> pure ()
    case mIrradianceTex of
      Just tex -> Texture.transitionStorageImageToShaderRead vcCommandBuffer (trImage tex) 6
      Nothing -> pure ()

  logInfo LogGeneral "procedural sky compute dispatch complete"

-- | Dispatch cloud noise generation compute shader to fill a 3D storage image.
dispatchCloudNoiseGeneration ::
  (MonadManaged m, MonadIO m, MonadLog m) =>
  VulkanContext ->
  ResourceManager ->
  TextureHandle -> -- 3D noise storage image
  NoiseParams ->
  m ()
dispatchCloudNoiseGeneration VulkanContext {..} rm noiseHandle NoiseParams {..} = do
  logInfo LogGeneral "dispatching cloud noise compute shader..."

  -- Load compute shader module
  noiseShader <- ShaderModule.managedShaderModule vcDevice "data/shaders/fir/cloud_noise_comp.spv"

  -- Create descriptor set layout
  noiseLayout <- DescriptorSetLayout.managedCloudNoiseComputeDescriptorSetLayout vcDevice

  -- Create pipeline layout
  noisePipelineLayout <- PipelineLayout.managedPipelineLayout vcDevice [noiseLayout]

  -- Create pipeline
  noisePipeline <- ComputePipeline.managedComputePipeline vcDevice noisePipelineLayout noiseShader

  -- Create descriptor pool
  noisePool <- DescriptorPool.managedCloudNoiseComputeDescriptorPool vcDevice

  -- Allocate descriptor set
  noiseDescriptorSet <- DescriptorSet.allocateDescriptorSet vcDevice noisePool [noiseLayout]

  -- Create UBO with noise params
  let noiseParams =
        NoiseGenUniforms
          { ngSeed = npSeed,
            ngFrequency = npFrequency,
            ngPersistence = npPersistence,
            ngZSlice = 0.0
          }
  (noiseParamsBuffer, _noiseParamsMemory) <- Buffer.managedUniformBuffer vcPhysicalDevice vcDevice [noiseParams]

  -- Get image view
  mNoiseView <- Texture.textureImageView rm noiseHandle

  -- Update descriptor set
  case mNoiseView of
    Just noiseView -> DescriptorSet.updateCloudNoiseComputeDescriptorSets vcDevice noiseDescriptorSet noiseView noiseParamsBuffer
    Nothing -> logInfo LogGeneral "warning: cloud noise view not found"

  -- Get VkImage handle and dimensions for mipgen
  mNoiseTex <- liftIO $ lookupTexture rm noiseHandle
  let (noiseImage, noiseW, noiseH) = case mNoiseTex of
        Just tex -> (trImage tex, trWidth tex, trHeight tex)
        Nothing -> (Vulkan.vkNullPtr, 0, 0)
      noiseD = noiseW -- 3D texture, depth == width (256)
      mipLevels = 5

  -- Set up mipgen compute pipeline
  mipgenShader <- ShaderModule.managedShaderModule vcDevice "data/shaders/fir/cloud_noise_mipgen_comp.spv"
  mipgenLayout <- DescriptorSetLayout.managedCloudNoiseMipGenComputeDescriptorSetLayout vcDevice
  mipgenPipelineLayout <- PipelineLayout.managedPipelineLayout vcDevice [mipgenLayout]
  mipgenPipeline <- ComputePipeline.managedComputePipeline vcDevice mipgenPipelineLayout mipgenShader
  mipgenPool <- DescriptorPool.managedCloudNoiseMipGenComputeDescriptorPool vcDevice
  -- Allocate 4 descriptor sets (one per mip level)
  mipgenDescriptorSets <- replicateM (mipLevels - 1) $ DescriptorSet.allocateDescriptorSet vcDevice mipgenPool [mipgenLayout]

  -- Create per-mip image views for the noise texture
  let noiseFormat = Vulkan.VK_FORMAT_R8G8B8A8_UNORM
  mipViews <-
    if noiseImage /= Vulkan.vkNullPtr
      then forM [0 .. mipLevels - 1] $ \mip -> do
        liftIO $ ImageView.createImageView3DSingleMip vcDevice noiseFormat noiseImage (fromIntegral mip)
      else pure (replicate mipLevels Vulkan.vkNullPtr)

  -- Create per-mip UBOs and pre-update all descriptor sets
  mipParamsBuffers <- forM [1 .. mipLevels - 1] $ \mip -> do
    let srcMip = mip - 1
        dstMip = mip
        srcSize = fromIntegral (noiseW `div` (2 ^ srcMip)) :: Foreign.C.CInt
    (buf, mem) <- Buffer.managedUniformBuffer vcPhysicalDevice vcDevice [srcSize]
    -- Update descriptor set with src/dst views
    DescriptorSet.updateCloudNoiseMipGenComputeDescriptorSets vcDevice (mipgenDescriptorSets !! (mip - 1)) (mipViews !! srcMip) (mipViews !! dstMip) buf
    pure (buf, mem)

  -- Dispatch compute shader + generate mipmaps
  CommandBuffer.withCommandBufferOneTime vcQueue vcCommandBuffer $ do
    -- Transition all mips to GENERAL for compute write (image may be in any layout from creation)
    when (noiseImage /= Vulkan.vkNullPtr) $
      CommandBuffer.mipLayerTransition
        vcCommandBuffer
        noiseImage
        Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
        Vulkan.VK_IMAGE_LAYOUT_GENERAL
        0
        (fromIntegral mipLevels)
        1
    -- 256x256x256 / 8x8x4 = 32x32x64 workgroups
    liftIO $ Vulkan.vkCmdBindPipeline vcCommandBuffer Vulkan.VK_PIPELINE_BIND_POINT_COMPUTE noisePipeline
    liftIO $ Foreign.Marshal.Array.withArray [noiseDescriptorSet] $ \dsPtr ->
      Vulkan.vkCmdBindDescriptorSets
        vcCommandBuffer
        Vulkan.VK_PIPELINE_BIND_POINT_COMPUTE
        noisePipelineLayout
        0
        1
        dsPtr
        0
        Vulkan.vkNullPtr
    CommandBuffer.cmdDispatch vcCommandBuffer 32 32 64

    -- Generate mipmaps 1..4 using REPEAT-aware compute shader
    when (noiseImage /= Vulkan.vkNullPtr) $ do
      forM_ [1 .. mipLevels - 1] $ \mip -> do
        let srcMip = mip - 1
            dstMip = mip
            dstW = noiseW `div` (2 ^ mip)
            dstH = noiseH `div` (2 ^ mip)
            dstD = noiseD `div` (2 ^ mip)
            ds = mipgenDescriptorSets !! (mip - 1)

        -- Transition dst mip to GENERAL for compute write
        CommandBuffer.mipLayerTransition
          vcCommandBuffer
          noiseImage
          Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
          Vulkan.VK_IMAGE_LAYOUT_GENERAL
          (fromIntegral dstMip)
          1
          1

        -- Dispatch mipgen compute shader
        liftIO $ Vulkan.vkCmdBindPipeline vcCommandBuffer Vulkan.VK_PIPELINE_BIND_POINT_COMPUTE mipgenPipeline
        liftIO $ Foreign.Marshal.Array.withArray [ds] $ \dsPtr ->
          Vulkan.vkCmdBindDescriptorSets
            vcCommandBuffer
            Vulkan.VK_PIPELINE_BIND_POINT_COMPUTE
            mipgenPipelineLayout
            0
            1
            dsPtr
            0
            Vulkan.vkNullPtr
        CommandBuffer.cmdDispatch vcCommandBuffer (fromIntegral (dstW `div` 8)) (fromIntegral (dstH `div` 8)) (fromIntegral (dstD `div` 4))

        -- Barrier: ensure compute writes are visible to next dispatch's reads
        let memoryBarrier =
              Vulkan.createVk
                ( Vulkan.set @"sType" Vulkan.VK_STRUCTURE_TYPE_MEMORY_BARRIER
                    Vulkan.&* Vulkan.set @"pNext" Vulkan.VK_NULL
                    Vulkan.&* Vulkan.set @"srcAccessMask" Vulkan.VK_ACCESS_SHADER_WRITE_BIT
                    Vulkan.&* Vulkan.set @"dstAccessMask" Vulkan.VK_ACCESS_SHADER_READ_BIT
                )
        liftIO $ Vulkan.withPtr memoryBarrier $ \bPtr ->
          Vulkan.vkCmdPipelineBarrier
            vcCommandBuffer
            Vulkan.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT
            Vulkan.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT
            Vulkan.VK_ZERO_FLAGS
            1
            bPtr
            0
            Vulkan.vkNullPtr
            0
            Vulkan.vkNullPtr

      -- Transition all mips to SHADER_READ_ONLY_OPTIMAL
      CommandBuffer.mipLayerTransition
        vcCommandBuffer
        noiseImage
        Vulkan.VK_IMAGE_LAYOUT_GENERAL
        Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
        0
        (fromIntegral mipLevels)
        1

  logInfo LogGeneral "cloud noise compute dispatch + mipgen complete"

-- | Dispatch cloud detail noise generation compute shader to fill a 64^3 3D storage image.
dispatchCloudDetailNoiseGeneration ::
  (MonadManaged m, MonadIO m, MonadLog m) =>
  VulkanContext ->
  ResourceManager ->
  TextureHandle -> -- 3D detail noise storage image
  m ()
dispatchCloudDetailNoiseGeneration VulkanContext {..} rm noiseHandle = do
  logInfo LogGeneral "dispatching cloud detail noise compute shader..."

  noiseShader <- ShaderModule.managedShaderModule vcDevice "data/shaders/fir/cloud_detail_noise_comp.spv"
  noiseLayout <- DescriptorSetLayout.managedCloudDetailNoiseComputeDescriptorSetLayout vcDevice
  noisePipelineLayout <- PipelineLayout.managedPipelineLayout vcDevice [noiseLayout]
  noisePipeline <- ComputePipeline.managedComputePipeline vcDevice noisePipelineLayout noiseShader
  noisePool <- DescriptorPool.managedCloudDetailNoiseComputeDescriptorPool vcDevice
  noiseDescriptorSet <- DescriptorSet.allocateDescriptorSet vcDevice noisePool [noiseLayout]

  let noiseParams =
        NoiseGenUniforms
          { ngSeed = 123.0,
            ngFrequency = 4.0,
            ngPersistence = 0.5,
            ngZSlice = 0.0
          }
  (noiseParamsBuffer, _noiseParamsMemory) <- Buffer.managedUniformBuffer vcPhysicalDevice vcDevice [noiseParams]

  mNoiseView <- Texture.textureImageView rm noiseHandle
  case mNoiseView of
    Just noiseView -> DescriptorSet.updateCloudDetailNoiseComputeDescriptorSets vcDevice noiseDescriptorSet noiseView noiseParamsBuffer
    Nothing -> logInfo LogGeneral "warning: cloud detail noise view not found"

  mNoiseTex <- liftIO $ lookupTexture rm noiseHandle
  let (noiseImage, _) = case mNoiseTex of
        Just tex -> (trImage tex, trWidth tex)
        Nothing -> (Vulkan.vkNullPtr, 0)

  CommandBuffer.withCommandBufferOneTime vcQueue vcCommandBuffer $ do
    -- 64x64x64 / 8x8x8 = 8x8x8 workgroups
    liftIO $ Vulkan.vkCmdBindPipeline vcCommandBuffer Vulkan.VK_PIPELINE_BIND_POINT_COMPUTE noisePipeline
    liftIO $ Foreign.Marshal.Array.withArray [noiseDescriptorSet] $ \dsPtr ->
      Vulkan.vkCmdBindDescriptorSets
        vcCommandBuffer
        Vulkan.VK_PIPELINE_BIND_POINT_COMPUTE
        noisePipelineLayout
        0
        1
        dsPtr
        0
        Vulkan.vkNullPtr
    CommandBuffer.cmdDispatch vcCommandBuffer 8 8 8

    -- Transition to SHADER_READ_ONLY_OPTIMAL
    when (noiseImage /= Vulkan.vkNullPtr) $ do
      CommandBuffer.mipLayerTransition
        vcCommandBuffer
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
  VulkanContext ->
  ResourceManager ->
  TextureHandle -> -- 2D weather map storage image
  m ()
dispatchWeatherMapGeneration VulkanContext {..} rm weatherHandle = do
  logInfo LogGeneral "dispatching weather map compute shader..."

  weatherShader <- ShaderModule.managedShaderModule vcDevice "data/shaders/fir/weather_map_comp.spv"
  weatherLayout <- DescriptorSetLayout.managedWeatherMapComputeDescriptorSetLayout vcDevice
  weatherPipelineLayout <- PipelineLayout.managedPipelineLayout vcDevice [weatherLayout]
  weatherPipeline <- ComputePipeline.managedComputePipeline vcDevice weatherPipelineLayout weatherShader
  weatherPool <- DescriptorPool.managedWeatherMapComputeDescriptorPool vcDevice
  weatherDescriptorSet <- DescriptorSet.allocateDescriptorSet vcDevice weatherPool [weatherLayout]

  let weatherParams =
        WeatherMapUniforms
          { wmSeed = 42.0,
            wmCoverageScale = 16.0,
            wmTypeScale = 24.0,
            wmHeightScale = 8.0
          }
  (weatherParamsBuffer, _weatherParamsMemory) <- Buffer.managedUniformBuffer vcPhysicalDevice vcDevice [weatherParams]

  mWeatherView <- Texture.textureImageView rm weatherHandle
  case mWeatherView of
    Just weatherView -> DescriptorSet.updateWeatherMapComputeDescriptorSets vcDevice weatherDescriptorSet weatherView weatherParamsBuffer
    Nothing -> logInfo LogGeneral "warning: weather map view not found"

  mWeatherTex <- liftIO $ lookupTexture rm weatherHandle
  let (weatherImage, _) = case mWeatherTex of
        Just tex -> (trImage tex, trWidth tex)
        Nothing -> (Vulkan.vkNullPtr, 0)

  CommandBuffer.withCommandBufferOneTime vcQueue vcCommandBuffer $ do
    -- 1024x1024 / 8x8 = 128x128x1 workgroups
    liftIO $ Vulkan.vkCmdBindPipeline vcCommandBuffer Vulkan.VK_PIPELINE_BIND_POINT_COMPUTE weatherPipeline
    liftIO $ Foreign.Marshal.Array.withArray [weatherDescriptorSet] $ \dsPtr ->
      Vulkan.vkCmdBindDescriptorSets
        vcCommandBuffer
        Vulkan.VK_PIPELINE_BIND_POINT_COMPUTE
        weatherPipelineLayout
        0
        1
        dsPtr
        0
        Vulkan.vkNullPtr
    CommandBuffer.cmdDispatch vcCommandBuffer 128 128 1

    -- Transition to SHADER_READ_ONLY_OPTIMAL
    when (weatherImage /= Vulkan.vkNullPtr) $ do
      CommandBuffer.mipLayerTransition
        vcCommandBuffer
        weatherImage
        Vulkan.VK_IMAGE_LAYOUT_GENERAL
        Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
        0
        1
        1

  logInfo LogGeneral "weather map compute dispatch complete"
