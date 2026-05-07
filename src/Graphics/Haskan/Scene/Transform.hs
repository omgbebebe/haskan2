{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Scene.Transform
  ( Transform (..)
  , defaultTransform
  , toMatrix
  ) where

import Control.Lens ((&), (.~), (^.))
import Linear (M44, Quaternion (..), V3 (..), V4 (..), _x, _y, _z)
import Linear.Matrix ((!*!))
import Linear.Matrix qualified as Matrix

data Transform = Transform
  { tPosition :: !(V3 Float)
  , tRotation :: !(Quaternion Float)
  , tScale :: !(V3 Float)
  }
  deriving (Eq, Show)

defaultTransform :: Transform
defaultTransform = Transform (V3 0 0 0) (Quaternion 1 (V3 0 0 0)) (V3 1 1 1)

toMatrix :: Transform -> M44 Float
toMatrix Transform {..} =
  let sx = tScale ^. _x
      sy = tScale ^. _y
      sz = tScale ^. _z
      scaleM =
        V4
          (V4 sx 0 0 0)
          (V4 0 sy 0 0)
          (V4 0 0 sz 0)
          (V4 0 0 0 1)
      rotTransM = Matrix.mkTransformation tRotation tPosition
   in rotTransM !*! scaleM
