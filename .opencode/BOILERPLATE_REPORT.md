# Boilerplate Analysis Report

**Date:** 2026-05-22
**Author:** Rune (AI Assistant)
**Project:** haskan2

## Summary

This report identifies functions with excessive parameter lists that could benefit from:
1. **Reader Monad Pattern** - Functions that pass the same context objects repeatedly
2. **Dedicated Types** - Groups of semantically related primitive parameters (Float, Int) that should be wrapped in newtypes or records

## Tools Used

- Local Hoogle instance (`hoogle server --database=.hoogle-local.hoo --port=8093`)
- haskell-docs-cli (`hdc`) for browsing documentation
- Direct source code analysis

---

## Category 1: Functions Requiring Reader Monad Pattern

These functions pass the same Vulkan context objects (`VkDevice`, `VkPhysicalDevice`, `VkQueue`, `VkCommandBuffer`) repeatedly. They should be refactored to use a `ReaderT` monad with a `VulkanContext` record.

### 1.1 `renderLoop` (Engine/Render.hs:652)

```haskell
renderLoop :: (MonadFail m, MonadManaged m, MonadIO m, MonadLog m, MonadClock m,
               MonadTelemetry m, MonadStateReader m, MonadGraphics m) =>
  Window -> VkPhysicalDevice -> VkSurfaceKHR -> VkInstance -> [String] -> Integer ->
  GameState AnyCamera -> MVar () -> MVar () -> TChan ControlMessage -> String ->
  Maybe String -> String -> Bool -> Bool -> Maybe Mesh -> m ()
```

**Issues:**
- 15 positional parameters
- Vulkan handles (`VkPhysicalDevice`, `VkSurfaceKHR`, `VkInstance`) always passed together
- Synchronization primitives (`MVar ()`, `MVar ()`, `TChan ControlMessage`) form a group
- Configuration parameters (`String`, `Maybe String`, `String`, `Bool`, `Bool`, `Maybe Mesh`) are runtime settings

**Recommendation:** 
```haskell
data RenderLoopConfig = RenderLoopConfig
  { rlcWindow :: Window
  , rlcPhysicalDevice :: VkPhysicalDevice
  , rlcSurface :: VkSurfaceKHR
  , rlcInstance :: VkInstance
  , rlcLayers :: [String]
  , rlcTargetFPS :: Integer
  , rlcGameState :: GameState AnyCamera
  , rlcFinishedSemaphore :: MVar ()
  , rlcReadySemaphore :: MVar ()
  , rlcControlChannel :: TChan ControlMessage
  , rlcMeshName :: String
  , rlcUvCheckMode :: Maybe String
  , rlcEnvMapDir :: String
  , rlcCloudTestMode :: Bool
  , rlcProceduralSkyEnabled :: Bool
  , rlcSimpleMesh :: Maybe Mesh
  }

type RenderLoopM m = ReaderT RenderLoopConfig m

renderLoop :: (MonadFail m, MonadManaged m, MonadIO m, ...) => RenderLoopM m ()
```

### 1.2 `dispatchCloudNoiseGeneration` (Setup.hs:739)

```haskell
dispatchCloudNoiseGeneration ::
  (MonadManaged m, MonadIO m, MonadLog m) =>
  VkDevice -> VkPhysicalDevice -> VkQueue -> VkCommandBuffer ->
  ResourceManager -> TextureHandle -> Float -> Float -> Float -> m ()
```

**Issues:**
- First 4 parameters are always the Vulkan context
- Last 3 Floats are noise parameters (seed, frequency, persistence)

**Recommendation:** 
```haskell
data VulkanContext = VulkanContext
  { vcDevice :: VkDevice
  , vcPhysicalDevice :: VkPhysicalDevice
  , vcQueue :: VkQueue
  , vcCommandBuffer :: VkCommandBuffer
  }

data NoiseParams = NoiseParams
  { npSeed :: Float
  , npFrequency :: Float
  , npPersistence :: Float
  }

dispatchCloudNoiseGeneration ::
  (MonadManaged m, MonadIO m, MonadLog m, MonadReader VulkanContext m) =>
  ResourceManager -> TextureHandle -> NoiseParams -> m ()
```

### 1.3 `dispatchProceduralSkyGeneration` (Setup.hs:557)

```haskell
dispatchProceduralSkyGeneration ::
  (MonadManaged m, MonadIO m, MonadLog m) =>
  VkDevice -> VkPhysicalDevice -> VkQueue -> VkCommandBuffer ->
  ResourceManager -> TextureHandle -> TextureHandle -> V3 Float -> Float ->
  Float -> m ()
```

**Same pattern** as dispatchCloudNoiseGeneration.

### 1.4 `dispatchWeatherMapGeneration` (Setup.hs:955)

