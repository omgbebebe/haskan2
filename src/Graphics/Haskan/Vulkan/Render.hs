{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Vulkan.Render
  ( RenderResult (..),
    drawFrame,
    presentFrame,
    createRenderContext,
    RenderContextConfig (..),
    maxFramesInFlight,
    RenderM,
    runRenderM,
  )
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Control.Monad.Reader (MonadReader, ReaderT, ask, asks, runReaderT)
import Data.Foldable (for_)
import Data.Traversable (for)
import Data.Vector qualified as Vector
import Data.Word (Word32, Word64)
import Foreign.Ptr (nullPtr)
import Graphics.Haskan.Logger (LogCategory (..), logDebugIO, logInfoIO, showT)
import Graphics.Haskan.Render.ShaderProgram (ShaderProgram (..))
import Graphics.Haskan.Vertex qualified as Vertex
import Graphics.Haskan.Vulkan.CommandBuffer qualified as CommandBuffer
import Graphics.Haskan.Vulkan.Framebuffer qualified as Framebuffer
import Graphics.Haskan.Vulkan.GraphicsPipeline qualified as GraphicsPipeline
import Graphics.Haskan.Vulkan.ImageView qualified as Haskan
import Graphics.Haskan.Vulkan.PhysicalDevice qualified as PhysicalDevice
import Graphics.Haskan.Vulkan.RenderPass qualified as RenderPass
import Graphics.Haskan.Vulkan.Swapchain qualified as Swapchain
import Graphics.Haskan.Vulkan.Types (RenderContext (..), RenderResult (..))
import Vulkan qualified as Vk26
import Vulkan.CStruct.Extends (SomeStruct (..))
import Vulkan.Zero (zero)

type RenderM m = ReaderT RenderContext m

runRenderM :: RenderContext -> RenderM m a -> m a
runRenderM ctx action = runReaderT action ctx

maxFramesInFlight :: Int
maxFramesInFlight = 2

data RenderContextConfig = RenderContextConfig
  { rccPhysicalDevice :: !Vk26.PhysicalDevice,
    rccDevice :: !Vk26.Device,
    rccSurface :: !Vk26.SurfaceKHR,
    rccPipelineLayout :: !Vk26.PipelineLayout,
    rccVertexShader :: !Vk26.ShaderModule,
    rccFragmentShader :: !Vk26.ShaderModule,
    rccDescriptorSets :: ![Vk26.DescriptorSet],
    rccCommandPool :: !Vk26.CommandPool,
    rccGraphicsQueue :: !Vk26.Queue,
    rccPresentQueue :: !Vk26.Queue,
    rccRenderFinishedFences :: ![Vk26.Fence],
    rccRenderFinishedSemaphores :: ![Vk26.Semaphore]
  }

createRenderContext ::
  (MonadIO m, MonadManaged m) =>
  RenderContextConfig ->
  m RenderContext
createRenderContext RenderContextConfig {..} = do
  let depthFormat = Vk26.FORMAT_D16_UNORM
      Vk26.SurfaceFormatKHR fmt _ = Swapchain.surfaceFormat
  surfaceExtent <- PhysicalDevice.surfaceExtent rccPhysicalDevice rccSurface
  let Vk26.Extent2D w h = surfaceExtent
  logDebugIO LogRender $ "createRenderContext extent=" <> showT w <> "x" <> showT h
  swapchain <- Swapchain.managedSwapchain rccDevice rccPhysicalDevice rccSurface surfaceExtent
  images <- Swapchain.getSwapchainImages rccDevice swapchain
  logDebugIO LogRender $ "createRenderContext swapchain images=" <> showT (length images)
  imageViews <- for images (Haskan.managedImageView rccDevice fmt)

  renderPass <- RenderPass.managedRenderPass rccDevice Swapchain.surfaceFormat depthFormat
  graphicsPipeline <-
    GraphicsPipeline.managedGraphicsPipeline
      rccDevice
      rccPipelineLayout
      renderPass
      ShaderProgram
        { spVertex = rccVertexShader,
          spTessControl = Nothing,
          spTessEvaluation = Nothing,
          spGeometry = Nothing,
          spFragment = rccFragmentShader,
          spSpecializationInfo = Nothing
        }
      surfaceExtent
      Vertex.vertexFormat
      1

  depthImage <- Swapchain.managedDepthImage rccPhysicalDevice rccDevice surfaceExtent depthFormat
  depthImageView <- Swapchain.managedDepthView rccDevice depthImage depthFormat
  logDebugIO LogRender "createRenderContext depth image created"

  framebuffers <- for imageViews $ \imageView ->
    Framebuffer.managedFramebuffer rccDevice renderPass surfaceExtent imageView depthImageView
  logDebugIO LogRender $ "createRenderContext framebuffers=" <> showT (length framebuffers)

  graphicsCommandBuffers <- for framebuffers (\_ -> CommandBuffer.createCommandBuffer rccDevice rccCommandPool)
  logDebugIO LogRender $ "createRenderContext commandBuffers=" <> showT (length graphicsCommandBuffers)

  pure
    RenderContext
      { device = rccDevice,
        swapchain = swapchain,
        swapchainImages = images,
        graphicsCommandBuffers = graphicsCommandBuffers,
        graphicsQueueHandler = rccGraphicsQueue,
        presentQueueHandler = rccPresentQueue,
        renderFinishedFences = rccRenderFinishedFences,
        renderFinishedSemaphores = rccRenderFinishedSemaphores,
        rcPipelineLayout = rccPipelineLayout,
        rcGraphicsPipeline = graphicsPipeline,
        rcRenderPass = renderPass,
        rcFramebuffers = framebuffers,
        rcDescriptorSets = rccDescriptorSets,
        rcSurfaceExtent = surfaceExtent,
        rcGraphicsCommandPool = rccCommandPool
      }

drawFrame :: (MonadIO m) => Vk26.Semaphore -> Int -> (Word32 -> Int -> IO ()) -> RenderM m RenderResult
drawFrame imageAvailableSemaphore fenceIndex recordAction = do
  RenderContext {..} <- ask
  -- Wait for previous frame using this fence to complete before acquiring image
  liftIO $ do
    let renderFinishedFence = renderFinishedFences !! fenceIndex
    Vk26.waitForFences device (Vector.fromList [renderFinishedFence]) True (maxBound :: Word64)
    Vk26.resetFences device (Vector.fromList [renderFinishedFence])

  (vkResult, imageIndex) <-
    liftIO $
      Vk26.acquireNextImageKHR device swapchain 100000000 imageAvailableSemaphore Vk26.NULL_HANDLE

  case vkResult of
    Vk26.SUCCESS -> FrameOk <$> renderImage imageAvailableSemaphore fenceIndex imageIndex recordAction
    Vk26.TIMEOUT -> pure FrameTimeout
    Vk26.SUBOPTIMAL_KHR -> pure $ FrameSuboptimal imageIndex
    Vk26.ERROR_OUT_OF_DATE_KHR -> do
      -- The acquire failed; the semaphore was never signaled.
      -- Signal the fence with a no-op submit so the next frame
      -- doesn't hang in vkWaitForFences.
      liftIO $ do
        let renderFinishedFence = renderFinishedFences !! fenceIndex
            submitInfo =
              Vk26.SubmitInfo
                ()
                Vector.empty
                Vector.empty
                Vector.empty
                Vector.empty
        Vk26.queueSubmit graphicsQueueHandler (Vector.fromList [SomeStruct submitInfo]) renderFinishedFence
      pure FrameOutOfDate
    _ -> pure $ FrameFailed (show vkResult)

renderImage ::
  (MonadIO m) =>
  Vk26.Semaphore ->
  Int ->
  Word32 ->
  (Word32 -> Int -> IO ()) ->
  RenderM m Word32
renderImage imageAvailableSemaphore fenceIndex imageIndex recordAction = do
  RenderContext {..} <- ask
  let commandBuffer = graphicsCommandBuffers !! fromIntegral imageIndex
      renderFinishedSemaphore = renderFinishedSemaphores !! fromIntegral imageIndex
      renderFinishedFence = renderFinishedFences !! fenceIndex
      Vk26.CommandBuffer cbHandle _ = commandBuffer

  liftIO $ do
    -- Now safe to record command buffer
    recordAction imageIndex fenceIndex

    let submitInfo =
          Vk26.SubmitInfo
            ()
            (Vector.fromList [imageAvailableSemaphore])
            (Vector.fromList [Vk26.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT])
            (Vector.fromList [cbHandle])
            (Vector.fromList [renderFinishedSemaphore])
    Vk26.queueSubmit graphicsQueueHandler (Vector.fromList [SomeStruct submitInfo]) renderFinishedFence
  pure imageIndex

presentFrame :: (MonadIO m) => Word32 -> Vk26.Semaphore -> RenderM m Vk26.Result
presentFrame imageIndex renderFinishedSem = do
  RenderContext {..} <- ask
  let presentInfo =
        Vk26.PresentInfoKHR
          ()
          (Vector.fromList [renderFinishedSem])
          (Vector.fromList [swapchain])
          (Vector.fromList [imageIndex])
          nullPtr
  liftIO $ Vk26.queuePresentKHR presentQueueHandler presentInfo
