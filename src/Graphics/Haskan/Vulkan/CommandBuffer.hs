module Graphics.Haskan.Vulkan.CommandBuffer where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Bits ((.|.))
import Data.Int (Int32)
import Data.Vector qualified as Vector
import Vulkan qualified as Vk26
import Vulkan.CStruct.Extends (SomeStruct(..))
import Vulkan.Zero (zero)
import Data.Word (Word32)

createCommandBuffer ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.CommandPool ->
  m Vk26.CommandBuffer
createCommandBuffer dev commandPool = do
  let allocateInfo =
        Vk26.CommandBufferAllocateInfo
          commandPool
          Vk26.COMMAND_BUFFER_LEVEL_PRIMARY
          1
  cbs <- liftIO $ Vk26.allocateCommandBuffers dev allocateInfo
  pure (Vector.head cbs)

withCommandBuffer ::
  (MonadIO m) =>
  Vk26.CommandBuffer ->
  m a ->
  m a
withCommandBuffer commandBuffer = withCommandBuffer' commandBuffer zero

withCommandBufferOneTime ::
  (MonadIO m) =>
  Vk26.Queue ->
  Vk26.CommandBuffer ->
  m () ->
  m ()
withCommandBufferOneTime queue commandBuffer action = do
  let Vk26.CommandBuffer cbHandle _ = commandBuffer
  withCommandBuffer' commandBuffer Vk26.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT action
  let submitInfo =
        Vk26.SubmitInfo
          ()
          Vector.empty
          Vector.empty
          (Vector.fromList [cbHandle])
          Vector.empty
  liftIO $ do
    Vk26.queueSubmit queue (Vector.fromList [SomeStruct submitInfo]) Vk26.NULL_HANDLE
    Vk26.queueWaitIdle queue

withCommandBuffer' ::
  (MonadIO m) =>
  Vk26.CommandBuffer ->
  Vk26.CommandBufferUsageFlags ->
  m a ->
  m a
withCommandBuffer' commandBuffer flags action = do
  liftIO $ Vk26.beginCommandBuffer commandBuffer (Vk26.CommandBufferBeginInfo () flags Nothing)
  result <- action
  liftIO $ Vk26.endCommandBuffer commandBuffer
  pure result

cmdDraw :: (MonadIO m) => Vk26.CommandBuffer -> Word32 -> Word32 -> Int32 -> Word32 -> m ()
cmdDraw commandBuffer indexCount firstIndex vertexOffset firstInstance =
  liftIO $ Vk26.cmdDrawIndexed commandBuffer indexCount 1 firstIndex vertexOffset firstInstance

cmdDrawIndexedIndirect :: (MonadIO m) => Vk26.CommandBuffer -> Vk26.Buffer -> Word32 -> Word32 -> m ()
cmdDrawIndexedIndirect commandBuffer buffer drawCount stride =
  liftIO $ Vk26.cmdDrawIndexedIndirect commandBuffer buffer 0 drawCount stride

cmdDrawIndexedIndirectOffset :: (MonadIO m) => Vk26.CommandBuffer -> Vk26.Buffer -> Vk26.DeviceSize -> Word32 -> Word32 -> m ()
cmdDrawIndexedIndirectOffset commandBuffer buffer offset drawCount stride =
  liftIO $ Vk26.cmdDrawIndexedIndirect commandBuffer buffer offset drawCount stride

cmdDispatch :: (MonadIO m) => Vk26.CommandBuffer -> Word32 -> Word32 -> Word32 -> m ()
cmdDispatch commandBuffer gx gy gz = liftIO $ Vk26.cmdDispatch commandBuffer gx gy gz

cmdBufferBarrier ::
  (MonadIO m) =>
  Vk26.CommandBuffer ->
  Vk26.Buffer ->
  Vk26.DeviceSize ->
  Vk26.PipelineStageFlags ->
  Vk26.AccessFlags ->
  Vk26.PipelineStageFlags ->
  Vk26.AccessFlags ->
  m ()
