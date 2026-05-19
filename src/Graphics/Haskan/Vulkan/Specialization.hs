{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}

module Graphics.Haskan.Vulkan.Specialization
  ( SpecEntry (..),
    SpecializationData (..),
    withSpecializationInfo,
  )
where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Word (Word32)
import Foreign (Ptr, alloca, allocaArray, copyBytes, plusPtr, poke, sizeOf)
import Foreign.C.Types (CSize)
import qualified Graphics.Vulkan.Core_1_0 as Vulkan
import Graphics.Vulkan.Marshal.Create (set, (&*))
import qualified Graphics.Vulkan.Marshal.Create as Vulkan

-- | A single specialization constant entry.
data SpecEntry = SpecEntry
  { -- | SpecId decoration in SPIR-V
    seConstantID :: !Word32,
    -- | Raw value bytes (host-endian, sized to type)
    seValue :: !ByteString
  }

-- | All specialization data for a single shader stage.
newtype SpecializationData = SpecializationData
  { sdEntries :: [SpecEntry]
  }

-- | Execute an action with a valid @VkSpecializationInfo@ pointer.
--
-- Memory for the map entries, raw data, and the info struct itself is
-- allocated on the C stack and freed after the action completes.
withSpecializationInfo ::
  SpecializationData ->
  (Ptr Vulkan.VkSpecializationInfo -> IO a) ->
  IO a
withSpecializationInfo SpecializationData {..} action = do
  let entryCount = length sdEntries
      totalSize = sum (map (BS.length . seValue) sdEntries)

  allocaArray entryCount $ \(entriesPtr :: Ptr Vulkan.VkSpecializationMapEntry) -> do
    allocaArray totalSize $ \(dataPtr :: Ptr Word32) -> do
      -- Write map entries and pack values contiguously
      let go :: Int -> Int -> [SpecEntry] -> IO ()
          go _ _ [] = pure ()
          go i offset (SpecEntry cid val : rest) = do
            let valLen = BS.length val
            poke (entriesPtr `plusPtr` (i * sizeOf (undefined :: Vulkan.VkSpecializationMapEntry))) $
              Vulkan.createVk
                ( set @"constantID" cid
                    &* set @"offset" (fromIntegral offset)
                    &* set @"size" (fromIntegral valLen)
                )
            BS.useAsCStringLen val $ \(valPtr, _) ->
              copyBytes (dataPtr `plusPtr` offset) valPtr valLen
            go (i + 1) (offset + valLen) rest

      go 0 0 sdEntries

      -- Build and run action with VkSpecializationInfo
      let specInfo =
            Vulkan.createVk
              ( set @"mapEntryCount" (fromIntegral entryCount)
                  &* set @"pMapEntries" entriesPtr
                  &* set @"dataSize" (fromIntegral totalSize)
                  &* set @"pData" dataPtr
              )
      alloca $ \specInfoPtr -> do
        poke specInfoPtr specInfo
        action specInfoPtr
