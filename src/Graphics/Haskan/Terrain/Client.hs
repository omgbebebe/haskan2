{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Terrain.Client
  ( TerrainTile (..),
    fetchTerrainTile,
    defaultTerrainHost,
  )
where

import Control.Exception (try)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Bits (shiftL, shiftR, (.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BSC
import Data.ByteString.Lazy qualified as BSL
import Data.Int (Int16)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector.Storable (Vector)
import Data.Vector.Storable qualified as Vector
import Data.Word (Word32, Word8)
import Graphics.Haskan.Logger (LogCategory (..), logInfoIO, showT)
import Network.HTTP.Client
import Network.HTTP.Types.Header (ResponseHeaders, hContentType)
import Network.HTTP.Types.Status (statusCode)

-- | Terrain tile with elevation and climate data.
data TerrainTile = TerrainTile
  { ttWidth :: !Int,
    ttHeight :: !Int,
    ttElevation :: !(Vector Int16),
    ttClimate :: !(Vector Float)
  }
  deriving (Show)

-- | Default terrain API host.
defaultTerrainHost :: String
defaultTerrainHost = "http://localhost:7777"

-- | Read X-Height and X-Width from response headers.
readDimensions :: ResponseHeaders -> Maybe (Int, Int)
readDimensions hdrs = do
  h <- lookup "x-height" hdrs >>= readInt
  w <- lookup "x-width" hdrs >>= readInt
  pure (h, w)
  where
    readInt bs = case reads (BSC.unpack bs) of
      [(n, "")] -> Just n
      _ -> Nothing

-- | Parse little-endian int16 from ByteString.
parseInt16LE :: ByteString -> Vector Int16
parseInt16LE bs = Vector.generate (BS.length bs `div` 2) $ \i ->
  let lo = fromIntegral (BS.index bs (i * 2)) :: Word8
      hi = fromIntegral (BS.index bs (i * 2 + 1)) :: Word8
   in fromIntegral (fromIntegral lo + fromIntegral hi * 256 :: Int)

-- | Parse little-endian float32 from ByteString.
parseFloat32LE :: ByteString -> Vector Float
parseFloat32LE bs =
  Vector.generate (BS.length bs `div` 4) $ \i ->
    let b0 = BS.index bs (i * 4)
        b1 = BS.index bs (i * 4 + 1)
        b2 = BS.index bs (i * 4 + 2)
        b3 = BS.index bs (i * 4 + 3)
        word =
          fromIntegral b0
            + fromIntegral b1 `shiftL` 8
            + fromIntegral b2 `shiftL` 16
            + fromIntegral b3 `shiftL` 24 ::
            Word32
     in wordToFloat word
  where
    wordToFloat :: Word32 -> Float
    wordToFloat w =
      let sign = if w > 0x7FFFFFFF then (-1.0) else 1.0
          expBits = fromIntegral ((w `shiftR` 23) .&. 0xFF) :: Int
          mantissa = fromIntegral (w .&. 0x7FFFFF) :: Float
          exponent
            | expBits == 0 = -126
            | expBits == 255 = 0
            | otherwise = fromIntegral expBits - 127
          fraction
            | expBits == 0 = mantissa / 8388608.0
            | otherwise = 1.0 + mantissa / 8388608.0
       in sign * fraction * (2.0 ** exponent)

-- | Fetch a terrain tile from the inference API.
-- Returns raw binary: int16 elevation + float32 climate (4 channels).
fetchTerrainTile ::
  (MonadIO m) =>
  -- | Base URL (e.g. "http://localhost:7777")
  String ->
  -- | Bounding box i1
  Int ->
  -- | Bounding box j1
  Int ->
  -- | Bounding box i2
  Int ->
  -- | Bounding box j2
  Int ->
  -- | Scale factor (1=90m, 2=45m, 4=22.5m, 8=11.25m)
  Int ->
  m (Either Text TerrainTile)
fetchTerrainTile host i1 j1 i2 j2 scale = liftIO $ do
  let url =
        host
          ++ "/terrain?i1="
          ++ show i1
          ++ "&j1="
          ++ show j1
          ++ "&i2="
          ++ show i2
          ++ "&j2="
          ++ show j2
          ++ "&scale="
          ++ show scale

  logInfoIO LogGeneral $ "fetching terrain: " <> Text.pack url

  manager <- newManager defaultManagerSettings
  request <- parseRequest url
  let requestWithHeaders = request {requestHeaders = [(hContentType, "application/octet-stream")]}

  result <- try $ httpLbs requestWithHeaders manager
  case result of
    Left (e :: HttpException) -> do
      let err = "HTTP request failed: " ++ show e
      logInfoIO LogGeneral $ "terrain fetch failed: " <> Text.pack err
      pure (Left $ Text.pack err)
    Right response -> do
      let status = statusCode (responseStatus response)
          body = BS.concat $ BSL.toChunks (responseBody response)
          headers = responseHeaders response
      if status /= 200
        then do
          let err = "HTTP " ++ show status
          logInfoIO LogGeneral $ "terrain fetch failed: " <> Text.pack err
          pure (Left $ Text.pack err)
        else do
          case readDimensions headers of
            Nothing -> do
              logInfoIO LogGeneral "terrain response missing X-Height/X-Width headers"
              pure (Left "missing dimension headers")
            Just (h, w) -> do
              let elevSize = h * w * 2
                  climateSize = h * w * 4 * 4
                  totalSize = elevSize + climateSize
              if BS.length body < totalSize
                then do
                  let err =
                        "incomplete response: got "
                          ++ show (BS.length body)
                          ++ " bytes, expected "
                          ++ show totalSize
                  logInfoIO LogGeneral $ "terrain parse failed: " <> Text.pack err
                  pure (Left $ Text.pack err)
                else do
                  let elevation = parseInt16LE (BS.take elevSize body)
                      climate = parseFloat32LE (BS.drop elevSize body)
                  logInfoIO LogGeneral $
                    "terrain tile loaded: "
                      <> showT w
                      <> "x"
                      <> showT h
                      <> " elevation="
                      <> showT (Vector.length elevation)
                      <> " climate="
                      <> showT (Vector.length climate)
                  pure $ Right $ TerrainTile w h elevation climate