cmdBufferBarrier commandBuffer buffer size srcStage srcAccess dstStage dstAccess = do
  let barrier =
        Vk26.BufferMemoryBarrier
          ()
          srcAccess
          dstAccess
          Vk26.QUEUE_FAMILY_IGNORED
          Vk26.QUEUE_FAMILY_IGNORED
          buffer
          0
          size
  liftIO $ Vk26.cmdPipelineBarrier commandBuffer srcStage dstStage zero Vector.empty (Vector.fromList [SomeStruct barrier]) Vector.empty

copyBufferToImageLayer ::
  (MonadIO m) =>
  Vk26.CommandBuffer ->
  Vk26.Buffer ->
  Vk26.Image ->
  Word32 ->
  Word32 ->
  -- | array layer
  Word32 ->
  -- | buffer offset
  Vk26.DeviceSize ->
  m ()
copyBufferToImageLayer commandBuffer buffer image width height layer bufferOffset = do
  let region =
        Vk26.BufferImageCopy
          bufferOffset
          0
          0
          (Vk26.ImageSubresourceLayers Vk26.IMAGE_ASPECT_COLOR_BIT 0 layer 1)
          (Vk26.Offset3D 0 0 0)
          (Vk26.Extent3D width height 1)
  liftIO $ Vk26.cmdCopyBufferToImage commandBuffer buffer image Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL (Vector.fromList [region])

layerTransitionAll ::
  (MonadIO m) =>
  Vk26.CommandBuffer ->
  Vk26.Image ->
  Vk26.ImageLayout ->
  Vk26.ImageLayout ->
  -- | layer count
  Word32 ->
  m ()
layerTransitionAll commandBuffer image oldLayout newLayout layerCount = do
  let (srcStage, srcAccessMask, dstStage, dstAccessMask) =
        case (oldLayout, newLayout) of
          (Vk26.IMAGE_LAYOUT_UNDEFINED, Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) ->
            ( Vk26.PIPELINE_STAGE_TOP_OF_PIPE_BIT,
              zero,
              Vk26.PIPELINE_STAGE_TRANSFER_BIT,
              Vk26.ACCESS_TRANSFER_WRITE_BIT
            )
          (Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) ->
            ( Vk26.PIPELINE_STAGE_TRANSFER_BIT,
              Vk26.ACCESS_TRANSFER_WRITE_BIT,
              Vk26.PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
              Vk26.ACCESS_SHADER_READ_BIT
            )
          (Vk26.IMAGE_LAYOUT_UNDEFINED, Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) ->
            ( Vk26.PIPELINE_STAGE_TOP_OF_PIPE_BIT,
              zero,
              Vk26.PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
              Vk26.ACCESS_SHADER_READ_BIT
            )
          _ ->
            ( Vk26.PIPELINE_STAGE_ALL_COMMANDS_BIT,
              Vk26.ACCESS_MEMORY_READ_BIT .|. Vk26.ACCESS_MEMORY_WRITE_BIT,
              Vk26.PIPELINE_STAGE_ALL_COMMANDS_BIT,
              Vk26.ACCESS_MEMORY_READ_BIT .|. Vk26.ACCESS_MEMORY_WRITE_BIT
            )
      subresourceRange =
        Vk26.ImageSubresourceRange Vk26.IMAGE_ASPECT_COLOR_BIT 0 1 0 layerCount
      barrier =
        Vk26.ImageMemoryBarrier
          ()
          srcAccessMask
          dstAccessMask
          oldLayout
          newLayout
          Vk26.QUEUE_FAMILY_IGNORED
          Vk26.QUEUE_FAMILY_IGNORED
          image
          subresourceRange
  liftIO $ Vk26.cmdPipelineBarrier commandBuffer srcStage dstStage zero Vector.empty Vector.empty (Vector.fromList [SomeStruct barrier])

copyBuffer ::
  (MonadIO m) =>
  Vk26.Queue ->
  Vk26.CommandBuffer ->
  Vk26.Buffer ->
  Vk26.Buffer ->
  Vk26.DeviceSize ->
  m ()
