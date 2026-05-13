module Graphics.Haskan.Render.RenderSystem
  ( DrawCall (..),
    extractDrawList,
  )
where

import Control.Concurrent.STM qualified as STM
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.Maybe (catMaybes, fromMaybe)
import Data.Word (Word32)
import Graphics.Haskan.Scene.ECS (EntityId (..), World (..))
import Graphics.Haskan.Scene.Transform (Transform, toMatrix)
import Graphics.Haskan.Vulkan.Resources
  ( MeshHandle,
    MeshResource,
    ResourceManager,
    TextureHandle (..),
    TextureResource,
    lookupMesh,
    lookupTexture,
  )
import Linear.Matrix (M44, (!*!))
import Linear.Matrix qualified as Matrix

data DrawCall = DrawCall
  { dcMesh :: !MeshResource,
    dcTransform :: !Transform,
    dcWorldMatrix :: !(M44 Float),
    dcMaterial :: !(Maybe TextureResource),
    dcMaterialIndex :: !Word32,
    dcMetallicFactor :: !Float,
    dcRoughnessFactor :: !Float,
    dcMetallicRoughnessIndex :: !Word32,
    dcNormalIndex :: !Word32,
    dcOcclusionIndex :: !Word32,
    dcOcclusionStrength :: !Float,
    dcEmissiveIndex :: !Word32
  }

extractDrawList ::
  (MonadIO m) =>
  World ->
  ResourceManager ->
  -- | texture handle -> material index mapping
  IntMap Word32 ->
  m [DrawCall]
extractDrawList world rm texIndexMap = liftIO $ do
  meshes <- STM.readTVarIO (wMeshes world)
  transforms <- STM.readTVarIO (wTransforms world)
  parents <- STM.readTVarIO (wParents world)
  materials <- STM.readTVarIO (wMaterials world)
  metallicFactors <- STM.readTVarIO (wMetallicFactors world)
  roughnessFactors <- STM.readTVarIO (wRoughnessFactors world)
  mrTextures <- STM.readTVarIO (wMetallicRoughnessTextures world)
  normalTextures <- STM.readTVarIO (wNormalTextures world)
  occlusionTextures <- STM.readTVarIO (wOcclusionTextures world)
  occlusionStrengths <- STM.readTVarIO (wOcclusionStrengths world)
  emissiveTextures <- STM.readTVarIO (wEmissiveTextures world)

  let worldMatrices = computeWorldMatrices transforms parents

  catMaybes <$> mapM (resolveEntity rm transforms materials metallicFactors roughnessFactors mrTextures normalTextures occlusionTextures occlusionStrengths emissiveTextures worldMatrices texIndexMap) (IntMap.toList meshes)

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
  IntMap Float ->
  IntMap Float ->
  IntMap TextureHandle ->
  IntMap TextureHandle ->
  IntMap TextureHandle ->
  IntMap Float ->
  IntMap TextureHandle ->
  IntMap (M44 Float) ->
  IntMap Word32 ->
  (Int, MeshHandle) ->
  IO (Maybe DrawCall)
resolveEntity rm transforms materials metallicFactors roughnessFactors mrTextures normalTextures occlusionTextures occlusionStrengths emissiveTextures worldMatrices texIndexMap (eidKey, meshHandle) = do
  mMeshRes <- lookupMesh rm meshHandle
  let mTransform = IntMap.lookup eidKey transforms
      mMaterialHandle = IntMap.lookup eidKey materials
      mWorldMatrix = IntMap.lookup eidKey worldMatrices
      mMetallic = IntMap.lookup eidKey metallicFactors
      mRoughness = IntMap.lookup eidKey roughnessFactors
      mMRTexture = IntMap.lookup eidKey mrTextures
      mNormalTexture = IntMap.lookup eidKey normalTextures
      mOcclusionTexture = IntMap.lookup eidKey occlusionTextures
      mOcclusionStrength = IntMap.lookup eidKey occlusionStrengths
      mEmissiveTexture = IntMap.lookup eidKey emissiveTextures

  mMatRes <- case mMaterialHandle of
    Just h -> lookupTexture rm h
    Nothing -> pure Nothing

  let lookUpIndex mHandle = case mHandle of
        Just h -> IntMap.findWithDefault 0 (fromIntegral $ unTextureHandle h) texIndexMap
        Nothing -> 0
      matIdx = lookUpIndex mMaterialHandle
      mrIdx = lookUpIndex mMRTexture
      normalIdx = lookUpIndex mNormalTexture
      occlusionIdx = lookUpIndex mOcclusionTexture
      emissiveIdx = lookUpIndex mEmissiveTexture
      metallic = fromMaybe 0.0 mMetallic
      roughness = fromMaybe 0.5 mRoughness
      occlusionStrength = fromMaybe 1.0 mOcclusionStrength

  case (mMeshRes, mTransform, mWorldMatrix) of
    (Just mesh, Just trans, Just wm) ->
      pure $
        Just
          DrawCall
            { dcMesh = mesh,
              dcTransform = trans,
              dcWorldMatrix = wm,
              dcMaterial = mMatRes,
              dcMaterialIndex = matIdx,
              dcMetallicFactor = metallic,
              dcRoughnessFactor = roughness,
              dcMetallicRoughnessIndex = mrIdx,
              dcNormalIndex = normalIdx,
              dcOcclusionIndex = occlusionIdx,
              dcOcclusionStrength = occlusionStrength,
              dcEmissiveIndex = emissiveIdx
            }
    _ -> pure Nothing
