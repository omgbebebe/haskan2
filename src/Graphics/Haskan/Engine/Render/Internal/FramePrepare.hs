module Graphics.Haskan.Engine.Render.Internal.FramePrepare
  ( buildComputeEntityData,
    buildAllEntityData,
    buildCullData,
    computeSkyParams,
    computeEntityDebugInfos,
    buildRenderDebugInfo,
  )
where

import Control.Lens ((^.))
import Data.Word (Word32)
import Foreign.C qualified
import Graphics.Haskan.Camera (AnyCamera, Camera (..))
import Graphics.Haskan.Camera qualified as Camera
import Graphics.Haskan.DayNight (computeSunState, defaultDayNightConfig)
import Graphics.Haskan.DayNight qualified as DayNight
import Graphics.Haskan.Engine.Scene (makeProjectionMatrix)
import Graphics.Haskan.Engine.Types
  ( ComputeCullData (..),
    ComputeEntityData (..),
    EntityDebugInfo (..),
    RenderDebugInfo (..),
    extractFrustumPlanes,
    toListOfV4,
    transformAABB,
  )
import Graphics.Haskan.Render.RenderSystem (DrawCall (..))
import Graphics.Haskan.Scene.Transform (tPosition)
import Graphics.Haskan.Vulkan.Resources (MeshResource (..))
import Linear (M44, V2 (..), V3 (..), V4 (..))
import Linear.Matrix (inv33, transpose, (!*), (!*!))
import Linear.V3 (_x, _y, _z)
import Linear.V4 (_w)

buildComputeEntityData :: DrawCall -> ComputeEntityData
buildComputeEntityData dc =
  let worldMat = dcWorldMatrix dc
      meshRes = dcMesh dc
      (wmin, wmax) = transformAABB worldMat (mrBounds meshRes)
      m33 =
        V3
          (V3 (worldMat ^. _x . _x) (worldMat ^. _x . _y) (worldMat ^. _x . _z))
          (V3 (worldMat ^. _y . _x) (worldMat ^. _y . _y) (worldMat ^. _y . _z))
          (V3 (worldMat ^. _z . _x) (worldMat ^. _z . _y) (worldMat ^. _z . _z))
      normalM33 = transpose (inv33 m33)
      normalM44 =
        V4
          (V4 (normalM33 ^. _x . _x) (normalM33 ^. _x . _y) (normalM33 ^. _x . _z) 0)
          (V4 (normalM33 ^. _y . _x) (normalM33 ^. _y . _y) (normalM33 ^. _y . _z) 0)
          (V4 (normalM33 ^. _z . _x) (normalM33 ^. _z . _y) (normalM33 ^. _z . _z) 0)
          (V4 0 0 0 1)
   in ComputeEntityData
        { ceTransform = (realToFrac <$>) <$> Linear.Matrix.transpose worldMat,
          ceNormalMatrix = (realToFrac <$>) <$> normalM44,
          ceAabbMin = V4 (realToFrac $ wmin ^. _x) (realToFrac $ wmin ^. _y) (realToFrac $ wmin ^. _z) 1,
          ceAabbMax = V4 (realToFrac $ wmax ^. _x) (realToFrac $ wmax ^. _y) (realToFrac $ wmax ^. _z) (1 :: Foreign.C.CFloat),
          ceMaterialIndex = dcMaterialIndex dc,
          ceFirstIndex = fromIntegral (mrFirstIndex meshRes),
          ceVertexOffset = fromIntegral (mrVertexOffset meshRes),
          ceIndexCount = fromIntegral (mrIndexCount meshRes),
          ceMetallicRoughnessIndex = dcMetallicRoughnessIndex dc,
          ceMetallicFactor = realToFrac (dcMetallicFactor dc),
          ceRoughnessFactor = realToFrac (dcRoughnessFactor dc),
          ceNormalIndex = dcNormalIndex dc,
          ceOcclusionIndex = dcOcclusionIndex dc,
          ceOcclusionStrength = realToFrac (dcOcclusionStrength dc),
          ceEmissiveIndex = dcEmissiveIndex dc
        }

