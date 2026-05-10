{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Debug.Screenshot
  ( saveSwapchainScreenshot
  , saveGBufferStage
  , ensureScreenshotDir
  ) where

import Control.Exception (SomeException, catch, throw)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Bits ((.|.), (.&.), shiftL)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime, formatTime, defaultTimeLocale)
import Data.Word (Word8, Word32)
import Data.Vector.Storable qualified as Vector
import Foreign (Ptr, castPtr, peekByteOff, poke, alloca, peek, plusPtr)
import Foreign.Marshal qualified
import Foreign.Storable (Storable (..))
import Graphics.Haskan.Logger (logInfoIO, showT, LogCategory (..))
import Graphics.Haskan.Resources (allocaAndPeek, allocaAndPeek_, throwVkResult)
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Ext qualified as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, setListRef, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import Numeric.Half (Half, fromHalf)

import Codec.Picture (Image (..), PixelRGBA8 (..), writePng)

screenshotDir :: FilePath
screenshotDir = "data/debug/screenshots"

ensureScreenshotDir :: IO ()
ensureScreenshotDir = createDirectoryIfMissing True screenshotDir

-- | Create a raw Vulkan buffer and memory for reading back image data.
createReadbackBuffer
  :: Vulkan.VkPhysicalDevice
  -> Vulkan.VkDevice
  -> Int  -- ^ size in bytes
  -> IO (Vulkan.VkBuffer, Vulkan.VkDeviceMemory)
createReadbackBuffer pdev dev size = do
  let bufferInfo = Vulkan.createVk
        $  set @"sType" Vulkan.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
        &* set @"pNext" Vulkan.VK_NULL
        &* set @"size" (fromIntegral size)
        &* set @"usage" Vulkan.VK_BUFFER_USAGE_TRANSFER_DST_BIT
        &* set @"sharingMode" Vulkan.VK_SHARING_MODE_EXCLUSIVE
        &* set @"queueFamilyIndexCount" 0
        &* set @"pQueueFamilyIndices" Vulkan.VK_NULL
  buffer <- allocaAndPeek $ \bptr ->
    withPtr bufferInfo $ \biPtr ->
      Vulkan.vkCreateBuffer dev biPtr Vulkan.vkNullPtr bptr

  memReqs <- alloca $ \mrptr -> do
    Vulkan.vkGetBufferMemoryRequirements dev buffer mrptr
    peek mrptr
  memTypeIdx <- findMemoryType pdev
    (Vulkan.getField @"memoryTypeBits" memReqs)
    (Vulkan.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT .|. Vulkan.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)

  let allocInfo = Vulkan.createVk
        $  set @"sType" Vulkan.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
        &* set @"pNext" Vulkan.VK_NULL
        &* set @"allocationSize" (Vulkan.getField @"size" memReqs)
        &* set @"memoryTypeIndex" memTypeIdx
  memory <- allocaAndPeek $ \mptr ->
    withPtr allocInfo $ \aiPtr ->
      Vulkan.vkAllocateMemory dev aiPtr Vulkan.vkNullPtr mptr
  Vulkan.vkBindBufferMemory dev buffer memory 0 >>= throwVkResult
  pure (buffer, memory)

findMemoryType
  :: Vulkan.VkPhysicalDevice
  -> Word32
  -> Vulkan.VkMemoryPropertyFlags
  -> IO Word32
findMemoryType pdev typeFilter properties = do
  memProps <- allocaAndPeek_ (Vulkan.vkGetPhysicalDeviceMemoryProperties pdev)
  let memoryTypeCount = Vulkan.getField @"memoryTypeCount" memProps

  memoryTypes <- withPtr memProps $ \mpPtr ->
    Foreign.Marshal.peekArray
      @Vulkan.VkMemoryType
      (fromIntegral memoryTypeCount)
      (mpPtr `Foreign.plusPtr` Vulkan.fieldOffset @"memoryTypes" @Vulkan.VkPhysicalDeviceMemoryProperties)

  let go [] = fail "failed to find suitable memory type"
      go ((i, ty) : rest) =
        let flags = Vulkan.getField @"propertyFlags" ty
        in if (typeFilter .&. (1 `shiftL` i)) /= 0 && (flags .&. properties) == properties
           then pure (fromIntegral i)
           else go rest
  go (zip [0..] memoryTypes)

