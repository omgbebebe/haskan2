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
import Foreign.Marshal.Array qualified
import Graphics.Haskan.Logger (LogCategory (..), logDebugIO, logInfoIO, showT)
import Graphics.Haskan.Render.ShaderProgram (ShaderProgram (..))
import Graphics.Haskan.Resources (allocaAndPeekVkResult, throwVkResult)
import Graphics.Haskan.Vertex qualified as Vertex
import Graphics.Haskan.Vulkan.CommandBuffer qualified as CommandBuffer
import Graphics.Haskan.Vulkan.DescriptorSet qualified as DescriptorSet
import Graphics.Haskan.Vulkan.Framebuffer qualified as Framebuffer
import Graphics.Haskan.Vulkan.GraphicsPipeline qualified as GraphicsPipeline
import Graphics.Haskan.Vulkan.ImageView qualified as Haskan
import Graphics.Haskan.Vulkan.PhysicalDevice qualified as PhysicalDevice
import Graphics.Haskan.Vulkan.RenderPass qualified as RenderPass
import Graphics.Haskan.Vulkan.Swapchain qualified as Swapchain
import Graphics.Haskan.Vulkan.Types (RenderContext (..), RenderResult (..))
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Ext qualified as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, setListRef, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan

type RenderM m = ReaderT RenderContext m

runRenderM :: RenderContext -> RenderM m a -> m a
runRenderM ctx action = runReaderT action ctx

maxFramesInFlight :: Int
maxFramesInFlight = 2

data RenderContextConfig = RenderContextConfig
  { rccPhysicalDevice :: !Vulkan.VkPhysicalDevice,
    rccDevice :: !Vulkan.VkDevice,
    rccSurface :: !Vulkan.VkSurfaceKHR,
    rccPipelineLayout :: !Vulkan.VkPipelineLayout,
    rccVertexShader :: !Vulkan.VkShaderModule,
    rccFragmentShader :: !Vulkan.VkShaderModule,
    rccDescriptorSets :: ![Vulkan.VkDescriptorSet],
    rccCommandPool :: !Vulkan.VkCommandPool,
    rccGraphicsQueue :: !Vulkan.VkQueue,
    rccPresentQueue :: !Vulkan.VkQueue,
    rccRenderFinishedFences :: ![Vulkan.VkFence],
    rccRenderFinishedSemaphores :: ![Vulkan.VkSemaphore]
  }

createRenderContext ::
  (MonadIO m, MonadManaged m) =>
  RenderContextConfig ->
  m RenderContext
createRenderContext RenderContextConfig {..} = do
    let -- depthFormat = Vulkan.VK_FORMAT_D32_SFLOAT
        depthFormat = Vulkan.VK_FORMAT_D16_UNORM
        format = Vulkan.getField @"format" Swapchain.surfaceFormat
    surfaceExtent <- PhysicalDevice.surfaceExtent rccPhysicalDevice rccSurface
    logDebugIO LogRender $ "createRenderContext extent=" <> showT (Vulkan.getField @"width" surfaceExtent) <> "x" <> showT (Vulkan.getField @"height" surfaceExtent)
    swapchain <- Swapchain.managedSwapchain rccDevice rccPhysicalDevice rccSurface surfaceExtent
    images <- Swapchain.getSwapchainImages rccDevice swapchain
    logDebugIO LogRender $ "createRenderContext swapchain images=" <> showT (length images)
    imageViews <- for images (Haskan.managedImageView rccDevice format)

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
            spFragment = rccFragmentShader
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

