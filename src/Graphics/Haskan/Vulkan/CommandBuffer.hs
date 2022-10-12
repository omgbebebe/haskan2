module Graphics.Haskan.Vulkan.CommandBuffer where

-- base
import Control.Monad.IO.Class (MonadIO, liftIO)

-- vulkan-api
import qualified Graphics.Vulkan as Vulkan
import qualified Graphics.Vulkan.Core_1_0 as Vulkan
import qualified Graphics.Vulkan.Marshal.Create as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, setListRef, (&*))

-- haskan
import Graphics.Haskan.Resources (allocaAndPeek, throwVkResult)

createCommandBuffer
  :: MonadIO m
  => Vulkan.VkDevice
  -> Vulkan.VkCommandPool
  -> m Vulkan.VkCommandBuffer
createCommandBuffer dev commandPool =
  let
    createInfo = Vulkan.createVk
      (  set @"sType" Vulkan.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
      &* set @"pNext" Vulkan.VK_NULL
      &* set @"commandPool" commandPool
      &* set @"level" Vulkan.VK_COMMAND_BUFFER_LEVEL_PRIMARY
      &* set @"commandBufferCount" 1
      )
  in liftIO $ withPtr createInfo (\ciPtr -> allocaAndPeek (Vulkan.vkAllocateCommandBuffers dev ciPtr))

{-
createOneTimeCommandBuffer
  :: MonadIO m
  => Vulkan.VkDevice
  -> Vulkan.VkCommandPool
  -> m Vulkan.VkCommandBuffer
createCommandBuffer dev commandPool =
-}

withCommandBuffer
  :: MonadIO m
  => Vulkan.VkCommandBuffer
  -> m a
  -> m a
withCommandBuffer commandBuffer action = withCommandBuffer' commandBuffer Vulkan.VK_ZERO_FLAGS action

withCommandBufferOneTime
  :: MonadIO m
  => Vulkan.VkQueue
  -> Vulkan.VkCommandBuffer
  -> m ()
  -> m ()
withCommandBufferOneTime queue commandBuffer action = do
  withCommandBuffer' commandBuffer Vulkan.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT action
  let
    submitInfo = Vulkan.createVk
      (  set @"sType" Vulkan.VK_STRUCTURE_TYPE_SUBMIT_INFO
      &* set @"pNext" Vulkan.VK_NULL
      &* set @"commandBufferCount" 1
      &* setListRef @"pCommandBuffers" [commandBuffer]
      &* set @"pWaitSemaphores" Vulkan.VK_NULL
      &* set @"pWaitDstStageMask" Vulkan.VK_NULL
      &* set @"pSignalSemaphores" Vulkan.VK_NULL
      )
  liftIO $ withPtr submitInfo
    (\siPtr -> do
        Vulkan.vkQueueSubmit queue 1 siPtr Vulkan.vkNullPtr
        Vulkan.vkQueueWaitIdle queue >>= throwVkResult
    )

withCommandBuffer'
  :: MonadIO m
  => Vulkan.VkCommandBuffer
  -> Vulkan.VkCommandBufferUsageBitmask Vulkan.FlagMask
  -> m a
  -> m a
withCommandBuffer' commandBuffer flags action =
  let
    commandBufferBeginInfo = Vulkan.createVk
      (  set @"sType" Vulkan.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
      &* set @"pNext" Vulkan.vkNullPtr
      &* set @"flags" flags --Vulkan.VK_ZERO_FLAGS
      &* set @"pInheritanceInfo" Vulkan.vkNullPtr
      )
    begin = liftIO $ withPtr commandBufferBeginInfo
            (\cbbiPtr ->
               Vulkan.vkBeginCommandBuffer commandBuffer cbbiPtr >>= throwVkResult
            )
    end = liftIO $ Vulkan.vkEndCommandBuffer commandBuffer >>= throwVkResult

  in (begin *> action <* end)

cmdDraw :: MonadIO m => Vulkan.VkCommandBuffer -> Int -> m ()
cmdDraw commandBuffer indexCount = liftIO $ Vulkan.vkCmdDrawIndexed commandBuffer (fromIntegral indexCount) 1 0 0 0

