{-# LANGUAGE DuplicateRecordFields, LambdaCase #-}

module Graphics.Haskan.Vulkan.Texture
  ( readImageFromFile,
    decodeImageBytes,
    managedTexture,
    managedTexture3D,
    managedTexture3DWithMips,
    managedSampler,
    managedSamplerNearest,
    managedSamplerWithLod,
    createSamplerWithLod,
    createTextureResource,
    textureImageView,
    generateGridTexture,
    generateCheckerboardTexture,
    createTextureFromData,
    createTextureFromDataSRGB,
    createTextureFromHalfFloatData,
    createTerrainElevationTexture,
    createTerrainClimateTexture,
    createStorageImage2D,
    createStorageImage3D,
    createStorageImageCube,
    transitionStorageImageToShaderRead,
    createTextureFromBytesCached,
    decodeTextureCached,
    uploadTexture,
    createTexture2DArray,
    createTexture2DArrayFromHandles,
    createCubemap,
    createCubemapMips,
  )
where

import Codec.Picture
import Control.Monad (forM, when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Bits
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Foldable (for_)
import Data.Int (Int16)
import Data.Vector.Storable qualified
import Data.Vector.Storable qualified as Vector
import Data.Word (Word32, Word8)
import Foreign.Storable (Storable)
import Graphics.Haskan.Assets.Cache (AssetCache)
import Graphics.Haskan.Assets.InternalFormat (InternalTexture (..), TextureMetadata (..))
import Graphics.Haskan.Assets.TexturePreprocessor
  ( TextureConfig,
    defaultTextureConfig,
    loadTextureBytesCached,
    loadTextureCached,
    resizeImage,
  )
import Graphics.Haskan.Logger (LogCategory (..), logDebugIO, showT)
import Graphics.Haskan.Resources (alloc, allocaAndPeek, allocaAndPeek_, throwVkResult)
import Graphics.Haskan.Vulkan.Buffer qualified as Haskan
import Graphics.Haskan.Vulkan.CommandBuffer qualified as Haskan
import Graphics.Haskan.Vulkan.ImageView qualified as Haskan
import Graphics.Haskan.Vulkan.Memory qualified as Haskan
import Graphics.Haskan.Vulkan.Resources
import Graphics.Haskan.Vulkan.Types (VulkanContext (..))
import Vulkan qualified as Vk26
import Vulkan.CStruct.Extends (SomeStruct(..))
import Vulkan.Zero (zero)
import Data.Vector qualified as V

readImageFromFile ::
  (MonadIO m) =>
  FilePath ->
  m (Data.Vector.Storable.Vector Word8, Int, Int)
readImageFromFile filePath = do
  image <-
    liftIO $
      readImageWithMetadata filePath
        >>= \case
          Right (dynamicImage, imageMetadata) -> pure (convertRGBA8 dynamicImage)
          Left e -> error e

  let (Image width height imageData) = image
  pure (imageData, width, height)

-- | Decode image bytes (PNG/JPEG) to RGBA8 pixel data.
decodeImageBytes ::
  (MonadIO m) =>
  ByteString ->
  m (Data.Vector.Storable.Vector Word8, Int, Int)
decodeImageBytes bs = do
  image <- case decodeImage bs of
    Right dynamicImage -> pure (convertRGBA8 dynamicImage)
    Left e -> error e

  let (Image width height imageData) = image
  pure (imageData, width, height)

managedTexture ::
  (MonadManaged m) =>
  VulkanContext ->
  FilePath ->
  m Vk26.ImageView
managedTexture vc filePath = do
  let dev = vcDevice vc
      pdev = vcPhysicalDevice vc
      queue = vcQueue vc
      commandBuffer = vcCommandBuffer vc
  (imgData, width, height) <- liftIO (readImageFromFile filePath)
  let dataList = Vector.toList imgData

  (stagingBuffer, stagingMemoryRequirement) <-
    Haskan.managedBuffer dev dataList Vk26.BUFFER_USAGE_TRANSFER_SRC_BIT

  stagingMemory <-
    Haskan.managedBufferMemory pdev dev stagingMemoryRequirement

  liftIO $ do
    Haskan.bindBufferMemory dev stagingBuffer stagingMemory dataList
    Haskan.copyDataToDeviceMemory dev stagingMemory dataList

  let format = Vk26.FORMAT_R8G8B8A8_UNORM
      imageExtent =
        Vk26.Extent3D (fromIntegral width) (fromIntegral height) 1
      createInfo =
        Vk26.ImageCreateInfo
                  { next = ()
                  , imageType = Vk26.IMAGE_TYPE_2D
                  , extent = imageExtent
                  , mipLevels = 1
                  , arrayLayers = 1
                  , format = format
                  , tiling = Vk26.IMAGE_TILING_OPTIMAL
                  , initialLayout = Vk26.IMAGE_LAYOUT_UNDEFINED
                  , usage = (Vk26.IMAGE_USAGE_TRANSFER_DST_BIT .|. Vk26.IMAGE_USAGE_SAMPLED_BIT)
                  , sharingMode = Vk26.SHARING_MODE_EXCLUSIVE
                  , samples = Vk26.SAMPLE_COUNT_1_BIT
                  , flags = zero
                  , queueFamilyIndices = V.empty
                  }

  image <-
    alloc
      "texture image"
      (Vk26.createImage dev createInfo Nothing)
      (\ptr -> Vk26.destroyImage dev ptr Nothing)

  imageMemoryRequirements <- liftIO $ Vk26.getImageMemoryRequirements dev image

  imageMemory <-
    Haskan.managedMemoryFor pdev dev imageMemoryRequirements [Vk26.MEMORY_PROPERTY_DEVICE_LOCAL_BIT]

  bindImageMemory dev image imageMemory 0

  Haskan.withCommandBufferOneTime queue commandBuffer $ do
    Haskan.layerTransition
      commandBuffer
      image
      Vk26.IMAGE_LAYOUT_UNDEFINED
      Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL

    Haskan.copyBufferToImage
      commandBuffer
      stagingBuffer
      image
      (fromIntegral width)
      (fromIntegral height)

    Haskan.layerTransition
      commandBuffer
      image
      Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
      Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL

    liftIO $ Vk26.queueWaitIdle queue
  Haskan.managedImageView dev format image

-- | Load a 3D texture from raw binary RGBA8 data.
-- Dimensions are width x height x depth, each pixel is 4 bytes (RGBA).
managedTexture3D ::
  (MonadManaged m) =>
  VulkanContext ->
  -- | Path to raw binary file
  FilePath ->
  -- | Width
  Int ->
  -- | Height
  Int ->
  -- | Depth
  Int ->
  m Vk26.ImageView
managedTexture3D vc filePath width height depth = do
  let dev = vcDevice vc
      pdev = vcPhysicalDevice vc
      queue = vcQueue vc
      commandBuffer = vcCommandBuffer vc
  imgData <- liftIO $ BS.readFile filePath
  let dataList = BS.unpack imgData
      expectedSize = width * height * depth * 4
      actualSize = BS.length imgData
  when (actualSize /= expectedSize) $
    error $
      "managedTexture3D: expected " ++ show expectedSize ++ " bytes, got " ++ show actualSize

  (stagingBuffer, stagingMemoryRequirement) <-
    Haskan.managedBuffer dev dataList Vk26.BUFFER_USAGE_TRANSFER_SRC_BIT

  stagingMemory <-
    Haskan.managedBufferMemory pdev dev stagingMemoryRequirement

  liftIO $ do
    Haskan.bindBufferMemory dev stagingBuffer stagingMemory dataList
    Haskan.copyDataToDeviceMemory dev stagingMemory dataList

  let format = Vk26.FORMAT_R8G8B8A8_UNORM
      imageExtent =
        Vk26.Extent3D (fromIntegral width) (fromIntegral height) (fromIntegral depth)
      createInfo =
        Vk26.ImageCreateInfo
                  { next = ()
                  , imageType = Vk26.IMAGE_TYPE_2D
                  , extent = imageExtent
                  , mipLevels = 1
                  , arrayLayers = 1
                  , format = format
                  , tiling = Vk26.IMAGE_TILING_OPTIMAL
                  , initialLayout = Vk26.IMAGE_LAYOUT_UNDEFINED
                  , usage = (Vk26.IMAGE_USAGE_TRANSFER_DST_BIT .|. Vk26.IMAGE_USAGE_SAMPLED_BIT)
                  , sharingMode = Vk26.SHARING_MODE_EXCLUSIVE
                  , samples = Vk26.SAMPLE_COUNT_1_BIT
                  , flags = zero
                  , queueFamilyIndices = V.empty
                  }

  image <-
    alloc
      "texture 3D image"
      (Vk26.createImage dev createInfo Nothing)
      (\ptr -> Vk26.destroyImage dev ptr Nothing)

  imageMemoryRequirements <- liftIO $ Vk26.getImageMemoryRequirements dev image

  imageMemory <-
    Haskan.managedMemoryFor pdev dev imageMemoryRequirements [Vk26.MEMORY_PROPERTY_DEVICE_LOCAL_BIT]

  bindImageMemory dev image imageMemory 0

  Haskan.withCommandBufferOneTime queue commandBuffer $ do
    Haskan.layerTransition
      commandBuffer
      image
      Vk26.IMAGE_LAYOUT_UNDEFINED
      Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL

    Haskan.copyBufferToImage3D
      commandBuffer
      stagingBuffer
      image
      (fromIntegral width)
      (fromIntegral height)
      (fromIntegral depth)

    Haskan.layerTransition
      commandBuffer
      image
      Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
      Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL

    liftIO $ Vk26.queueWaitIdle queue
  Haskan.managedImageView3D dev format image

managedTexture3DWithMips ::
  (MonadManaged m) =>
  VulkanContext ->
  -- | Path to raw binary file
  FilePath ->
  -- | Width
  Int ->
  -- | Height
  Int ->
  -- | Depth
  Int ->
  -- | Mip level count
  Int ->
  m Vk26.ImageView
managedTexture3DWithMips vc filePath width height depth mipLevels = do
  let dev = vcDevice vc
      pdev = vcPhysicalDevice vc
      queue = vcQueue vc
      commandBuffer = vcCommandBuffer vc
  imgData <- liftIO $ BS.readFile filePath
  let dataList = BS.unpack imgData
      expectedSize = width * height * depth * 4
      actualSize = BS.length imgData
  when (actualSize /= expectedSize) $
    error $
      "managedTexture3DWithMips: expected " ++ show expectedSize ++ " bytes, got " ++ show actualSize

  (stagingBuffer, stagingMemoryRequirement) <-
    Haskan.managedBuffer dev dataList Vk26.BUFFER_USAGE_TRANSFER_SRC_BIT

  stagingMemory <-
    Haskan.managedBufferMemory pdev dev stagingMemoryRequirement

  liftIO $ do
    Haskan.bindBufferMemory dev stagingBuffer stagingMemory dataList
    Haskan.copyDataToDeviceMemory dev stagingMemory dataList

  let format = Vk26.FORMAT_R8G8B8A8_UNORM
      imageExtent =
        Vk26.Extent3D (fromIntegral width) (fromIntegral height) (fromIntegral depth)
      createInfo =
        Vk26.ImageCreateInfo
                  { next = ()
                  , imageType = Vk26.IMAGE_TYPE_3D
                  , extent = imageExtent
                  , mipLevels = (fromIntegral mipLevels)
                  , arrayLayers = 1
                  , format = format
                  , tiling = Vk26.IMAGE_TILING_OPTIMAL
                  , initialLayout = Vk26.IMAGE_LAYOUT_UNDEFINED
                  , usage = (Vk26.IMAGE_USAGE_TRANSFER_SRC_BIT .|. Vk26.IMAGE_USAGE_TRANSFER_DST_BIT .|. Vk26.IMAGE_USAGE_SAMPLED_BIT)
                  , sharingMode = Vk26.SHARING_MODE_EXCLUSIVE
                  , samples = Vk26.SAMPLE_COUNT_1_BIT
                  , flags = zero
                  , queueFamilyIndices = V.empty
                  }

  image <-
    alloc
      "texture 3D image"
      (Vk26.createImage dev createInfo Nothing)
      (\ptr -> Vk26.destroyImage dev ptr Nothing)

  imageMemoryRequirements <- liftIO $ Vk26.getImageMemoryRequirements dev image

  imageMemory <-
    Haskan.managedMemoryFor pdev dev imageMemoryRequirements [Vk26.MEMORY_PROPERTY_DEVICE_LOCAL_BIT]

  bindImageMemory dev image imageMemory 0

  Haskan.withCommandBufferOneTime queue commandBuffer $ do
    Haskan.mipLayerTransition
      commandBuffer
      image
      Vk26.IMAGE_LAYOUT_UNDEFINED
      Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
      0
      1
      1

    Haskan.copyBufferToImage3D
      commandBuffer
      stagingBuffer
      image
      (fromIntegral width)
      (fromIntegral height)
      (fromIntegral depth)

    -- Generate mipmaps
    for_ [1 .. mipLevels - 1] $ \mip -> do
      let srcMip = fromIntegral (mip - 1)
          dstMip = fromIntegral mip
          srcW = fromIntegral (width `div` (2 ^ (mip - 1)))
          srcH = fromIntegral (height `div` (2 ^ (mip - 1)))
          srcD = fromIntegral (depth `div` (2 ^ (mip - 1)))
          dstW = fromIntegral (width `div` (2 ^ mip))
          dstH = fromIntegral (height `div` (2 ^ mip))
          dstD = fromIntegral (depth `div` (2 ^ mip))
          srcOldLayout =
            if mip == 1
              then Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
              else Vk26.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL

      Haskan.mipLayerTransition
        commandBuffer
        image
        srcOldLayout
        Vk26.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
        srcMip
        1
        1

      Haskan.mipLayerTransition
        commandBuffer
        image
        Vk26.IMAGE_LAYOUT_UNDEFINED
        Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
        dstMip
        1
        1

      Haskan.cmdBlitImage3DMip
        commandBuffer
        image
        srcMip
        dstMip
        srcW
        srcH
        srcD
        dstW
        dstH
        dstD

      Haskan.mipLayerTransition
        commandBuffer
        image
        Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
        Vk26.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
        dstMip
        1
        1

    Haskan.mipLayerTransition
      commandBuffer
      image
      Vk26.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
      Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
      0
      (fromIntegral mipLevels)
      1

    liftIO $ Vk26.queueWaitIdle queue
  Haskan.managedImageView3DMips dev format image (fromIntegral mipLevels)

bindImageMemory ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.Image ->
  Vk26.DeviceMemory ->
  Vk26.DeviceSize ->
  m ()
bindImageMemory dev image memory offset = liftIO $ Vk26.bindImageMemory dev image memory offset
managedSampler ::
  (MonadManaged m) =>
  Vk26.Device ->
  m Vk26.Sampler
managedSampler dev =
  alloc
    "Sampler"
    (createSampler dev)
    (\ptr -> Vk26.destroySampler dev ptr Nothing)

createSampler ::
  (MonadIO m) =>
  Vk26.Device ->
  m Vk26.Sampler
createSampler dev =
  let createInfo =
        Vk26.SamplerCreateInfo
                  { next = ()
                  , flags = zero
                  , magFilter = Vk26.FILTER_LINEAR
                  , minFilter = Vk26.FILTER_LINEAR
                  , addressModeU = Vk26.SAMPLER_ADDRESS_MODE_REPEAT
                  , addressModeV = Vk26.SAMPLER_ADDRESS_MODE_REPEAT
                  , addressModeW = Vk26.SAMPLER_ADDRESS_MODE_REPEAT
                  , anisotropyEnable = False
                  , maxAnisotropy = 1.0
                  , borderColor = Vk26.BORDER_COLOR_INT_OPAQUE_BLACK
                  , unnormalizedCoordinates = False
                  , compareEnable = False
                  , compareOp = Vk26.COMPARE_OP_ALWAYS
                  , mipmapMode = Vk26.SAMPLER_MIPMAP_MODE_LINEAR
                  , mipLodBias = 0.0
                  , minLod = 0.0
                  , maxLod = 0.0
                  }
   in liftIO $ Vk26.createSampler dev createInfo Nothing

createSamplerWithLod ::
  (MonadIO m) =>
  Vk26.Device ->
  -- | max LOD
  Float ->
  m Vk26.Sampler
createSamplerWithLod dev maxLod =
  let createInfo =
        Vk26.SamplerCreateInfo
                  { next = ()
                  , flags = zero
                  , magFilter = Vk26.FILTER_LINEAR
                  , minFilter = Vk26.FILTER_LINEAR
                  , addressModeU = Vk26.SAMPLER_ADDRESS_MODE_REPEAT
                  , addressModeV = Vk26.SAMPLER_ADDRESS_MODE_REPEAT
                  , addressModeW = Vk26.SAMPLER_ADDRESS_MODE_REPEAT
                  , anisotropyEnable = False
                  , maxAnisotropy = 1.0
                  , borderColor = Vk26.BORDER_COLOR_INT_OPAQUE_BLACK
                  , unnormalizedCoordinates = False
                  , compareEnable = False
                  , compareOp = Vk26.COMPARE_OP_ALWAYS
                  , mipmapMode = Vk26.SAMPLER_MIPMAP_MODE_LINEAR
                  , mipLodBias = 0.0
                  , minLod = 0.0
                  , maxLod = maxLod
                  }
    in liftIO $ Vk26.createSampler dev createInfo Nothing

managedSamplerNearest ::
  (MonadManaged m) =>
  Vk26.Device ->
  m Vk26.Sampler
managedSamplerNearest dev =
  alloc
    "SamplerNearest"
    (createSamplerNearest dev)
    (\ptr -> Vk26.destroySampler dev ptr Nothing)

managedSamplerWithLod ::
  (MonadManaged m) =>
  Vk26.Device ->
  Float ->
  m Vk26.Sampler
managedSamplerWithLod dev maxLod =
  alloc
    "SamplerWithLod"
    (createSamplerWithLod dev maxLod)
    (\ptr -> Vk26.destroySampler dev ptr Nothing)

createSamplerNearest ::
  (MonadIO m) =>
  Vk26.Device ->
  m Vk26.Sampler
createSamplerNearest dev =
  let createInfo =
        Vk26.SamplerCreateInfo
                  { next = ()
                  , flags = zero
                  , magFilter = Vk26.FILTER_NEAREST
                  , minFilter = Vk26.FILTER_NEAREST
                  , addressModeU = Vk26.SAMPLER_ADDRESS_MODE_REPEAT
                  , addressModeV = Vk26.SAMPLER_ADDRESS_MODE_REPEAT
                  , addressModeW = Vk26.SAMPLER_ADDRESS_MODE_REPEAT
                  , anisotropyEnable = False
                  , maxAnisotropy = 1.0
                  , borderColor = Vk26.BORDER_COLOR_INT_OPAQUE_BLACK
                  , unnormalizedCoordinates = False
                  , compareEnable = False
                  , compareOp = Vk26.COMPARE_OP_ALWAYS
                  , mipmapMode = Vk26.SAMPLER_MIPMAP_MODE_NEAREST
                  , mipLodBias = 0.0
                  , minLod = 0.0
                  , maxLod = 0.0
                  }
    in liftIO $ Vk26.createSampler dev createInfo Nothing

-- | Shared texture upload logic: staging buffer -> image -> imageView -> register.
uploadTextureWithFormat ::
  (MonadManaged m, MonadIO m) =>
  ResourceManager ->
  VulkanContext ->
  Int ->
  Int ->
  Data.Vector.Storable.Vector Word8 ->
  Vk26.Format ->
  m TextureHandle
uploadTextureWithFormat rm vc width height imgData format = do
  let dataList = Vector.toList imgData
      dev = vcDevice vc
      pdev = vcPhysicalDevice vc
      queue = vcQueue vc
      commandBuffer = vcCommandBuffer vc

  (stagingBuffer, stagingMemoryRequirement) <-
    Haskan.managedBuffer dev dataList Vk26.BUFFER_USAGE_TRANSFER_SRC_BIT

  stagingMemory <-
    Haskan.managedBufferMemory pdev dev stagingMemoryRequirement

  liftIO $ do
    Haskan.bindBufferMemory dev stagingBuffer stagingMemory dataList
    Haskan.copyDataToDeviceMemory dev stagingMemory dataList

  let imageExtent =
        Vk26.Extent3D (fromIntegral width) (fromIntegral height) 1
      createInfo =
        Vk26.ImageCreateInfo
                  { next = ()
                  , imageType = Vk26.IMAGE_TYPE_2D
                  , extent = imageExtent
                  , mipLevels = 1
                  , arrayLayers = 1
                  , format = format
                  , tiling = Vk26.IMAGE_TILING_OPTIMAL
                  , initialLayout = Vk26.IMAGE_LAYOUT_UNDEFINED
                  , usage = (Vk26.IMAGE_USAGE_TRANSFER_DST_BIT .|. Vk26.IMAGE_USAGE_SAMPLED_BIT)
                  , sharingMode = Vk26.SHARING_MODE_EXCLUSIVE
                  , samples = Vk26.SAMPLE_COUNT_1_BIT
                  , flags = zero
                  , queueFamilyIndices = V.empty
                  }

  image <- liftIO $ Vk26.createImage dev createInfo Nothing

  imageMemoryRequirements <- liftIO $ Vk26.getImageMemoryRequirements dev image
  logDebugIO LogTexture $ "texture image memory requirements size=" <> showT ((\(Vk26.MemoryRequirements size _ _) -> size) imageMemoryRequirements) <> " width=" <> showT width <> " height=" <> showT height

  imageMemory <-
    Haskan.allocateMemoryFor pdev dev imageMemoryRequirements [Vk26.MEMORY_PROPERTY_DEVICE_LOCAL_BIT]

  liftIO $ bindImageMemory dev image imageMemory 0

  Haskan.withCommandBufferOneTime queue commandBuffer $ do
    Haskan.layerTransition
      commandBuffer
      image
      Vk26.IMAGE_LAYOUT_UNDEFINED
      Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL

    Haskan.copyBufferToImage
      commandBuffer
      stagingBuffer
      image
      (fromIntegral width)
      (fromIntegral height)

    Haskan.layerTransition
      commandBuffer
      image
      Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
      Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL

    liftIO $ Vk26.queueWaitIdle queue
  imageView <- Haskan.createImageView dev format image

  texH <- TextureHandle <$> allocHandle (rmNextId rm)

  let destroy = do
        Vk26.destroyImageView dev imageView Nothing
        Vk26.destroyImage dev image Nothing
        Vk26.freeMemory dev imageMemory Nothing

      resource =
        TextureResource
          { trHandle = texH,
            trImage = image,
            trImageView = imageView,
            trMemory = imageMemory,
            trWidth = width,
            trHeight = height,
            trPixelData = Just imgData,
            trDestroy = destroy
          }

  registerTexture rm resource
  pure texH

uploadTextureSRGB ::
  (MonadManaged m, MonadIO m) =>
  ResourceManager ->
  VulkanContext ->
  Int ->
  Int ->
  Data.Vector.Storable.Vector Word8 ->
  m TextureHandle
uploadTextureSRGB rm vc width height imgData =
  uploadTextureWithFormat rm vc width height imgData Vk26.FORMAT_R8G8B8A8_SRGB

createTextureFromDataSRGB ::
  (MonadManaged m, MonadIO m) =>
  ResourceManager ->
  VulkanContext ->
  Int ->
  Int ->
  Data.Vector.Storable.Vector Word8 ->
  m TextureHandle
createTextureFromDataSRGB = uploadTextureSRGB

uploadTexture ::
  (MonadManaged m, MonadIO m) =>
  ResourceManager ->
  VulkanContext ->
  Int ->
  Int ->
  Data.Vector.Storable.Vector Word8 ->
  m TextureHandle
uploadTexture rm vc width height imgData =
  uploadTextureWithFormat rm vc width height imgData Vk26.FORMAT_R8G8B8A8_UNORM

createTextureFromHalfFloatData ::
  (MonadManaged m, MonadIO m) =>
  ResourceManager ->
  VulkanContext ->
  Int ->
  Int ->
  Data.Vector.Storable.Vector Word8 ->
  m TextureHandle
createTextureFromHalfFloatData rm vc width height imgData =
  uploadTextureWithFormat rm vc width height imgData Vk26.FORMAT_R16G16B16A16_SFLOAT

uploadTextureWithFormatVector ::
  (MonadManaged m, MonadIO m, Storable a) =>
  ResourceManager ->
  VulkanContext ->
  Int ->
  Int ->
  Vector.Vector a ->
  Vk26.Format ->
  m TextureHandle
uploadTextureWithFormatVector rm vc width height imgData format = do
  let dataList = Vector.toList imgData
      dev = vcDevice vc
      pdev = vcPhysicalDevice vc
      queue = vcQueue vc
      commandBuffer = vcCommandBuffer vc

  (stagingBuffer, stagingMemoryRequirement) <-
    Haskan.managedBuffer dev dataList Vk26.BUFFER_USAGE_TRANSFER_SRC_BIT

  stagingMemory <-
    Haskan.managedBufferMemory pdev dev stagingMemoryRequirement

  liftIO $ do
    Haskan.bindBufferMemory dev stagingBuffer stagingMemory dataList
    Haskan.copyDataToDeviceMemory dev stagingMemory dataList

  let imageExtent =
        Vk26.Extent3D (fromIntegral width) (fromIntegral height) 1
      createInfo =
        Vk26.ImageCreateInfo
                  { next = ()
                  , imageType = Vk26.IMAGE_TYPE_2D
                  , extent = imageExtent
                  , mipLevels = 1
                  , arrayLayers = 1
                  , format = format
                  , tiling = Vk26.IMAGE_TILING_OPTIMAL
                  , initialLayout = Vk26.IMAGE_LAYOUT_UNDEFINED
                  , usage = (Vk26.IMAGE_USAGE_TRANSFER_DST_BIT .|. Vk26.IMAGE_USAGE_SAMPLED_BIT)
                  , sharingMode = Vk26.SHARING_MODE_EXCLUSIVE
                  , samples = Vk26.SAMPLE_COUNT_1_BIT
                  , flags = zero
                  , queueFamilyIndices = V.empty
                  }

  image <- liftIO $ Vk26.createImage dev createInfo Nothing

  imageMemoryRequirements <- liftIO $ Vk26.getImageMemoryRequirements dev image

  imageMemory <-
    Haskan.allocateMemoryFor pdev dev imageMemoryRequirements [Vk26.MEMORY_PROPERTY_DEVICE_LOCAL_BIT]

  liftIO $ bindImageMemory dev image imageMemory 0

  Haskan.withCommandBufferOneTime queue commandBuffer $ do
    Haskan.layerTransition
      commandBuffer
      image
      Vk26.IMAGE_LAYOUT_UNDEFINED
      Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL

    Haskan.copyBufferToImage
      commandBuffer
      stagingBuffer
      image
      (fromIntegral width)
      (fromIntegral height)

    Haskan.layerTransition
      commandBuffer
      image
      Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
      Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL

    liftIO $ Vk26.queueWaitIdle queue
  imageView <- Haskan.createImageView dev format image

  texH <- TextureHandle <$> allocHandle (rmNextId rm)

  let destroy = do
        Vk26.destroyImageView dev imageView Nothing
        Vk26.destroyImage dev image Nothing
        Vk26.freeMemory dev imageMemory Nothing

      resource =
        TextureResource
          { trHandle = texH,
            trImage = image,
            trImageView = imageView,
            trMemory = imageMemory,
            trWidth = width,
            trHeight = height,
            trPixelData = Nothing,
            trDestroy = destroy
          }

  registerTexture rm resource
  pure texH

createTerrainElevationTexture ::
  (MonadManaged m, MonadIO m) =>
  ResourceManager ->
  VulkanContext ->
  Int ->
  Int ->
  Vector.Vector Int16 ->
  m TextureHandle
createTerrainElevationTexture rm vc width height vec =
  uploadTextureWithFormatVector rm vc width height vec Vk26.FORMAT_R16_SNORM

createTerrainClimateTexture ::
  (MonadManaged m, MonadIO m) =>
  ResourceManager ->
  VulkanContext ->
  Int ->
  Int ->
  Vector.Vector Float ->
  m TextureHandle
createTerrainClimateTexture rm vc width height vec =
  uploadTextureWithFormatVector rm vc width height vec Vk26.FORMAT_R32G32B32A32_SFLOAT

-- | Create and register a texture resource from file, using asset cache.
createTextureResource ::
  (MonadManaged m, MonadIO m) =>
  ResourceManager ->
  VulkanContext ->
  AssetCache ->
  FilePath ->
  m TextureHandle
createTextureResource rm vc cache filePath = do
  result <- loadTextureCached cache filePath defaultTextureConfig
  case result of
    Left err -> error $ "createTextureResource: " <> err
    Right (InternalTexture meta imgData) ->
      uploadTexture rm vc (itmWidth meta) (itmHeight meta) imgData

-- | Create and register a texture from raw RGBA8 pixel data.
createTextureFromData ::
  (MonadManaged m, MonadIO m) =>
  ResourceManager ->
  VulkanContext ->
  Int ->
  Int ->
  Data.Vector.Storable.Vector Word8 ->
  m TextureHandle
createTextureFromData = uploadTexture

-- | Create and register a texture from raw bytes, using asset cache.
createTextureFromBytesCached ::
  (MonadManaged m, MonadIO m) =>
  ResourceManager ->
  VulkanContext ->
  AssetCache ->
  ByteString ->
  m TextureHandle
createTextureFromBytesCached rm vc cache rawBytes = do
  result <- loadTextureBytesCached cache rawBytes defaultTextureConfig
  case result of
    Left err -> error $ "createTextureFromBytesCached: " <> err
    Right (InternalTexture meta imgData) ->
      uploadTexture rm vc (itmWidth meta) (itmHeight meta) imgData

-- | Decode texture bytes using asset cache, returning dimensions and pixel data.
-- Does NOT upload to GPU.
decodeTextureCached ::
  (MonadIO m) =>
  AssetCache ->
  ByteString ->
  m (Either String (Int, Int, Data.Vector.Storable.Vector Word8))
decodeTextureCached cache rawBytes = liftIO $ do
  result <- loadTextureBytesCached cache rawBytes defaultTextureConfig
  case result of
    Left err -> pure (Left err)
    Right (InternalTexture meta imgData) -> pure (Right (itmWidth meta, itmHeight meta, imgData))

-- | Resolve a texture handle to its VkImageView.
textureImageView :: (MonadIO m) => ResourceManager -> TextureHandle -> m (Maybe Vk26.ImageView)
textureImageView rm handle = do
  mTex <- lookupTexture rm handle
  pure $ fmap trImageView mTex

-- | Generate a procedural checkerboard texture as RGBA8 pixel data.
-- Checker pattern with given square size in pixels.
generateCheckerboardTexture :: Int -> Int -> Int -> Data.Vector.Storable.Vector Word8
generateCheckerboardTexture width height squareSize =
  Data.Vector.Storable.generate (width * height * 4) $ \idx ->
    let pixel = idx `div` 4
        x = pixel `mod` width
        y = pixel `div` width
        sqX = x `div` squareSize
        sqY = y `div` squareSize
        isWhite = even (sqX + sqY)
     in case idx `mod` 4 of
          0 -> if isWhite then 220 else 40 -- R
          1 -> if isWhite then 220 else 40 -- G
          2 -> if isWhite then 220 else 40 -- B
          _ -> 255 -- A

-- | Generate a procedural grid texture as RGBA8 pixel data.
-- Dark gray background with lighter gray grid lines every `spacing` pixels.
generateGridTexture :: Int -> Int -> Int -> Data.Vector.Storable.Vector Word8
generateGridTexture width height spacing =
  Data.Vector.Storable.generate (width * height * 4) $ \idx ->
    let pixel = idx `div` 4
        x = pixel `mod` width
        y = pixel `div` width
        onGrid = (x `mod` spacing == 0) || (y `mod` spacing == 0)
        majorGrid = (x `mod` (spacing * 5) == 0) || (y `mod` (spacing * 5) == 0)
     in case idx `mod` 4 of
          0 -> if majorGrid then 180 else if onGrid then 120 else 64 -- R
          1 -> if majorGrid then 180 else if onGrid then 120 else 64 -- G
          2 -> if majorGrid then 180 else if onGrid then 120 else 64 -- B
          _ -> 255 -- A

-- | Create a 2D texture array from multiple RGBA8 textures.
-- All textures must have the same width and height.
createTexture2DArray ::
  (MonadManaged m, MonadIO m) =>
  ResourceManager ->
  VulkanContext ->
  -- | width
  Int ->
  -- | height
  Int ->
  -- | one per layer
  [Data.Vector.Storable.Vector Word8] ->
  m TextureHandle
createTexture2DArray rm vc width height layers = do
  let dev = vcDevice vc
      pdev = vcPhysicalDevice vc
      queue = vcQueue vc
      commandBuffer = vcCommandBuffer vc
      numLayers = length layers
      layerSize = width * height * 4
      allData = Vector.toList $ mconcat layers

  -- Staging buffer
  (stagingBuffer, stagingMemoryRequirement) <-
    Haskan.managedBuffer dev allData Vk26.BUFFER_USAGE_TRANSFER_SRC_BIT

  stagingMemory <-
    Haskan.managedBufferMemory pdev dev stagingMemoryRequirement

  liftIO $ do
    Haskan.bindBufferMemory dev stagingBuffer stagingMemory allData
    Haskan.copyDataToDeviceMemory dev stagingMemory allData

  let format = Vk26.FORMAT_R8G8B8A8_UNORM
      imageExtent =
        Vk26.Extent3D (fromIntegral width) (fromIntegral height) 1
      createInfo =
        Vk26.ImageCreateInfo
                  { next = ()
                  , imageType = Vk26.IMAGE_TYPE_2D
                  , extent = imageExtent
                  , mipLevels = 1
                  , arrayLayers = (fromIntegral numLayers)
                  , format = format
                  , tiling = Vk26.IMAGE_TILING_OPTIMAL
                  , initialLayout = Vk26.IMAGE_LAYOUT_UNDEFINED
                  , usage = (Vk26.IMAGE_USAGE_TRANSFER_DST_BIT .|. Vk26.IMAGE_USAGE_SAMPLED_BIT)
                  , sharingMode = Vk26.SHARING_MODE_EXCLUSIVE
                  , samples = Vk26.SAMPLE_COUNT_1_BIT
                  , flags = zero
                  , queueFamilyIndices = V.empty
                  }

  image <- liftIO $ Vk26.createImage dev createInfo Nothing

  imageMemoryRequirements <- liftIO $ Vk26.getImageMemoryRequirements dev image
  logDebugIO LogTexture $ "texture2DArray image memory requirements size=" <> showT ((\(Vk26.MemoryRequirements size _ _) -> size) imageMemoryRequirements) <> " layers=" <> showT numLayers <> " width=" <> showT width <> " height=" <> showT height

  imageMemory <-
    Haskan.allocateMemoryFor pdev dev imageMemoryRequirements [Vk26.MEMORY_PROPERTY_DEVICE_LOCAL_BIT]

  liftIO $ bindImageMemory dev image imageMemory 0

  Haskan.withCommandBufferOneTime queue commandBuffer $ do
    Haskan.layerTransitionAll
      commandBuffer
      image
      Vk26.IMAGE_LAYOUT_UNDEFINED
      Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
      (fromIntegral numLayers)

    for_ (zip [0 ..] layers) $ \(layerIdx, _) -> do
      let offset = fromIntegral (layerIdx * layerSize)
      Haskan.copyBufferToImageLayer
        commandBuffer
        stagingBuffer
        image
        (fromIntegral width)
        (fromIntegral height)
        (fromIntegral layerIdx)
        offset

    Haskan.layerTransitionAll
      commandBuffer
      image
      Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
      Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
      (fromIntegral numLayers)

    liftIO $ Vk26.queueWaitIdle queue
  imageView <- Haskan.createImageView2DArray dev format image (fromIntegral numLayers)

  texH <- TextureHandle <$> allocHandle (rmNextId rm)

  let destroy = do
        Vk26.destroyImageView dev imageView Nothing
        Vk26.destroyImage dev image Nothing
        Vk26.freeMemory dev imageMemory Nothing

      resource =
        TextureResource
          { trHandle = texH,
            trImage = image,
            trImageView = imageView,
            trMemory = imageMemory,
            trWidth = width,
            trHeight = height,
            trPixelData = Nothing, -- GPU-only array, no CPU pixel data stored
            trDestroy = destroy
          }

  registerTexture rm resource
  pure texH

-- | Create a Texture2DArray from a list of existing texture handles.
-- All textures are resized to the target dimensions using bilinear sampling.
createTexture2DArrayFromHandles ::
  (MonadManaged m, MonadIO m) =>
  ResourceManager ->
  VulkanContext ->
  -- | target width
  Int ->
  -- | target height
  Int ->
  -- | texture handles (will be resized to target size)
  [TextureHandle] ->
  m TextureHandle
createTexture2DArrayFromHandles rm vc targetW targetH handles = do
  let resizePixels w h srcW srcH srcPixels
        | w == srcW && h == srcH = srcPixels
        | otherwise =
            let img :: Image PixelRGBA8
                img = Image srcW srcH srcPixels
                resized = resizeImage img w h
             in imageData resized

  layers <- forM handles $ \h -> do
    mTex <- liftIO $ lookupTexture rm h
    case mTex of
      Nothing -> do
        logDebugIO LogTexture $ "bindless: missing texture " <> showT h <> ", using checkerboard"
        pure $ generateCheckerboardTexture targetW targetH 32
      Just tex -> do
        case trPixelData tex of
          Just pixels -> pure $ resizePixels targetW targetH (trWidth tex) (trHeight tex) pixels
          Nothing -> do
            logDebugIO LogTexture $ "bindless: no CPU pixels for texture " <> showT h
            pure $ generateCheckerboardTexture targetW targetH 32

  createTexture2DArray rm vc targetW targetH layers

-- | Create a cubemap texture from 6 RGBA8 face images.
-- Faces must be square and all the same size.
-- Order: +X, -X, +Y, -Y, +Z, -Z
createCubemap ::
  (MonadManaged m, MonadIO m) =>
  ResourceManager ->
  VulkanContext ->
  -- | face width/height
  Int ->
  -- | 6 face pixel datas
  [Data.Vector.Storable.Vector Word8] ->
  m TextureHandle
createCubemap rm vc faceSize faces = do
  let dev = vcDevice vc
      pdev = vcPhysicalDevice vc
      queue = vcQueue vc
      commandBuffer = vcCommandBuffer vc
      numFaces = length faces
      facePixelCount = faceSize * faceSize * 4
      allData = Vector.toList $ mconcat faces

  -- Staging buffer (manual alloc, freed after upload)
  (stagingBuffer, stagingMemoryRequirement) <-
    Haskan.createBuffer dev allData Vk26.BUFFER_USAGE_TRANSFER_SRC_BIT

  stagingMemory <-
    Haskan.createBufferMemory pdev dev stagingMemoryRequirement

  liftIO $ do
    Haskan.bindBufferMemory dev stagingBuffer stagingMemory allData
    Haskan.copyDataToDeviceMemory dev stagingMemory allData

  let format = Vk26.FORMAT_R8G8B8A8_UNORM
      imageExtent =
        Vk26.Extent3D (fromIntegral faceSize) (fromIntegral faceSize) 1
      createInfo =
        Vk26.ImageCreateInfo
                  { next = ()
                  , imageType = Vk26.IMAGE_TYPE_2D
                  , extent = imageExtent
                  , mipLevels = 1
                  , arrayLayers = 6
                  , format = format
                  , tiling = Vk26.IMAGE_TILING_OPTIMAL
                  , initialLayout = Vk26.IMAGE_LAYOUT_UNDEFINED
                  , usage = (Vk26.IMAGE_USAGE_TRANSFER_DST_BIT .|. Vk26.IMAGE_USAGE_SAMPLED_BIT)
                  , sharingMode = Vk26.SHARING_MODE_EXCLUSIVE
                  , samples = Vk26.SAMPLE_COUNT_1_BIT
                  , flags = Vk26.IMAGE_CREATE_CUBE_COMPATIBLE_BIT
                  , queueFamilyIndices = V.empty
                  }

  image <- liftIO $ Vk26.createImage dev createInfo Nothing

  imageMemoryRequirements <- liftIO $ Vk26.getImageMemoryRequirements dev image
  logDebugIO LogTexture $ "cubemap image memory requirements size=" <> showT ((\(Vk26.MemoryRequirements size _ _) -> size) imageMemoryRequirements) <> " faceSize=" <> showT faceSize

  imageMemory <-
    Haskan.allocateMemoryFor pdev dev imageMemoryRequirements [Vk26.MEMORY_PROPERTY_DEVICE_LOCAL_BIT]

  liftIO $ bindImageMemory dev image imageMemory 0

  Haskan.withCommandBufferOneTime queue commandBuffer $ do
    Haskan.layerTransitionAll
      commandBuffer
      image
      Vk26.IMAGE_LAYOUT_UNDEFINED
      Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
      6

    for_ (zip [0 ..] faces) $ \(faceIdx, _) -> do
      let offset = fromIntegral (faceIdx * facePixelCount)
      Haskan.copyBufferToImageLayer
        commandBuffer
        stagingBuffer
        image
        (fromIntegral faceSize)
        (fromIntegral faceSize)
        (fromIntegral faceIdx)
        offset

    Haskan.layerTransitionAll
      commandBuffer
      image
      Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
      Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
      6

    liftIO $ Vk26.queueWaitIdle queue

  -- Free staging resources
  liftIO $ do
    Vk26.destroyBuffer dev stagingBuffer Nothing
    Vk26.freeMemory dev stagingMemory Nothing

  imageView <- Haskan.createImageViewCube dev format image

  texH <- TextureHandle <$> allocHandle (rmNextId rm)

  let destroy = do
        Vk26.destroyImageView dev imageView Nothing
        Vk26.destroyImage dev image Nothing
        Vk26.freeMemory dev imageMemory Nothing

      resource =
        TextureResource
          { trHandle = texH,
            trImage = image,
            trImageView = imageView,
            trMemory = imageMemory,
            trWidth = faceSize,
            trHeight = faceSize,
            trPixelData = Nothing,
            trDestroy = destroy
          }

  registerTexture rm resource
  pure texH

-- | Create a mipmapped cubemap texture from 6 RGBA8 face images.
-- Faces must be square and all the same size.
-- Order: +X, -X, +Y, -Y, +Z, -Z
-- Generates mipmaps via vkCmdBlitImage.
createCubemapMips ::
  (MonadManaged m, MonadIO m) =>
  ResourceManager ->
  VulkanContext ->
  -- | face width/height
  Int ->
  -- | 6 face pixel datas
  [Data.Vector.Storable.Vector Word8] ->
  m TextureHandle
createCubemapMips rm vc faceSize faces = do
  let dev = vcDevice vc
      pdev = vcPhysicalDevice vc
      queue = vcQueue vc
      commandBuffer = vcCommandBuffer vc
      numFaces = length faces
      facePixelCount = faceSize * faceSize * 4
      allData = Vector.toList $ mconcat faces
      mipLevels = floor (logBase 2 (fromIntegral faceSize :: Double)) + 1

  -- Staging buffer (manual alloc, freed after upload)
  (stagingBuffer, stagingMemoryRequirement) <-
    Haskan.createBuffer dev allData Vk26.BUFFER_USAGE_TRANSFER_SRC_BIT

  stagingMemory <-
    Haskan.createBufferMemory pdev dev stagingMemoryRequirement

  liftIO $ do
    Haskan.bindBufferMemory dev stagingBuffer stagingMemory allData
    Haskan.copyDataToDeviceMemory dev stagingMemory allData

  let format = Vk26.FORMAT_R8G8B8A8_UNORM
      imageExtent =
        Vk26.Extent3D (fromIntegral faceSize) (fromIntegral faceSize) 1
      createInfo =
        Vk26.ImageCreateInfo
                  { next = ()
                  , imageType = Vk26.IMAGE_TYPE_2D
                  , extent = imageExtent
                  , mipLevels = (fromIntegral mipLevels)
                  , arrayLayers = 6
                  , format = format
                  , tiling = Vk26.IMAGE_TILING_OPTIMAL
                  , initialLayout = Vk26.IMAGE_LAYOUT_UNDEFINED
                  , usage = (Vk26.IMAGE_USAGE_TRANSFER_SRC_BIT .|. Vk26.IMAGE_USAGE_TRANSFER_DST_BIT .|. Vk26.IMAGE_USAGE_SAMPLED_BIT)
                  , sharingMode = Vk26.SHARING_MODE_EXCLUSIVE
                  , samples = Vk26.SAMPLE_COUNT_1_BIT
                  , flags = Vk26.IMAGE_CREATE_CUBE_COMPATIBLE_BIT
                  , queueFamilyIndices = V.empty
                  }

  image <- liftIO $ Vk26.createImage dev createInfo Nothing

  imageMemoryRequirements <- liftIO $ Vk26.getImageMemoryRequirements dev image
  logDebugIO LogTexture $ "cubemapMips image memory requirements size=" <> showT ((\(Vk26.MemoryRequirements size _ _) -> size) imageMemoryRequirements) <> " faceSize=" <> showT faceSize <> " mipLevels=" <> showT mipLevels

  imageMemory <-
    Haskan.allocateMemoryFor pdev dev imageMemoryRequirements [Vk26.MEMORY_PROPERTY_DEVICE_LOCAL_BIT]

  liftIO $ bindImageMemory dev image imageMemory 0

  Haskan.withCommandBufferOneTime queue commandBuffer $ do
    -- Transition all layers of mip 0 to DST optimal
    Haskan.mipLayerTransition
      commandBuffer
      image
      Vk26.IMAGE_LAYOUT_UNDEFINED
      Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
      0
      1
      6

    -- Upload face data to mip 0
    for_ (zip [0 ..] faces) $ \(faceIdx, _) -> do
      let offset = fromIntegral (faceIdx * facePixelCount)
      Haskan.copyBufferToImageLayer
        commandBuffer
        stagingBuffer
        image
        (fromIntegral faceSize)
        (fromIntegral faceSize)
        (fromIntegral faceIdx)
        offset

    -- Generate mipmaps
    for_ [1 .. mipLevels - 1] $ \mip -> do
      let srcMip = fromIntegral (mip - 1)
          dstMip = fromIntegral mip
          srcSize = faceSize `div` (2 ^ (mip - 1))
          dstSize = faceSize `div` (2 ^ mip)
          srcOldLayout =
            if mip == 1
              then Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
              else Vk26.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL

      -- Transition src mip to SRC optimal
      Haskan.mipLayerTransition
        commandBuffer
        image
        srcOldLayout
        Vk26.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
        srcMip
        1
        6

      -- Transition dst mip to DST optimal
      Haskan.mipLayerTransition
        commandBuffer
        image
        Vk26.IMAGE_LAYOUT_UNDEFINED
        Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
        dstMip
        1
        6

      -- Blit all 6 faces
      Haskan.cmdBlitImageCubemapMip
        commandBuffer
        image
        srcMip
        dstMip
        (fromIntegral srcSize)
        (fromIntegral dstSize)

      -- Transition dst mip to SRC optimal for next iteration
      Haskan.mipLayerTransition
        commandBuffer
        image
        Vk26.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
        Vk26.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
        dstMip
        1
        6

    -- Transition all mips to SHADER_READ_ONLY_OPTIMAL
    Haskan.mipLayerTransition
      commandBuffer
      image
      Vk26.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
      Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
      0
      (fromIntegral mipLevels)
      6

    liftIO $ Vk26.queueWaitIdle queue

  -- Free staging resources
  liftIO $ do
    Vk26.destroyBuffer dev stagingBuffer Nothing
    Vk26.freeMemory dev stagingMemory Nothing

  imageView <- Haskan.createImageViewCubeMips dev format image (fromIntegral mipLevels)

  texH <- TextureHandle <$> allocHandle (rmNextId rm)

  let destroy = do
        Vk26.destroyImageView dev imageView Nothing
        Vk26.destroyImage dev image Nothing
        Vk26.freeMemory dev imageMemory Nothing

      resource =
        TextureResource
          { trHandle = texH,
            trImage = image,
            trImageView = imageView,
            trMemory = imageMemory,
            trWidth = faceSize,
            trHeight = faceSize,
            trPixelData = Nothing,
            trDestroy = destroy
          }

  registerTexture rm resource
  pure texH

-- | Create a 2D storage image for compute shader writes and later sampling.
-- Image is transitioned to GENERAL layout for compute writes.
createStorageImage2D ::
  (MonadManaged m, MonadIO m) =>
  ResourceManager ->
  VulkanContext ->
  Int ->
  Int ->
  Vk26.Format ->
  m TextureHandle
createStorageImage2D rm vc width height format = do
  let dev = vcDevice vc
      pdev = vcPhysicalDevice vc
      queue = vcQueue vc
      commandBuffer = vcCommandBuffer vc
      imageExtent =
        Vk26.Extent3D (fromIntegral width) (fromIntegral height) 1
      createInfo =
        Vk26.ImageCreateInfo
                  { next = ()
                  , imageType = Vk26.IMAGE_TYPE_2D
                  , extent = imageExtent
                  , mipLevels = 1
                  , arrayLayers = 1
                  , format = format
                  , tiling = Vk26.IMAGE_TILING_OPTIMAL
                  , initialLayout = Vk26.IMAGE_LAYOUT_UNDEFINED
                  , usage = (Vk26.IMAGE_USAGE_STORAGE_BIT .|. Vk26.IMAGE_USAGE_SAMPLED_BIT)
                  , sharingMode = Vk26.SHARING_MODE_EXCLUSIVE
                  , samples = Vk26.SAMPLE_COUNT_1_BIT
                  , flags = zero
                  , queueFamilyIndices = V.empty
                  }

  image <- liftIO $ Vk26.createImage dev createInfo Nothing

  imageMemoryRequirements <- liftIO $ Vk26.getImageMemoryRequirements dev image
  logDebugIO LogTexture $ "storage image 2D memory requirements size=" <> showT ((\(Vk26.MemoryRequirements size _ _) -> size) imageMemoryRequirements) <> " width=" <> showT width <> " height=" <> showT height

  imageMemory <-
    Haskan.allocateMemoryFor pdev dev imageMemoryRequirements [Vk26.MEMORY_PROPERTY_DEVICE_LOCAL_BIT]

  liftIO $ bindImageMemory dev image imageMemory 0

  -- Transition to GENERAL for compute writes
  Haskan.withCommandBufferOneTime queue commandBuffer $ do
    Haskan.layerTransition
      commandBuffer
      image
      Vk26.IMAGE_LAYOUT_UNDEFINED
      Vk26.IMAGE_LAYOUT_GENERAL

    liftIO $ Vk26.queueWaitIdle queue

  imageView <- Haskan.createImageView dev format image

  texH <- TextureHandle <$> allocHandle (rmNextId rm)

  let destroy = do
        Vk26.destroyImageView dev imageView Nothing
        Vk26.destroyImage dev image Nothing
        Vk26.freeMemory dev imageMemory Nothing

      resource =
        TextureResource
          { trHandle = texH,
            trImage = image,
            trImageView = imageView,
            trMemory = imageMemory,
            trWidth = width,
            trHeight = height,
            trPixelData = Nothing,
            trDestroy = destroy
          }

  registerTexture rm resource
  pure texH

-- | Create a 3D storage image for compute shader writes and later sampling.
-- Image is transitioned to GENERAL layout for compute writes.
-- Includes TRANSFER_SRC and TRANSFER_DST for mipmap generation.
createStorageImage3D ::
  (MonadManaged m, MonadIO m) =>
  ResourceManager ->
  VulkanContext ->
  Int ->
  Int ->
  Int ->
  Int -> -- mip levels
  Vk26.Format ->
  m TextureHandle
createStorageImage3D rm vc width height depth mipLevels format = do
  let dev = vcDevice vc
      pdev = vcPhysicalDevice vc
      queue = vcQueue vc
      commandBuffer = vcCommandBuffer vc
      imageExtent =
        Vk26.Extent3D (fromIntegral width) (fromIntegral height) (fromIntegral depth)
      createInfo =
        Vk26.ImageCreateInfo
                  { next = ()
                  , imageType = Vk26.IMAGE_TYPE_3D
                  , extent = imageExtent
                  , mipLevels = (fromIntegral mipLevels)
                  , arrayLayers = 1
                  , format = format
                  , tiling = Vk26.IMAGE_TILING_OPTIMAL
                  , initialLayout = Vk26.IMAGE_LAYOUT_UNDEFINED
                  , usage = (Vk26.IMAGE_USAGE_STORAGE_BIT .|. Vk26.IMAGE_USAGE_SAMPLED_BIT .|. Vk26.IMAGE_USAGE_TRANSFER_SRC_BIT .|. Vk26.IMAGE_USAGE_TRANSFER_DST_BIT)
                  , sharingMode = Vk26.SHARING_MODE_EXCLUSIVE
                  , samples = Vk26.SAMPLE_COUNT_1_BIT
                  , flags = zero
                  , queueFamilyIndices = V.empty
                  }

  image <- liftIO $ Vk26.createImage dev createInfo Nothing

  imageMemoryRequirements <- liftIO $ Vk26.getImageMemoryRequirements dev image
  logDebugIO LogTexture $ "storage image 3D memory requirements size=" <> showT ((\(Vk26.MemoryRequirements size _ _) -> size) imageMemoryRequirements) <> " width=" <> showT width <> " height=" <> showT height <> " depth=" <> showT depth <> " mips=" <> showT mipLevels

  imageMemory <-
    Haskan.allocateMemoryFor pdev dev imageMemoryRequirements [Vk26.MEMORY_PROPERTY_DEVICE_LOCAL_BIT]

  liftIO $ bindImageMemory dev image imageMemory 0

  -- Transition to GENERAL for compute writes (all mips)
  Haskan.withCommandBufferOneTime queue commandBuffer $ do
    Haskan.mipLayerTransition
      commandBuffer
      image
      Vk26.IMAGE_LAYOUT_UNDEFINED
      Vk26.IMAGE_LAYOUT_GENERAL
      0
      (fromIntegral mipLevels)
      1

    liftIO $ Vk26.queueWaitIdle queue

  imageView <-
    if mipLevels > 1
      then Haskan.createImageView3DMips dev format image (fromIntegral mipLevels)
      else Haskan.createImageView3D dev format image

  texH <- TextureHandle <$> allocHandle (rmNextId rm)

  let destroy = do
        Vk26.destroyImageView dev imageView Nothing
        Vk26.destroyImage dev image Nothing
        Vk26.freeMemory dev imageMemory Nothing

      resource =
        TextureResource
          { trHandle = texH,
            trImage = image,
            trImageView = imageView,
            trMemory = imageMemory,
            trWidth = width,
            trHeight = height,
            trPixelData = Nothing,
            trDestroy = destroy
          }

  registerTexture rm resource
  pure texH

-- | Create a cube storage image for compute shader writes and later sampling.
-- Image is transitioned to GENERAL layout for compute writes.
createStorageImageCube ::
  (MonadManaged m, MonadIO m) =>
  ResourceManager ->
  VulkanContext ->
  Int ->
  Vk26.Format ->
  m TextureHandle
createStorageImageCube rm vc faceSize format = do
  let dev = vcDevice vc
      pdev = vcPhysicalDevice vc
      queue = vcQueue vc
      commandBuffer = vcCommandBuffer vc
      imageExtent =
        Vk26.Extent3D (fromIntegral faceSize) (fromIntegral faceSize) 1
      createInfo =
        Vk26.ImageCreateInfo
                  { next = ()
                  , imageType = Vk26.IMAGE_TYPE_2D
                  , extent = imageExtent
                  , mipLevels = 1
                  , arrayLayers = 6
                  , format = format
                  , tiling = Vk26.IMAGE_TILING_OPTIMAL
                  , initialLayout = Vk26.IMAGE_LAYOUT_UNDEFINED
                  , usage = (Vk26.IMAGE_USAGE_STORAGE_BIT .|. Vk26.IMAGE_USAGE_SAMPLED_BIT)
                  , sharingMode = Vk26.SHARING_MODE_EXCLUSIVE
                  , samples = Vk26.SAMPLE_COUNT_1_BIT
                  , flags = Vk26.IMAGE_CREATE_CUBE_COMPATIBLE_BIT
                  , queueFamilyIndices = V.empty
                  }

  image <- liftIO $ Vk26.createImage dev createInfo Nothing

  imageMemoryRequirements <- liftIO $ Vk26.getImageMemoryRequirements dev image
  logDebugIO LogTexture $ "storage image cube memory requirements size=" <> showT ((\(Vk26.MemoryRequirements size _ _) -> size) imageMemoryRequirements) <> " faceSize=" <> showT faceSize

  imageMemory <-
    Haskan.allocateMemoryFor pdev dev imageMemoryRequirements [Vk26.MEMORY_PROPERTY_DEVICE_LOCAL_BIT]

  liftIO $ bindImageMemory dev image imageMemory 0

  -- Transition to GENERAL for compute writes
  Haskan.withCommandBufferOneTime queue commandBuffer $ do
    Haskan.layerTransitionAll
      commandBuffer
      image
      Vk26.IMAGE_LAYOUT_UNDEFINED
      Vk26.IMAGE_LAYOUT_GENERAL
      6

    liftIO $ Vk26.queueWaitIdle queue

  imageView <- Haskan.createImageViewCube dev format image

  texH <- TextureHandle <$> allocHandle (rmNextId rm)

  let destroy = do
        Vk26.destroyImageView dev imageView Nothing
        Vk26.destroyImage dev image Nothing
        Vk26.freeMemory dev imageMemory Nothing

      resource =
        TextureResource
          { trHandle = texH,
            trImage = image,
            trImageView = imageView,
            trMemory = imageMemory,
            trWidth = faceSize,
            trHeight = faceSize,
            trPixelData = Nothing,
            trDestroy = destroy
          }

  registerTexture rm resource
  pure texH

-- | Transition a storage image from GENERAL to SHADER_READ_ONLY_OPTIMAL
-- after compute shader writes are complete.
transitionStorageImageToShaderRead ::
  (MonadIO m) =>
  Vk26.CommandBuffer ->
  Vk26.Image ->
  -- | layer count (1 for 2D, 6 for cube)
  Word32 ->
  m ()
transitionStorageImageToShaderRead commandBuffer image layerCount = do
  let subresourceRange =
        Vk26.ImageSubresourceRange Vk26.IMAGE_ASPECT_COLOR_BIT 0 1 0 layerCount
      barrier =
        Vk26.ImageMemoryBarrier
                  { next = ()
                  , oldLayout = Vk26.IMAGE_LAYOUT_GENERAL
                  , newLayout = Vk26.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
                  , srcQueueFamilyIndex = Vk26.QUEUE_FAMILY_IGNORED
                  , dstQueueFamilyIndex = Vk26.QUEUE_FAMILY_IGNORED
                  , image = image
                  , subresourceRange = subresourceRange
                  , srcAccessMask = Vk26.ACCESS_SHADER_WRITE_BIT
                  , dstAccessMask = Vk26.ACCESS_SHADER_READ_BIT
                  }
  liftIO $ Vk26.cmdPipelineBarrier commandBuffer Vk26.PIPELINE_STAGE_COMPUTE_SHADER_BIT Vk26.PIPELINE_STAGE_FRAGMENT_SHADER_BIT zero V.empty V.empty (V.fromList [SomeStruct barrier])
