{-# language GeneralizedNewtypeDeriving #-}
module Graphics.Haskan.Vulkan.VertexFormat where

-- base
import Control.Applicative
import Data.Functor.Contravariant
import Data.Word (Word8)
import qualified Foreign.C
 
-- contravariant
import Data.Functor.Contravariant.Divisible

-- linear
import Linear (V2, V3, V4)

-- vulkan-api
import qualified Graphics.Vulkan.Core_1_0 as Vulkan
import qualified Graphics.Vulkan.Marshal.Create as Vulkan
import Graphics.Vulkan.Marshal.Create (set, setAt, setVkRef, setListRef, setStrRef, (&*))

newtype Component =
  Component { format :: Vulkan.VkFormat } deriving Show

newtype VertexFormat v =
  VertexFormat (Const [Component] v)
  deriving (Contravariant, Divisible, Show)

v2_s32float :: VertexFormat (V2 Foreign.C.CFloat)
v2_s32float =
  VertexFormat
    ( Const
        ( [ Component { format = Vulkan.VK_FORMAT_R32G32_SFLOAT}] )
    )

v3_s32float :: VertexFormat (V3 Foreign.C.CFloat)
v3_s32float =
  VertexFormat
    ( Const
        ( [ Component { format = Vulkan.VK_FORMAT_R32G32B32_SFLOAT}] )
    )

v4_word8 :: VertexFormat (V4 Word8)
v4_word8 =
  VertexFormat
    ( Const
        ( [ Component { format = Vulkan.VK_FORMAT_R8G8B8A8_UINT}] )
    )

strideSize :: VertexFormat v -> Int
strideSize (VertexFormat (Const components)) =
  sum (map componentSize components)

componentSize :: Component -> Int
componentSize c =
  case format c of
    Vulkan.VK_FORMAT_R32G32B32A32_SFLOAT ->
      4 * 4
    Vulkan.VK_FORMAT_R32G32B32_SFLOAT ->
      3 * 4
    Vulkan.VK_FORMAT_R32G32_SFLOAT ->
      2 * 4
    Vulkan.VK_FORMAT_R8G8B8A8_UINT ->
      4 * 1

attributeDescriptions :: Int -> VertexFormat v -> [ Vulkan.VkVertexInputAttributeDescription ]
attributeDescriptions binding ( VertexFormat (Const components) ) =
  getZipList
    ( toAttributeDescription
        <$> ZipList components
        <*> ZipList (scanl (+) 0 (map componentSize components))
        <*> ZipList [0..]
    )

  where
    toAttributeDescription :: Component -> Int -> Int -> Vulkan.VkVertexInputAttributeDescription
    toAttributeDescription (Component format) offset location=
      Vulkan.createVk
        (  set @"location" (fromIntegral location)
        &* set @"binding" (fromIntegral binding)
        &* set @"format" format
        &* set @"offset" (fromIntegral offset)
        )
