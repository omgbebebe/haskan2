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
import Data.Vector qualified as Vector
import Data.Word (Word32, Word64)
import Foreign (Ptr, alloca, allocaArray, castPtr, copyBytes, free, mallocBytes, plusPtr, poke, sizeOf)
import System.IO.Unsafe (unsafePerformIO)
import Vulkan qualified as Vk26

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
-- Memory for the raw data buffer is allocated on the C stack and freed after
-- the action completes. Map entries are passed as a Vector.
withSpecializationInfo ::
  SpecializationData ->
  (Vk26.SpecializationInfo -> IO a) ->
  IO a
withSpecializationInfo SpecializationData {..} action = do
  let entryCount = length sdEntries
      totalSize = sum (map (BS.length . seValue) sdEntries)

  allocaArray totalSize $ \(dataPtr :: Ptr Word32) -> do
    let go :: Int -> Int -> [SpecEntry] -> IO [Vk26.SpecializationMapEntry]
        go _ _ [] = pure []
        go i offset (SpecEntry cid val : rest) = do
          let valLen = BS.length val
          BS.useAsCStringLen val $ \(valPtr, _) ->
            copyBytes (dataPtr `plusPtr` offset) valPtr valLen
          restEntries <- go (i + 1) (offset + valLen) rest
          pure (Vk26.SpecializationMapEntry cid (fromIntegral offset) (fromIntegral valLen) : restEntries)

    mapEntries <- go 0 0 sdEntries
    action (Vk26.SpecializationInfo (Vector.fromList mapEntries) (fromIntegral totalSize) (castPtr dataPtr))

-- | Allocate a long-lived @VkSpecializationInfo@.
--
-- The caller is responsible for freeing the data pointer with 'freeSpecializationInfo'.
-- This is needed when the specialization info must outlive a single @with@-style
-- callback (e.g. stored in a 'ShaderProgram' record).
mallocSpecializationInfo :: SpecializationData -> IO Vk26.SpecializationInfo
mallocSpecializationInfo SpecializationData {..} = do
  let entryCount = length sdEntries
      totalSize = sum (map (BS.length . seValue) sdEntries)

  dataPtr <- mallocBytes totalSize

  let go :: Int -> Int -> [SpecEntry] -> IO [Vk26.SpecializationMapEntry]
      go _ _ [] = pure []
      go i offset (SpecEntry cid val : rest) = do
        let valLen = BS.length val
        BS.useAsCStringLen val $ \(valPtr, _) ->
          copyBytes (dataPtr `plusPtr` offset) valPtr valLen
        restEntries <- go (i + 1) (offset + valLen) rest
        pure (Vk26.SpecializationMapEntry cid (fromIntegral offset) (fromIntegral valLen) : restEntries)

  mapEntries <- go 0 0 sdEntries
  pure (Vk26.SpecializationInfo (Vector.fromList mapEntries) (fromIntegral totalSize) (castPtr dataPtr))

-- | Free the data pointer associated with a @VkSpecializationInfo@ allocated by 'mallocSpecializationInfo'.
freeSpecializationInfo :: Vk26.SpecializationInfo -> IO ()
freeSpecializationInfo (Vk26.SpecializationInfo _ _ dptr) = free dptr
