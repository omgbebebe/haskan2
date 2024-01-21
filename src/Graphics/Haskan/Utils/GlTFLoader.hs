module Graphics.Haskan.Utils.GlTFLoader where

import Codec.GlTF (GlTF, fromFile)
import Codec.GlTF.URI (loadURI, URI)
import Control.Monad.IO.Class (MonadIO, liftIO)
import System.IO (FilePath)
import Data.ByteString (ByteString)

load :: (MonadFail m, MonadIO m) => m GlTF
load = do
  res <- liftIO (fromFile "data/gltf/003_minimal.gltf")
  case res of
    Left err -> fail $ "failed to load gltf: " <> err
    Right d -> pure d

loadBuffer :: URI -> ByteString
loadBuffer = undefined

loadFile :: FilePath -> IO (Either String ByteString)
loadFile fp = undefined
