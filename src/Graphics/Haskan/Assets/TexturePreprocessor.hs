{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}

module Graphics.Haskan.Assets.TexturePreprocessor
  ( TextureConfig(..)
  , defaultTextureConfig
  , preprocessTexture
  , loadTextureCached
  , loadTextureBytesCached
  , resizeToPowerOfTwo
  , nextPowerOfTwo
  ) where

import Codec.Picture
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Bits (shiftR, (.|.))
import qualified Data.Bits
import Data.Bits (shiftL, shiftR, (.|.), finiteBitSize)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as BSB
import qualified Data.ByteString.Lazy as BSL
import Data.Maybe (fromMaybe)
import Data.Vector.Storable (Vector)
import qualified Data.Vector.Storable as Vector
import Data.Word (Word8, Word32)
import System.FilePath (takeFileName)

import Graphics.Haskan.Assets.Cache
import Graphics.Haskan.Assets.InternalFormat
import Graphics.Haskan.Logger (logDebugIO, showT, LogCategory(..))

-- | Configuration for texture preprocessing.
data TextureConfig = TextureConfig
  { tcTargetWidth      :: !(Maybe Int)    -- ^ Desired width (Nothing = keep original, rounded up to PoT)
  , tcTargetHeight     :: !(Maybe Int)    -- ^ Desired height (Nothing = keep original, rounded up to PoT)
  , tcForcePowerOfTwo  :: !Bool           -- ^ Resize to next power of two
  , tcGenerateMips     :: !Bool           -- ^ Generate mipmaps (placeholder)
  , tcTargetFormat     :: !TextureFormat  -- ^ Output pixel format
  } deriving (Eq, Show)

defaultTextureConfig :: TextureConfig
defaultTextureConfig = TextureConfig
  { tcTargetWidth     = Just 256
  , tcTargetHeight    = Just 256
  , tcForcePowerOfTwo = True
  , tcGenerateMips    = False
  , tcTargetFormat    = R8G8B8A8_UNORM
  }

-- | Compute the next power of two >= n.
nextPowerOfTwo :: Int -> Int
nextPowerOfTwo n
  | n <= 1   = 1
  | otherwise = go (n - 1) 1
  where
    go x s
      | s < finiteBitSize x = go (x .|. shiftR x s) (s * 2)
      | otherwise = x + 1

-- | Resize an image to target dimensions using bilinear sampling.
resizeImage :: Image PixelRGBA8 -> Int -> Int -> Image PixelRGBA8
resizeImage (Image w h vec) tw th =
  generateImage sample tw th
  where
    sample tx ty =
      let sx = fromIntegral tx * fromIntegral w / fromIntegral tw
          sy = fromIntegral ty * fromIntegral h / fromIntegral th
          x0 = floor sx
          y0 = floor sy
          x1 = min (w - 1) (x0 + 1)
          y1 = min (h - 1) (y0 + 1)
          fx = sx - fromIntegral x0
          fy = sy - fromIntegral y0
          ixf = 1 - fx
          iyf = 1 - fy
          p00 = pixelAt' x0 y0
          p10 = pixelAt' x1 y0
          p01 = pixelAt' x0 y1
          p11 = pixelAt' x1 y1
          lerpPixel a b t = round (fromIntegral a * (1 - t) + fromIntegral b * t)
          blendChannel i =
            let c00 = p00 !! i
                c10 = p10 !! i
                c01 = p01 !! i
                c11 = p11 !! i
                c0 = lerpPixel c00 c10 fx
                c1 = lerpPixel c01 c11 fx
            in lerpPixel c0 c1 fy
      in PixelRGBA8 (blendChannel 0) (blendChannel 1) (blendChannel 2) (blendChannel 3)

    pixelAt' x y =
      let idx = (y * w + x) * 4
      in [ vec Vector.! idx
         , vec Vector.! (idx + 1)
         , vec Vector.! (idx + 2)
         , vec Vector.! (idx + 3)
         ]

-- | Resize to power-of-two dimensions if configured.
resizeToPowerOfTwo :: TextureConfig -> Image PixelRGBA8 -> Image PixelRGBA8
resizeToPowerOfTwo TextureConfig{..} img
  | not tcForcePowerOfTwo = img
  | otherwise =
      let w = imageWidth img
          h = imageHeight img
          tw = fromMaybe (nextPowerOfTwo w) tcTargetWidth
          th = fromMaybe (nextPowerOfTwo h) tcTargetHeight
      in if w == tw && h == th
         then img
         else resizeImage img tw th

-- | Convert an image to internal texture format.
imageToInternal :: Image PixelRGBA8 -> TextureConfig -> InternalTexture
imageToInternal img config =
  let img' = resizeToPowerOfTwo config img
      w = imageWidth img'
      h = imageHeight img'
      vec = imageData img'
      meta = TextureMetadata
        { itmWidth      = w
        , itmHeight     = h
        , itmMipLevels  = if tcGenerateMips config then 1 else 1  -- placeholder
        , itmFormat     = tcTargetFormat config
        , itmArrayLayer = 0
        }
  in InternalTexture meta vec