```haskell
dispatchWeatherMapGeneration ::
  (MonadManaged m, MonadIO m, MonadLog m) =>
  VkDevice -> VkPhysicalDevice -> VkQueue -> VkCommandBuffer ->
  ResourceManager -> TextureHandle -> m ()
```

**Same pattern** - Vulkan context + ResourceManager + TextureHandle.

### 1.5 `dispatchCloudDetailNoiseGeneration` (Setup.hs:889)

```haskell
dispatchCloudDetailNoiseGeneration ::
  (MonadManaged m, MonadIO m, MonadLog m) =>
  VkDevice -> VkPhysicalDevice -> VkQueue -> VkCommandBuffer ->
  ResourceManager -> TextureHandle -> m ()
```

**Same pattern**.

### 1.6 `loadIBLTextures` (Setup.hs:233)

```haskell
loadIBLTextures ::
  (MonadManaged m, MonadIO m, MonadLog m) =>
  ResourceManager -> VkPhysicalDevice -> VkDevice -> VkQueue ->
  VkCommandBuffer -> String -> Bool -> m IBLTextures
```

**Issues:**
- Vulkan handles in different order than dispatch functions
- `ResourceManager` comes first, then Vulkan handles

**Recommendation:** Standardize order: VulkanContext first, then ResourceManager.

### 1.7 `createRenderContext` (Render.hs:48)

```haskell
createRenderContext ::
  (MonadIO m, MonadManaged m) =>
  VkPhysicalDevice -> VkDevice -> VkSurfaceKHR -> VkPipelineLayout ->
  VkShaderModule -> VkShaderModule -> [VkDescriptorSet] -> VkCommandPool ->
  VkQueue -> VkQueue -> [VkFence] -> [VkSemaphore] -> m RenderContext
```

**Issues:**
- 12 parameters
- Shader modules (vert/frag) should be a `ShaderProgram` or pair
- Queues (graphics/present) should be a record
- Fences and semaphores are frame synchronization primitives

---

## Category 2: Functions Requiring Dedicated Types

These functions have chains of semantically related primitive parameters that should be wrapped in newtypes or records.

### 2.1 `bernstein5` (HosekWilkie.hs:3667)

```haskell
bernstein5 :: Float -> Float -> Float -> Float -> Float -> Float -> Float -> Float
```

**Issues:**
- 8 Float parameters with no semantic meaning
- This is a polynomial evaluation: `bernstein5 a b c d e f g x`
- Coefficients a-g and evaluation point x are indistinguishable at call sites

**Recommendation:**
```haskell
newtype BernsteinCoeff5 = BernsteinCoeff5 (V7 Float)
  -- or: data BernsteinPoly5 = BernsteinPoly5 !Float !Float !Float !Float !Float !Float !Float

bernstein5 :: BernsteinPoly5 -> Float -> Float
```

### 2.2 `buildRecordContext` (PassRecording.hs:97)

```haskell
buildRecordContext ::
  RenderContext -> DeferredResources -> ComputeCullResources ->
  [VkDescriptorSet] -> VkSampler -> VkBuffer -> FrameState -> AnyCamera ->
  [DrawCall] -> Word32 -> (V3 Float, V3 Float, V3 Float) -> V3 Float -> Float ->
  Float -> V3 Float -> Float -> [TVar (M44 CFloat)] -> [TVar Float] ->
  M44 CFloat -> Float -> Float -> Float -> Float -> Float -> Float -> Float ->
  Float -> Float -> M44 Float -> Float -> Float -> V3 Float -> Float -> Float ->
  Maybe DrawData -> RecordContext
```

**Issues:**
- 32 parameters (!)
- Many Floats are cloud/weather parameters (windDirX, windDirZ, cloudCoverage, cloudDetail, cloudAbsorption, weatherCoverageScale, weatherTypeBias, stormIntensity, weatherAnimSpeed)
- Sky parameters (skyTint, iblInt, sunAzimuth, sunScreenX, sunScreenY)
- Time parameters (time, prevTime)
- Camera parameters (cameraPos, skyboxRays, sunDir, cloudHeight)

**Recommendation:** Break into multiple records:
```haskell
data CloudParams = CloudParams
  { cpWindDirX :: !Float
  , cpWindDirZ :: !Float
  , cpCloudCoverage :: !Float
  , cpCloudDetail :: !Float
  , cpCloudAbsorption :: !Float
  , cpWeatherCoverageScale :: !Float
  , cpWeatherTypeBias :: !Float
  , cpStormIntensity :: !Float
  , cpWeatherAnimSpeed :: !Float
  }

data SkyParams = SkyParams
  { spSkyTint :: !(V3 Float)
  , spIBLIntensity :: !Float
  , spSunAzimuth :: !Float
  , spSunScreenX :: !Float
  , spSunScreenY :: !Float
  , spSunDir :: !(V3 Float)
  }

data FrameParams = FrameParams
  { fpTime :: !Float
  , fpPrevTime :: !Float
  , fpPrevViewProj :: !(M44 CFloat)
  , fpCurrentCloudViewProj :: !(M44 CFloat)
  }

buildRecordContext ::
  RenderContext -> DeferredResources -> ComputeCullResources ->
  [VkDescriptorSet] -> VkSampler -> VkBuffer -> FrameState -> AnyCamera ->
  [DrawCall] -> Word32 -> CloudParams -> SkyParams -> FrameParams ->
  Maybe DrawData -> RecordContext
```

