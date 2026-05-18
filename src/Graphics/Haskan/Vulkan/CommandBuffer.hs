module Graphics.Haskan.Vulkan.CommandBuffer where

import Control.Monad ((>=>))
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Bits ((.|.))
import Data.Int (Int32)
import Data.Word (Word32)
import Graphics.Haskan.Resources (allocaAndPeek, throwVkResult)
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, setAt, setListRef, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan

createCommandBuffer ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkCommandPool ->
  m Vulkan.VkCommandBuffer
createCommandBuffer dev commandPool =
  let createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"commandPool" commandPool
              &* set @"level" Vulkan.VK_COMMAND_BUFFER_LEVEL_PRIMARY
              &* set @"commandBufferCount" 1
          )
   in liftIO $ withPtr createInfo (allocaAndPeek . Vulkan.vkAllocateCommandBuffers dev)

withCommandBuffer ::
  (MonadIO m) =>
  Vulkan.VkCommandBuffer ->
  m a ->
  m a
withCommandBuffer commandBuffer = withCommandBuffer' commandBuffer Vulkan.VK_ZERO_FLAGS

withCommandBufferOneTime ::
  (MonadIO m) =>
  Vulkan.VkQueue ->
  Vulkan.VkCommandBuffer ->
  m () ->
  m ()
withCommandBufferOneTime queue commandBuffer action = do
  withCommandBuffer' commandBuffer Vulkan.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT action
  let submitInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_SUBMIT_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"commandBufferCount" 1
              &* setListRef @"pCommandBuffers" [commandBuffer]
              &* set @"pWaitSemaphores" Vulkan.VK_NULL
              &* set @"pWaitDstStageMask" Vulkan.VK_NULL
              &* set @"pSignalSemaphores" Vulkan.VK_NULL
          )
  liftIO $
    withPtr
      submitInfo
      ( \siPtr -> do
          Vulkan.vkQueueSubmit queue 1 siPtr Vulkan.vkNullPtr
          Vulkan.vkQueueWaitIdle queue >>= throwVkResult
      )

withCommandBuffer' ::
  (MonadIO m) =>
  Vulkan.VkCommandBuffer ->
  Vulkan.VkCommandBufferUsageBitmask Vulkan.FlagMask ->
  m a ->
  m a
withCommandBuffer' commandBuffer flags action =
  let commandBufferBeginInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
              &* set @"pNext" Vulkan.vkNullPtr
              &* set @"flags" flags -- Vulkan.VK_ZERO_FLAGS
              &* set @"pInheritanceInfo" Vulkan.vkNullPtr
          )
      begin =
        liftIO $
          withPtr
            commandBufferBeginInfo
            ( Vulkan.vkBeginCommandBuffer commandBuffer
                Control.Monad.>=> throwVkResult
            )
      end = liftIO $ Vulkan.vkEndCommandBuffer commandBuffer >>= throwVkResult
   in (begin *> action <* end)

cmdDraw :: (MonadIO m) => Vulkan.VkCommandBuffer -> Word32 -> Word32 -> Int32 -> Word32 -> m ()
cmdDraw commandBuffer indexCount firstIndex vertexOffset firstInstance =
  liftIO $ Vulkan.vkCmdDrawIndexed commandBuffer indexCount 1 firstIndex vertexOffset firstInstance

cmdDrawIndexedIndirect :: (MonadIO m) => Vulkan.VkCommandBuffer -> Vulkan.VkBuffer -> Word32 -> Word32 -> m ()
cmdDrawIndexedIndirect commandBuffer buffer drawCount stride =
  liftIO $ Vulkan.vkCmdDrawIndexedIndirect commandBuffer buffer 0 drawCount stride

cmdDispatch :: (MonadIO m) => Vulkan.VkCommandBuffer -> Word32 -> Word32 -> Word32 -> m ()
cmdDispatch commandBuffer gx gy gz = liftIO $ Vulkan.vkCmdDispatch commandBuffer gx gy gz

cmdBufferBarrier ::
  (MonadIO m) =>
  Vulkan.VkCommandBuffer ->
  Vulkan.VkBuffer ->
  Vulkan.VkDeviceSize ->
  Vulkan.VkPipelineStageFlags ->
  Vulkan.VkAccessFlags ->
  Vulkan.VkPipelineStageFlags ->
  Vulkan.VkAccessFlags ->
  m ()
