{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}

module Graphics.Haskan.Vulkan.Specialization
  ( SpecEntry (..),
    SpecializationData (..),
    withSpecializationInfo,
    mallocSpecializationInfo,
    freeSpecializationInfo,
    packFloat,
  )
where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Word (Word32)
import Foreign (Ptr, alloca, allocaArray, castPtr, copyBytes, free, mallocBytes, peek, plusPtr, poke, sizeOf)
import Foreign.C.Types (CSize)
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Marshal.Create (set, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan
import System.IO.Unsafe (unsafePerformIO)

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

-- | Pack a 'Float' into a 4-byte 'ByteString' (host-endian).
packFloat :: Float -> ByteString
packFloat x =
  unsafePerformIO $
    alloca $ \(p :: Ptr Float) -> do
      poke p x
      BS.packCStringLen (castPtr p, sizeOf x)
{-# NOINLINE packFloat #-}

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
              Vulkan.createVk @(Vulkan.VkSpecializationMapEntry)
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
                  &* set @"pData" (Foreign.castPtr dataPtr)
              )
      alloca $ \specInfoPtr -> do
        poke specInfoPtr specInfo
        action specInfoPtr

-- | Allocate a long-lived @VkSpecializationInfo@ on the C heap.
--
-- The caller is responsible for freeing with 'freeSpecializationInfo'.
-- This is needed when the pointer must outlive a single @with@-style
-- callback (e.g. stored in a 'ShaderProgram' record).
mallocSpecializationInfo :: SpecializationData -> IO (Ptr Vulkan.VkSpecializationInfo)
mallocSpecializationInfo SpecializationData {..} = do
  let entryCount = length sdEntries
      totalSize = sum (map (BS.length . seValue) sdEntries)

  entriesPtr <- mallocBytes (entryCount * sizeOf (undefined :: Vulkan.VkSpecializationMapEntry))
  dataPtr <- mallocBytes totalSize

  let go :: Int -> Int -> [SpecEntry] -> IO ()
      go _ _ [] = pure ()
      go i offset (SpecEntry cid val : rest) = do
        let valLen = BS.length val
        poke (entriesPtr `plusPtr` (i * sizeOf (undefined :: Vulkan.VkSpecializationMapEntry))) $
          Vulkan.createVk @(Vulkan.VkSpecializationMapEntry)
            ( set @"constantID" cid
                &* set @"offset" (fromIntegral offset)
                &* set @"size" (fromIntegral valLen)
            )
        BS.useAsCStringLen val $ \(valPtr, _) ->
          copyBytes (dataPtr `plusPtr` offset) valPtr valLen
        go (i + 1) (offset + valLen) rest

  go 0 0 sdEntries

  specInfoPtr <- mallocBytes (sizeOf (undefined :: Vulkan.VkSpecializationInfo))
  poke specInfoPtr $
    Vulkan.createVk
      ( set @"mapEntryCount" (fromIntegral entryCount)
          &* set @"pMapEntries" entriesPtr
          &* set @"dataSize" (fromIntegral totalSize)
          &* set @"pData" (Foreign.castPtr dataPtr)
      )

  pure specInfoPtr

-- | Free a @VkSpecializationInfo@ allocated by 'mallocSpecializationInfo'.
--
-- This also frees the associated map entries and raw data arrays.
freeSpecializationInfo :: Ptr Vulkan.VkSpecializationInfo -> IO ()
freeSpecializationInfo ptr = do
  specInfo <- peek ptr
  free (Vulkan.getField @"pMapEntries" specInfo)
  free (Vulkan.getField @"pData" specInfo)
  free ptr
