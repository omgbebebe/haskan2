{-# LANGUAGE LambdaCase #-}

module Graphics.Haskan.Vulkan.Texture
  ( readImageFromFile
  , decodeImageBytes
  , managedTexture
  , managedSampler
  , createSamplerWithLod
  , createTextureResource
  , textureImageView
  , generateGridTexture
  , generateCheckerboardTexture
  , createTextureFromData
  , createTextureFromBytesCached
  , decodeTextureCached
  , uploadTexture
  , createTexture2DArray
  , createCubemap
  , createCubemapMips
  ) where
import Codec.Picture
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Bits
import Data.ByteString (ByteString)
import Data.Foldable (for_)
import Data.Vector.Storable qualified
import Data.Vector.Storable qualified as Vector
import Data.Word (Word8)
import Graphics.Haskan.Logger (logDebugIO, showT, LogCategory (..))
import Graphics.Haskan.Resources (alloc, allocaAndPeek, allocaAndPeek_, throwVkResult)
import Graphics.Haskan.Vulkan.Buffer qualified as Haskan
import Graphics.Haskan.Vulkan.CommandBuffer qualified as Haskan
import Graphics.Haskan.Vulkan.ImageView qualified as Haskan
import Graphics.Haskan.Vulkan.Memory qualified as Haskan
import Graphics.Haskan.Vulkan.Resources
import Graphics.Haskan.Assets.Cache (AssetCache)
import Graphics.Haskan.Assets.TexturePreprocessor
  ( TextureConfig
  , defaultTextureConfig
  , loadTextureCached
  , loadTextureBytesCached
  )
import Graphics.Haskan.Assets.InternalFormat (InternalTexture(..), TextureMetadata(..))

import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan

readImageFromFile ::
  (MonadIO m) =>
  FilePath ->
  m ((Data.Vector.Storable.Vector Word8), Int, Int)
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
  m ((Data.Vector.Storable.Vector Word8), Int, Int)
decodeImageBytes bs = do
  image <- case decodeImage bs of
    Right dynamicImage -> pure (convertRGBA8 dynamicImage)
    Left e -> error e

  let (Image width height imageData) = image
  pure (imageData, width, height)

managedTexture ::
  (MonadManaged m) =>
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  FilePath -> -- Data.Vector.Storable.Vector Word8
  Vulkan.VkQueue ->
  Vulkan.VkCommandBuffer ->
  m Vulkan.VkImageView
managedTexture pdev dev filePath queue commandBuffer = do
  (imgData, width, height) <- liftIO (readImageFromFile filePath)
  let dataList = Vector.toList imgData

  (stagingBuffer, stagingMemoryRequirement) <-
    Haskan.managedBuffer dev dataList Vulkan.VK_BUFFER_USAGE_TRANSFER_SRC_BIT

  stagingMemory <-
    Haskan.managedBufferMemory pdev dev stagingMemoryRequirement

  liftIO $ do
    Haskan.bindBufferMemory dev stagingBuffer stagingMemory dataList
    Haskan.copyDataToDeviceMemory dev stagingMemory dataList

  let format = Vulkan.VK_FORMAT_R8G8B8A8_UNORM
      imageExtent =
        Vulkan.createVk
          ( set @"width" (fromIntegral width)
              &* set @"height" (fromIntegral height)
              &* set @"depth" 1
          )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"imageType" Vulkan.VK_IMAGE_TYPE_2D
              &* set @"extent" imageExtent
              &* set @"mipLevels" 1
              &* set @"arrayLayers" 1
              &* set @"format" format
              &* set @"tiling" Vulkan.VK_IMAGE_TILING_OPTIMAL
              &* set @"initialLayout" Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
              &* set @"usage" (Vulkan.VK_IMAGE_USAGE_TRANSFER_DST_BIT .|. Vulkan.VK_IMAGE_USAGE_SAMPLED_BIT)
              &* set @"sharingMode" Vulkan.VK_SHARING_MODE_EXCLUSIVE
              &* set @"samples" Vulkan.VK_SAMPLE_COUNT_1_BIT
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"queueFamilyIndexCount" 0
              &* set @"pQueueFamilyIndices" Vulkan.VK_NULL
          )

  image <-
    alloc
      "texture image"
      (withPtr createInfo (\ciPtr -> allocaAndPeek (Vulkan.vkCreateImage dev ciPtr Vulkan.vkNullPtr)))
      (\ptr -> Vulkan.vkDestroyImage dev ptr Vulkan.vkNullPtr)

  imageMemoryRequirements <-
    allocaAndPeek_
      (Vulkan.vkGetImageMemoryRequirements dev image)

  imageMemory <-
    Haskan.managedMemoryFor pdev dev imageMemoryRequirements [Vulkan.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT]

  bindImageMemory dev image imageMemory 0

  Haskan.withCommandBufferOneTime queue commandBuffer $ do
    Haskan.layerTransition
      commandBuffer
      image
      Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
      Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL

    Haskan.copyBufferToImage
      commandBuffer
      stagingBuffer
      image
      (fromIntegral width)
      (fromIntegral height)

    Haskan.layerTransition
      commandBuffer
      image
      Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
      Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL

  liftIO $ Vulkan.vkQueueWaitIdle queue >>= throwVkResult
  imageView <- Haskan.managedImageView dev format image
  pure imageView