copyBuffer
  :: MonadIO m
  => Vulkan.VkQueue
  -> Vulkan.VkCommandBuffer
  -> Vulkan.VkBuffer
  -> Vulkan.VkBuffer
  -> Vulkan.VkDeviceSize
  -> m ()
copyBuffer queue commandBuffer srcBuffer dstBuffer size = do
  let
    regionSize = Vulkan.createVk
      (  set @"size" size
      &* set @"srcOffset" 0
      &* set @"dstOffset" 0
      )
  withCommandBufferOneTime queue commandBuffer
    ( liftIO $ withPtr regionSize (\rsPtr -> Vulkan.vkCmdCopyBuffer commandBuffer srcBuffer dstBuffer 1 rsPtr ))

layerTransition
  :: MonadIO m
  => Vulkan.VkCommandBuffer
  -> Vulkan.VkImage
  -> Vulkan.VkImageLayout
  -> Vulkan.VkImageLayout
  -> m ()
layerTransition commandBuffer image oldLayout newLayout = do
  let
    (srcStage, srcAccessMask, dstStage, dstAccessMask) =
      case (oldLayout, newLayout) of
        (Vulkan.VK_IMAGE_LAYOUT_UNDEFINED, Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) ->
          (Vulkan.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT
          ,Vulkan.VK_ZERO_FLAGS
          ,Vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT
          ,Vulkan.VK_ACCESS_TRANSFER_WRITE_BIT
          )
        (Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) ->
          (Vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT
          ,Vulkan.VK_ACCESS_TRANSFER_WRITE_BIT
          ,Vulkan.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT
          ,Vulkan.VK_ACCESS_SHADER_READ_BIT
          )

    subresourceRange = Vulkan.createVk
      (  set @"aspectMask" Vulkan.VK_IMAGE_ASPECT_COLOR_BIT
      &* set @"baseMipLevel" 0
      &* set @"levelCount" 1
      &* set @"baseArrayLayer" 0
      &* set @"layerCount" 1
      )
    barrier = Vulkan.createVk
      (  set @"sType" Vulkan.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
      &* set @"pNext" Vulkan.VK_NULL
      &* set @"oldLayout" oldLayout
      &* set @"newLayout" newLayout
      &* set @"srcQueueFamilyIndex" Vulkan.VK_QUEUE_FAMILY_IGNORED
      &* set @"dstQueueFamilyIndex" Vulkan.VK_QUEUE_FAMILY_IGNORED
      &* set @"image" image
      &* set @"subresourceRange" subresourceRange
      &* set @"srcAccessMask" srcAccessMask
      &* set @"dstAccessMask" dstAccessMask
      )
  liftIO $ withPtr barrier
    (\bPtr -> Vulkan.vkCmdPipelineBarrier
      commandBuffer
      srcStage dstStage
      Vulkan.VK_ZERO_FLAGS
      0 Vulkan.vkNullPtr
      0 Vulkan.vkNullPtr
      1 bPtr
    )

copyBufferToImage
  :: MonadIO m
  => Vulkan.VkCommandBuffer
  -> Vulkan.VkBuffer
  -> Vulkan.VkImage
  -> Vulkan.Word32
  -> Vulkan.Word32
  -> m ()
copyBufferToImage commandBuffer buffer image width height = do
  let
    imageSubresource = Vulkan.createVk
      (  set @"aspectMask" Vulkan.VK_IMAGE_ASPECT_COLOR_BIT
      &* set @"mipLevel" 0
      &* set @"baseArrayLayer" 0
      &* set @"layerCount" 1
      )
    imageExtent = Vulkan.createVk
      (  set @"width" width
      &* set @"height" height
      &* set @"depth" 1
      )
    imageOffset = Vulkan.createVk
      (  set @"x" 0
      &* set @"y" 0
      &* set @"z" 0
      )
    region = Vulkan.createVk
      (  set @"bufferOffset" 0
      &* set @"bufferRowLength" 0
      &* set @"bufferImageHeight" 0
      &* set @"imageSubresource" imageSubresource
      &* set @"imageOffset" imageOffset
      &* set @"imageExtent" imageExtent
      )
  liftIO $ withPtr region
    (\rPtr ->
       Vulkan.vkCmdCopyBufferToImage
         commandBuffer
         buffer
         image
         Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
         1
         rPtr
    )
