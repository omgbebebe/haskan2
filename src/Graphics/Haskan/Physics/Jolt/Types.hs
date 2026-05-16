module Graphics.Haskan.Physics.Jolt.Types where

import Data.Word (Word32)
import Foreign (Ptr)
import Linear (V3 (..), Quaternion (..))

newtype JoltWorld = JoltWorld (Ptr ())
  deriving (Eq, Show)

newtype BodyId = BodyId { unBodyId :: Int }
  deriving (Eq, Show, Ord)

data BodyState = BodyState
  { bsPosition :: !(V3 Float)
  , bsRotation :: !(Quaternion Float)
  , bsVelocity :: !(V3 Float)
  , bsActive   :: !Bool
  }
  deriving (Eq, Show)

data BodyType
  = BoxBody !(V3 Float) Float -- ^ half-extents, mass
  | SphereBody !Float Float   -- ^ radius, mass
  | StaticPlane !(V3 Float) Float -- ^ normal, distance
  deriving (Eq, Show)
