module Graphics.Haskan.Vulkan.Memory (managedMemoryFor, allocateMemoryFor) where

import Control.Monad (guard)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Bits
import Data.Foldable (for_)
import Foreign qualified
import Foreign.Marshal qualified
import Graphics.Haskan.Logger (LogCategory (..), logDebugIO, showT)
import Graphics.Haskan.Resources (alloc, allocaAndPeek, allocaAndPeek_)
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan

managedMemoryFor ::
  (MonadManaged m) =>
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  Vulkan.VkMemoryRequirements ->
  [Vulkan.VkMemoryPropertyFlags] ->
  m Vulkan.VkDeviceMemory
managedMemoryFor pdev dev memoryRequirements memoryRequiredFlags =
  alloc
    "Memory region"
    (allocateMemoryFor pdev dev memoryRequirements memoryRequiredFlags)
    (\ptr -> Vulkan.vkFreeMemory dev ptr Vulkan.vkNullPtr)

allocateMemoryFor ::
  (MonadIO m) =>
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  Vulkan.VkMemoryRequirements ->
  [Vulkan.VkMemoryPropertyFlags] ->
  m Vulkan.VkDeviceMemory
allocateMemoryFor pdev dev memoryRequirements memoryRequiredFlags = do
  let allocSize = Vulkan.getField @"size" memoryRequirements
  logDebugIO LogVulkan $ "allocateMemoryFor size=" <> showT allocSize <> " memTypeBits=" <> showT (Vulkan.getField @"memoryTypeBits" memoryRequirements)
  memoryProperties <-
    allocaAndPeek_ (Vulkan.vkGetPhysicalDeviceMemoryProperties pdev)
  let memoryTypeCount =
        Vulkan.getField @"memoryTypeCount" memoryProperties

  memoryTypes <-
    liftIO $
      withPtr
        memoryProperties
        ( \mpPtr ->
            Foreign.Marshal.peekArray
              @Vulkan.VkMemoryType
              (fromIntegral memoryTypeCount)
              ( mpPtr
                  `Foreign.plusPtr` Vulkan.fieldOffset @"memoryTypes" @Vulkan.VkPhysicalDeviceMemoryProperties
              )
        )

  let possibleMemoryTypeIndices = do
        (i, memoryType) <-
          zip [0 ..] memoryTypes

        guard
          ( testBit
              (Vulkan.getField @"memoryTypeBits" memoryRequirements)
              (fromIntegral i)
          )

        for_
          memoryRequiredFlags
          ( \f ->
              guard (Vulkan.getField @"propertyFlags" memoryType .&. f > zeroBits)
          )

        pure i

  memoryTypeIndex <-
    case possibleMemoryTypeIndices of
      [] -> error "required memory type not found"
      (i : _) -> pure i

  let allocateInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"allocationSize" (Vulkan.getField @"size" memoryRequirements)
              &* set @"memoryTypeIndex" memoryTypeIndex
          )

  liftIO $ withPtr allocateInfo (\aiPtr -> allocaAndPeek (Vulkan.vkAllocateMemory dev aiPtr Vulkan.vkNullPtr))
