{-# LANGUAGE LambdaCase #-}

module Graphics.Haskan.Engine.Render.Internal.Setup
  ( compileAllShaders,
    createShaderModules,
    loadIBLTextures,
    IBLTextures (..),
    SceneLoadResult (..),
    loadScene,
  )
where

import Control.Monad (forM, forM_, replicateM, unless, when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.List (nub)
import Data.Maybe (catMaybes, fromMaybe, listToMaybe)
import Data.Text qualified as Text
import Data.Vector.Storable (Vector)
import Data.Vector.Storable qualified as VS
import Data.Word (Word32, Word8)
import FIR qualified
import Foreign.C qualified
import Graphics.Haskan.Assets.Cache (AssetCache)
import Graphics.Haskan.BoundingBox (BBox (..), emptyBBox, fromPoints)
import Graphics.Haskan.Camera (AnyCamera, Camera (..))
import Graphics.Haskan.Camera qualified as Camera
import Graphics.Haskan.DayNight (computeSunState, defaultDayNightConfig)
import Graphics.Haskan.DayNight qualified as DayNight
import Graphics.Haskan.Engine.Capabilities.Log (MonadLog (..), logInfo)
import Graphics.Haskan.Engine.Scene (adjustCameraForScene, computeMeshBounds, computeSceneBounds, computeSkyboxRays, computeWorldSpaceBounds, drawCallToSnapshot, makeProjectionMatrix)
import Graphics.Haskan.Engine.Types (ComputeCullData (..), ComputeCullResources (..), ComputeEntityData (..), ControlMessage (..), DrawIndexedIndirectCommand (..), EngineConfig (..), EntityDebugInfo (..), FrameStats (..), FrameTime (..), GameState (..), InputBuffer (..), LightData (..), RenderDebugInfo (..), WorldState (..), emptyFrameStats, extractFrustumPlanes, filterVisible, flushInputBuffer, forkIOWithHandler, newInputBuffer, toListOfV4, transformAABB, updateFrameStats, writeInputBuffer)
import Graphics.Haskan.Input (Action (..), ActionEvent, payloadToActionEvent)
import Graphics.Haskan.Logger (LogCategory (..), logInfoIO, showT)
import Graphics.Haskan.Mesh qualified as Mesh
import Graphics.Haskan.Model qualified as Model
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
import Graphics.Haskan.Vulkan.DeferredResources (DeferredResources (..), createDeferredResources)
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
import Graphics.Haskan.Vulkan.Resources (ResourceManager, TextureHandle (..))
import Graphics.Haskan.Vulkan.Semaphore qualified as Semaphore
import Graphics.Haskan.Vulkan.ShaderModule qualified as ShaderModule
import Graphics.Haskan.Vulkan.Shaders.Compute.Cull qualified as CullShaders
import Graphics.Haskan.Vulkan.Shaders.Deferred.Clouds qualified as CloudShaders
import Graphics.Haskan.Vulkan.Shaders.Deferred.GBuffer qualified as GBufferShaders
import Graphics.Haskan.Vulkan.Shaders.Deferred.Lighting qualified as LightingShaders
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
  liftIO $ FIR.compileTo "data/shaders/fir/wire_vert.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] WireframeShaders.vertex
  logInfo LogGeneral "  wire_vert.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/wire_geom.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] WireframeShaders.geometry
  logInfo LogGeneral "  wire_geom.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/wire_frag.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] WireframeShaders.fragment
  logInfo LogGeneral "  wire_frag.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/cull_comp.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] CullShaders.program
  logInfo LogGeneral "  cull_comp.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/cloud_vert.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] CloudShaders.cloudVertex
  logInfo LogGeneral "  cloud_vert.spv done"
  liftIO $ FIR.compileTo "data/shaders/fir/cloud_frag.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] CloudShaders.cloudFragment
  logInfo LogGeneral "  cloud_frag.spv done"

-- | Create all shader modules from compiled SPIR-V
createShaderModules ::
  (MonadManaged m, MonadIO m) =>
  Vulkan.VkDevice ->
  m
    ( Vulkan.VkShaderModule,
      Vulkan.VkShaderModule,
      Vulkan.VkShaderModule,
      Vulkan.VkShaderModule,
      Vulkan.VkShaderModule,
      Vulkan.VkShaderModule,
      Vulkan.VkShaderModule,
      Vulkan.VkShaderModule,
      Vulkan.VkShaderModule,
      Vulkan.VkShaderModule,
      Vulkan.VkShaderModule,
      Vulkan.VkShaderModule
    )
createShaderModules device = do
  vertShader <- ShaderModule.managedShaderModule device "data/shaders/fir/vert.spv"
  fragShader <- ShaderModule.managedShaderModule device "data/shaders/fir/frag.spv"
  gbufVertShader <- ShaderModule.managedShaderModule device "data/shaders/fir/gbuf_vert.spv"
  gbufFragShader <- ShaderModule.managedShaderModule device "data/shaders/fir/gbuf_frag.spv"
  lightVertShader <- ShaderModule.managedShaderModule device "data/shaders/fir/light_vert.spv"
  lightFragShader <- ShaderModule.managedShaderModule device "data/shaders/fir/light_frag.spv"
  wireVertShader <- ShaderModule.managedShaderModule device "data/shaders/fir/wire_vert.spv"
  wireGeomShader <- ShaderModule.managedShaderModule device "data/shaders/fir/wire_geom.spv"
  wireFragShader <- ShaderModule.managedShaderModule device "data/shaders/fir/wire_frag.spv"
  cullShader <- ShaderModule.managedShaderModule device "data/shaders/fir/cull_comp.spv"
  cloudVertShader <- ShaderModule.managedShaderModule device "data/shaders/fir/cloud_vert.spv"
  cloudFragShader <- ShaderModule.managedShaderModule device "data/shaders/fir/cloud_frag.spv"
  pure (vertShader, fragShader, gbufVertShader, gbufFragShader, lightVertShader, lightFragShader, wireVertShader, wireGeomShader, wireFragShader, cullShader, cloudVertShader, cloudFragShader)

data IBLTextures = IBLTextures
  { iblRadianceCubemap :: !TextureHandle,
    iblIrradianceCubemap :: !TextureHandle,
    iblRadianceView :: !(Maybe Vulkan.VkImageView),
    iblIrradianceView :: !(Maybe Vulkan.VkImageView),
    iblSampler :: !Vulkan.VkSampler,
    iblBrdfView :: !(Maybe Vulkan.VkImageView),
    iblCloudNoiseView :: !(Maybe Vulkan.VkImageView)
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
  m IBLTextures
loadIBLTextures rm physicalDevice device graphicsQueueHandler textureCommandBuffer envMapDir = do
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

  lightingSampler <- Texture.createSamplerWithLod device (fromIntegral radMipLevels - 1)
  logInfo LogGeneral "lighting sampler created with mip support"

  let brdfPixels = BRDF.generateBRDFLUT 256 256
  brdfTexHandle <- Texture.createTextureFromData rm physicalDevice device 256 256 brdfPixels graphicsQueueHandler textureCommandBuffer
  mBrdfView <- Texture.textureImageView rm brdfTexHandle
  logInfo LogGeneral "BRDF LUT generated"

  logInfo LogGeneral "loading 3D cloud noise texture..."
  cloudNoiseView <- Texture.managedTexture3D physicalDevice device "data/textures/cloud_noise/cloud_noise_256.raw" 256 256 256 graphicsQueueHandler textureCommandBuffer
  logInfo LogGeneral "3D cloud noise texture loaded"

  pure
    IBLTextures
      { iblRadianceCubemap = radianceCubemap,
        iblIrradianceCubemap = irradianceCubemap,
        iblRadianceView = mRadianceView,
        iblIrradianceView = mIrradianceView,
        iblSampler = lightingSampler,
        iblBrdfView = mBrdfView,
        iblCloudNoiseView = Just cloudNoiseView
      }

data SceneLoadResult = SceneLoadResult
  { slrECSWorld :: !ECS.World,
    slrNumEntities :: !Int,
    slrSceneBounds :: !BBox,
    slrTexturePixelMap :: !(IntMap (Int, Int, Vector Word8))
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
      pure $ SceneLoadResult world 1 sceneBbox IntMap.empty
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
          pure $ SceneLoadResult world 10000 sceneBbox IntMap.empty
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

              pure $ SceneLoadResult world (length (girMeshes result)) sceneBbox pixelMap
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

              pure $ SceneLoadResult world 1 sceneBbox IntMap.empty
