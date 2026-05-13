module Graphics.Haskan.Engine.Render.Internal.FrameState
  ( FrameState (..),
    readFrameState,
  )
where

import Data.Word (Word32)
import Graphics.Haskan.Engine.Capabilities.StateReader (MonadStateReader (..))

-- | All TVar-derived frame state read once per frame
data FrameState = FrameState
  { fsWireframe :: !Bool,
    fsDebugMode :: !Word32,
    fsAxisOverlay :: !Float,
    fsGroundPlane :: !Float,
    fsTimeOfDay :: !Float,
    fsDayNightEnabled :: !Bool,
    fsCloudHeight :: !Float
  }
  deriving (Show)

readFrameState :: (MonadStateReader m) => m FrameState
readFrameState =
  FrameState
    <$> readWireframe
    <*> readDebugMode
    <*> readAxisOverlay
    <*> readGroundPlane
    <*> readTimeOfDay
    <*> readDayNightEnabled
    <*> readCloudHeight
