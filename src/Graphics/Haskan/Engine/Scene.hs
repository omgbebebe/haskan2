{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Engine.Scene
  ( computeSkyboxRays
  , modelMatrix
  , makeProjectionMatrix
  , drawCallToSnapshot
  , computeMeshBounds
  , computeWorldSpaceBounds
  , computeSceneBounds
  , adjustCameraForScene
  ) where

import Control.Monad (forM)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Maybe (catMaybes)
import Foreign.C qualified
import Graphics.Haskan.BoundingBox (BBox (..), bboxCenter, bboxDiagonal, emptyBBox, fromPoints, mergeBBox, mergePoint)
import Graphics.Haskan.Camera (Camera (..))
import Graphics.Haskan.Debug.FrameInspector (RenderableSnapshot (..))
import Graphics.Haskan.Engine.Types (transformAABB)
import Graphics.Haskan.Mesh qualified as Mesh
import Graphics.Haskan.Render.RenderSystem (DrawCall (..))
import Graphics.Haskan.Scene.ECS qualified as ECS
import Graphics.Haskan.Scene.Transform (Transform (..))
import Graphics.Haskan.Scene.Transform qualified as Transform
import Graphics.Haskan.Vertex (Vertex (..))
import Graphics.Haskan.Vulkan.Resources (MeshHandle, ResourceManager, lookupMesh, mrBounds, mrIndexCount)
import Graphics.Haskan.Vulkan.Resources (MeshHandle)
import Linear (M44, V2 (..), V3 (..), V4 (..), (*^), (^+^), (^-^), normalize)
import Linear.Matrix (identity, inv33, inv44, transpose, (!*), (!*!))
import Linear.Projection qualified
import Linear.Quaternion (Quaternion (..))
import Linear.V3 (_x, _y, _z)
import Linear.V4 (_w)
import System.IO.Unsafe (unsafePerformIO)

computeSkyboxRays :: M44 Float -> M44 Float -> (V3 Float, V3 Float, V3 Float)
computeSkyboxRays view proj =
  let V4 (V4 v00 v01 v02 _) (V4 v10 v11 v12 _) (V4 v20 v21 v22 _) _ = view
      worldRot = V3 (V3 v00 v01 v02) (V3 v10 v11 v12) (V3 v20 v21 v22)

      V4 (V4 fx _ _ _) (V4 _ fy _ _) _ _ = proj

      ndcToDir :: V4 Float -> V3 Float
      ndcToDir (V4 x y _z _w) =
        let viewDir = V3 (x / fx) (y / fy) (-1)
        in normalize (worldRot !* viewDir)

      bottomLeft  = ndcToDir (V4 (-1) (-1) 0 1)
      bottomRight = ndcToDir (V4 1    (-1) 0 1)
      topLeft     = ndcToDir (V4 (-1) 1    0 1)

      ray0 = bottomLeft
      ray1 = 2 *^ bottomRight ^-^ bottomLeft
      ray2 = 2 *^ topLeft ^-^ bottomLeft
  in (ray0, ray1, ray2)

modelMatrix :: M44 Foreign.C.CFloat
modelMatrix =
  let rotate = identity
      translate = identity
   in translate !*! rotate

makeProjectionMatrix :: Float -> Float -> M44 Foreign.C.CFloat
makeProjectionMatrix width height =
  Linear.Projection.perspective
    (pi / 3)
    (realToFrac width / realToFrac height)
    0.01
    400000.0

drawCallToSnapshot :: DrawCall -> RenderableSnapshot
drawCallToSnapshot DrawCall {..} =
  RenderableSnapshot
    { rsName = "entity"
    , rsWorldMatrix = (realToFrac <$>) <$> dcWorldMatrix
    , rsScale = V3 1 1 1
    , rsVisible = True
    , rsMaterial = maybe "default" (const "textured") dcMaterial
    , rsMesh = "mesh"
    , rsIndexCount = mrIndexCount dcMesh
    }

computeMeshBounds :: Mesh.Mesh -> BBox
computeMeshBounds mesh =
  fromPoints (map (fmap realToFrac . vPos) (Mesh.vertices mesh))

computeWorldSpaceBounds :: ECS.World -> ResourceManager -> IO BBox
computeWorldSpaceBounds world rm = do
  entities <- ECS.allEntitiesWithMesh world
  boundsList <- forM entities $ \eid -> do
    mMeshHandle <- ECS.getMesh world eid
    mTransform <- ECS.getTransform world eid
    case (mMeshHandle, mTransform) of
      (Just meshHandle, Just transform) -> do
        mMeshRes <- lookupMesh rm meshHandle
        case mMeshRes of
          Just meshRes -> do
            let worldMat = Transform.toMatrix transform
                (wmin, wmax) = transformAABB worldMat (mrBounds meshRes)
            pure $ Just $ BBox wmin wmax
          Nothing -> pure Nothing
      _ -> pure Nothing
  pure $ foldl mergeBBox emptyBBox (catMaybes boundsList)

computeSceneBounds :: [MeshHandle] -> ResourceManager -> BBox
computeSceneBounds meshes rm = unsafePerformIO $ do
  boundsList <- mapM (\mh -> do
    mMesh <- lookupMesh rm mh
    case mMesh of
      Just meshRes -> pure $ mrBounds meshRes
      Nothing -> pure emptyBBox
    ) meshes
  pure $ foldl mergeBBox emptyBBox boundsList

adjustCameraForScene :: Camera a => BBox -> a -> a
adjustCameraForScene bbox cam =
  let center = bboxCenter bbox
      diag = bboxDiagonal bbox
      fov = pi / 3
      padding = 1.5
      r = diag / 2
      targetDist = max (0.1 + r) (r / sin (fov / 2) * padding)
      maxDist = targetDist * 5.0
      cam' = setTarget cam (fmap realToFrac center)
      cam'' = setMaxDistance cam' (realToFrac maxDist)
  in setDistance cam'' (realToFrac targetDist)
