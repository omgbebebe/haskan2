{-# LANGUAGE StrictData #-}

module Graphics.Haskan.Assets.Cache
  ( AssetCache,
    CacheKey,
    mkCacheKey,
    initCache,
    cacheLookup,
    cacheInsert,
    cacheInvalidate,
    cachePath,
  )
where

import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder (Builder, byteString, toLazyByteString, word32HexFixed)
import Data.ByteString.Char8 qualified as BSC
import Data.ByteString.Lazy (toStrict)
import Data.List (foldl')
import Data.Word (Word32, Word8)
import System.Directory
import System.FilePath ((</>))

-- | Opaque cache handle. Wraps the root cache directory.
newtype AssetCache = AssetCache
  { acRoot :: FilePath
  }
  deriving (Eq, Show)

-- | Cache key: hex-encoded deterministic hash of source content + config fingerprint.
newtype CacheKey = CacheKey ByteString
  deriving (Eq, Ord, Show)

-- | Simple djb2 hash over a ByteString.
djb2 :: ByteString -> Word32
djb2 = BS.foldl' (\h b -> h * 33 + fromIntegral b) 5381

-- | Build a cache key from source bytes and a config tag.
-- The config tag encodes preprocessing parameters (target format, dimensions, etc.)
mkCacheKey :: ByteString -> ByteString -> CacheKey
mkCacheKey sourceBytes configTag =
  let srcHash = djb2 sourceBytes
      cfgHash = djb2 configTag
      builder :: Builder
      builder = word32HexFixed srcHash <> byteString "-" <> word32HexFixed cfgHash
   in CacheKey (toStrict (toLazyByteString builder))

-- | Initialise the cache, creating the directory if absent.
initCache :: (MonadIO m) => FilePath -> m AssetCache
initCache root = liftIO $ do
  createDirectoryIfMissing True root
  createDirectoryIfMissing True (root </> "textures")
  createDirectoryIfMissing True (root </> "meshes")
  pure (AssetCache root)

-- | Compute the on-disk path for a cached entry.
cachePath :: AssetCache -> CacheKey -> FilePath -> FilePath
cachePath (AssetCache root) (CacheKey key) subdir =
  root </> subdir </> BSC.unpack key <> ".bin"

-- | Check if a cached entry exists and is valid (non-empty).
cacheLookup :: (MonadIO m) => AssetCache -> CacheKey -> FilePath -> m Bool
cacheLookup cache key subdir = liftIO $ do
  let path = cachePath cache key subdir
  exists <- doesFileExist path
  if exists
    then (> 0) . fromIntegral @Integer . fromIntegral @Int . fromIntegral . BS.length <$> BS.readFile path
    else pure False

-- | Write a preprocessed blob to the cache.
cacheInsert :: (MonadIO m) => AssetCache -> CacheKey -> FilePath -> ByteString -> m ()
cacheInsert cache key subdir bytes = liftIO $ do
  let path = cachePath cache key subdir
  createDirectoryIfMissing True (takeDirectory path)
  BS.writeFile path bytes

-- | Remove a single cached entry.
cacheInvalidate :: (MonadIO m) => AssetCache -> CacheKey -> FilePath -> m ()
cacheInvalidate cache key subdir = liftIO $ do
  let path = cachePath cache key subdir
  exists <- doesFileExist path
  when exists (removeFile path)

takeDirectory :: FilePath -> FilePath
takeDirectory = fst . splitFileName

splitFileName :: FilePath -> (FilePath, FilePath)
splitFileName fp = case break (== '/') fp of
  (a, []) -> (".", a)
  (a, b) -> (a, drop 1 b)