cmdBufferBarrier commandBuffer buffer size srcStage srcAccess dstStage dstAccess = do
  let barrier =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"srcAccessMask" srcAccess
              &* set @"dstAccessMask" dstAccess
              &* set @"srcQueueFamilyIndex" Vulkan.VK_QUEUE_FAMILY_IGNORED
              &* set @"dstQueueFamilyIndex" Vulkan.VK_QUEUE_FAMILY_IGNORED
              &* set @"buffer" buffer
              &* set @"offset" 0
              &* set @"size" size
          )
  liftIO $
    withPtr
      barrier
      ( \bPtr ->
          Vulkan.vkCmdPipelineBarrier
            commandBuffer
            srcStage
            dstStage
            Vulkan.VK_ZERO_FLAGS
            0
            Vulkan.vkNullPtr
            1
            bPtr
            0
            Vulkan.vkNullPtr
      )

copyBufferToImageLayer ::
  (MonadIO m) =>
  Vulkan.VkCommandBuffer ->
  Vulkan.VkBuffer ->
  Vulkan.VkImage ->
  Vulkan.Word32 ->
  Vulkan.Word32 ->
  -- | array layer
  Vulkan.Word32 ->
  -- | buffer offset
  Vulkan.VkDeviceSize ->
  m ()
copyBufferToImageLayer commandBuffer buffer image width height layer bufferOffset = do
  let imageSubresource =
        Vulkan.createVk
          ( set @"aspectMask" Vulkan.VK_IMAGE_ASPECT_COLOR_BIT
              &* set @"mipLevel" 0
              &* set @"baseArrayLayer" layer
              &* set @"layerCount" 1
          )
      imageExtent =
        Vulkan.createVk
          ( set @"width" width
              &* set @"height" height
              &* set @"depth" 1
          )
      imageOffset =
        Vulkan.createVk
          ( set @"x" 0
              &* set @"y" 0
              &* set @"z" 0
          )
      region =
        Vulkan.createVk
          ( set @"bufferOffset" bufferOffset
              &* set @"bufferRowLength" 0
              &* set @"bufferImageHeight" 0
              &* set @"imageSubresource" imageSubresource
              &* set @"imageOffset" imageOffset
              &* set @"imageExtent" imageExtent
          )
  liftIO $
    withPtr
      region
      ( Vulkan.vkCmdCopyBufferToImage
          commandBuffer
          buffer
          image
          Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
          1
      )

layerTransitionAll ::
  (MonadIO m) =>
  Vulkan.VkCommandBuffer ->
  Vulkan.VkImage ->
  Vulkan.VkImageLayout ->
  Vulkan.VkImageLayout ->
  -- | layer count
  Vulkan.Word32 ->
  m ()
layerTransitionAll commandBuffer image oldLayout newLayout layerCount = do
  let (srcStage, srcAccessMask, dstStage, dstAccessMask) =
        case (oldLayout, newLayout) of
          (Vulkan.VK_IMAGE_LAYOUT_UNDEFINED, Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) ->
            ( Vulkan.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
              Vulkan.VK_ZERO_FLAGS,
              Vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT,
              Vulkan.VK_ACCESS_TRANSFER_WRITE_BIT
            )
          (Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) ->
            ( Vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT,
              Vulkan.VK_ACCESS_TRANSFER_WRITE_BIT,
              Vulkan.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
              Vulkan.VK_ACCESS_SHADER_READ_BIT
            )
          (Vulkan.VK_IMAGE_LAYOUT_UNDEFINED, Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) ->
            ( Vulkan.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
              Vulkan.VK_ZERO_FLAGS,
              Vulkan.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
              Vulkan.VK_ACCESS_SHADER_READ_BIT
            )
          _ ->
            ( Vulkan.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
              Vulkan.VK_ACCESS_MEMORY_READ_BIT .|. Vulkan.VK_ACCESS_MEMORY_WRITE_BIT,
              Vulkan.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
              Vulkan.VK_ACCESS_MEMORY_READ_BIT .|. Vulkan.VK_ACCESS_MEMORY_WRITE_BIT
            )

      subresourceRange =
        Vulkan.createVk
          ( set @"aspectMask" Vulkan.VK_IMAGE_ASPECT_COLOR_BIT
              &* set @"baseMipLevel" 0
              &* set @"levelCount" 1
              &* set @"baseArrayLayer" 0
              &* set @"layerCount" layerCount
          )
      barrier =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
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
  liftIO $
    withPtr
      barrier
      ( Vulkan.vkCmdPipelineBarrier
          commandBuffer
          srcStage
          dstStage
          Vulkan.VK_ZERO_FLAGS
          0
          Vulkan.vkNullPtr
          0
          Vulkan.vkNullPtr
          1
      )