### 2.3 `computeHWCoeffs` (HosekWilkie.hs)

```haskell
computeHWCoeffs :: Float -> Float -> Float -> HWCoeffs
```

**Issues:**
- 3 Floats with no semantic meaning
- These are turbidity, albedo, elevation

**Recommendation:**
```haskell
data SkyConfig = SkyConfig
  { scTurbidity :: !Float
  , scAlbedo :: !Float
  , scElevation :: !Float
  }

computeHWCoeffs :: SkyConfig -> HWCoeffs
```

### 2.4 `runHaskan` (Haskan.hs:11)

```haskell
runHaskan ::
  Text -> String -> Maybe Integer -> Maybe FilePath -> Bool -> Bool ->
  Bool -> String -> Int -> Float -> Float -> Bool -> Bool -> Bool -> IO ()
```

**Issues:**
- 14 parameters
- Booleans are positional (uvCheckCube, uvCheckSphere, uvCheckPlane, dayNight, cloudTest, proceduralSky)
- Configuration parameters mixed with runtime parameters

**Recommendation:**
```haskell
data UVCheckMode = UVCheckCube | UVCheckSphere | UVCheckPlane

data RenderConfig = RenderConfig
  { rcUVCheckMode :: Maybe UVCheckMode
  , rcDayNight :: !Bool
  , rcCloudTest :: !Bool
  , rcProceduralSky :: !Bool
  }

data EngineParams = EngineParams
  { epTitle :: !Text
  , epMeshName :: !String
  , epTimeout :: !(Maybe Integer)
  , epDebugSocket :: !(Maybe FilePath)
  , epEnvDir :: !String
  , epNumLights :: !Int
  , epInitialTime :: !Float
  , epTimeSpeed :: !Float
  , epRenderConfig :: !RenderConfig
  }

runHaskan :: EngineParams -> IO ()
```

---

## Category 3: Shader Module Compilation Functions

### 3.1 `compileAllShaders` (Setup.hs:117)

```haskell
compileAllShaders :: (MonadLog m, MonadIO m) => m ()
```

This is actually a good candidate for **no change** - it uses `do` notation well and doesn't have excessive parameters. However, it could benefit from a configuration type if shader paths were parameterized.

---

## Category 4: Data Constructors with Excessive Fields

### 4.1 `ShaderModules` (Setup.hs:170)

```haskell
data ShaderModules = ShaderModules
  { smForwardVert :: !VkShaderModule
  , smForwardFrag :: !VkShaderModule
  , smGbufVert :: !VkShaderModule
  , smGbufFrag :: !VkShaderModule
  , smLightVert :: !VkShaderModule
  , smLightFrag :: !VkShaderModule
  , smLightProcFrag :: !VkShaderModule
  , smWireVert :: !VkShaderModule
  , smWireGeom :: !VkShaderModule
  , smWireFrag :: !VkShaderModule
  , smCull :: !VkShaderModule
  , smCloudVert :: !VkShaderModule
  , smCloudFrag :: !VkShaderModule
  , smGodrayVert :: !VkShaderModule
  , smGodrayFrag :: !VkShaderModule
  , smAPVolume :: !VkShaderModule
  , smSimpleForwardVert :: !VkShaderModule
  , smSimpleForwardFrag :: !VkShaderModule
  }
```

**Issues:**
- 18 fields
- Forward/gbuf/light/cloud/godray shaders are pairs (vert/frag)
- Wireframe has vertex+geometry+fragment

**Recommendation:**
```haskell
data ShaderPair = ShaderPair
  { spVertex :: !VkShaderModule
  , spFragment :: !VkShaderModule
  }

data WireframeShaders = WireframeShaders
  { wsVertex :: !VkShaderModule
  , wsGeometry :: !(Maybe VkShaderModule)
  , wsFragment :: !VkShaderModule
  }

data ShaderModules = ShaderModules
  { smForward :: !ShaderPair
  , smGBuffer :: !ShaderPair
  , smLighting :: !ShaderPair
  , smLightingProcedural :: !VkShaderModule  -- fragment only
  , smWireframe :: !WireframeShaders
  , smCull :: !VkShaderModule  -- compute
  , smCloud :: !ShaderPair
  , smGodRay :: !ShaderPair
  , smAPVolume :: !VkShaderModule  -- compute
  , smSimpleForward :: !ShaderPair
  }
```