readPixels :: Ptr Word8 -> Int -> Int -> Vulkan.VkFormat -> Bool -> IO [Word8]
readPixels ptr width height format needsSwizzle
  | format == Vulkan.VK_FORMAT_R16G16B16A16_SFLOAT = do
      let readPixel idx = do
            let row = (height - 1) - (idx `div` width)  -- flip Y
                col = idx `mod` width
                offset = (row * width + col) * 8
            rHalf <- peekByteOff ptr (offset + 0) :: IO Half
            gHalf <- peekByteOff ptr (offset + 2) :: IO Half
            bHalf <- peekByteOff ptr (offset + 4) :: IO Half
            aHalf <- peekByteOff ptr (offset + 6) :: IO Half
            let toWord8 h = round (max 0.0 (min 1.0 (fromHalf h)) * 255.0)
                r = toWord8 rHalf
                g = toWord8 gHalf
                b = toWord8 bHalf
                a = toWord8 aHalf
            pure [r, g, b, a]
      concat <$> mapM readPixel [0 .. width * height - 1]
  | otherwise = do
      let readPixel idx = do
            let row = (height - 1) - (idx `div` width)  -- flip Y: Vulkan top->bottom, PNG bottom->top
                col = idx `mod` width
                offset = (row * width + col) * 4
            r <- peekByteOff ptr (offset + 0) :: IO Word8
            g <- peekByteOff ptr (offset + 1) :: IO Word8
            b <- peekByteOff ptr (offset + 2) :: IO Word8
            a <- peekByteOff ptr (offset + 3) :: IO Word8
            pure $ if needsSwizzle
                   then [b, g, r, a]  -- BGRA -> RGBA
                   else [r, g, b, a]
      concat <$> mapM readPixel [0 .. width * height - 1]