bindImageMemory ::
  (MonadIO m) =>
  Vulkan.VkDevice ->
  Vulkan.VkImage ->
  Vulkan.VkDeviceMemory ->
  Vulkan.VkDeviceSize ->
  m ()
bindImageMemory dev image memory offset =
  liftIO (Vulkan.vkBindImageMemory dev image memory offset) >>= throwVkResult

managedSampler ::
  MonadManaged m =>
  Vulkan.VkDevice ->
  m Vulkan.VkSampler
managedSampler dev =
  alloc
    "Sampler"
    (createSampler dev)
    (\ptr -> Vulkan.vkDestroySampler dev ptr Vulkan.vkNullPtr)

createSampler ::
  MonadIO m =>
  Vulkan.VkDevice ->
  m Vulkan.VkSampler
createSampler dev =
  let createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"magFilter" Vulkan.VK_FILTER_LINEAR
              &* set @"minFilter" Vulkan.VK_FILTER_LINEAR
              &* set @"addressModeU" Vulkan.VK_SAMPLER_ADDRESS_MODE_REPEAT
              &* set @"addressModeV" Vulkan.VK_SAMPLER_ADDRESS_MODE_REPEAT
              &* set @"addressModeW" Vulkan.VK_SAMPLER_ADDRESS_MODE_REPEAT
              --      &* set @"anisotropyEnable" Vulkan.VK_TRUE
              --      &* set @"maxAnisotropy" 16.0
              &* set @"anisotropyEnable" Vulkan.VK_FALSE
              &* set @"maxAnisotropy" 1.0
              &* set @"borderColor" Vulkan.VK_BORDER_COLOR_INT_OPAQUE_BLACK
              &* set @"unnormalizedCoordinates" Vulkan.VK_FALSE
              &* set @"compareEnable" Vulkan.VK_FALSE
              &* set @"compareOp" Vulkan.VK_COMPARE_OP_ALWAYS
              &* set @"mipmapMode" Vulkan.VK_SAMPLER_MIPMAP_MODE_LINEAR
              &* set @"mipLodBias" 0.0
              &* set @"minLod" 0.0
              &* set @"maxLod" 0.0
          )
   in liftIO $ withPtr createInfo (\ciPtr -> allocaAndPeek (Vulkan.vkCreateSampler dev ciPtr Vulkan.vkNullPtr))

createSamplerWithLod ::
  MonadIO m =>
  Vulkan.VkDevice ->
  Float -> -- ^ max LOD
  m Vulkan.VkSampler
createSamplerWithLod dev maxLod =
  let createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"magFilter" Vulkan.VK_FILTER_LINEAR
              &* set @"minFilter" Vulkan.VK_FILTER_LINEAR
              &* set @"addressModeU" Vulkan.VK_SAMPLER_ADDRESS_MODE_REPEAT
              &* set @"addressModeV" Vulkan.VK_SAMPLER_ADDRESS_MODE_REPEAT
              &* set @"addressModeW" Vulkan.VK_SAMPLER_ADDRESS_MODE_REPEAT
              &* set @"anisotropyEnable" Vulkan.VK_FALSE
              &* set @"maxAnisotropy" 1.0
              &* set @"borderColor" Vulkan.VK_BORDER_COLOR_INT_OPAQUE_BLACK
              &* set @"unnormalizedCoordinates" Vulkan.VK_FALSE
              &* set @"compareEnable" Vulkan.VK_FALSE
              &* set @"compareOp" Vulkan.VK_COMPARE_OP_ALWAYS
              &* set @"mipmapMode" Vulkan.VK_SAMPLER_MIPMAP_MODE_LINEAR
              &* set @"mipLodBias" 0.0
              &* set @"minLod" 0.0
              &* set @"maxLod" maxLod
          )
   in liftIO $ withPtr createInfo (\ciPtr -> allocaAndPeek (Vulkan.vkCreateSampler dev ciPtr Vulkan.vkNullPtr))