-- | Serialize an internal texture to a ByteString.
serializeInternalTexture :: InternalTexture -> ByteString
serializeInternalTexture (InternalTexture meta vec) =
  let builder =
        BSB.word32BE (fromIntegral $ itmWidth meta)
        <> BSB.word32BE (fromIntegral $ itmHeight meta)
        <> BSB.word32BE (fromIntegral $ itmMipLevels meta)
        <> BSB.word32BE (formatTag (itmFormat meta))
        <> BSB.word32BE (fromIntegral $ itmArrayLayer meta)
        <> BSB.word32BE (fromIntegral $ Vector.length vec)
        <> BSB.byteString (BS.pack (Vector.toList vec))
  in BSL.toStrict (BSB.toLazyByteString builder)
  where
    formatTag R8G8B8A8_UNORM    = 1
    formatTag R8G8B8A8_SRGB     = 2
    formatTag R16G16B16A16_FLOAT = 3

-- | Deserialize a ByteString to an internal texture.
deserializeInternalTexture :: ByteString -> Maybe InternalTexture
deserializeInternalTexture bs
  | BS.length bs < 24 = Nothing
  | otherwise =
      let w     = fromIntegral $ decodeWord32BE (BS.take 4 bs)
          h     = fromIntegral $ decodeWord32BE (BS.take 4 (BS.drop 4 bs))
          mips  = fromIntegral $ decodeWord32BE (BS.take 4 (BS.drop 8 bs))
          fmt   = decodeFormat $ decodeWord32BE (BS.take 4 (BS.drop 12 bs))
          layer = fromIntegral $ decodeWord32BE (BS.take 4 (BS.drop 16 bs))
          dlen  = fromIntegral $ decodeWord32BE (BS.take 4 (BS.drop 20 bs))
          data_ = BS.drop 24 bs
      in if BS.length data_ < dlen
         then Nothing
         else do
           fmt' <- fmt
           let meta = TextureMetadata w h mips fmt' layer
               vec  = Vector.fromListN dlen (BS.unpack (BS.take dlen data_))
           pure (InternalTexture meta vec)
  where
    decodeWord32BE :: ByteString -> Word32
    decodeWord32BE b =
      fromIntegral (BS.index b 0) `shiftL` 24 .|.
      fromIntegral (BS.index b 1) `shiftL` 16 .|.
      fromIntegral (BS.index b 2) `shiftL` 8  .|.
      fromIntegral (BS.index b 3)
    decodeFormat 1 = Just R8G8B8A8_UNORM
    decodeFormat 2 = Just R8G8B8A8_SRGB
    decodeFormat 3 = Just R16G16B16A16_FLOAT
    decodeFormat _ = Nothing

-- | Preprocess raw image bytes into internal format.
preprocessTexture :: MonadIO m => ByteString -> TextureConfig -> m (Either String InternalTexture)
preprocessTexture rawBytes config = liftIO $ do
  case decodeImage rawBytes of
    Left err    -> pure (Left err)
    Right dynImg -> do
      let img = convertRGBA8 dynImg
      pure (Right (imageToInternal img config))

-- | Build a config fingerprint for cache key derivation.
configFingerprint :: TextureConfig -> ByteString
configFingerprint TextureConfig{..} =
  BSL.toStrict $ BSB.toLazyByteString $
    BSB.word32BE (fromIntegral $ fromMaybe 0 tcTargetWidth)
    <> BSB.word32BE (fromIntegral $ fromMaybe 0 tcTargetHeight)
    <> BSB.word8 (if tcForcePowerOfTwo then 1 else 0)
    <> BSB.word8 (if tcGenerateMips then 1 else 0)
    <> BSB.word32BE (formatTag tcTargetFormat)
  where
    formatTag R8G8B8A8_UNORM    = 1
    formatTag R8G8B8A8_SRGB     = 2
    formatTag R16G16B16A16_FLOAT = 3

-- | Load a texture from file, using the cache if available.
loadTextureCached :: MonadIO m => AssetCache -> FilePath -> TextureConfig -> m (Either String InternalTexture)
loadTextureCached cache filePath config = liftIO $ do
  rawBytes <- BS.readFile filePath
  let key = mkCacheKey rawBytes (configFingerprint config)
      subdir = "textures"

  cached <- cacheLookup cache key subdir
  if cached
    then do
      logDebugIO LogTexture $ "Cache hit for " <> showT filePath
      let path = cachePath cache key subdir
      blob <- BS.readFile path
      case deserializeInternalTexture blob of
        Just tex -> pure (Right tex)
        Nothing  -> do
          logDebugIO LogTexture $ "Cache corrupted for " <> showT filePath <> ", reprocessing"
          reprocess rawBytes config cache key subdir
    else do
      logDebugIO LogTexture $ "Cache miss for " <> showT filePath
      reprocess rawBytes config cache key subdir

-- | Load a texture from raw bytes, using the cache if available.
loadTextureBytesCached :: MonadIO m => AssetCache -> ByteString -> TextureConfig -> m (Either String InternalTexture)
loadTextureBytesCached cache rawBytes config = liftIO $ do
  let key = mkCacheKey rawBytes (configFingerprint config)
      subdir = "textures"

  cached <- cacheLookup cache key subdir
  if cached
    then do
      logDebugIO LogTexture "Cache hit (bytes)"
      let path = cachePath cache key subdir
      blob <- BS.readFile path
      case deserializeInternalTexture blob of
        Just tex -> pure (Right tex)
        Nothing  -> do
          logDebugIO LogTexture "Cache corrupted (bytes), reprocessing"
          reprocess rawBytes config cache key subdir
    else do
      logDebugIO LogTexture "Cache miss (bytes)"
      reprocess rawBytes config cache key subdir

reprocess rawBytes config cache key subdir = do
  result <- preprocessTexture rawBytes config
  case result of
    Left err -> pure (Left err)
    Right tex -> do
      let blob = serializeInternalTexture tex
      cacheInsert cache key subdir blob
      pure (Right tex)
