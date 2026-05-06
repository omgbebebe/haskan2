module Graphics.Haskan.Utils.GlTFLoader where

import Codec.GlTF (GlTF, fromFile)
import Codec.GlTF.URI (loadURI, URI)
import Control.Monad.IO.Class (MonadIO, liftIO)
import System.IO (FilePath)
import Data.ByteString (ByteString)
import Graphics.Haskan.Utils.ObjLoader (Obj(..))
--import Graphics.Haskan.Model (Obj(..))

loadGltf :: (MonadIO m) => FilePath -> m Obj
loadGltf filePath = undefined
{--
do
  gltf <- liftIO $ fromFile filePath
  case gltf of
    Left err -> error $ "Failed to load glTF file: " ++ show err
    Right gltfData -> return $ Obj gltfData
--}