-- | Shared texture upload logic: staging buffer -> image -> imageView -> register.
uploadTexture ::
  (MonadManaged m, MonadIO m) =>
  ResourceManager ->
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  Int -> Int ->
  Data.Vector.Storable.Vector Word8 ->
  Vulkan.VkQueue ->
  Vulkan.VkCommandBuffer ->
  m TextureHandle
uploadTexture rm pdev dev width height imgData queue commandBuffer = do
  let dataList = Vector.toList imgData

  (stagingBuffer, stagingMemoryRequirement) <-
    Haskan.managedBuffer dev dataList Vulkan.VK_BUFFER_USAGE_TRANSFER_SRC_BIT

  stagingMemory <-
    Haskan.managedBufferMemory pdev dev stagingMemoryRequirement

  liftIO $ do
    Haskan.bindBufferMemory dev stagingBuffer stagingMemory dataList
    Haskan.copyDataToDeviceMemory dev stagingMemory dataList

  let format = Vulkan.VK_FORMAT_R8G8B8A8_UNORM
      imageExtent =
        Vulkan.createVk
          ( set @"width" (fromIntegral width)
              &* set @"height" (fromIntegral height)
              &* set @"depth" 1
          )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"imageType" Vulkan.VK_IMAGE_TYPE_2D
              &* set @"extent" imageExtent
              &* set @"mipLevels" 1
              &* set @"arrayLayers" 1
              &* set @"format" format
              &* set @"tiling" Vulkan.VK_IMAGE_TILING_OPTIMAL
              &* set @"initialLayout" Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
              &* set @"usage" (Vulkan.VK_IMAGE_USAGE_TRANSFER_DST_BIT .|. Vulkan.VK_IMAGE_USAGE_SAMPLED_BIT)
              &* set @"sharingMode" Vulkan.VK_SHARING_MODE_EXCLUSIVE
              &* set @"samples" Vulkan.VK_SAMPLE_COUNT_1_BIT
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"queueFamilyIndexCount" 0
              &* set @"pQueueFamilyIndices" Vulkan.VK_NULL
          )

  image <- liftIO $ withPtr createInfo (\ciPtr -> allocaAndPeek (Vulkan.vkCreateImage dev ciPtr Vulkan.vkNullPtr))

  imageMemoryRequirements <-
    allocaAndPeek_
      (Vulkan.vkGetImageMemoryRequirements dev image)
  logDebugIO LogTexture $ "texture image memory requirements size=" <> showT (Vulkan.getField @"size" imageMemoryRequirements) <> " width=" <> showT width <> " height=" <> showT height

  imageMemory <-
    Haskan.allocateMemoryFor pdev dev imageMemoryRequirements [Vulkan.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT]

  liftIO $ bindImageMemory dev image imageMemory 0

  Haskan.withCommandBufferOneTime queue commandBuffer $ do
    Haskan.layerTransition
      commandBuffer
      image
      Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
      Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL

    Haskan.copyBufferToImage
      commandBuffer
      stagingBuffer
      image
      (fromIntegral width)
      (fromIntegral height)

    Haskan.layerTransition
      commandBuffer
      image
      Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
      Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL

  liftIO $ Vulkan.vkQueueWaitIdle queue >>= throwVkResult
  imageView <- Haskan.createImageView dev format image

  texH <- TextureHandle <$> allocHandle (rmNextId rm)

  let destroy = do
        Vulkan.vkDestroyImageView dev imageView Vulkan.vkNullPtr
        Vulkan.vkDestroyImage dev image Vulkan.vkNullPtr
        Vulkan.vkFreeMemory dev imageMemory Vulkan.vkNullPtr

      resource =
        TextureResource
          { trHandle = texH
          , trImage = image
          , trImageView = imageView
          , trMemory = imageMemory
          , trWidth = width
          , trHeight = height
          , trPixelData = Just imgData
          , trDestroy = destroy
          }

  registerTexture rm resource
  pure texH