drawFrame :: (MonadIO m) => Vulkan.VkSemaphore -> Int -> (Vulkan.Word32 -> Int -> IO ()) -> RenderM m RenderResult
drawFrame imageAvailableSemaphore fenceIndex recordAction = do
  RenderContext {..} <- ask
  -- Wait for previous frame using this fence to complete before acquiring image
  liftIO $ do
    let renderFinishedFence = renderFinishedFences !! fenceIndex
    Foreign.Marshal.Array.withArray [renderFinishedFence] $ \ptr -> do
      Vulkan.vkWaitForFences device 1 ptr Vulkan.VK_TRUE maxBound >>= throwVkResult
      Vulkan.vkResetFences device 1 ptr >>= throwVkResult

  (imageIndex, vkResult) <-
    liftIO $
      allocaAndPeekVkResult $
        Vulkan.vkAcquireNextImageKHR device swapchain 100000000 imageAvailableSemaphore Vulkan.VK_NULL_HANDLE

  case vkResult of
    Vulkan.VK_SUCCESS -> FrameOk <$> renderImage imageAvailableSemaphore fenceIndex imageIndex recordAction
    Vulkan.VK_TIMEOUT -> pure FrameTimeout
    Vulkan.VK_SUBOPTIMAL_KHR -> pure $ FrameSuboptimal imageIndex
    Vulkan.VK_ERROR_OUT_OF_DATE_KHR -> do
      -- The acquire failed; the semaphore was never signaled.
      -- Signal the fence with a no-op submit so the next frame
      -- doesn't hang in vkWaitForFences.
      liftIO $ do
        let renderFinishedFence = renderFinishedFences !! fenceIndex
            emptySubmitInfo =
              Vulkan.createVk
                ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_SUBMIT_INFO
                    &* set @"pNext" Vulkan.vkNullPtr
                    &* set @"waitSemaphoreCount" 0
                    &* set @"pWaitSemaphores" Vulkan.vkNullPtr
                    &* set @"pWaitDstStageMask" Vulkan.vkNullPtr
                    &* set @"commandBufferCount" 0
                    &* set @"pCommandBuffers" Vulkan.vkNullPtr
                    &* set @"signalSemaphoreCount" 0
                    &* set @"pSignalSemaphores" Vulkan.vkNullPtr
                )
        withPtr emptySubmitInfo $ \siPtr ->
          Vulkan.vkQueueSubmit graphicsQueueHandler 1 siPtr renderFinishedFence >>= throwVkResult
      pure FrameOutOfDate
    _ -> pure $ FrameFailed (show vkResult)

renderImage ::
  (MonadIO m) =>
  Vulkan.VkSemaphore ->
  Int ->
  Vulkan.Word32 ->
  (Vulkan.Word32 -> Int -> IO ()) ->
  RenderM m Vulkan.Word32
renderImage imageAvailableSemaphore fenceIndex imageIndex recordAction = do
  RenderContext {..} <- ask
  let commandBuffer = graphicsCommandBuffers !! fromIntegral imageIndex
      renderFinishedSemaphore = renderFinishedSemaphores !! fromIntegral imageIndex
      renderFinishedFence = renderFinishedFences !! fenceIndex

  liftIO $ do
    -- Now safe to record command buffer
    recordAction imageIndex fenceIndex

    let submitInfo =
          Vulkan.createVk
            ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_SUBMIT_INFO
                &* set @"pNext" Vulkan.vkNullPtr
                &* set @"waitSemaphoreCount" 1
                &* setListRef @"pWaitSemaphores" [imageAvailableSemaphore]
                &* setListRef @"pWaitDstStageMask" [Vulkan.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT]
                &* set @"commandBufferCount" 1
                &* setListRef @"pCommandBuffers" [commandBuffer]
                &* set @"signalSemaphoreCount" 1
                &* setListRef @"pSignalSemaphores" [renderFinishedSemaphore]
            )
    withPtr submitInfo $ \siPtr ->
      Vulkan.vkQueueSubmit graphicsQueueHandler 1 siPtr renderFinishedFence >>= throwVkResult
  pure imageIndex

presentFrame :: (MonadIO m) => Vulkan.Word32 -> Vulkan.VkSemaphore -> RenderM m Vulkan.VkResult
presentFrame imageIndex renderFinishedSem = do
  RenderContext {..} <- ask
  let presentInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR
              &* set @"pNext" Vulkan.vkNullPtr
              &* set @"waitSemaphoreCount" 1
              &* setListRef @"pWaitSemaphores" [renderFinishedSem]
              &* set @"swapchainCount" 1
              &* setListRef @"pSwapchains" [swapchain]
              &* setListRef @"pImageIndices" [imageIndex]
              &* set @"pResults" Vulkan.vkNullPtr
          )
  liftIO $ withPtr presentInfo (Vulkan.vkQueuePresentKHR presentQueueHandler)