copyBuffer queue commandBuffer srcBuffer dstBuffer size = do
  let region = Vk26.BufferCopy 0 0 size
  withCommandBufferOneTime
    queue
    commandBuffer
    (liftIO $ Vk26.cmdCopyBuffer commandBuffer srcBuffer dstBuffer (Vector.fromList [region]))

mipLayerTransition ::
  (MonadIO m) =>
  Vk26.CommandBuffer ->
  Vk26.Image ->
  Vk26.ImageLayout ->
  Vk26.ImageLayout ->
  -- | base mip level
  Word32 ->
  -- | level count
  Word32 ->
  -- | layer count
  Word32 ->
  m ()
mipLayerTransition commandBuffer image oldLayout newLayout baseMip levelCount layerCount = do
  let (srcStage, srcAccessMask, dstStage, dstAccessMask) =
        case (oldLayout, newLayout) of
          _
            | oldLayout == newLayout ->
                ( Vk26.PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                  zero,
                  Vk26.PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
                  zero
                )
          (Vk26.IMAGE_LAYOUT_UNDEFINED, Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) ->
            ( Vk26.PIPELINE_STAGE_TOP_OF_PIPE_BIT,
              zero,
              Vk26.PIPELINE_STAGE_TRANSFER_BIT,
              Vk26.ACCESS_TRANSFER_WRITE_BIT
            )
          (Vk26.IMAGE_LAYOUT_UNDEFINED, Vk26.IMAGE_LAYOUT_GENERAL) ->
            ( Vk26.PIPELINE_STAGE_TOP_OF_PIPE_BIT,
              zero,
              Vk26.PIPELINE_STAGE_COMPUTE_SHADER_BIT,
              Vk26.ACCESS_SHADER_WRITE_BIT
            )
          (Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, Vk26.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL) ->
            ( Vk26.PIPELINE_STAGE_TRANSFER_BIT,
              Vk26.ACCESS_TRANSFER_WRITE_BIT,
              Vk26.PIPELINE_STAGE_TRANSFER_BIT,
              Vk26.ACCESS_TRANSFER_READ_BIT
            )
          (Vk26.IMAGE_LAYOUT_GENERAL, Vk26.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL) ->
            ( Vk26.PIPELINE_STAGE_COMPUTE_SHADER_BIT,
              Vk26.ACCESS_SHADER_WRITE_BIT,
              Vk26.PIPELINE_STAGE_TRANSFER_BIT,
              Vk26.ACCESS_TRANSFER_READ_BIT
            )
          (Vk26.IMAGE_LAYOUT_GENERAL, Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) ->
            ( Vk26.PIPELINE_STAGE_COMPUTE_SHADER_BIT,
              Vk26.ACCESS_SHADER_WRITE_BIT,
              Vk26.PIPELINE_STAGE_TRANSFER_BIT,
              Vk26.ACCESS_TRANSFER_WRITE_BIT
            )
          (Vk26.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) ->
            ( Vk26.PIPELINE_STAGE_TRANSFER_BIT,
              Vk26.ACCESS_TRANSFER_READ_BIT,
              Vk26.PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
              Vk26.ACCESS_SHADER_READ_BIT
            )
          (Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) ->
            ( Vk26.PIPELINE_STAGE_TRANSFER_BIT,
              Vk26.ACCESS_TRANSFER_WRITE_BIT,
              Vk26.PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
              Vk26.ACCESS_SHADER_READ_BIT
            )
          (Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, Vk26.IMAGE_LAYOUT_GENERAL) ->
            ( Vk26.PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
              Vk26.ACCESS_SHADER_READ_BIT,
              Vk26.PIPELINE_STAGE_COMPUTE_SHADER_BIT,
              Vk26.ACCESS_SHADER_WRITE_BIT
            )
          _ ->
            ( Vk26.PIPELINE_STAGE_ALL_COMMANDS_BIT,
              Vk26.ACCESS_MEMORY_READ_BIT .|. Vk26.ACCESS_MEMORY_WRITE_BIT,
              Vk26.PIPELINE_STAGE_ALL_COMMANDS_BIT,
              Vk26.ACCESS_MEMORY_READ_BIT .|. Vk26.ACCESS_MEMORY_WRITE_BIT
            )
      subresourceRange =
        Vk26.ImageSubresourceRange Vk26.IMAGE_ASPECT_COLOR_BIT baseMip levelCount 0 layerCount
      barrier =
        Vk26.ImageMemoryBarrier
          ()
          srcAccessMask
          dstAccessMask
          oldLayout
          newLayout
          Vk26.QUEUE_FAMILY_IGNORED
          Vk26.QUEUE_FAMILY_IGNORED
          image
          subresourceRange
  liftIO $ Vk26.cmdPipelineBarrier commandBuffer srcStage dstStage zero Vector.empty Vector.empty (Vector.fromList [SomeStruct barrier])