-- | Create and register a texture resource from file, using asset cache.
createTextureResource ::
  (MonadManaged m, MonadIO m) =>
  ResourceManager ->
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  AssetCache ->
  FilePath ->
  Vulkan.VkQueue ->
  Vulkan.VkCommandBuffer ->
  m TextureHandle
createTextureResource rm pdev dev cache filePath queue commandBuffer = do
  result <- loadTextureCached cache filePath defaultTextureConfig
  case result of
    Left err -> error $ "createTextureResource: " <> err
    Right (InternalTexture meta imgData) ->
      uploadTexture rm pdev dev (itmWidth meta) (itmHeight meta) imgData queue commandBuffer

-- | Create and register a texture from raw RGBA8 pixel data.
createTextureFromData ::
  (MonadManaged m, MonadIO m) =>
  ResourceManager ->
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  Int ->
  Int ->
  Data.Vector.Storable.Vector Word8 ->
  Vulkan.VkQueue ->
  Vulkan.VkCommandBuffer ->
  m TextureHandle
createTextureFromData rm pdev dev width height imgData queue commandBuffer =
  uploadTexture rm pdev dev width height imgData queue commandBuffer

-- | Create and register a texture from raw bytes, using asset cache.
createTextureFromBytesCached ::
  (MonadManaged m, MonadIO m) =>
  ResourceManager ->
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  AssetCache ->
  ByteString ->
  Vulkan.VkQueue ->
  Vulkan.VkCommandBuffer ->
  m TextureHandle
createTextureFromBytesCached rm pdev dev cache rawBytes queue commandBuffer = do
  result <- loadTextureBytesCached cache rawBytes defaultTextureConfig
  case result of
    Left err -> error $ "createTextureFromBytesCached: " <> err
    Right (InternalTexture meta imgData) ->
      uploadTexture rm pdev dev (itmWidth meta) (itmHeight meta) imgData queue commandBuffer

-- | Decode texture bytes using asset cache, returning dimensions and pixel data.
-- Does NOT upload to GPU.
decodeTextureCached ::
  MonadIO m =>
  AssetCache ->
  ByteString ->
  m (Either String (Int, Int, Data.Vector.Storable.Vector Word8))
decodeTextureCached cache rawBytes = liftIO $ do
  result <- loadTextureBytesCached cache rawBytes defaultTextureConfig
  case result of
    Left err -> pure (Left err)
    Right (InternalTexture meta imgData) -> pure (Right (itmWidth meta, itmHeight meta, imgData))


-- | Resolve a texture handle to its VkImageView.
textureImageView :: MonadIO m => ResourceManager -> TextureHandle -> m (Maybe Vulkan.VkImageView)
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
        isWhite = (sqX + sqY) `mod` 2 == 0
     in case idx `mod` 4 of
          0 -> if isWhite then 220 else 40   -- R
          1 -> if isWhite then 220 else 40   -- G
          2 -> if isWhite then 220 else 40   -- B
          _ -> 255                        -- A

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
          0 -> if majorGrid then 180 else if onGrid then 120 else 64   -- R
          1 -> if majorGrid then 180 else if onGrid then 120 else 64   -- G
          2 -> if majorGrid then 180 else if onGrid then 120 else 64   -- B
          _ -> 255                                                    -- A

-- | Create a 2D texture array from multiple RGBA8 textures.
-- All textures must have the same width and height.
createTexture2DArray ::
  (MonadManaged m, MonadIO m) =>
  ResourceManager ->
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  Int -> -- ^ width
  Int -> -- ^ height
  [Data.Vector.Storable.Vector Word8] -> -- ^ one per layer
  Vulkan.VkQueue ->
  Vulkan.VkCommandBuffer ->
  m TextureHandle
