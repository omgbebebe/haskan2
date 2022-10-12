module Graphics.Haskan.Mesh where

-- base
import Data.Word (Word32)

-- haskan
import Graphics.Haskan.Face (Face(..))
import Graphics.Haskan.Vertex (Vertex(..))

data Mesh =
  Mesh { vertices :: [Vertex]
       , indices :: [Word32]
       } deriving (Eq, Show)
