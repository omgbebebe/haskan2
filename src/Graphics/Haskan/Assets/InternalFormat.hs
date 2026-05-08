{-# LANGUAGE StrictData #-}

module Graphics.Haskan.Assets.InternalFormat
  ( InternalTexture(..)
  , InternalMesh(..)
  , TextureMetadata(..)
  , TextureFormat(..)
  , CacheVersion(..)
  , currentCacheVersion
  ) where

import Data.ByteString (ByteString)
import Data.Word (Word8, Word32)
import Data.Vector.Storable (Vector)

-- | Cache format version. Bumped when internal format changes.
newtype CacheVersion = CacheVersion Word32
  deriving (Eq, Show)

currentCacheVersion :: CacheVersion
currentCacheVersion = CacheVersion 1

-- | Metadata for an internal texture.
data TextureMetadata = TextureMetadata
  { itmWidth      :: !Int
  , itmHeight     :: !Int
  , itmMipLevels  :: !Int
  , itmFormat     :: !TextureFormat
  , itmArrayLayer :: !Int
  } deriving (Eq, Show)

data TextureFormat
  = R8G8B8A8_UNORM
  | R8G8B8A8_SRGB
  | R16G16B16A16_FLOAT
  deriving (Eq, Show)

-- | Internal texture representation.
-- Raw pixel data is tightly packed RGBA8, row-major.
data InternalTexture = InternalTexture
  { itMetadata :: !TextureMetadata
  , itData     :: !(Vector Word8)
  } deriving (Eq, Show)

-- | Placeholder for future mesh preprocessing.
data InternalMesh = InternalMesh
  { imPositions  :: !(Vector Float)
  , imNormals    :: !(Vector Float)
  , imUVs        :: !(Vector Float)
  , imIndices    :: !(Vector Word32)
  , imBounds     :: !(Float, Float, Float, Float, Float, Float) -- minX,Y,Z maxX,Y,Z
  } deriving (Eq, Show)
