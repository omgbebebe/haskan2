{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.UI.Backend
  ( ImGuiBackend (..),
    initImGuiBackend,
    shutdownImGuiBackend,
    newImGuiFrame,
    renderImGuiFrame,
    buildImGuiFrame,
    buildCloudDebugPanel,
    recordImGuiDrawData,
  )
where

import Control.Concurrent.STM qualified as STM
import Control.Monad (unless, when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Coerce (coerce)
import Data.Word (Word32)
import Foreign.C (CFloat (..))
import Foreign.C.String (CString, withCString)
import Foreign.Marshal.Alloc qualified
import Foreign.Ptr (FunPtr, Ptr, castPtr, nullPtr)
import Foreign.Storable qualified
import qualified DearImGui.Raw as ImGui.Raw
import qualified DearImGui.SDL as ImGui.SDL
import qualified DearImGui.SDL.Vulkan as ImGui.SDL.Vulkan
import qualified DearImGui.Vulkan as ImGui.Vulkan
import qualified SDL
import qualified Vulkan as Vk
import qualified Vulkan.Core10.Handles as Vk
import qualified Vulkan.Zero as Vk
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Haskan.Logger (LogCategory (..), logInfoIO)
import Graphics.Haskan.Vulkan.RenderPass qualified as RenderPass

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
-- Cloud Debug Panel
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

buildCloudDebugPanel :: STM.TVar Float -> STM.TVar Float -> STM.TVar Float -> STM.TVar Float -> IO ()
buildCloudDebugPanel tvHeight tvCoverage tvDetail tvAbsorption =
  withCString "Cloud Debug" $ \windowTitle -> do
    open <- ImGui.Raw.begin windowTitle Nothing Nothing
    when open $ do
      withCString "Height" $ \label -> sliderFloatTVar label 0.0 2000.0 tvHeight
      withCString "Coverage" $ \label -> sliderFloatTVar label 0.0 1.0 tvCoverage
      withCString "Detail" $ \label -> sliderFloatTVar label 0.0 1.0 tvDetail
      withCString "Absorption" $ \label -> sliderFloatTVar label 0.0 10.0 tvAbsorption
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
