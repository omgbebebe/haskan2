module Graphics.Haskan.Render.RenderSystem
  ( DrawCall (..)
  , extractDrawList
  ) where

import Control.Concurrent.STM qualified as STM
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Word (Word32)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.Maybe (catMaybes)
import Linear.Matrix (M44, (!*!))
import Linear.Matrix qualified as Matrix

import Graphics.Haskan.Scene.ECS (EntityId (..), World (..))
import Graphics.Haskan.Scene.Transform (Transform, toMatrix)
import Graphics.Haskan.Vulkan.Resources
  ( ResourceManager
  , MeshHandle
  , TextureHandle(..)
  , lookupMesh
  , lookupTexture
  , MeshResource
  , TextureResource
  )

data DrawCall = DrawCall
  { dcMesh :: !MeshResource
  , dcTransform :: !Transform
  , dcWorldMatrix :: !(M44 Float)
  , dcMaterial :: !(Maybe TextureResource)
  , dcMaterialIndex :: !Word32
  }

extractDrawList ::
  MonadIO m =>
  World ->
  ResourceManager ->
  IntMap Word32 -> -- ^ texture handle -> material index mapping
  m [DrawCall]
extractDrawList world rm texIndexMap = liftIO $ do
  meshes <- STM.readTVarIO (wMeshes world)
  transforms <- STM.readTVarIO (wTransforms world)
  parents <- STM.readTVarIO (wParents world)
  materials <- STM.readTVarIO (wMaterials world)

  let worldMatrices = computeWorldMatrices transforms parents

  fmap catMaybes $ mapM (resolveEntity rm transforms materials worldMatrices texIndexMap) (IntMap.toList meshes)

computeWorldMatrices ::
  IntMap Transform ->
  IntMap EntityId ->
  IntMap (M44 Float)
computeWorldMatrices transforms parents =
  IntMap.fromList [(k, go k) | k <- IntMap.keys transforms]
  where
    go eidKey =
      case IntMap.lookup eidKey transforms of
        Nothing -> Matrix.identity
        Just t ->
          case IntMap.lookup eidKey parents of
            Nothing -> toMatrix t
            Just (EntityId p) -> toMatrix t !*! go (fromIntegral p)

resolveEntity ::
  ResourceManager ->
  IntMap Transform ->
  IntMap TextureHandle ->
  IntMap (M44 Float) ->
  IntMap Word32 ->
  (Int, MeshHandle) ->
  IO (Maybe DrawCall)
resolveEntity rm transforms materials worldMatrices texIndexMap (eidKey, meshHandle) = do
  mMeshRes <- lookupMesh rm meshHandle
  let mTransform = IntMap.lookup eidKey transforms
      mMaterialHandle = IntMap.lookup eidKey materials
      mWorldMatrix = IntMap.lookup eidKey worldMatrices

  mMatRes <- case mMaterialHandle of
    Just h -> lookupTexture rm h
    Nothing -> pure Nothing

  let matIdx = case mMaterialHandle of
        Just h -> IntMap.findWithDefault 0 (fromIntegral $ unTextureHandle h) texIndexMap
        Nothing -> 0

  case (mMeshRes, mTransform, mWorldMatrix) of
    (Just mesh, Just trans, Just wm) -> pure $ Just DrawCall
      { dcMesh = mesh
      , dcTransform = trans
      , dcWorldMatrix = wm
      , dcMaterial = mMatRes
      , dcMaterialIndex = matIdx
      }
    _ -> pure Nothing