copyBuffer ::
  (MonadIO m) =>
  Vulkan.VkQueue ->
  Vulkan.VkCommandBuffer ->
  Vulkan.VkBuffer ->
  Vulkan.VkBuffer ->
  Vulkan.VkDeviceSize ->
  m ()
copyBuffer queue commandBuffer srcBuffer dstBuffer size = do
  let regionSize =
        Vulkan.createVk
          ( set @"size" size
              &* set @"srcOffset" 0
              &* set @"dstOffset" 0
          )
  withCommandBufferOneTime
    queue
    commandBuffer
    (liftIO $ withPtr regionSize (Vulkan.vkCmdCopyBuffer commandBuffer srcBuffer dstBuffer 1))

mipLayerTransition ::
  (MonadIO m) =>
  Vulkan.VkCommandBuffer ->
  Vulkan.VkImage ->
  Vulkan.VkImageLayout ->
  Vulkan.VkImageLayout ->
  -- | base mip level
  Vulkan.Word32 ->
  -- | level count
  Vulkan.Word32 ->
  -- | layer count
  Vulkan.Word32 ->
  m ()
mipLayerTransition commandBuffer image oldLayout newLayout baseMip levelCount layerCount = do
  let (srcStage, srcAccessMask, dstStage, dstAccessMask) =
        case (oldLayout, newLayout) of
          _
            | oldLayout == newLayout ->
                ( Vulkan.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                  Vulkan.VK_ZERO_FLAGS,
                  Vulkan.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
                  Vulkan.VK_ZERO_FLAGS
                )
          (Vulkan.VK_IMAGE_LAYOUT_UNDEFINED, Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) ->
            ( Vulkan.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
              Vulkan.VK_ZERO_FLAGS,
              Vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT,
              Vulkan.VK_ACCESS_TRANSFER_WRITE_BIT
            )
          (Vulkan.VK_IMAGE_LAYOUT_UNDEFINED, Vulkan.VK_IMAGE_LAYOUT_GENERAL) ->
            ( Vulkan.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
              Vulkan.VK_ZERO_FLAGS,
              Vulkan.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
              Vulkan.VK_ACCESS_SHADER_WRITE_BIT
            )
          (Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, Vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL) ->
            ( Vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT,
              Vulkan.VK_ACCESS_TRANSFER_WRITE_BIT,
              Vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT,
              Vulkan.VK_ACCESS_TRANSFER_READ_BIT
            )
          (Vulkan.VK_IMAGE_LAYOUT_GENERAL, Vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL) ->
            ( Vulkan.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
              Vulkan.VK_ACCESS_SHADER_WRITE_BIT,
              Vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT,
              Vulkan.VK_ACCESS_TRANSFER_READ_BIT
            )
          (Vulkan.VK_IMAGE_LAYOUT_GENERAL, Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) ->
            ( Vulkan.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
              Vulkan.VK_ACCESS_SHADER_WRITE_BIT,
              Vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT,
              Vulkan.VK_ACCESS_TRANSFER_WRITE_BIT
            )
          (Vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) ->
            ( Vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT,
              Vulkan.VK_ACCESS_TRANSFER_READ_BIT,
              Vulkan.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
              Vulkan.VK_ACCESS_SHADER_READ_BIT
            )
          (Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) ->
            ( Vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT,
              Vulkan.VK_ACCESS_TRANSFER_WRITE_BIT,
              Vulkan.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
              Vulkan.VK_ACCESS_SHADER_READ_BIT
            )

      subresourceRange =
        Vulkan.createVk
          ( set @"aspectMask" Vulkan.VK_IMAGE_ASPECT_COLOR_BIT
              &* set @"baseMipLevel" baseMip
              &* set @"levelCount" levelCount
              &* set @"baseArrayLayer" 0
              &* set @"layerCount" layerCount
          )
      barrier =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
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
  liftIO $
    withPtr
      barrier
      ( Vulkan.vkCmdPipelineBarrier
          commandBuffer
          srcStage
          dstStage
          Vulkan.VK_ZERO_FLAGS
          0
          Vulkan.vkNullPtr
          0
          Vulkan.vkNullPtr
          1
      )