createTexture2DArray rm pdev dev width height layers queue commandBuffer = do
  let numLayers = length layers
      layerSize = width * height * 4
      allData = Vector.toList $ mconcat layers

  -- Staging buffer
  (stagingBuffer, stagingMemoryRequirement) <-
    Haskan.managedBuffer dev allData Vulkan.VK_BUFFER_USAGE_TRANSFER_SRC_BIT

  stagingMemory <-
    Haskan.managedBufferMemory pdev dev stagingMemoryRequirement

  liftIO $ do
    Haskan.bindBufferMemory dev stagingBuffer stagingMemory allData
    Haskan.copyDataToDeviceMemory dev stagingMemory allData

  let format = Vulkan.VK_FORMAT_R8G8B8A8_UNORM
      imageExtent =
        Vulkan.createVk
          ( set @"width" (fromIntegral width)
              &* set @"height" (fromIntegral height)
              &* set @"depth" 1
          )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"imageType" Vulkan.VK_IMAGE_TYPE_2D
              &* set @"extent" imageExtent
              &* set @"mipLevels" 1
              &* set @"arrayLayers" (fromIntegral numLayers)
              &* set @"format" format
              &* set @"tiling" Vulkan.VK_IMAGE_TILING_OPTIMAL
              &* set @"initialLayout" Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
              &* set @"usage" (Vulkan.VK_IMAGE_USAGE_TRANSFER_DST_BIT .|. Vulkan.VK_IMAGE_USAGE_SAMPLED_BIT)
              &* set @"sharingMode" Vulkan.VK_SHARING_MODE_EXCLUSIVE
              &* set @"samples" Vulkan.VK_SAMPLE_COUNT_1_BIT
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"queueFamilyIndexCount" 0
              &* set @"pQueueFamilyIndices" Vulkan.VK_NULL
          )

  image <- liftIO $ withPtr createInfo (\ciPtr -> allocaAndPeek (Vulkan.vkCreateImage dev ciPtr Vulkan.vkNullPtr))

  imageMemoryRequirements <-
    allocaAndPeek_
      (Vulkan.vkGetImageMemoryRequirements dev image)
  logDebugIO LogTexture $ "texture2DArray image memory requirements size=" <> showT (Vulkan.getField @"size" imageMemoryRequirements) <> " layers=" <> showT numLayers <> " width=" <> showT width <> " height=" <> showT height

  imageMemory <-
    Haskan.allocateMemoryFor pdev dev imageMemoryRequirements [Vulkan.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT]

  liftIO $ bindImageMemory dev image imageMemory 0

  Haskan.withCommandBufferOneTime queue commandBuffer $ do
    Haskan.layerTransitionAll
      commandBuffer
      image
      Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
      Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
      (fromIntegral numLayers)

    for_ (zip [0..] layers) $ \(layerIdx, _) -> do
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
      Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
      Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
      (fromIntegral numLayers)

  liftIO $ Vulkan.vkQueueWaitIdle queue >>= throwVkResult
  imageView <- Haskan.createImageView2DArray dev format image (fromIntegral numLayers)

  texH <- TextureHandle <$> allocHandle (rmNextId rm)

  let destroy = do
        Vulkan.vkDestroyImageView dev imageView Vulkan.vkNullPtr
        Vulkan.vkDestroyImage dev image Vulkan.vkNullPtr
        Vulkan.vkFreeMemory dev imageMemory Vulkan.vkNullPtr

      resource =
        TextureResource
          { trHandle = texH
          , trImage = image
          , trImageView = imageView
          , trMemory = imageMemory
          , trWidth = width
          , trHeight = height
          , trPixelData = Nothing -- GPU-only array, no CPU pixel data stored
          , trDestroy = destroy
          }

  registerTexture rm resource
  pure texH

-- | Create a cubemap texture from 6 RGBA8 face images.
-- Faces must be square and all the same size.
-- Order: +X, -X, +Y, -Y, +Z, -Z
createCubemap ::
  (MonadManaged m, MonadIO m) =>
  ResourceManager ->
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  Int -> -- ^ face width/height
  [Data.Vector.Storable.Vector Word8] -> -- ^ 6 face pixel datas
  Vulkan.VkQueue ->
  Vulkan.VkCommandBuffer ->
  m TextureHandle