buildAllEntityData :: [DrawCall] -> [ComputeEntityData]
buildAllEntityData = map buildComputeEntityData

buildCullData :: Float -> Float -> AnyCamera -> [DrawCall] -> ComputeCullData
buildCullData w h camera drawList =
  let vp = (realToFrac <$>) <$> (makeProjectionMatrix w h !*! Camera.unViewMatrix (Camera.toMatrix camera)) :: M44 Float
      planes = extractFrustumPlanes vp
      camPos = Camera.cameraPosition camera
   in ComputeCullData
        { ccFrustumPlanes = map (fmap realToFrac) planes,
          ccCameraPosition = V4 (realToFrac $ camPos ^. _x) (realToFrac $ camPos ^. _y) (realToFrac $ camPos ^. _z) 1,
          ccEntityCount = fromIntegral (length drawList),
          ccLodDistance1 = 100.0,
          ccLodDistance2 = 400.0,
          ccPad3 = 0
        }

computeSkyParams :: Bool -> Float -> (DayNight.SunState, V3 Float, Float, Float, V3 Float)
computeSkyParams dnEnabled currentTime =
  let sunState =
        if dnEnabled
          then computeSunState defaultDayNightConfig currentTime
          else DayNight.SunState (V3 (-1) (-1) (-1)) 1.0 (V3 1 1 1) (V3 1 1 1) 0.3 0.0
   in ( sunState,
        DayNight.ssSkyTint sunState,
        DayNight.ssIBLIntensity sunState,
        DayNight.ssAzimuth sunState,
        DayNight.ssDirection sunState
      )

sampleLocalVerts :: [V3 Float]
sampleLocalVerts =
  [ V3 (-0.5) (-0.5) (-0.5),
    V3 0.5 (-0.5) (-0.5),
    V3 0.5 0.5 (-0.5),
    V3 (-0.5) 0.5 (-0.5),
    V3 (-0.5) (-0.5) 0.5,
    V3 0.5 (-0.5) 0.5,
    V3 0.5 0.5 0.5,
    V3 (-0.5) 0.5 0.5
  ]

toNDC :: M44 Float -> V3 Float -> V3 Float
toNDC mvp (V3 x y z) =
  let V4 cx cy cz cw = (mvp !* V4 x y z 1.0) :: V4 Float
   in if abs cw > 0.001 then V3 (cx / cw) (cy / cw) (cz / cw) else V3 cx cy cz

computeEntityDebugInfos :: [DrawCall] -> M44 Float -> M44 Float -> [EntityDebugInfo]
computeEntityDebugInfos drawList projMat viewMat =
  zipWith
    ( \idx dc ->
        let modelMat = Linear.Matrix.transpose $ (realToFrac <$>) <$> dcWorldMatrix dc :: M44 Float
            mvp = projMat !*! viewMat !*! modelMat
            ndcVerts = map (toNDC mvp) sampleLocalVerts
         in EntityDebugInfo
              { ediEntityId = idx,
                ediWorldMatrix = map (map realToFrac) (toListOfV4 (fmap (fmap realToFrac) modelMat)),
                ediPosition = realToFrac <$> tPosition (dcTransform dc),
                ediSampleVerticesNDC = ndcVerts
              }
    )
    [0 ..]
    drawList

buildRenderDebugInfo ::
  Int ->
  V3 Float ->
  V3 Float ->
  M44 Float ->
  [EntityDebugInfo] ->
  RenderDebugInfo
buildRenderDebugInfo frameNumber camPos camTarget projMat entityDebugInfos =
  RenderDebugInfo
    { rdiFrameNumber = frameNumber,
      rdiCameraPos = camPos,
      rdiCameraTarget = camTarget,
      rdiProjectionMatrix = map (map realToFrac) (toListOfV4 (fmap (fmap realToFrac) projMat)),
      rdiEntities = entityDebugInfos
    }