layerTransition ::
  (MonadIO m) =>
  Vulkan.VkCommandBuffer ->
  Vulkan.VkImage ->
  Vulkan.VkImageLayout ->
  Vulkan.VkImageLayout ->
  m ()
layerTransition commandBuffer image oldLayout newLayout = do
  let (srcStage, srcAccessMask, dstStage, dstAccessMask) =
        case (oldLayout, newLayout) of
          (Vulkan.VK_IMAGE_LAYOUT_UNDEFINED, Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) ->
            ( Vulkan.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
              Vulkan.VK_ZERO_FLAGS,
              Vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT,
              Vulkan.VK_ACCESS_TRANSFER_WRITE_BIT
            )
          (Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) ->
            ( Vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT,
              Vulkan.VK_ACCESS_TRANSFER_WRITE_BIT,
              Vulkan.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
              Vulkan.VK_ACCESS_SHADER_READ_BIT
            )
          (Vulkan.VK_IMAGE_LAYOUT_UNDEFINED, Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) ->
            ( Vulkan.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
              Vulkan.VK_ZERO_FLAGS,
              Vulkan.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
              Vulkan.VK_ACCESS_SHADER_READ_BIT
            )
          (Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, Vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL) ->
            ( Vulkan.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
              Vulkan.VK_ACCESS_SHADER_READ_BIT,
              Vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT,
              Vulkan.VK_ACCESS_TRANSFER_READ_BIT
            )
          (Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) ->
            ( Vulkan.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
              Vulkan.VK_ACCESS_SHADER_READ_BIT,
              Vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT,
              Vulkan.VK_ACCESS_TRANSFER_WRITE_BIT
            )
          (Vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) ->
            ( Vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT,
              Vulkan.VK_ACCESS_TRANSFER_READ_BIT,
              Vulkan.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
              Vulkan.VK_ACCESS_SHADER_READ_BIT
            )
          (Vulkan.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, Vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL) ->
            ( Vulkan.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
              Vulkan.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
              Vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT,
              Vulkan.VK_ACCESS_TRANSFER_READ_BIT
            )
          _ ->
            ( Vulkan.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
              Vulkan.VK_ACCESS_MEMORY_READ_BIT .|. Vulkan.VK_ACCESS_MEMORY_WRITE_BIT,
              Vulkan.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
              Vulkan.VK_ACCESS_MEMORY_READ_BIT .|. Vulkan.VK_ACCESS_MEMORY_WRITE_BIT
            )
      subresourceRange =
        Vulkan.createVk
          ( set @"aspectMask" Vulkan.VK_IMAGE_ASPECT_COLOR_BIT
              &* set @"baseMipLevel" 0
              &* set @"levelCount" 1
              &* set @"baseArrayLayer" 0
              &* set @"layerCount" 1
          )
      barrier =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
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
  liftIO $
    withPtr
      barrier
      ( Vulkan.vkCmdPipelineBarrier
          commandBuffer
          srcStage
          dstStage
          Vulkan.VK_ZERO_FLAGS
          0
          Vulkan.vkNullPtr
          0
          Vulkan.vkNullPtr
          1
      )

cmdCopyImage ::
  (MonadIO m) =>
  Vulkan.VkCommandBuffer ->
  Vulkan.VkImage ->
  Vulkan.VkImage ->
  Vulkan.Word32 ->
  Vulkan.Word32 ->
  m ()
