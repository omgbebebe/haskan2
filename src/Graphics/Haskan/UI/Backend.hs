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
import Data.Word (Word32)
import Foreign.C (CFloat (..), CBool)
import Foreign.C.String (CString, withCString)
import Foreign.Marshal.Alloc qualified
import Foreign.Marshal.Utils (fromBool, toBool)
import Foreign.Ptr (FunPtr, Ptr, castPtr, nullPtr)
import Foreign.Storable qualified
import qualified DearImGui as ImGui
import qualified DearImGui.Raw as ImGui.Raw
import qualified DearImGui.SDL as ImGui.SDL
import qualified DearImGui.SDL.Vulkan as ImGui.SDL.Vulkan
import qualified DearImGui.Vulkan as ImGui.Vulkan
import qualified SDL
import qualified SDL.Raw.Video as SDL.Raw.Video
import qualified Vulkan as Vk
import qualified Vulkan.Core10.Handles as Vk
import qualified Vulkan.Zero as Vk
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Haskan.Logger (LogCategory (..), logInfoIO, showT)
import Graphics.Haskan.Vulkan.RenderPass qualified as RenderPass
import Unsafe.Coerce (unsafeCoerce)
-- ---------------------------------------------------------------------------
-- Vulkan interop: convert vulkan-api handles to vulkan package handles
-- ---------------------------------------------------------------------------

-- | vulkan-api handles are type synonyms: type VkDevice = Ptr VkDevice_T
-- The vulkan package uses data types: Device = Device (Ptr Device_T) DeviceCmds
-- dear-imgui only uses the *Handle accessors, never the Cmds fields,
-- so 'zero' is safe for Cmds.
-- castPtr converts between phantom-tagged pointer types (same runtime rep).

toVulkanDevice :: Vulkan.VkDevice -> Vk.Device
toVulkanDevice ptr = Vk.Device (castPtr ptr) Vk.zero

toVulkanInstance :: Vulkan.VkInstance -> Vk.Instance
toVulkanInstance ptr = Vk.Instance (castPtr ptr) Vk.zero

toVulkanPhysicalDevice :: Vulkan.VkPhysicalDevice -> Vk.PhysicalDevice
toVulkanPhysicalDevice ptr = Vk.PhysicalDevice (castPtr ptr) Vk.zero

toVulkanQueue :: Vulkan.VkQueue -> Vk.Queue
toVulkanQueue ptr = Vk.Queue (castPtr ptr) Vk.zero

toVulkanCommandBuffer :: Vulkan.VkCommandBuffer -> Vk.CommandBuffer
toVulkanCommandBuffer ptr = Vk.CommandBuffer (castPtr ptr) Vk.zero

toVulkanRenderPass :: Vulkan.VkRenderPass -> Vk.RenderPass
toVulkanRenderPass = Vk.RenderPass . coerce

toVulkanDescriptorPool :: Vulkan.VkDescriptorPool -> Vk.DescriptorPool
toVulkanDescriptorPool = Vk.DescriptorPool . coerce

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
  Vulkan.VkInstance ->
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  Word32 ->
  Vulkan.VkQueue ->
  Vulkan.VkDescriptorPool ->
  Vulkan.VkRenderPass ->
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
          { ImGui.Vulkan.instance' = toVulkanInstance vkInstance,
            ImGui.Vulkan.physicalDevice = toVulkanPhysicalDevice vkPhysicalDevice,
            ImGui.Vulkan.device = toVulkanDevice vkDevice,
            ImGui.Vulkan.queueFamily = queueFamily,
            ImGui.Vulkan.queue = toVulkanQueue vkQueue,
            ImGui.Vulkan.pipelineCache = Vk.NULL_HANDLE,
            ImGui.Vulkan.descriptorPool = toVulkanDescriptorPool vkDescriptorPool,
            ImGui.Vulkan.subpass = 0,
            ImGui.Vulkan.minImageCount = minImageCount,
            ImGui.Vulkan.imageCount = imageCount,
            ImGui.Vulkan.msaaSamples = Vk.SAMPLE_COUNT_1_BIT,
            ImGui.Vulkan.rendering = Left (toVulkanRenderPass vkRenderPass),
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
        putStrLn $ "Dear ImGui Vulkan error: " <> show res

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
    cpAbsorption :: !(STM.TVar Float)
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
-- Composes Cloud, Weather, and global debug controls.
data DebugPanelEnv = DebugPanelEnv
  { dpeCloud :: !CloudPanel,
    dpeWeather :: !WeatherPanel,
    dpeDebugMode :: !(STM.TVar Word32),
    dpeWireframe :: !(STM.TVar Bool)
  }

-- | Build the debug panel using ReaderT for clean parameter access.
buildDebugPanel :: ReaderT DebugPanelEnv IO ()
buildDebugPanel = do
  env <- ask
  let CloudPanel{..} = dpeCloud env
      WeatherPanel{..} = dpeWeather env
      tvDebugMode = dpeDebugMode env
      tvWireframe = dpeWireframe env
  liftIO $ withCString "Debug Panels" $ \windowTitle -> do
    _open <- ImGui.Raw.begin windowTitle Nothing Nothing
    -- Cloud section
    withCString "Cloud" $ \cloudLabel -> do
      cloudOpen <- ImGui.Raw.collapsingHeader cloudLabel Foreign.Ptr.nullPtr zeroBits
      when cloudOpen $ do
        withCString "Height" $ \label -> sliderFloatTVar label 0.0 10000.0 cpHeight
        withCString "Wind Direction" $ \label -> sliderFloatTVar label 0.0 360.0 cpWindDirection
        withCString "Wind Speed" $ \label -> sliderFloatTVar label 0.0 100.0 cpWindSpeed
        withCString "Detail" $ \label -> sliderFloatTVar label 0.0 1.0 cpDetail
        withCString "Absorption" $ \label -> sliderFloatTVar label 0.0 10.0 cpAbsorption
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
          withCString "Cloud Density" $ \label -> ImGui.Raw.radioButtonI label modePtr 13
          withCString "Height Mask" $ \label -> ImGui.Raw.radioButtonI label modePtr 14
          withCString "Raw Noise" $ \label -> ImGui.Raw.radioButtonI label modePtr 15
          newMode <- Foreign.Storable.peek modePtr
          STM.atomically $ STM.writeTVar tvDebugMode (fromIntegral newMode)
        withCString "Wireframe" $ \label -> checkboxTVar label tvWireframe
    ImGui.Raw.end

-- ---------------------------------------------------------------------------
-- Command buffer recording
-- ---------------------------------------------------------------------------

recordImGuiDrawData ::
  Vulkan.VkCommandBuffer ->
  Vulkan.VkRenderPass ->
  Vulkan.VkFramebuffer ->
  Vulkan.VkExtent2D ->
  ImGui.Raw.DrawData ->
  IO ()
recordImGuiDrawData cmdBuf renderPass framebuffer extent drawData =
  RenderPass.withImGuiRenderPass cmdBuf renderPass framebuffer extent $ do
    let vkCmdBuf = toVulkanCommandBuffer cmdBuf
    ImGui.Vulkan.vulkanRenderDrawData drawData vkCmdBuf Nothing
