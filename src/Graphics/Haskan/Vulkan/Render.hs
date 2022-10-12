{-# language RecordWildCards #-}
module Graphics.Haskan.Vulkan.Render
  (RenderContext(..)
  ,RenderResult(..)
  , drawFrame
  , presentFrame
  , createRenderContext
  , maxFramesInFlight
  ) where

-- base
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Traversable (for)
import Data.Foldable (for_)
import qualified Foreign.Marshal.Array

-- vulkan-api
import qualified Graphics.Vulkan as Vulkan
import qualified Graphics.Vulkan.Core_1_0 as Vulkan
import qualified Graphics.Vulkan.Ext as Vulkan
import qualified Graphics.Vulkan.Marshal.Create as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, setListRef, (&*))

-- managed
import Control.Monad.Managed (MonadManaged)
-- haskan
import qualified Graphics.Haskan.Vulkan.CommandBuffer as CommandBuffer
import qualified Graphics.Haskan.Vulkan.DescriptorSet as DescriptorSet
import qualified Graphics.Haskan.Vulkan.Framebuffer as Framebuffer
import qualified Graphics.Haskan.Vulkan.GraphicsPipeline as GraphicsPipeline
import qualified Graphics.Haskan.Vulkan.ImageView as Haskan
import qualified Graphics.Haskan.Vulkan.PhysicalDevice as PhysicalDevice
import qualified Graphics.Haskan.Vulkan.RenderPass as RenderPass
import qualified Graphics.Haskan.Vulkan.Swapchain as Swapchain
import qualified Graphics.Haskan.Vertex as Vertex
import Graphics.Haskan.Resources (throwVkResult, allocaAndPeekVkResult)

import Graphics.Haskan.Vulkan.Types (RenderContext(..), RenderResult(..))

maxFramesInFlight :: Int
maxFramesInFlight = 2

createRenderContext
  :: (MonadIO m, MonadManaged m)
  => Vulkan.VkPhysicalDevice
  -> Vulkan.VkDevice
  -> Vulkan.VkSurfaceKHR
  -> Vulkan.VkPipelineLayout
  -> Vulkan.VkShaderModule
  -> Vulkan.VkShaderModule
  -> [Vulkan.VkDescriptorSet]
  -> Vulkan.VkCommandPool
  -> Vulkan.VkQueue
  -> Vulkan.VkQueue
  -> [Vulkan.VkFence]
  -> [Vulkan.VkSemaphore]
  -> [Vulkan.VkBuffer]
  -> [Vulkan.VkBuffer]
  -> Int
  -> m RenderContext
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
  renderFinishedSemaphores
  vertexBuffers
  indexBuffers
  indexCount = do
  let
    --depthFormat = Vulkan.VK_FORMAT_D32_SFLOAT
    depthFormat = Vulkan.VK_FORMAT_D16_UNORM
    format = Vulkan.getField @"format" Swapchain.surfaceFormat
  surfaceExtent <- PhysicalDevice.surfaceExtent pdev surface
  swapchain <- Swapchain.managedSwapchain device surface surfaceExtent
  -- TODO: embed imageViews somewhere
  images <- Swapchain.getSwapchainImages device swapchain
  imageViews <- for images (Haskan.managedImageView device format)

  renderPass <- RenderPass.managedRenderPass device Swapchain.surfaceFormat depthFormat
  graphicsPipeline <-
    GraphicsPipeline.managedGraphicsPipeline
      device
      pipelineLayout
      renderPass
      vertShader
      fragShader
      surfaceExtent
      Vertex.vertexFormat

  depthImage <- Swapchain.managedDepthImage pdev device surfaceExtent depthFormat
  depthImageView <- Swapchain.managedDepthView device depthImage depthFormat
 
  framebuffers <- for imageViews $ \imageView ->
    Framebuffer.managedFramebuffer device renderPass surfaceExtent imageView depthImageView


  graphicsCommandBuffers <- for framebuffers (\_ -> CommandBuffer.createCommandBuffer device graphicsCommandPool)
 
  for_ (zip3 framebuffers graphicsCommandBuffers descriptorSets)
    (\(fb, cb, ds) -> CommandBuffer.withCommandBuffer cb
      (RenderPass.withRenderPass cb renderPass fb surfaceExtent $ do
       GraphicsPipeline.cmdBindPipeline cb graphicsPipeline
       liftIO $ Foreign.Marshal.Array.withArray [ ds ] $ \dsPtr ->
         DescriptorSet.cmdBindDescriptorSets
           cb
           Vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS
           pipelineLayout
           0
           1
           dsPtr
           0
           Vulkan.vkNullPtr
     
       liftIO $ Foreign.Marshal.Array.withArray vertexBuffers $ \bufferPtr ->
         Foreign.Marshal.Array.withArray [ 0 ] $ \offsetPtr ->
           Vulkan.vkCmdBindVertexBuffers cb 0 1 bufferPtr offsetPtr

       for_ indexBuffers $ \indexBuffer -> liftIO $
         Vulkan.vkCmdBindIndexBuffer cb indexBuffer 0 Vulkan.VK_INDEX_TYPE_UINT32

       CommandBuffer.cmdDraw cb indexCount
      )
    )

  pure RenderContext{..}


