{-# LANGUAGE DuplicateRecordFields #-}

module Graphics.Haskan.Vulkan.Memory (managedMemoryFor, allocateMemoryFor) where

import Control.Monad (guard)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Bits
import Data.Foldable (for_)
import Data.Vector qualified as Vector
import Graphics.Haskan.Logger (LogCategory (..), logDebugIO, showT)
import Graphics.Haskan.Resources (alloc)
import Vulkan qualified
import Vulkan.Core10 qualified
import Vulkan.Zero (zero)

managedMemoryFor ::
  (MonadManaged m) =>
  Vulkan.PhysicalDevice ->
  Vulkan.Device ->
  Vulkan.MemoryRequirements ->
  [Vulkan.MemoryPropertyFlagBits] ->
  m Vulkan.DeviceMemory
managedMemoryFor pdev dev memoryRequirements memoryRequiredFlags =
  alloc
    "Memory region"
    (allocateMemoryFor pdev dev memoryRequirements memoryRequiredFlags)
    (\ptr -> Vulkan.freeMemory dev ptr Nothing)

allocateMemoryFor ::
  (MonadIO m) =>
  Vulkan.PhysicalDevice ->
  Vulkan.Device ->
  Vulkan.MemoryRequirements ->
  [Vulkan.MemoryPropertyFlagBits] ->
  m Vulkan.DeviceMemory
allocateMemoryFor pdev dev memoryRequirements memoryRequiredFlags = do
  let Vulkan.MemoryRequirements {size = allocSize, memoryTypeBits = reqTypeBits} = memoryRequirements
  logDebugIO LogVulkan $ "allocateMemoryFor size=" <> showT allocSize <> " memTypeBits=" <> showT reqTypeBits
  memoryProperties <- liftIO $ Vulkan.getPhysicalDeviceMemoryProperties pdev
  let Vulkan.PhysicalDeviceMemoryProperties {memoryTypeCount = mtc, memoryTypes = mts} = memoryProperties
      memoryTypeCount = fromIntegral mtc
      memoryTypes = Vector.take memoryTypeCount mts

  let possibleMemoryTypeIndices = do
        (i, mt) <- zip [0 ..] (Vector.toList memoryTypes)
        let Vulkan.MemoryType {propertyFlags = props} = mt
        guard (testBit reqTypeBits i)
        for_
          memoryRequiredFlags
          ( \f ->
              guard ((props .&. f) /= zero)
          )
        pure (fromIntegral i)

  memoryTypeIndex <-
    case possibleMemoryTypeIndices of
      [] -> error "required memory type not found"
      (i : _) -> pure i

  let allocateInfo =
        Vulkan.MemoryAllocateInfo
          { next = (),
            allocationSize = allocSize,
            memoryTypeIndex = memoryTypeIndex
          }

  liftIO $ Vulkan.allocateMemory dev allocateInfo Nothing