layerTransition ::
  (MonadIO m) =>
  Vk26.CommandBuffer ->
  Vk26.Image ->
  Vk26.ImageLayout ->
  Vk26.ImageLayout ->
  m ()
layerTransition commandBuffer image oldLayout newLayout = do
  let (srcStage, srcAccessMask, dstStage, dstAccessMask) =
        case (oldLayout, newLayout) of
          (Vk26.IMAGE_LAYOUT_UNDEFINED, Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) ->
            ( Vk26.PIPELINE_STAGE_TOP_OF_PIPE_BIT,
              zero,
              Vk26.PIPELINE_STAGE_TRANSFER_BIT,
              Vk26.ACCESS_TRANSFER_WRITE_BIT
            )
          (Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) ->
            ( Vk26.PIPELINE_STAGE_TRANSFER_BIT,
              Vk26.ACCESS_TRANSFER_WRITE_BIT,
              Vk26.PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
              Vk26.ACCESS_SHADER_READ_BIT
            )
          (Vk26.IMAGE_LAYOUT_UNDEFINED, Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) ->
            ( Vk26.PIPELINE_STAGE_TOP_OF_PIPE_BIT,
              zero,
              Vk26.PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
              Vk26.ACCESS_SHADER_READ_BIT
            )
          (Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, Vk26.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL) ->
            ( Vk26.PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
              Vk26.ACCESS_SHADER_READ_BIT,
              Vk26.PIPELINE_STAGE_TRANSFER_BIT,
              Vk26.ACCESS_TRANSFER_READ_BIT
            )
          (Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) ->
            ( Vk26.PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
              Vk26.ACCESS_SHADER_READ_BIT,
              Vk26.PIPELINE_STAGE_TRANSFER_BIT,
              Vk26.ACCESS_TRANSFER_WRITE_BIT
            )
          (Vk26.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) ->
            ( Vk26.PIPELINE_STAGE_TRANSFER_BIT,
              Vk26.ACCESS_TRANSFER_READ_BIT,
              Vk26.PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
              Vk26.ACCESS_SHADER_READ_BIT
            )
          (Vk26.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, Vk26.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL) ->
            ( Vk26.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
              Vk26.ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
              Vk26.PIPELINE_STAGE_TRANSFER_BIT,
              Vk26.ACCESS_TRANSFER_READ_BIT
            )
          _ ->
            ( Vk26.PIPELINE_STAGE_ALL_COMMANDS_BIT,
              Vk26.ACCESS_MEMORY_READ_BIT .|. Vk26.ACCESS_MEMORY_WRITE_BIT,
              Vk26.PIPELINE_STAGE_ALL_COMMANDS_BIT,
              Vk26.ACCESS_MEMORY_READ_BIT .|. Vk26.ACCESS_MEMORY_WRITE_BIT
            )
      subresourceRange =
        Vk26.ImageSubresourceRange Vk26.IMAGE_ASPECT_COLOR_BIT 0 1 0 1
      barrier =
        Vk26.ImageMemoryBarrier
          ()
          srcAccessMask
          dstAccessMask
          oldLayout
          newLayout
          Vk26.QUEUE_FAMILY_IGNORED
          Vk26.QUEUE_FAMILY_IGNORED
          image
          subresourceRange
  liftIO $ Vk26.cmdPipelineBarrier commandBuffer srcStage dstStage zero Vector.empty Vector.empty (Vector.fromList [SomeStruct barrier])