drawFrame :: (MonadFail m, MonadIO m) => RenderContext -> Vulkan.VkSemaphore -> Int -> m RenderResult
drawFrame ctx@RenderContext{..} imageAvailableSemaphore fenceIndex = do
  let

  (imageIndex, vkResult) <- liftIO $ allocaAndPeekVkResult $
    --Vulkan.vkAcquireNextImageKHR device swapchain 100 imageAvailableSemaphore Vulkan.VK_NULL_HANDLE
    Vulkan.vkAcquireNextImageKHR device swapchain maxBound imageAvailableSemaphore Vulkan.VK_NULL_HANDLE
 
  case vkResult of
    Vulkan.VK_SUCCESS -> FrameOk <$> renderImage ctx imageAvailableSemaphore fenceIndex imageIndex
    Vulkan.VK_SUBOPTIMAL_KHR -> pure $ FrameSuboptimal imageIndex
    Vulkan.VK_ERROR_OUT_OF_DATE_KHR -> pure FrameOutOfDate
    _ -> pure $ FrameFailed (show vkResult)

renderImage
  :: MonadIO m
  => RenderContext
  -> Vulkan.VkSemaphore
  -> Int
  -> Vulkan.Word32
  -> m Vulkan.Word32
renderImage RenderContext{..} imageAvailableSemaphore fenceIndex imageIndex = do
  let
    commandBuffer = graphicsCommandBuffers !! (fromIntegral imageIndex)
    renderFinishedSemaphore = renderFinishedSemaphores !! (fromIntegral imageIndex)
    renderFinishedFence = renderFinishedFences !! fenceIndex
    submitInfo = Vulkan.createVk
      (  set @"sType" Vulkan.VK_STRUCTURE_TYPE_SUBMIT_INFO
      &* set @"pNext" Vulkan.vkNullPtr
      &* set @"waitSemaphoreCount" 1
      &* setListRef @"pWaitSemaphores" [imageAvailableSemaphore]
      &* setListRef @"pWaitDstStageMask" [Vulkan.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT]
      &* set @"commandBufferCount" 1
      &* setListRef @"pCommandBuffers" [commandBuffer]
      &* set @"signalSemaphoreCount" 1
      &* setListRef @"pSignalSemaphores" [renderFinishedSemaphore]
      )
  liftIO $ withPtr submitInfo $ \siPtr -> do
    Foreign.Marshal.Array.withArray [renderFinishedFence] $ \ptr -> do
      Vulkan.vkWaitForFences device 1 ptr Vulkan.VK_TRUE maxBound >>= throwVkResult
      Vulkan.vkResetFences device 1 ptr >>= throwVkResult
    Vulkan.vkQueueSubmit graphicsQueueHandler 1 siPtr renderFinishedFence >>= throwVkResult
  pure (imageIndex)

presentFrame :: MonadIO m => RenderContext -> Vulkan.Word32 -> Vulkan.VkSemaphore -> m Vulkan.VkResult
presentFrame RenderContext{..} imageIndex renderFinishedSem = do
  let
    presentInfo = Vulkan.createVk
      (  set @"sType" Vulkan.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR
      &* set @"pNext" Vulkan.vkNullPtr
      &* set @"waitSemaphoreCount" 1
      &* setListRef @"pWaitSemaphores" [renderFinishedSem]
      &* set @"swapchainCount" 1
      &* setListRef @"pSwapchains" [swapchain]
      &* setListRef @"pImageIndices" [imageIndex]
      &* set @"pResults" Vulkan.vkNullPtr
      )
  liftIO $ withPtr presentInfo (\piPtr -> Vulkan.vkQueuePresentKHR presentQueueHandler piPtr)
