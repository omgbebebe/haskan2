{-# LANGUAGE BlockArguments #-}

module Graphics.Haskan.Terrain.Texture
  ( fetchAndUploadTerrainTile,
  )
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Text (Text)
import Graphics.Haskan.Logger (LogCategory (..), logInfoIO, showT)
import Graphics.Haskan.Terrain.Client (TerrainTile (..), fetchTerrainTile)
import Graphics.Haskan.Vulkan.Resources (ResourceManager, TextureHandle)
import Graphics.Haskan.Vulkan.Texture (createTerrainClimateTexture, createTerrainElevationTexture)
import Graphics.Haskan.Vulkan.Types (VulkanContext)

fetchAndUploadTerrainTile ::
  (MonadManaged m, MonadIO m) =>
  ResourceManager ->
  VulkanContext ->
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
  -- | Scale factor
  Int ->
  m (Either Text (TextureHandle, TextureHandle))
fetchAndUploadTerrainTile rm vc host i1 j1 i2 j2 scale = do
  result <- fetchTerrainTile host i1 j1 i2 j2 scale
  case result of
    Left err -> pure (Left err)
    Right tile -> do
      logInfoIO LogGeneral $
        "uploading terrain tile "
          <> showT (ttWidth tile)
          <> "x"
          <> showT (ttHeight tile)
          <> " to GPU"
      elevHandle <- createTerrainElevationTexture rm vc (ttWidth tile) (ttHeight tile) (ttElevation tile)
      climateHandle <- createTerrainClimateTexture rm vc (ttWidth tile) (ttHeight tile) (ttClimate tile)
      pure (Right (elevHandle, climateHandle))
