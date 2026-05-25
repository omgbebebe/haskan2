{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.UI.Backend
  ( ImGuiBackend (..),
    initImGuiBackend,
    shutdownImGuiBackend,
    newImGuiFrame,
    renderImGuiFrame,
    buildImGuiFrame,
    CloudPanel (..),
    WeatherPanel (..),
    DebugPanelEnv (..),
    buildDebugPanel,
    recordImGuiDrawData,
  )
where

import Control.Concurrent.STM qualified as STM
import Control.Monad (unless, when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (ReaderT, ask, runReaderT)
import Data.Bits (zeroBits)
import Data.Coerce (coerce)
import Data.IORef (IORef, readIORef)
import Data.Word (Word32)
import DearImGui qualified as ImGui
import DearImGui.Raw qualified as ImGui.Raw
import DearImGui.SDL qualified as ImGui.SDL
import DearImGui.SDL.Vulkan qualified as ImGui.SDL.Vulkan
import DearImGui.Vulkan qualified as ImGui.Vulkan
import Foreign.C (CBool, CFloat (..))
import Foreign.C.String (CString, withCString)
import Foreign.Marshal.Alloc qualified
import Foreign.Marshal.Utils (fromBool, toBool)
import Foreign.Ptr (FunPtr, Ptr, castPtr, nullPtr)
import Foreign.Storable qualified
import Graphics.Haskan.Camera (AnyCamera, cameraDistance, cameraPosition)
import Graphics.Haskan.Engine.Types (FrameStats (..))
import Graphics.Haskan.Logger (LogCategory (..), logInfoIO, showT)
import Graphics.Haskan.Vulkan.RenderPass qualified as RenderPass
import Linear (V3 (..))
import Numeric (showFFloat)
import SDL qualified
import SDL.Raw.Video qualified as SDL.Raw.Video
import Unsafe.Coerce (unsafeCoerce)
import Vulkan qualified as Vk
import Vulkan.Core10.Handles qualified as Vk
import Vulkan.Zero qualified as Vk

-- ---------------------------------------------------------------------------
-- ImGui backend state
-- ---------------------------------------------------------------------------

data ImGuiBackend = ImGuiBackend
  { ibContext :: !ImGui.Raw.Context,
    ibInitResult :: !Bool,
    ibCheckResultFunPtr :: !(FunPtr (Vk.Result -> IO ()))
  }

-- ---------------------------------------------------------------------------
-- Initialization
-- ---------------------------------------------------------------------------

initImGuiBackend ::
  SDL.Window ->
  Vk.Instance ->
  Vk.PhysicalDevice ->
  Vk.Device ->
  Word32 ->
  Vk.Queue ->
  Vk.DescriptorPool ->
  Vk.RenderPass ->
  Word32 ->
  Word32 ->
  IO ImGuiBackend
initImGuiBackend window vkInstance vkPhysicalDevice vkDevice queueFamily vkQueue vkDescriptorPool vkRenderPass minImageCount imageCount = do
  logInfoIO LogGeneral "Initializing Dear ImGui"

  -- Create ImGui context
  ctx <- ImGui.Raw.createContext
  logInfoIO LogGeneral "Dear ImGui context created"

  -- Set font global scale based on display DPI
  Foreign.Marshal.Alloc.alloca $ \dpiPtr -> do
    ret <- SDL.Raw.Video.getDisplayDPI 0 dpiPtr nullPtr nullPtr
    when (ret == 0) $ do
      CFloat dpi <- Foreign.Storable.peek dpiPtr
      let scale = max 1.0 (dpi / 96.0)
      logInfoIO LogGeneral $ "Display DPI: " <> showT dpi <> ", ImGui font scale: " <> showT scale
      ImGui.setFontGlobalScale scale

  -- Initialize SDL backend for Vulkan
  sdlOk <- ImGui.SDL.Vulkan.sdl2InitForVulkan window
  logInfoIO LogGeneral $ "Dear ImGui SDL backend init: " <> if sdlOk then "OK" else "FAILED"

  -- Initialize Vulkan backend
  let initInfo =
        ImGui.Vulkan.InitInfo
          { ImGui.Vulkan.instance' = vkInstance,
            ImGui.Vulkan.physicalDevice = vkPhysicalDevice,
            ImGui.Vulkan.device = vkDevice,
            ImGui.Vulkan.queueFamily = queueFamily,
            ImGui.Vulkan.queue = vkQueue,
            ImGui.Vulkan.pipelineCache = Vk.NULL_HANDLE,
            ImGui.Vulkan.descriptorPool = vkDescriptorPool,
            ImGui.Vulkan.subpass = 0,
            ImGui.Vulkan.minImageCount = minImageCount,
            ImGui.Vulkan.imageCount = imageCount,
            ImGui.Vulkan.msaaSamples = Vk.SAMPLE_COUNT_1_BIT,
            ImGui.Vulkan.rendering = Left vkRenderPass,
            ImGui.Vulkan.mbAllocator = Nothing,
            ImGui.Vulkan.checkResult = checkVkResult
          }
  (checkFn, vulkanOk) <- ImGui.Vulkan.vulkanInit initInfo
  logInfoIO LogGeneral $ "Dear ImGui Vulkan backend init: " <> if vulkanOk then "OK" else "FAILED"

  -- Create font atlas texture
  when vulkanOk $ do
    fontOk <- ImGui.Vulkan.vulkanCreateFontsTexture
    logInfoIO LogGeneral $ "Dear ImGui font texture: " <> if fontOk then "OK" else "FAILED"

  pure
    ImGuiBackend
      { ibContext = ctx,
        ibInitResult = vulkanOk,
        ibCheckResultFunPtr = checkFn
      }
  where
    checkVkResult :: Vk.Result -> IO ()
    checkVkResult res =
      unless (res == Vk.SUCCESS) $
        putStrLn $
          "Dear ImGui Vulkan error: " <> show res

-- ---------------------------------------------------------------------------
-- Shutdown
-- ---------------------------------------------------------------------------

shutdownImGuiBackend :: ImGuiBackend -> IO ()
shutdownImGuiBackend ImGuiBackend {..} = do
  logInfoIO LogGeneral "Shutting down Dear ImGui"
  ImGui.Vulkan.vulkanShutdown (ibCheckResultFunPtr, ibInitResult)
  ImGui.SDL.sdl2Shutdown
  ImGui.Raw.destroyContext ibContext

-- ---------------------------------------------------------------------------
-- Frame functions
-- ---------------------------------------------------------------------------

buildImGuiFrame :: IO () -> IO (Maybe ImGui.Raw.DrawData)
buildImGuiFrame buildUI = do
  ImGui.Vulkan.vulkanNewFrame
  ImGui.SDL.sdl2NewFrame
  ImGui.Raw.newFrame
  buildUI
  ImGui.Raw.render
  drawData <- ImGui.Raw.getDrawData
  -- If draw data has zero command lists, return Nothing to skip rendering
  let ptr = case drawData of ImGui.Raw.DrawData p -> p
  if ptr == nullPtr
    then pure Nothing
    else pure (Just drawData)

-- | Deprecated: use 'buildImGuiFrame' instead
newImGuiFrame :: IO ()
newImGuiFrame = do
  ImGui.Vulkan.vulkanNewFrame
  ImGui.SDL.sdl2NewFrame
  ImGui.Raw.newFrame

-- | Deprecated: use 'buildImGuiFrame' instead
renderImGuiFrame :: IO () -> IO (Maybe ImGui.Raw.DrawData)
renderImGuiFrame = buildImGuiFrame

-- ---------------------------------------------------------------------------
-- Debug Panel
-- ---------------------------------------------------------------------------

sliderFloatTVar ::
  CString ->
  Float ->
  Float ->
  STM.TVar Float ->
  IO ()
sliderFloatTVar label minVal maxVal tv = do
  currentVal <- STM.readTVarIO tv
  Foreign.Marshal.Alloc.alloca $ \ptr -> do
    Foreign.Storable.poke ptr (Foreign.C.CFloat currentVal)
    _changed <- ImGui.Raw.sliderFloat label ptr (Foreign.C.CFloat minVal) (Foreign.C.CFloat maxVal) Foreign.Ptr.nullPtr
    Foreign.C.CFloat newVal <- Foreign.Storable.peek ptr
    STM.atomically $ STM.writeTVar tv (realToFrac newVal)

checkboxTVar :: CString -> STM.TVar Bool -> IO ()
checkboxTVar label tv = do
  currentVal <- STM.readTVarIO tv
  Foreign.Marshal.Alloc.alloca $ \ptr -> do
    Foreign.Storable.poke ptr (fromBool currentVal)
    _changed <- ImGui.Raw.checkbox label ptr
    newVal <- Foreign.Storable.peek ptr
    STM.atomically $ STM.writeTVar tv (toBool newVal)

radioButtonMode :: CString -> Word32 -> STM.TVar Word32 -> IO ()
radioButtonMode label mode tv = do
  currentMode <- STM.readTVarIO tv
  _clicked <- ImGui.Raw.radioButton label (fromBool (mode == currentMode))
  when (mode == currentMode) $ pure ()
  -- Note: radioButton returns whether it was clicked, but we need to handle
  -- the mode change. In ImGui, radio buttons are typically grouped and the
  -- user clicks one to select it. We handle this by checking if ANY radio
  -- button in the group was clicked and updating accordingly.
  -- However, radioButtonI is easier for this pattern:
  -- radioButtonI label ptr mode
  -- where ptr points to the current mode value.
  --
  -- Actually, let me simplify: use a single alloca for the mode and call
  -- radioButtonI for each option. This is cleaner.
  pure ()

weatherStateText :: Float -> String
weatherStateText c
  | c < 0.15 = "Weather: Clear Sky"
  | c < 0.35 = "Weather: Fair / Scattered"
  | c < 0.60 = "Weather: Partly Cloudy"
  | c < 0.80 = "Weather: Overcast"
  | otherwise = "Weather: Storm"

-- | Parameters for the Cloud section of the debug panel.
data CloudPanel = CloudPanel
  { cpHeight :: !(STM.TVar Float),
    cpWindDirection :: !(STM.TVar Float),
    cpWindSpeed :: !(STM.TVar Float),
    cpDetail :: !(STM.TVar Float),
    cpAbsorption :: !(STM.TVar Float),
    cpNoiseSeed :: !(STM.TVar Float),
    cpNoiseFrequency :: !(STM.TVar Float),
    cpNoisePersistence :: !(STM.TVar Float)
  }

-- | Parameters for the Weather section of the debug panel.
data WeatherPanel = WeatherPanel
  { wpCoverage :: !(STM.TVar Float),
    wpCoverageScale :: !(STM.TVar Float),
    wpTypeBias :: !(STM.TVar Float),
    wpStormIntensity :: !(STM.TVar Float),
    wpAnimSpeed :: !(STM.TVar Float)
  }

-- | Environment for building the entire debug panel.
-- Composes Cloud, Weather, Time, Status, and global debug controls.
data DebugPanelEnv = DebugPanelEnv
  { dpeCloud :: !CloudPanel,
    dpeWeather :: !WeatherPanel,
    dpeTimeOfDay :: !(STM.TVar Float),
    dpeTimeSpeed :: !(STM.TVar Float),
    dpeFrameStatsRef :: !(IORef FrameStats),
    dpeCamera :: !AnyCamera,
    dpeDebugMode :: !(STM.TVar Word32),
    dpeWireframe :: !(STM.TVar Bool),
    dpePhysicsAutoStep :: !(STM.TVar Bool),
    dpePhysicsTimeScale :: !(STM.TVar Float),
    dpeNoiseNeedsRegeneration :: !(STM.TVar Bool),
    dpeSaveCloudOutput :: !(STM.TVar (Maybe String)),
    dpeSaveNoiseSlices :: !(STM.TVar Bool)
  }

-- | Build the debug panel using ReaderT for clean parameter access.
buildDebugPanel :: ReaderT DebugPanelEnv IO ()
buildDebugPanel = do
  env <- ask
  let CloudPanel {..} = dpeCloud env
      WeatherPanel {..} = dpeWeather env
      tvDebugMode = dpeDebugMode env
      tvWireframe = dpeWireframe env
      tvTimeOfDay = dpeTimeOfDay env
      tvTimeSpeed = dpeTimeSpeed env
      tvPhysicsAutoStep = dpePhysicsAutoStep env
      tvPhysicsTimeScale = dpePhysicsTimeScale env
      tvNoiseNeedsRegeneration = dpeNoiseNeedsRegeneration env
      tvSaveCloudOutput = dpeSaveCloudOutput env
      tvSaveNoiseSlices = dpeSaveNoiseSlices env
      frameStatsRef = dpeFrameStatsRef env
      cam = dpeCamera env
  liftIO $ withCString "Debug Panels" $ \windowTitle -> do
    _open <- ImGui.Raw.begin windowTitle Nothing Nothing

    -- Status section
    withCString "Status" $ \statusLabel -> do
      statusOpen <- ImGui.Raw.collapsingHeader statusLabel Foreign.Ptr.nullPtr zeroBits
      when statusOpen $ do
        -- FPS from frame stats
        stats <- readIORef frameStatsRef
        let frameCount = fsFrameCount stats
            accumTime = fsAccumTime stats
            fps =
              if frameCount > 0
                then 1_000_000_000.0 / fromIntegral (accumTime `div` fromIntegral frameCount)
                else 0.0 :: Float
        withCString ("FPS: " ++ show (round fps :: Int)) $ \text -> ImGui.Raw.textUnformatted text Nothing
        -- Camera info
        let V3 cx cy cz = cameraPosition cam
            dist = cameraDistance cam
        withCString ("Camera: dist=" ++ showFFloat (Just 1) dist "" ++ " pos=(" ++ showFFloat (Just 1) cx "" ++ "," ++ showFFloat (Just 1) cy "" ++ "," ++ showFFloat (Just 1) cz "" ++ ")") $ \text ->
          ImGui.Raw.textUnformatted text Nothing

    -- Time section
    withCString "Time" $ \timeLabel -> do
      timeOpen <- ImGui.Raw.collapsingHeader timeLabel Foreign.Ptr.nullPtr zeroBits
      when timeOpen $ do
        withCString "Time of Day" $ \label -> sliderFloatTVar label 0.0 24.0 tvTimeOfDay
        withCString "Time Speed" $ \label -> sliderFloatTVar label 0.0 3600.0 tvTimeSpeed

    -- Cloud section
    withCString "Cloud" $ \cloudLabel -> do
      cloudOpen <- ImGui.Raw.collapsingHeader cloudLabel Foreign.Ptr.nullPtr zeroBits
      when cloudOpen $ do
        withCString "Height" $ \label -> sliderFloatTVar label 0.0 10000.0 cpHeight
        withCString "Wind Direction" $ \label -> sliderFloatTVar label 0.0 360.0 cpWindDirection
        withCString "Wind Speed" $ \label -> sliderFloatTVar label 0.0 100.0 cpWindSpeed
        withCString "Detail" $ \label -> sliderFloatTVar label 0.0 1.0 cpDetail
        withCString "Absorption" $ \label -> sliderFloatTVar label 0.0 10.0 cpAbsorption
        ImGui.Raw.separator
        withCString "Noise Seed" $ \label -> sliderFloatTVar label 0.0 1000.0 cpNoiseSeed
        withCString "Noise Frequency" $ \label -> sliderFloatTVar label 0.1 8.0 cpNoiseFrequency
        withCString "Noise Persistence" $ \label -> sliderFloatTVar label 0.1 0.9 cpNoisePersistence
        withCString "Regenerate Noise" $ \label -> do
          clicked <- ImGui.Raw.button label
          when clicked $ liftIO $ STM.atomically $ STM.writeTVar tvNoiseNeedsRegeneration True

    -- Weather section
    withCString "Weather" $ \weatherLabel -> do
      weatherOpen <- ImGui.Raw.collapsingHeader weatherLabel Foreign.Ptr.nullPtr zeroBits
      when weatherOpen $ do
        covVal <- STM.readTVarIO wpCoverage
        withCString (weatherStateText covVal) $ \text -> ImGui.Raw.textUnformatted text Nothing
        withCString "Coverage" $ \label -> sliderFloatTVar label 0.0 1.0 wpCoverage
        withCString "Coverage Scale" $ \label -> sliderFloatTVar label 0.0 2.0 wpCoverageScale
        withCString "Type Bias" $ \label -> sliderFloatTVar label (-1.0) 1.0 wpTypeBias
        withCString "Storm Intensity" $ \label -> sliderFloatTVar label 0.0 2.0 wpStormIntensity
        withCString "Anim Speed" $ \label -> sliderFloatTVar label 0.0 2.0 wpAnimSpeed

    -- Render Debug section
    withCString "Render Debug" $ \renderLabel -> do
      renderOpen <- ImGui.Raw.collapsingHeader renderLabel Foreign.Ptr.nullPtr zeroBits
      when renderOpen $ do
        Foreign.Marshal.Alloc.alloca $ \modePtr -> do
          currentMode <- STM.readTVarIO tvDebugMode
          Foreign.Storable.poke modePtr (fromIntegral currentMode)
          withCString "Final" $ \label -> ImGui.Raw.radioButtonI label modePtr 0
          withCString "Albedo" $ \label -> ImGui.Raw.radioButtonI label modePtr 1
          withCString "Normals" $ \label -> ImGui.Raw.radioButtonI label modePtr 2
          withCString "Roughness" $ \label -> ImGui.Raw.radioButtonI label modePtr 3
          withCString "Metallic" $ \label -> ImGui.Raw.radioButtonI label modePtr 4
          withCString "Position" $ \label -> ImGui.Raw.radioButtonI label modePtr 5
          withCString "Emissive" $ \label -> ImGui.Raw.radioButtonI label modePtr 6
          withCString "AO" $ \label -> ImGui.Raw.radioButtonI label modePtr 7
          withCString "NdotL" $ \label -> ImGui.Raw.radioButtonI label modePtr 8
          withCString "Irradiance" $ \label -> ImGui.Raw.radioButtonI label modePtr 9
          withCString "Specular IBL" $ \label -> ImGui.Raw.radioButtonI label modePtr 10
          withCString "Fresnel" $ \label -> ImGui.Raw.radioButtonI label modePtr 11
          withCString "Skybox" $ \label -> ImGui.Raw.radioButtonI label modePtr 12
          withCString "Weather##debug" $ \label -> ImGui.Raw.radioButtonI label modePtr 13
          withCString "Height Mask" $ \label -> ImGui.Raw.radioButtonI label modePtr 14
          withCString "Raw Noise" $ \label -> ImGui.Raw.radioButtonI label modePtr 15
          withCString "Cloud Density" $ \label -> ImGui.Raw.radioButtonI label modePtr 16
          newMode <- Foreign.Storable.peek modePtr
          STM.atomically $ STM.writeTVar tvDebugMode (fromIntegral newMode)
        withCString "Wireframe" $ \label -> checkboxTVar label tvWireframe
        ImGui.Raw.separator
        withCString "Save Cloud Output" $ \label -> do
          clicked <- ImGui.Raw.button label
          when clicked $ liftIO $ STM.atomically $ STM.writeTVar tvSaveCloudOutput (Just "cloud_debug")
        withCString "Save Noise Slices" $ \label -> do
          clicked <- ImGui.Raw.button label
          when clicked $ liftIO $ STM.atomically $ STM.writeTVar tvSaveNoiseSlices True

    -- Physics section
    withCString "Physics" $ \physicsLabel -> do
      physicsOpen <- ImGui.Raw.collapsingHeader physicsLabel Foreign.Ptr.nullPtr zeroBits
      when physicsOpen $ do
        withCString "Auto Step" $ \label -> checkboxTVar label tvPhysicsAutoStep
        withCString "Time Scale" $ \label -> sliderFloatTVar label 0.0 5.0 tvPhysicsTimeScale

    ImGui.Raw.end

-- ---------------------------------------------------------------------------
-- Command buffer recording
-- ---------------------------------------------------------------------------

recordImGuiDrawData ::
  Vk.CommandBuffer ->
  Vk.RenderPass ->
  Vk.Framebuffer ->
  Vk.Extent2D ->
  ImGui.Raw.DrawData ->
  IO ()
recordImGuiDrawData cmdBuf renderPass framebuffer extent drawData =
  RenderPass.withImGuiRenderPass cmdBuf renderPass framebuffer extent $ do
    ImGui.Vulkan.vulkanRenderDrawData drawData cmdBuf Nothing
