{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Scene.ECS
  ( EntityId (..)
  , World (..)
  , createWorld
  , spawnEntity
  , despawnEntity
  , setTransform
  , getTransform
  , hasTransform
  , setMesh
  , getMesh
  , hasMesh
  , setMaterial
  , getMaterial
  , hasMaterial
  , setMetallicFactor
  , getMetallicFactor
  , setRoughnessFactor
  , getRoughnessFactor
  , setMetallicRoughnessTexture
  , getMetallicRoughnessTexture
  , setNormalTexture
  , getNormalTexture
  , setOcclusionTexture
  , getOcclusionTexture
  , setOcclusionStrength
  , getOcclusionStrength
  , setEmissiveTexture
  , getEmissiveTexture
  , setParent
  , getParent
  , hasParent
  , getChildren
  , allEntities
  , allEntitiesWithMesh
  ) where

import Control.Concurrent.STM (TVar)
import Control.Concurrent.STM qualified as STM
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.Maybe (catMaybes)
import Data.Word (Word32)
import Graphics.Haskan.Scene.Transform (Transform)
import Graphics.Haskan.Vulkan.Resources (MeshHandle, TextureHandle)

newtype EntityId = EntityId {unEntityId :: Word32}
  deriving (Eq, Ord, Show)

entityKey :: EntityId -> Int
entityKey = fromIntegral . unEntityId

data World = World
  { wNextEntity :: !(TVar Word32)
  , wTransforms :: !(TVar (IntMap Transform))
  , wMeshes :: !(TVar (IntMap MeshHandle))
  , wMaterials :: !(TVar (IntMap TextureHandle))
  , wParents :: !(TVar (IntMap EntityId))
  , wMetallicFactors :: !(TVar (IntMap Float))
  , wRoughnessFactors :: !(TVar (IntMap Float))
  , wMetallicRoughnessTextures :: !(TVar (IntMap TextureHandle))
  , wNormalTextures :: !(TVar (IntMap TextureHandle))
  , wOcclusionTextures :: !(TVar (IntMap TextureHandle))
  , wOcclusionStrengths :: !(TVar (IntMap Float))
  , wEmissiveTextures :: !(TVar (IntMap TextureHandle))
  }

createWorld :: MonadIO m => m World
createWorld = liftIO $ do
  World
    <$> STM.newTVarIO 0
    <*> STM.newTVarIO IntMap.empty
    <*> STM.newTVarIO IntMap.empty
    <*> STM.newTVarIO IntMap.empty
    <*> STM.newTVarIO IntMap.empty
    <*> STM.newTVarIO IntMap.empty
    <*> STM.newTVarIO IntMap.empty
    <*> STM.newTVarIO IntMap.empty
    <*> STM.newTVarIO IntMap.empty
    <*> STM.newTVarIO IntMap.empty
    <*> STM.newTVarIO IntMap.empty
    <*> STM.newTVarIO IntMap.empty

spawnEntity :: MonadIO m => World -> m EntityId
spawnEntity World {..} = liftIO $ STM.atomically $ do
  eid <- STM.readTVar wNextEntity
  STM.writeTVar wNextEntity (eid + 1)
  pure (EntityId eid)

despawnEntity :: MonadIO m => EntityId -> World -> m ()
despawnEntity eid World {..} = liftIO $ STM.atomically $ do
  let k = entityKey eid
  STM.modifyTVar' wTransforms (IntMap.delete k)
  STM.modifyTVar' wMeshes (IntMap.delete k)
  STM.modifyTVar' wMaterials (IntMap.delete k)
  STM.modifyTVar' wParents (IntMap.delete k)
  STM.modifyTVar' wMetallicFactors (IntMap.delete k)
  STM.modifyTVar' wRoughnessFactors (IntMap.delete k)
  STM.modifyTVar' wMetallicRoughnessTextures (IntMap.delete k)
  STM.modifyTVar' wNormalTextures (IntMap.delete k)
  STM.modifyTVar' wOcclusionTextures (IntMap.delete k)
  STM.modifyTVar' wOcclusionStrengths (IntMap.delete k)
  STM.modifyTVar' wEmissiveTextures (IntMap.delete k)

setTransform :: MonadIO m => World -> EntityId -> Transform -> m ()
setTransform World {..} eid t =
  liftIO $ STM.atomically $ STM.modifyTVar' wTransforms (IntMap.insert (entityKey eid) t)

getTransform :: MonadIO m => World -> EntityId -> m (Maybe Transform)
getTransform World {..} eid =
  liftIO $ STM.atomically $ IntMap.lookup (entityKey eid) <$> STM.readTVar wTransforms

hasTransform :: MonadIO m => World -> EntityId -> m Bool
hasTransform world eid = maybe False (const True) <$> getTransform world eid

setMesh :: MonadIO m => World -> EntityId -> MeshHandle -> m ()
setMesh World {..} eid h =
  liftIO $ STM.atomically $ STM.modifyTVar' wMeshes (IntMap.insert (entityKey eid) h)

getMesh :: MonadIO m => World -> EntityId -> m (Maybe MeshHandle)
getMesh World {..} eid =
  liftIO $ STM.atomically $ IntMap.lookup (entityKey eid) <$> STM.readTVar wMeshes

hasMesh :: MonadIO m => World -> EntityId -> m Bool
hasMesh world eid = maybe False (const True) <$> getMesh world eid

setMaterial :: MonadIO m => World -> EntityId -> TextureHandle -> m ()
setMaterial World {..} eid h =
  liftIO $ STM.atomically $ STM.modifyTVar' wMaterials (IntMap.insert (entityKey eid) h)

getMaterial :: MonadIO m => World -> EntityId -> m (Maybe TextureHandle)
getMaterial World {..} eid =
  liftIO $ STM.atomically $ IntMap.lookup (entityKey eid) <$> STM.readTVar wMaterials

hasMaterial :: MonadIO m => World -> EntityId -> m Bool
hasMaterial world eid = maybe False (const True) <$> getMaterial world eid

setMetallicFactor :: MonadIO m => World -> EntityId -> Float -> m ()
setMetallicFactor World {..} eid v =
  liftIO $ STM.atomically $ STM.modifyTVar' wMetallicFactors (IntMap.insert (entityKey eid) v)

getMetallicFactor :: MonadIO m => World -> EntityId -> m (Maybe Float)
getMetallicFactor World {..} eid =
  liftIO $ STM.atomically $ IntMap.lookup (entityKey eid) <$> STM.readTVar wMetallicFactors

setRoughnessFactor :: MonadIO m => World -> EntityId -> Float -> m ()
setRoughnessFactor World {..} eid v =
  liftIO $ STM.atomically $ STM.modifyTVar' wRoughnessFactors (IntMap.insert (entityKey eid) v)

getRoughnessFactor :: MonadIO m => World -> EntityId -> m (Maybe Float)
getRoughnessFactor World {..} eid =
  liftIO $ STM.atomically $ IntMap.lookup (entityKey eid) <$> STM.readTVar wRoughnessFactors

setMetallicRoughnessTexture :: MonadIO m => World -> EntityId -> TextureHandle -> m ()
setMetallicRoughnessTexture World {..} eid h =
  liftIO $ STM.atomically $ STM.modifyTVar' wMetallicRoughnessTextures (IntMap.insert (entityKey eid) h)

getMetallicRoughnessTexture :: MonadIO m => World -> EntityId -> m (Maybe TextureHandle)
getMetallicRoughnessTexture World {..} eid =
  liftIO $ STM.atomically $ IntMap.lookup (entityKey eid) <$> STM.readTVar wMetallicRoughnessTextures

setNormalTexture :: MonadIO m => World -> EntityId -> TextureHandle -> m ()
setNormalTexture World {..} eid h =
  liftIO $ STM.atomically $ STM.modifyTVar' wNormalTextures (IntMap.insert (entityKey eid) h)

getNormalTexture :: MonadIO m => World -> EntityId -> m (Maybe TextureHandle)
getNormalTexture World {..} eid =
  liftIO $ STM.atomically $ IntMap.lookup (entityKey eid) <$> STM.readTVar wNormalTextures

setOcclusionTexture :: MonadIO m => World -> EntityId -> TextureHandle -> m ()
setOcclusionTexture World {..} eid h =
  liftIO $ STM.atomically $ STM.modifyTVar' wOcclusionTextures (IntMap.insert (entityKey eid) h)

getOcclusionTexture :: MonadIO m => World -> EntityId -> m (Maybe TextureHandle)
getOcclusionTexture World {..} eid =
  liftIO $ STM.atomically $ IntMap.lookup (entityKey eid) <$> STM.readTVar wOcclusionTextures

setOcclusionStrength :: MonadIO m => World -> EntityId -> Float -> m ()
setOcclusionStrength World {..} eid v =
  liftIO $ STM.atomically $ STM.modifyTVar' wOcclusionStrengths (IntMap.insert (entityKey eid) v)

getOcclusionStrength :: MonadIO m => World -> EntityId -> m (Maybe Float)
getOcclusionStrength World {..} eid =
  liftIO $ STM.atomically $ IntMap.lookup (entityKey eid) <$> STM.readTVar wOcclusionStrengths

setEmissiveTexture :: MonadIO m => World -> EntityId -> TextureHandle -> m ()
setEmissiveTexture World {..} eid h =
  liftIO $ STM.atomically $ STM.modifyTVar' wEmissiveTextures (IntMap.insert (entityKey eid) h)

getEmissiveTexture :: MonadIO m => World -> EntityId -> m (Maybe TextureHandle)
getEmissiveTexture World {..} eid =
  liftIO $ STM.atomically $ IntMap.lookup (entityKey eid) <$> STM.readTVar wEmissiveTextures

setParent :: MonadIO m => World -> EntityId -> EntityId -> m ()
setParent World {..} child parent =
  liftIO $ STM.atomically $ STM.modifyTVar' wParents (IntMap.insert (entityKey child) parent)

getParent :: MonadIO m => World -> EntityId -> m (Maybe EntityId)
getParent World {..} eid =
  liftIO $ STM.atomically $ IntMap.lookup (entityKey eid) <$> STM.readTVar wParents

hasParent :: MonadIO m => World -> EntityId -> m Bool
hasParent world eid = maybe False (const True) <$> getParent world eid

getChildren :: MonadIO m => World -> EntityId -> m [EntityId]
getChildren World {..} eid = liftIO $ STM.atomically $ do
  parents <- STM.readTVar wParents
  pure [EntityId (fromIntegral k) | (k, p) <- IntMap.toList parents, p == eid]

allEntities :: MonadIO m => World -> m [EntityId]
allEntities World {..} = liftIO $ STM.atomically $ do
  next <- STM.readTVar wNextEntity
  pure [EntityId e | e <- [0 .. next - 1]]

allEntitiesWithMesh :: MonadIO m => World -> m [EntityId]
allEntitiesWithMesh World {..} = liftIO $ STM.atomically $ do
  meshes <- STM.readTVar wMeshes
  pure [EntityId (fromIntegral k) | k <- IntMap.keys meshes]