cmdCopyImage commandBuffer srcImage dstImage width height = do
  let srcSubresource =
        Vulkan.createVk
          ( set @"aspectMask" Vulkan.VK_IMAGE_ASPECT_COLOR_BIT
              &* set @"mipLevel" 0
              &* set @"baseArrayLayer" 0
              &* set @"layerCount" 1
          )
      dstSubresource =
        Vulkan.createVk
          ( set @"aspectMask" Vulkan.VK_IMAGE_ASPECT_COLOR_BIT
              &* set @"mipLevel" 0
              &* set @"baseArrayLayer" 0
              &* set @"layerCount" 1
          )
      copyRegion =
        Vulkan.createVk
          ( set @"srcSubresource" srcSubresource
              &* set @"srcOffset"
                ( Vulkan.createVk
                    ( set @"x" 0
                        &* set @"y" 0
                        &* set @"z" 0
                    )
                )
              &* set @"dstSubresource" dstSubresource
              &* set @"dstOffset"
                ( Vulkan.createVk
                    ( set @"x" 0
                        &* set @"y" 0
                        &* set @"z" 0
                    )
                )
              &* set @"extent"
                ( Vulkan.createVk
                    ( set @"width" width
                        &* set @"height" height
                        &* set @"depth" 1
                    )
                )
          )
  liftIO $
    withPtr
      copyRegion
      ( Vulkan.vkCmdCopyImage
          commandBuffer
          srcImage
          Vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
          dstImage
          Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
          1
      )

copyBufferToImage ::
  (MonadIO m) =>
  Vulkan.VkCommandBuffer ->
  Vulkan.VkBuffer ->
  Vulkan.VkImage ->
  Vulkan.Word32 ->
  Vulkan.Word32 ->
  m ()
copyBufferToImage commandBuffer buffer image width height = do
  let imageSubresource =
        Vulkan.createVk
          ( set @"aspectMask" Vulkan.VK_IMAGE_ASPECT_COLOR_BIT
              &* set @"mipLevel" 0
              &* set @"baseArrayLayer" 0
              &* set @"layerCount" 1
          )
      imageExtent =
        Vulkan.createVk
          ( set @"width" width
              &* set @"height" height
              &* set @"depth" 1
          )
      imageOffset =
        Vulkan.createVk
          ( set @"x" 0
              &* set @"y" 0
              &* set @"z" 0
          )
      region =
        Vulkan.createVk
          ( set @"bufferOffset" 0
              &* set @"bufferRowLength" 0
              &* set @"bufferImageHeight" 0
              &* set @"imageSubresource" imageSubresource
              &* set @"imageOffset" imageOffset
              &* set @"imageExtent" imageExtent
          )
  liftIO $
    withPtr
      region
      ( Vulkan.vkCmdCopyBufferToImage
          commandBuffer
          buffer
          image
          Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
          1
      )

copyBufferToImage3D ::
  (MonadIO m) =>
  Vulkan.VkCommandBuffer ->
  Vulkan.VkBuffer ->
  Vulkan.VkImage ->
  Vulkan.Word32 ->
  Vulkan.Word32 ->
  Vulkan.Word32 ->
  m ()
copyBufferToImage3D commandBuffer buffer image width height depth = do
  let imageSubresource =
        Vulkan.createVk
          ( set @"aspectMask" Vulkan.VK_IMAGE_ASPECT_COLOR_BIT
              &* set @"mipLevel" 0
              &* set @"baseArrayLayer" 0
              &* set @"layerCount" 1
          )
      imageExtent =
        Vulkan.createVk
          ( set @"width" width
              &* set @"height" height
              &* set @"depth" depth
          )
      imageOffset =
        Vulkan.createVk
          ( set @"x" 0
              &* set @"y" 0
              &* set @"z" 0
          )
      region =
        Vulkan.createVk
          ( set @"bufferOffset" 0
              &* set @"bufferRowLength" 0
              &* set @"bufferImageHeight" 0
              &* set @"imageSubresource" imageSubresource
              &* set @"imageOffset" imageOffset
              &* set @"imageExtent" imageExtent
          )
  liftIO $
    withPtr
      region
      ( Vulkan.vkCmdCopyBufferToImage
          commandBuffer
          buffer
          image
          Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
          1
      )

cmdBlitImageCubemapMip ::
  (MonadIO m) =>
  Vulkan.VkCommandBuffer ->
  Vulkan.VkImage ->
  -- | src mip level
  Word32 ->
  -- | dst mip level
  Word32 ->
  -- | src size
  Int32 ->
  -- | dst size
  Int32 ->
  m ()
