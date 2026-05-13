{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Vulkan.Render
  ( RenderResult (..),
    drawFrame,
    presentFrame,
    createRenderContext,
    maxFramesInFlight,
  )
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Foldable (for_)
import Data.Traversable (for)
import Foreign.Marshal.Array qualified
import Graphics.Haskan.Logger (logDebugIO, logInfoIO, showT, LogCategory (..))
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

maxFramesInFlight :: Int
maxFramesInFlight = 2

createRenderContext ::
  (MonadIO m, MonadManaged m) =>
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  Vulkan.VkSurfaceKHR ->
  Vulkan.VkPipelineLayout ->
  Vulkan.VkShaderModule ->
  Vulkan.VkShaderModule ->
  [Vulkan.VkDescriptorSet] ->
  Vulkan.VkCommandPool ->
  Vulkan.VkQueue ->
  Vulkan.VkQueue ->
  [Vulkan.VkFence] ->
  [Vulkan.VkSemaphore] ->
  m RenderContext
createRenderContext
  pdev
  device
  surface
  pipelineLayout
  vertShader
  fragShader
  descriptorSets
  graphicsCommandPool
  graphicsQueueHandler
  presentQueueHandler
  renderFinishedFences
  renderFinishedSemaphores = do
    let -- depthFormat = Vulkan.VK_FORMAT_D32_SFLOAT
        depthFormat = Vulkan.VK_FORMAT_D16_UNORM
        format = Vulkan.getField @"format" Swapchain.surfaceFormat
    surfaceExtent <- PhysicalDevice.surfaceExtent pdev surface
    logDebugIO LogRender $ "createRenderContext extent=" <> showT (Vulkan.getField @"width" surfaceExtent) <> "x" <> showT (Vulkan.getField @"height" surfaceExtent)
    swapchain <- Swapchain.managedSwapchain device pdev surface surfaceExtent
    images <- Swapchain.getSwapchainImages device swapchain
    logDebugIO LogRender $ "createRenderContext swapchain images=" <> showT (length images)
    imageViews <- for images (Haskan.managedImageView device format)

    renderPass <- RenderPass.managedRenderPass device Swapchain.surfaceFormat depthFormat
    graphicsPipeline <-
      GraphicsPipeline.managedGraphicsPipeline
        device
        pipelineLayout
        renderPass
        ShaderProgram
          { spVertex = vertShader
          , spTessControl = Nothing
          , spTessEvaluation = Nothing
          , spGeometry = Nothing
          , spFragment = fragShader
          }
        surfaceExtent
        Vertex.vertexFormat
        1

    depthImage <- Swapchain.managedDepthImage pdev device surfaceExtent depthFormat
    depthImageView <- Swapchain.managedDepthView device depthImage depthFormat
    logDebugIO LogRender "createRenderContext depth image created"

    framebuffers <- for imageViews $ \imageView ->
      Framebuffer.managedFramebuffer device renderPass surfaceExtent imageView depthImageView
    logDebugIO LogRender $ "createRenderContext framebuffers=" <> showT (length framebuffers)

    graphicsCommandBuffers <- for framebuffers (\_ -> CommandBuffer.createCommandBuffer device graphicsCommandPool)
    logDebugIO LogRender $ "createRenderContext commandBuffers=" <> showT (length graphicsCommandBuffers)

    pure
      RenderContext
          { device = device,
            swapchain = swapchain,
            swapchainImages = images,
            graphicsCommandBuffers = graphicsCommandBuffers,
            graphicsQueueHandler = graphicsQueueHandler,
            presentQueueHandler = presentQueueHandler,
            renderFinishedFences = renderFinishedFences,
            renderFinishedSemaphores = renderFinishedSemaphores,
            rcPipelineLayout = pipelineLayout,
            rcGraphicsPipeline = graphicsPipeline,
            rcRenderPass = renderPass,
            rcFramebuffers = framebuffers,
            rcDescriptorSets = descriptorSets,
            rcSurfaceExtent = surfaceExtent,
            rcGraphicsCommandPool = graphicsCommandPool
          }

drawFrame :: (MonadIO m) => RenderContext -> Vulkan.VkSemaphore -> Int -> (Vulkan.Word32 -> Int -> IO ()) -> m RenderResult
drawFrame ctx@RenderContext {..} imageAvailableSemaphore fenceIndex recordAction = do
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
    Vulkan.VK_SUCCESS -> FrameOk <$> renderImage ctx imageAvailableSemaphore fenceIndex imageIndex recordAction
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
  MonadIO m =>
  RenderContext ->
  Vulkan.VkSemaphore ->
  Int ->
  Vulkan.Word32 ->
  (Vulkan.Word32 -> Int -> IO ()) ->
  m Vulkan.Word32
renderImage RenderContext {..} imageAvailableSemaphore fenceIndex imageIndex recordAction = do
  let commandBuffer = graphicsCommandBuffers !! (fromIntegral imageIndex)
      renderFinishedSemaphore = renderFinishedSemaphores !! (fromIntegral imageIndex)
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
  pure (imageIndex)

presentFrame :: MonadIO m => RenderContext -> Vulkan.Word32 -> Vulkan.VkSemaphore -> m Vulkan.VkResult
presentFrame RenderContext {..} imageIndex renderFinishedSem = do
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
  liftIO $ withPtr presentInfo (\piPtr -> Vulkan.vkQueuePresentKHR presentQueueHandler piPtr)
