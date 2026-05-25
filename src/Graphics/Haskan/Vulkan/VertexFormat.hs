{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Graphics.Haskan.Vulkan.VertexFormat where

import Control.Applicative
import Data.Functor.Contravariant
import Data.Functor.Contravariant.Divisible
import Data.Word (Word32, Word8)
import Foreign.C qualified
import Vulkan qualified
import Linear (V2, V3, V4)

newtype Component = Component {format :: Vulkan.Format}
  deriving (Show)

newtype VertexFormat v
  = VertexFormat (Const [Component] v)
  deriving (Contravariant, Divisible, Show)

v2_s32float :: VertexFormat (V2 Foreign.C.CFloat)
v2_s32float =
  VertexFormat
    ( Const
        [Component {format = Vulkan.FORMAT_R32G32_SFLOAT}]
    )

v3_s32float :: VertexFormat (V3 Foreign.C.CFloat)
v3_s32float =
  VertexFormat
    ( Const
        [Component {format = Vulkan.FORMAT_R32G32B32_SFLOAT}]
    )

v4_word8 :: VertexFormat (V4 Word8)
v4_word8 =
  VertexFormat
    ( Const
        [Component {format = Vulkan.FORMAT_R8G8B8A8_UINT}]
    )

v4_s32float :: VertexFormat (V4 Foreign.C.CFloat)
v4_s32float =
  VertexFormat
    ( Const
        [Component {format = Vulkan.FORMAT_R32G32B32A32_SFLOAT}]
    )

strideSize :: VertexFormat v -> Int
strideSize (VertexFormat (Const components)) =
  sum (map componentSize components)

componentSize :: Component -> Int
componentSize c =
  case format c of
    Vulkan.FORMAT_R32G32B32A32_SFLOAT ->
      4 * 4
    Vulkan.FORMAT_R32G32B32_SFLOAT ->
      3 * 4
    Vulkan.FORMAT_R32G32_SFLOAT ->
      2 * 4
    Vulkan.FORMAT_R8G8B8A8_UINT ->
      4

attributeDescriptions :: Int -> VertexFormat v -> [Vulkan.VertexInputAttributeDescription]
attributeDescriptions binding (VertexFormat (Const components)) =
  getZipList
    ( toAttributeDescription
        <$> ZipList components
        <*> ZipList (scanl (+) 0 (map componentSize components))
        <*> ZipList [0 ..]
    )
  where
    toAttributeDescription :: Component -> Int -> Int -> Vulkan.VertexInputAttributeDescription
    toAttributeDescription (Component fmt) off loc =
      Vulkan.VertexInputAttributeDescription (fromIntegral loc) (fromIntegral binding) fmt (fromIntegral off)