cmdBlitImageCubemapMip commandBuffer image srcMip dstMip srcSize dstSize = do
  let srcSubresource =
        Vulkan.createVk
          ( set @"aspectMask" Vulkan.VK_IMAGE_ASPECT_COLOR_BIT
              &* set @"mipLevel" srcMip
              &* set @"baseArrayLayer" 0
              &* set @"layerCount" 6
          )
      dstSubresource =
        Vulkan.createVk
          ( set @"aspectMask" Vulkan.VK_IMAGE_ASPECT_COLOR_BIT
              &* set @"mipLevel" dstMip
              &* set @"baseArrayLayer" 0
              &* set @"layerCount" 6
          )
      srcOffset0 = Vulkan.createVk (set @"x" 0 &* set @"y" 0 &* set @"z" 0)
      srcOffset1 = Vulkan.createVk (set @"x" srcSize &* set @"y" srcSize &* set @"z" 1)
      dstOffset0 = Vulkan.createVk (set @"x" 0 &* set @"y" 0 &* set @"z" 0)
      dstOffset1 = Vulkan.createVk (set @"x" dstSize &* set @"y" dstSize &* set @"z" 1)
      region =
        Vulkan.createVk
          ( set @"srcSubresource" srcSubresource
              &* setAt @"srcOffsets" @0 srcOffset0
              &* setAt @"srcOffsets" @1 srcOffset1
              &* set @"dstSubresource" dstSubresource
              &* setAt @"dstOffsets" @0 dstOffset0
              &* setAt @"dstOffsets" @1 dstOffset1
          )
  liftIO $
    withPtr
      region
      ( \rPtr ->
          Vulkan.vkCmdBlitImage
            commandBuffer
            image
            Vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
            image
            Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
            1
            rPtr
            Vulkan.VK_FILTER_LINEAR
      )

cmdBlitImage3DMip ::
  (MonadIO m) =>
  Vulkan.VkCommandBuffer ->
  Vulkan.VkImage ->
  -- | src mip level
  Word32 ->
  -- | dst mip level
  Word32 ->
  -- | src width
  Int32 ->
  -- | src height
  Int32 ->
  -- | src depth
  Int32 ->
  -- | dst width
  Int32 ->
  -- | dst height
  Int32 ->
  -- | dst depth
  Int32 ->
  m ()
cmdBlitImage3DMip commandBuffer image srcMip dstMip srcW srcH srcD dstW dstH dstD = do
  let srcSubresource =
        Vulkan.createVk
          ( set @"aspectMask" Vulkan.VK_IMAGE_ASPECT_COLOR_BIT
              &* set @"mipLevel" srcMip
              &* set @"baseArrayLayer" 0
              &* set @"layerCount" 1
          )
      dstSubresource =
        Vulkan.createVk
          ( set @"aspectMask" Vulkan.VK_IMAGE_ASPECT_COLOR_BIT
              &* set @"mipLevel" dstMip
              &* set @"baseArrayLayer" 0
              &* set @"layerCount" 1
          )
      srcOffset0 = Vulkan.createVk (set @"x" 0 &* set @"y" 0 &* set @"z" 0)
      srcOffset1 = Vulkan.createVk (set @"x" srcW &* set @"y" srcH &* set @"z" srcD)
      dstOffset0 = Vulkan.createVk (set @"x" 0 &* set @"y" 0 &* set @"z" 0)
      dstOffset1 = Vulkan.createVk (set @"x" dstW &* set @"y" dstH &* set @"z" dstD)
      region =
        Vulkan.createVk
          ( set @"srcSubresource" srcSubresource
              &* setAt @"srcOffsets" @0 srcOffset0
              &* setAt @"srcOffsets" @1 srcOffset1
              &* set @"dstSubresource" dstSubresource
              &* setAt @"dstOffsets" @0 dstOffset0
              &* setAt @"dstOffsets" @1 dstOffset1
          )
  liftIO $
    withPtr
      region
      ( \rPtr ->
          Vulkan.vkCmdBlitImage
            commandBuffer
            image
            Vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
            image
            Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
            1
            rPtr
            Vulkan.VK_FILTER_LINEAR
      )