-- | Save a Vulkan image to PNG. Handles BGRA->RGBA swizzle for B8G8R8A8 format.
saveImageToPng device pdev commandPool queue image extent format currentLayout path =
  catch
    (saveImageToPng' device pdev commandPool queue image extent format currentLayout path)
    (\e -> do
      logInfoIO LogGeneral $ "screenshot FAILED: " <> Text.pack (show (e :: SomeException))
      throw e)

saveImageToPng'
  :: Vulkan.VkDevice
  -> Vulkan.VkPhysicalDevice
  -> Vulkan.VkCommandPool
  -> Vulkan.VkQueue
  -> Vulkan.VkImage
  -> Vulkan.VkExtent2D
  -> Vulkan.VkFormat
  -> Vulkan.VkImageLayout  -- ^ current layout
  -> FilePath
  -> IO ()
saveImageToPng' device pdev commandPool queue image extent format currentLayout path = do
  let width = fromIntegral $ Vulkan.getField @"width" extent
      height = fromIntegral $ Vulkan.getField @"height" extent
      bytesPerPixel = if format == Vulkan.VK_FORMAT_R16G16B16A16_SFLOAT then 8 else 4
      imageSize = width * height * bytesPerPixel
      needsSwizzle = format == Vulkan.VK_FORMAT_B8G8R8A8_SRGB || format == Vulkan.VK_FORMAT_B8G8R8A8_UNORM

  -- Create staging buffer
  (stagingBuffer, stagingMemory) <- createReadbackBuffer pdev device imageSize

  -- Allocate temporary command buffer
  let allocInfo = Vulkan.createVk
        $  set @"sType" Vulkan.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
        &* set @"pNext" Vulkan.VK_NULL
        &* set @"commandPool" commandPool
        &* set @"level" Vulkan.VK_COMMAND_BUFFER_LEVEL_PRIMARY
        &* set @"commandBufferCount" 1
  cmdBuf <- alloca $ \ptr -> do
    withPtr allocInfo $ \aptr ->
      Vulkan.vkAllocateCommandBuffers device aptr ptr >>= throwVkResult
    peek ptr

  -- Record copy commands
  let beginInfo = Vulkan.createVk
        $  set @"sType" Vulkan.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
        &* set @"pNext" Vulkan.VK_NULL
        &* set @"flags" Vulkan.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT
        &* set @"pInheritanceInfo" Vulkan.VK_NULL
  withPtr beginInfo $ \biPtr ->
    Vulkan.vkBeginCommandBuffer cmdBuf biPtr >>= throwVkResult

  -- For debug screenshots, use GENERAL layout to avoid layout transition issues
  -- The image should be in SHADER_READ_ONLY_OPTIMAL after rendering, but using
  -- GENERAL allows us to read without explicit transitions
  let copyLayout = Vulkan.VK_IMAGE_LAYOUT_GENERAL

  -- Transition image to GENERAL (from whatever layout it's currently in)
  let barrier = Vulkan.createVk
        $  set @"sType" Vulkan.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
        &* set @"pNext" Vulkan.VK_NULL
        &* set @"srcAccessMask" Vulkan.VK_ACCESS_MEMORY_READ_BIT
        &* set @"dstAccessMask" Vulkan.VK_ACCESS_TRANSFER_READ_BIT
        &* set @"oldLayout" currentLayout
        &* set @"newLayout" copyLayout
        &* set @"srcQueueFamilyIndex" Vulkan.VK_QUEUE_FAMILY_IGNORED
        &* set @"dstQueueFamilyIndex" Vulkan.VK_QUEUE_FAMILY_IGNORED
        &* set @"image" image
        &* set @"subresourceRange"
            ( Vulkan.createVk
              $  set @"aspectMask" Vulkan.VK_IMAGE_ASPECT_COLOR_BIT
              &* set @"baseMipLevel" 0
              &* set @"levelCount" 1
              &* set @"baseArrayLayer" 0
              &* set @"layerCount" 1
            )
  withPtr barrier $ \bPtr ->
    Vulkan.vkCmdPipelineBarrier
      cmdBuf
      Vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT
      Vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT
      Vulkan.VK_ZERO_FLAGS
      0 Vulkan.vkNullPtr
      0 Vulkan.vkNullPtr
      1
      bPtr

  -- Copy image to buffer
  let copy = Vulkan.createVk
        $  set @"bufferOffset" 0
        &* set @"bufferRowLength" 0
        &* set @"bufferImageHeight" 0
        &* set @"imageSubresource"
            ( Vulkan.createVk
              $  set @"aspectMask" Vulkan.VK_IMAGE_ASPECT_COLOR_BIT
              &* set @"mipLevel" 0
              &* set @"baseArrayLayer" 0
              &* set @"layerCount" 1
            )
        &* set @"imageExtent"
            ( Vulkan.createVk
              $  set @"width" (fromIntegral width)
              &* set @"height" (fromIntegral height)
              &* set @"depth" 1
            )
        &* set @"imageOffset"
            ( Vulkan.createVk
              $  set @"x" 0
              &* set @"y" 0
              &* set @"z" 0
            )
  withPtr copy $ \copyPtr ->
    Vulkan.vkCmdCopyImageToBuffer
      cmdBuf
      image
      copyLayout
      stagingBuffer
      1
      copyPtr

  -- Transition back to original layout
  let barrierBack = Vulkan.createVk
        $  set @"sType" Vulkan.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
        &* set @"pNext" Vulkan.VK_NULL
        &* set @"srcAccessMask" Vulkan.VK_ACCESS_TRANSFER_READ_BIT
        &* set @"dstAccessMask" Vulkan.VK_ACCESS_MEMORY_READ_BIT
        &* set @"oldLayout" copyLayout
        &* set @"newLayout" currentLayout
        &* set @"srcQueueFamilyIndex" Vulkan.VK_QUEUE_FAMILY_IGNORED
        &* set @"dstQueueFamilyIndex" Vulkan.VK_QUEUE_FAMILY_IGNORED
        &* set @"image" image
        &* set @"subresourceRange"
            ( Vulkan.createVk
              $  set @"aspectMask" Vulkan.VK_IMAGE_ASPECT_COLOR_BIT
              &* set @"baseMipLevel" 0
              &* set @"levelCount" 1
              &* set @"baseArrayLayer" 0
              &* set @"layerCount" 1
            )
  withPtr barrierBack $ \bbPtr ->
    Vulkan.vkCmdPipelineBarrier
      cmdBuf
      Vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT
      Vulkan.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT
      Vulkan.VK_ZERO_FLAGS
      0 Vulkan.vkNullPtr
      0 Vulkan.vkNullPtr
      1
      bbPtr

  Vulkan.vkEndCommandBuffer cmdBuf >>= throwVkResult

  -- Submit
  let submitInfo = Vulkan.createVk
        $  set @"sType" Vulkan.VK_STRUCTURE_TYPE_SUBMIT_INFO
        &* set @"pNext" Vulkan.VK_NULL
        &* set @"waitSemaphoreCount" 0
        &* set @"pWaitSemaphores" Vulkan.VK_NULL
        &* set @"pWaitDstStageMask" Vulkan.VK_NULL
        &* set @"commandBufferCount" 1
        &* setListRef @"pCommandBuffers" [cmdBuf]
        &* set @"signalSemaphoreCount" 0
        &* set @"pSignalSemaphores" Vulkan.VK_NULL

  fenceInfo <- allocaAndPeek $ \fptr ->
    withPtr (Vulkan.createVk $ set @"sType" Vulkan.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO &* set @"pNext" Vulkan.VK_NULL &* set @"flags" Vulkan.VK_ZERO_FLAGS) $ \fciPtr ->
      Vulkan.vkCreateFence device fciPtr Vulkan.vkNullPtr fptr

  withPtr submitInfo $ \siPtr ->
    Vulkan.vkQueueSubmit queue 1 siPtr fenceInfo >>= throwVkResult

  alloca $ \fencePtr -> do
    poke fencePtr fenceInfo
    Vulkan.vkWaitForFences device 1 fencePtr Vulkan.VK_TRUE 1000000000 >>= throwVkResult

  Vulkan.vkDestroyFence device fenceInfo Vulkan.vkNullPtr
  alloca $ \ptr -> do
    poke ptr cmdBuf
    Vulkan.vkFreeCommandBuffers device commandPool 1 ptr

  -- Map buffer and read pixels
  pixelsPtr <- allocaAndPeek (Vulkan.vkMapMemory device stagingMemory 0 (fromIntegral imageSize) Vulkan.VK_ZERO_FLAGS)
  let pixels = castPtr pixelsPtr :: Ptr Word8
  pixelList <- readPixels pixels width height format needsSwizzle
  let img = Image width height (Vector.fromList pixelList) :: Image PixelRGBA8
  writePng path img
  Vulkan.vkUnmapMemory device stagingMemory

  -- Cleanup
  Vulkan.vkDestroyBuffer device stagingBuffer Vulkan.vkNullPtr
  Vulkan.vkFreeMemory device stagingMemory Vulkan.vkNullPtr

  logInfoIO LogGeneral $ "screenshot saved: " <> Text.pack path

-- | Save current swapchain image as screenshot.
saveSwapchainScreenshot
  :: Vulkan.VkDevice
  -> Vulkan.VkPhysicalDevice
  -> Vulkan.VkCommandPool
  -> Vulkan.VkQueue
  -> Vulkan.VkImage
  -> Vulkan.VkExtent2D
  -> IO FilePath
saveSwapchainScreenshot device pdev commandPool queue image extent = do
  ensureScreenshotDir
  timestamp <- formatTime defaultTimeLocale "%Y%m%d_%H%M%S" <$> getCurrentTime
  let path = screenshotDir </> (timestamp ++ "_screenshot.png")
  saveImageToPng device pdev commandPool queue image extent Vulkan.VK_FORMAT_B8G8R8A8_SRGB Vulkan.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR path
  pure path

-- | Save a g-buffer attachment as a pipeline stage screenshot.
saveGBufferStage
  :: Vulkan.VkDevice
  -> Vulkan.VkPhysicalDevice
  -> Vulkan.VkCommandPool
  -> Vulkan.VkQueue
  -> Vulkan.VkImage
  -> Vulkan.VkExtent2D
  -> Vulkan.VkFormat
  -> FilePath  -- ^ base name, e.g. "albedo"
  -> IO FilePath
saveGBufferStage device pdev commandPool queue image extent format name = do
  ensureScreenshotDir
  timestamp <- formatTime defaultTimeLocale "%Y%m%d_%H%M%S" <$> getCurrentTime
  let path = screenshotDir </> (timestamp ++ "_" ++ name ++ ".png")
  saveImageToPng device pdev commandPool queue image extent format Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL path
  pure path