cmdCopyImage ::
  (MonadIO m) =>
  Vk26.CommandBuffer ->
  Vk26.Image ->
  Vk26.Image ->
  Word32 ->
  Word32 ->
  m ()
cmdCopyImage commandBuffer srcImage dstImage width height = do
  let srcSubresource = Vk26.ImageSubresourceLayers Vk26.IMAGE_ASPECT_COLOR_BIT 0 0 1
      dstSubresource = Vk26.ImageSubresourceLayers Vk26.IMAGE_ASPECT_COLOR_BIT 0 0 1
      copyRegion =
        Vk26.ImageCopy
          srcSubresource
          (Vk26.Offset3D 0 0 0)
          dstSubresource
          (Vk26.Offset3D 0 0 0)
          (Vk26.Extent3D width height 1)
  liftIO $ Vk26.cmdCopyImage commandBuffer srcImage Vk26.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL dstImage Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL (Vector.fromList [copyRegion])

copyBufferToImage ::
  (MonadIO m) =>
  Vk26.CommandBuffer ->
  Vk26.Buffer ->
  Vk26.Image ->
  Word32 ->
  Word32 ->
  m ()
copyBufferToImage commandBuffer buffer image width height = do
  let region =
        Vk26.BufferImageCopy
          0
          0
          0
          (Vk26.ImageSubresourceLayers Vk26.IMAGE_ASPECT_COLOR_BIT 0 0 1)
          (Vk26.Offset3D 0 0 0)
          (Vk26.Extent3D width height 1)
  liftIO $ Vk26.cmdCopyBufferToImage commandBuffer buffer image Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL (Vector.fromList [region])

copyBufferToImage3D ::
  (MonadIO m) =>
  Vk26.CommandBuffer ->
  Vk26.Buffer ->
  Vk26.Image ->
  Word32 ->
  Word32 ->
  Word32 ->
  m ()
copyBufferToImage3D commandBuffer buffer image width height depth = do
  let region =
        Vk26.BufferImageCopy
          0
          0
          0
          (Vk26.ImageSubresourceLayers Vk26.IMAGE_ASPECT_COLOR_BIT 0 0 1)
          (Vk26.Offset3D 0 0 0)
          (Vk26.Extent3D width height depth)
  liftIO $ Vk26.cmdCopyBufferToImage commandBuffer buffer image Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL (Vector.fromList [region])

cmdBlitImageCubemapMip ::
  (MonadIO m) =>
  Vk26.CommandBuffer ->
  Vk26.Image ->
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
        Vk26.ImageSubresourceLayers Vk26.IMAGE_ASPECT_COLOR_BIT srcMip 0 6
      dstSubresource =
        Vk26.ImageSubresourceLayers Vk26.IMAGE_ASPECT_COLOR_BIT dstMip 0 6
      region =
        Vk26.ImageBlit
          srcSubresource
          (Vk26.Offset3D 0 0 0, Vk26.Offset3D srcSize srcSize 1)
          dstSubresource
          (Vk26.Offset3D 0 0 0, Vk26.Offset3D dstSize dstSize 1)
  liftIO $ Vk26.cmdBlitImage commandBuffer image Vk26.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL image Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL (Vector.fromList [region]) Vk26.FILTER_LINEAR

cmdBlitImage3DMip ::
  (MonadIO m) =>
  Vk26.CommandBuffer ->
  Vk26.Image ->
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
        Vk26.ImageSubresourceLayers Vk26.IMAGE_ASPECT_COLOR_BIT srcMip 0 1
      dstSubresource =
        Vk26.ImageSubresourceLayers Vk26.IMAGE_ASPECT_COLOR_BIT dstMip 0 1
      region =
        Vk26.ImageBlit
          srcSubresource
          (Vk26.Offset3D 0 0 0, Vk26.Offset3D srcW srcH srcD)
          dstSubresource
          (Vk26.Offset3D 0 0 0, Vk26.Offset3D dstW dstH dstD)
  liftIO $ Vk26.cmdBlitImage commandBuffer image Vk26.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL image Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL (Vector.fromList [region]) Vk26.FILTER_LINEAR
