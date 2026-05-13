{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Debug.FrameInspector
  ( FrameSnapshot (..),
    CameraSnapshot (..),
    RenderableSnapshot (..),
    PerformanceSnapshot (..),
    FrameInspector,
    defaultInspector,
    buildFrameSnapshot,
    renderMarkdown,
  )
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)
import Foreign.C (CFloat)
import Graphics.Haskan.Camera (Camera (..), ViewMatrix (..))
import Graphics.Haskan.Vulkan.Types (RenderContext (..))
import Linear (M44, V2 (..), V3 (..), V4 (..))
import Linear.Matrix qualified as Matrix
import System.Clock (Clock (..), TimeSpec, getTime, toNanoSecs)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import Text.Printf (printf)

type FrameInspector = FrameSnapshot -> IO ()

data FrameSnapshot = FrameSnapshot
  { fsFrameNumber :: !Word64,
    fsTimestamp :: !Word64,
    fsCamera :: !CameraSnapshot,
    fsRenderables :: ![RenderableSnapshot],
    fsActivePass :: !Text,
    fsValidation :: ![Text],
    fsPerformance :: !PerformanceSnapshot
  }
  deriving (Show)

data CameraSnapshot = CameraSnapshot
  { csPosition :: !(V3 Float),
    csForward :: !(V3 Float),
    csFov :: !Float,
    csNearFar :: !(Float, Float),
    csViewMatrix :: !(M44 Float),
    csProjMatrix :: !(M44 Float)
  }
  deriving (Show)

data RenderableSnapshot = RenderableSnapshot
  { rsName :: !Text,
    rsWorldMatrix :: !(M44 Float),
    rsScale :: !(V3 Float),
    rsVisible :: !Bool,
    rsMaterial :: !Text,
    rsMesh :: !Text,
    rsIndexCount :: !Int
  }
  deriving (Show)

data PerformanceSnapshot = PerformanceSnapshot
  { psFrameTimeCPU :: !Float,
    psDrawCalls :: !Int,
    psTriangles :: !Int
  }
  deriving (Show)

buildFrameSnapshot ::
  (Camera cam, MonadIO m) =>
  Word64 ->
  TimeSpec ->
  RenderContext ->
  cam ->
  M44 Float ->
  [RenderableSnapshot] ->
  m FrameSnapshot
buildFrameSnapshot frame startTime _rc cam proj renderables = liftIO $ do
  now <- getTime Monotonic
  let dt = fromIntegral (toNanoSecs now - toNanoSecs startTime) / 1e6 :: Float
  let vm = unViewMatrix (toMatrix cam)
  let camSnapshot = extractCamera vm proj cam

  pure $
    FrameSnapshot
      { fsFrameNumber = frame,
        fsTimestamp = fromIntegral (toNanoSecs now),
        fsCamera = camSnapshot,
        fsRenderables = renderables,
        fsActivePass = "forward",
        fsValidation = [],
        fsPerformance =
          PerformanceSnapshot
            { psFrameTimeCPU = dt,
              psDrawCalls = length renderables,
              psTriangles = sum (map rsIndexCount renderables) `div` 3
            }
      }

extractCamera :: (Camera cam) => M44 CFloat -> M44 Float -> cam -> CameraSnapshot
extractCamera vm proj cam =
  let pos = realToFrac <$> cameraPosition cam
      fwd = realToFrac <$> cameraForward cam
   in CameraSnapshot
        { csPosition = pos,
          csForward = fwd,
          csFov = 60.0,
          csNearFar = (0.1, 10000.0),
          csViewMatrix = (realToFrac <$>) <$> vm,
          csProjMatrix = proj
        }

renderMarkdown :: FrameSnapshot -> String
renderMarkdown fs =
  let FrameSnapshot {..} = fs
      CameraSnapshot {..} = fsCamera
      PerformanceSnapshot {..} = fsPerformance
      V3 cx cy cz = csPosition
      V3 fx fy fz = csForward
   in unlines $
        [ "## Frame " ++ show fsFrameNumber ++ " Snapshot",
          "",
          "**Timestamp:** " ++ show fsTimestamp ++ " ns",
          "",
          "### Camera",
          "- **Position:** (" ++ fmtF cx ++ ", " ++ fmtF cy ++ ", " ++ fmtF cz ++ ")",
          "- **Forward:**  (" ++ fmtF fx ++ ", " ++ fmtF fy ++ ", " ++ fmtF fz ++ ")",
          "- **FOV:** "
            ++ fmtF csFov
            ++ "°, Near: "
            ++ fmtF (fst csNearFar)
            ++ ", Far: "
            ++ fmtF (snd csNearFar),
          "",
          "### Scene Objects (" ++ show (length fsRenderables) ++ " total)",
          "",
          "| Name | Position | Scale | Material | Mesh | Triangles |",
          "|------|----------|-------|----------|------|-----------|"
        ]
          ++ map renderRenderable fsRenderables
          ++ [ "",
               "### Pipeline",
               "- **Pass:** " ++ Text.unpack fsActivePass,
               "",
               "### Performance",
               "- **CPU frame time:** " ++ fmtF psFrameTimeCPU ++ " ms",
               "- **Draw calls:** " ++ show psDrawCalls,
               "- **Triangles:** " ++ show psTriangles,
               "",
               if null fsValidation
                 then "### Validation\nClean."
                 else "### Validation\n" ++ unlines (map (\v -> "- " ++ Text.unpack v) fsValidation)
             ]

renderRenderable :: RenderableSnapshot -> String
renderRenderable RenderableSnapshot {..} =
  let V3 wx wy wz = extractTranslation rsWorldMatrix
      V3 sx sy sz = rsScale
   in "| "
        ++ Text.unpack rsName
        ++ " | ("
        ++ fmtF wx
        ++ ", "
        ++ fmtF wy
        ++ ", "
        ++ fmtF wz
        ++ ")"
        ++ " | ("
        ++ fmtF sx
        ++ ", "
        ++ fmtF sy
        ++ ", "
        ++ fmtF sz
        ++ ")"
        ++ " | "
        ++ Text.unpack rsMaterial
        ++ " | "
        ++ Text.unpack rsMesh
        ++ " | "
        ++ show (rsIndexCount `div` 3)
        ++ " |"

extractTranslation :: M44 Float -> V3 Float
extractTranslation m =
  let V4 _ _ _ trans = m
      V4 x y z _ = trans
   in V3 x y z

fmtF :: Float -> String
fmtF = printf "%.2f"

defaultInspector :: FilePath -> FrameInspector
defaultInspector dir snapshot = do
  createDirectoryIfMissing True dir
  let path = dir </> ("frame-" ++ show (fsFrameNumber snapshot) ++ ".md")
  writeFile path (renderMarkdown snapshot)
  putStrLn $ "[FrameInspector] wrote " ++ path