### 4.2 `IBLTextures` (Setup.hs:216)

```haskell
data IBLTextures = IBLTextures
  { iblRadianceCubemap :: !TextureHandle
  , iblIrradianceCubemap :: !TextureHandle
  , iblRadianceView :: !(Maybe VkImageView)
  , iblIrradianceView :: !(Maybe VkImageView)
  , iblSampler :: !VkSampler
  , iblBrdfView :: !(Maybe VkImageView)
  , iblCloudNoiseHandle :: !TextureHandle
  , iblCloudNoiseView :: !(Maybe VkImageView)
  , iblCloudDetailNoiseView :: !(Maybe VkImageView)
  , iblBlueNoiseView :: !(Maybe VkImageView)
  , iblBlueNoiseSampler :: !VkSampler
  , iblNoiseSampler :: !VkSampler
  , iblWeatherMapView :: !(Maybe VkImageView)
  }
```

**Issues:**
- 13 fields
- Cubemap pairs (radiance/irradiance) are separated
- Samplers are mixed with textures

**Recommendation:**
```haskell
data Cubemap = Cubemap
  { cmHandle :: !TextureHandle
  , cmView :: !(Maybe VkImageView)
  }

data IBLTextures = IBLTextures
  { iblRadiance :: !Cubemap
  , iblIrradiance :: !Cubemap
  , iblSampler :: !VkSampler
  , iblBrdfView :: !(Maybe VkImageView)
  , iblCloudNoise :: !Cubemap
  , iblCloudDetailNoiseView :: !(Maybe VkImageView)
  , iblBlueNoise :: !(Maybe VkImageView, VkSampler)
  , iblNoiseSampler :: !VkSampler
  , iblWeatherMapView :: !(Maybe VkImageView)
  }
```

### 4.3 `RecordContext` (PassRecording.hs:48)

Already discussed in 2.2 - this has ~35 fields and should be broken into sub-records.

---

## Implementation Priority

### High Priority (Immediate Impact)

1. **`VulkanContext` record** - Wrap `VkDevice`, `VkPhysicalDevice`, `VkQueue`, `VkCommandBuffer`
   - Affects: 6+ functions in Setup.hs
   - Estimated parameter reduction: 4 per function

2. **`CloudParams` record** - Group cloud/weather Float parameters
   - Affects: `buildRecordContext`, `buildDeferredGraph`
   - Estimated parameter reduction: 9 parameters

3. **`ShaderPair` type** - Pair vertex/fragment shaders
   - Affects: `ShaderModules` record
   - Estimated field reduction: 8 fields

### Medium Priority (Code Clarity)

4. **`RenderLoopConfig` record** - Group `renderLoop` parameters
   - Affects: `renderLoop`, `Engine.hs` call site
   - Estimated parameter reduction: 15 parameters

5. **`EngineParams` record** - Group `runHaskan` parameters
   - Affects: `runHaskan`, CLI argument parsing
   - Estimated parameter reduction: 13 parameters

6. **`SkyParams` record** - Group sky/lighting parameters
   - Affects: `buildRecordContext`, `buildDeferredGraph`
   - Estimated parameter reduction: 6 parameters

### Low Priority (Nice to Have)

7. **`BernsteinPoly5` type** - Wrap polynomial coefficients
   - Affects: `bernstein5`, `HosekWilkie` module
   - Estimated parameter reduction: 7 parameters

8. **`UVCheckMode` type** - Replace 3 Bool parameters
   - Affects: `runHaskan`, CLI parsing
   - Estimated parameter reduction: 3 Bools

---

## Appendix: Hoogle Setup

Local Hoogle instance is now configured:

```bash
# Generate database (already done)
cabal haddock --haddock-hyperlink-source
hoogle generate --local=dist-newstyle/build/x86_64-linux/ghc-9.12.3/haskan2-0.1.0.0/doc/html/haskan2 --database=.hoogle-local.hoo

# Start server
hoogle server --database=.hoogle-local.hoo --port=8093

# Browse with CLI
hdc ":module Graphics.Haskan.Engine.Render" --hoogle http://localhost:8093/
```

The Hoogle database is stored in `.hoogle-local.hoo` and the dev shell now includes `hoogle` and `haskellPackages.hoogle`.

---

## Conclusion

The most impactful refactor would be:
1. Introducing `VulkanContext` (reduces 4 params × 6 functions = 24 params)
2. Introducing `CloudParams` + `SkyParams` (reduces ~15 params in `buildRecordContext`)
3. Introducing `ShaderPair` (reduces 8 fields in `ShaderModules`)

These three changes alone would eliminate approximately **50+ positional parameters** from the codebase, dramatically improving readability and reducing boilerplate.
