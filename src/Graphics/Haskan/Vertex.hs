{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Vertex where

import Data.Functor.Contravariant
import Data.Functor.Contravariant.Divisible
import Foreign qualified
import Foreign.C qualified
import Foreign.Storable (Storable (..), peekByteOff)
import Graphics.Haskan.Vulkan.VertexFormat
import Linear (V2 (..), V3 (..), V4 (..))

type VertexIndex = Foreign.Word32

data Vertex = Vertex
  { vPos :: V3 Foreign.C.CFloat,
    vTexUV :: V2 Foreign.C.CFloat,
    vNorm :: V3 Foreign.C.CFloat,
    vCol :: V3 Foreign.C.CFloat
  }
  deriving (Eq, Show)

instance Storable Vertex where
  sizeOf _ = strideSize vertexFormat
  alignment _ = strideSize vertexFormat
  peek ptr =
    let vPosSz = sizeOf (undefined :: V3 Foreign.C.CFloat)
        vTexUVSz = sizeOf (undefined :: V2 Foreign.C.CFloat)
        vNormSz = sizeOf (undefined :: V3 Foreign.C.CFloat)
     in Vertex
          <$> peekByteOff ptr 0
          <*> peekByteOff ptr vPosSz
          <*> peekByteOff ptr (vPosSz + vTexUVSz)
          <*> peekByteOff ptr (vPosSz + vTexUVSz + vNormSz)
  poke ptr Vertex {..} =
    let vPosSz = sizeOf (undefined :: V3 Foreign.C.CFloat)
        vTexUVSz = sizeOf (undefined :: V2 Foreign.C.CFloat)
        vNormSz = sizeOf (undefined :: V3 Foreign.C.CFloat)
     in do
          pokeByteOff ptr 0 vPos
          pokeByteOff ptr (vPosSz) vTexUV
          pokeByteOff ptr (vPosSz + vTexUVSz) vNorm
          pokeByteOff ptr (vPosSz + vTexUVSz + vNormSz) vCol

vertexFormat :: VertexFormat Vertex
vertexFormat =
  vertex
    >$< v3_s32float
      >*< v2_s32float
      >*< v3_s32float
      >*< v3_s32float
  where
    vertex Vertex {..} =
      (vPos, (vTexUV, (vNorm, vCol)))

(>*<) :: Divisible f => f a -> f b -> f (a, b)
(>*<) = divided

infixr 5 >*<