createCubemap rm pdev dev faceSize faces queue commandBuffer = do
  let numFaces = length faces
      facePixelCount = faceSize * faceSize * 4
      allData = Vector.toList $ mconcat faces

  -- Staging buffer (manual alloc, freed after upload)
  (stagingBuffer, stagingMemoryRequirement) <-
    Haskan.createBuffer dev allData Vulkan.VK_BUFFER_USAGE_TRANSFER_SRC_BIT

  stagingMemory <-
    Haskan.createBufferMemory pdev dev stagingMemoryRequirement

  liftIO $ do
    Haskan.bindBufferMemory dev stagingBuffer stagingMemory allData
    Haskan.copyDataToDeviceMemory dev stagingMemory allData

  let format = Vulkan.VK_FORMAT_R8G8B8A8_UNORM
      imageExtent =
        Vulkan.createVk
          ( set @"width" (fromIntegral faceSize)
              &* set @"height" (fromIntegral faceSize)
              &* set @"depth" 1
          )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"imageType" Vulkan.VK_IMAGE_TYPE_2D
              &* set @"extent" imageExtent
              &* set @"mipLevels" 1
              &* set @"arrayLayers" 6
              &* set @"format" format
              &* set @"tiling" Vulkan.VK_IMAGE_TILING_OPTIMAL
              &* set @"initialLayout" Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
              &* set @"usage" (Vulkan.VK_IMAGE_USAGE_TRANSFER_DST_BIT .|. Vulkan.VK_IMAGE_USAGE_SAMPLED_BIT)
              &* set @"sharingMode" Vulkan.VK_SHARING_MODE_EXCLUSIVE
              &* set @"samples" Vulkan.VK_SAMPLE_COUNT_1_BIT
              &* set @"flags" Vulkan.VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT
              &* set @"queueFamilyIndexCount" 0
              &* set @"pQueueFamilyIndices" Vulkan.VK_NULL
          )

  image <- liftIO $ withPtr createInfo (\ciPtr -> allocaAndPeek (Vulkan.vkCreateImage dev ciPtr Vulkan.vkNullPtr))

  imageMemoryRequirements <-
    allocaAndPeek_
      (Vulkan.vkGetImageMemoryRequirements dev image)
  logDebugIO LogTexture $ "cubemap image memory requirements size=" <> showT (Vulkan.getField @"size" imageMemoryRequirements) <> " faceSize=" <> showT faceSize

  imageMemory <-
    Haskan.allocateMemoryFor pdev dev imageMemoryRequirements [Vulkan.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT]

  liftIO $ bindImageMemory dev image imageMemory 0

  Haskan.withCommandBufferOneTime queue commandBuffer $ do
    Haskan.layerTransitionAll
      commandBuffer
      image
      Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
      Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
      6

    for_ (zip [0..] faces) $ \(faceIdx, _) -> do
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
      Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
      Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
      6

  liftIO $ Vulkan.vkQueueWaitIdle queue >>= throwVkResult

  -- Free staging resources
  liftIO $ do
    Vulkan.vkDestroyBuffer dev stagingBuffer Vulkan.vkNullPtr
    Vulkan.vkFreeMemory dev stagingMemory Vulkan.vkNullPtr

  imageView <- Haskan.createImageViewCube dev format image

  texH <- TextureHandle <$> allocHandle (rmNextId rm)

  let destroy = do
        Vulkan.vkDestroyImageView dev imageView Vulkan.vkNullPtr
        Vulkan.vkDestroyImage dev image Vulkan.vkNullPtr
        Vulkan.vkFreeMemory dev imageMemory Vulkan.vkNullPtr

      resource =
        TextureResource
          { trHandle = texH
          , trImage = image
          , trImageView = imageView
          , trMemory = imageMemory
          , trWidth = faceSize
          , trHeight = faceSize
          , trPixelData = Nothing
          , trDestroy = destroy
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
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  Int -> -- ^ face width/height
  [Data.Vector.Storable.Vector Word8] -> -- ^ 6 face pixel datas
  Vulkan.VkQueue ->
  Vulkan.VkCommandBuffer ->
  m TextureHandle
createCubemapMips rm pdev dev faceSize faces queue commandBuffer = do
  let numFaces = length faces
      facePixelCount = faceSize * faceSize * 4
      allData = Vector.toList $ mconcat faces
      mipLevels = floor (logBase 2 (fromIntegral faceSize :: Double)) + 1

  -- Staging buffer (manual alloc, freed after upload)
  (stagingBuffer, stagingMemoryRequirement) <-
    Haskan.createBuffer dev allData Vulkan.VK_BUFFER_USAGE_TRANSFER_SRC_BIT

  stagingMemory <-
    Haskan.createBufferMemory pdev dev stagingMemoryRequirement

  liftIO $ do
    Haskan.bindBufferMemory dev stagingBuffer stagingMemory allData
    Haskan.copyDataToDeviceMemory dev stagingMemory allData

  let format = Vulkan.VK_FORMAT_R8G8B8A8_UNORM
      imageExtent =
        Vulkan.createVk
          ( set @"width" (fromIntegral faceSize)
              &* set @"height" (fromIntegral faceSize)
              &* set @"depth" 1
          )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"imageType" Vulkan.VK_IMAGE_TYPE_2D
              &* set @"extent" imageExtent
              &* set @"mipLevels" (fromIntegral mipLevels)
              &* set @"arrayLayers" 6
              &* set @"format" format
              &* set @"tiling" Vulkan.VK_IMAGE_TILING_OPTIMAL
              &* set @"initialLayout" Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
              &* set @"usage" (Vulkan.VK_IMAGE_USAGE_TRANSFER_SRC_BIT .|. Vulkan.VK_IMAGE_USAGE_TRANSFER_DST_BIT .|. Vulkan.VK_IMAGE_USAGE_SAMPLED_BIT)
              &* set @"sharingMode" Vulkan.VK_SHARING_MODE_EXCLUSIVE
              &* set @"samples" Vulkan.VK_SAMPLE_COUNT_1_BIT
              &* set @"flags" Vulkan.VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT
              &* set @"queueFamilyIndexCount" 0
              &* set @"pQueueFamilyIndices" Vulkan.VK_NULL
          )

  image <- liftIO $ withPtr createInfo (\ciPtr -> allocaAndPeek (Vulkan.vkCreateImage dev ciPtr Vulkan.vkNullPtr))

  imageMemoryRequirements <-
    allocaAndPeek_
      (Vulkan.vkGetImageMemoryRequirements dev image)
  logDebugIO LogTexture $ "cubemapMips image memory requirements size=" <> showT (Vulkan.getField @"size" imageMemoryRequirements) <> " faceSize=" <> showT faceSize <> " mipLevels=" <> showT mipLevels

  imageMemory <-
    Haskan.allocateMemoryFor pdev dev imageMemoryRequirements [Vulkan.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT]

  liftIO $ bindImageMemory dev image imageMemory 0

  Haskan.withCommandBufferOneTime queue commandBuffer $ do
    -- Transition all layers of mip 0 to DST optimal
    Haskan.mipLayerTransition
      commandBuffer
      image
      Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
      Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
      0 1 6

    -- Upload face data to mip 0
    for_ (zip [0..] faces) $ \(faceIdx, _) -> do
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
          srcOldLayout = if mip == 1
                           then Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
                           else Vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL

      -- Transition src mip to SRC optimal
      Haskan.mipLayerTransition
        commandBuffer
        image
        srcOldLayout
        Vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
        srcMip 1 6

      -- Transition dst mip to DST optimal
      Haskan.mipLayerTransition
        commandBuffer
        image
        Vulkan.VK_IMAGE_LAYOUT_UNDEFINED
        Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
        dstMip 1 6

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
        Vulkan.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
        Vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
        dstMip 1 6

    -- Transition all mips to SHADER_READ_ONLY_OPTIMAL
    Haskan.mipLayerTransition
      commandBuffer
      image
      Vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
      Vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
      0 (fromIntegral mipLevels) 6

  liftIO $ Vulkan.vkQueueWaitIdle queue >>= throwVkResult

  -- Free staging resources
  liftIO $ do
    Vulkan.vkDestroyBuffer dev stagingBuffer Vulkan.vkNullPtr
    Vulkan.vkFreeMemory dev stagingMemory Vulkan.vkNullPtr

  imageView <- Haskan.createImageViewCubeMips dev format image (fromIntegral mipLevels)

  texH <- TextureHandle <$> allocHandle (rmNextId rm)

  let destroy = do
        Vulkan.vkDestroyImageView dev imageView Vulkan.vkNullPtr
        Vulkan.vkDestroyImage dev image Vulkan.vkNullPtr
        Vulkan.vkFreeMemory dev imageMemory Vulkan.vkNullPtr

      resource =
        TextureResource
          { trHandle = texH
          , trImage = image
          , trImageView = imageView
          , trMemory = imageMemory
          , trWidth = faceSize
          , trHeight = faceSize
          , trPixelData = Nothing
          , trDestroy = destroy
          }

  registerTexture rm resource
  pure texH
