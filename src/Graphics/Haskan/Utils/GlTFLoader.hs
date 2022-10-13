module Graphics.Haskan.Utils.GlTFLoader where

import Codec.GlTF (GlTF, fromFile)
import Control.Monad.IO.Class (MonadIO, liftIO)

load :: (MonadFail m, MonadIO m) => m GlTF
load = do
  res <- liftIO (fromFile "data/gltf/003_minimal.gltf")
  case res of
    Left err -> fail $ "failed to load gltf: " <> err
    Right d -> pure d
