module Graphics.Haskan.Physics.Jolt.Types where

import Data.Word (Word32)
import Foreign (Ptr)
import Linear (Quaternion (..), V3 (..))

newtype JoltWorld = JoltWorld (Ptr ())
  deriving (Eq, Show)

newtype BodyId = BodyId {unBodyId :: Int}
  deriving (Eq, Show, Ord)

data BodyState = BodyState
  { bsPosition :: !(V3 Float),
    bsRotation :: !(Quaternion Float),
    bsVelocity :: !(V3 Float),
    bsActive :: !Bool
  }
  deriving (Eq, Show)

data BodyType
  = -- | half-extents, mass
    BoxBody !(V3 Float) Float
  | -- | radius, mass
    SphereBody !Float Float
  | -- | normal, distance
    StaticPlane !(V3 Float) Float
  deriving (Eq, Show)
