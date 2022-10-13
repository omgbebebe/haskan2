module Graphics.Haskan.Mesh where

import Data.Word (Word32)
import Graphics.Haskan.Face (Face (..))
import Graphics.Haskan.Vertex (Vertex (..))

data Mesh = Mesh
  { vertices :: [Vertex],
    indices :: [Word32]
  }
  deriving (Eq, Show)
