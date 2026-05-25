module Graphics.Haskan.Render.Bindless
  ( BindlessSet (..),
    createBindlessSet,
    registerTexture,
  )
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Vector qualified as Vector
import Data.Word (Word32)
import Graphics.Haskan.Logger (LogCategory (..), logInfoIO, showT)
import Graphics.Haskan.Vulkan.DescriptorPool qualified as DescriptorPool
import Graphics.Haskan.Vulkan.DescriptorSet (updateBindlessTexture)
import Graphics.Haskan.Vulkan.DescriptorSetLayout qualified as DescriptorSetLayout
import Vulkan qualified as Vk26

-- | Handle to a bindless texture descriptor set.
data BindlessSet = BindlessSet
  { bsDescriptorSet :: !Vk26.DescriptorSet,
    bsSampler :: !Vk26.Sampler,
    bsNextIndex :: !(IORef Word32),
    bsMaxTextures :: !Word32
  }

createBindlessSet ::
  (MonadIO m, MonadManaged m) =>
  Vk26.Device ->
  Vk26.Sampler ->
  m BindlessSet
createBindlessSet dev sampler = do
  layout <- DescriptorSetLayout.managedBindlessDescriptorSetLayout dev
  pool <- DescriptorPool.managedBindlessDescriptorPool dev DescriptorSetLayout.maxBindlessTextures
  ds <- allocateDescriptorSet dev pool [layout]
  idxRef <- liftIO $ newIORef 0
  logInfoIO LogRender $ "Bindless set created with " <> showT DescriptorSetLayout.maxBindlessTextures <> " slots"
  pure
    BindlessSet
      { bsDescriptorSet = ds,
        bsSampler = sampler,
        bsNextIndex = idxRef,
        bsMaxTextures = fromIntegral DescriptorSetLayout.maxBindlessTextures
      }

registerTexture ::
  (MonadIO m) =>
  Vk26.Device ->
  BindlessSet ->
  Vk26.ImageView ->
  m (Maybe Word32)
registerTexture dev bindlessSet textureView = do
  nextIdx <- liftIO $ readIORef (bsNextIndex bindlessSet)
  if nextIdx >= bsMaxTextures bindlessSet
    then do
      logInfoIO LogRender "Bindless texture array full, cannot register more textures"
      pure Nothing
    else do
      updateBindlessTexture
        dev
        (bsDescriptorSet bindlessSet)
        (bsSampler bindlessSet)
        textureView
        nextIdx
      liftIO $ modifyIORef' (bsNextIndex bindlessSet) (+ 1)
      logInfoIO LogRender $ "Registered texture at bindless index " <> showT nextIdx
      pure (Just nextIdx)

-- Internal: allocate a descriptor set from pool + layout
allocateDescriptorSet ::
  (MonadIO m) =>
  Vk26.Device ->
  Vk26.DescriptorPool ->
  [Vk26.DescriptorSetLayout] ->
  m Vk26.DescriptorSet
allocateDescriptorSet dev descriptorPool setLayouts = do
  let allocateInfo =
        Vk26.DescriptorSetAllocateInfo
          ()
          descriptorPool
          (Vector.fromList setLayouts)
  liftIO $ do
    dss <- Vk26.allocateDescriptorSets dev allocateInfo
    pure (Vector.head dss)
