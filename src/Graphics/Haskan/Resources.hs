{-# language RankNTypes #-}
module Graphics.Haskan.Resources
  ( alloc
  , alloc_
  , MonadManaged
  , allocaAndPeek
  , allocaAndPeek_
  , allocaAndPeekVkResult
  , peekVkList
  , peekVkList_
  , throwVkResult
  ) where

-- base
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Exception (bracket)
import qualified Foreign.Marshal.Alloc
import qualified Foreign.Marshal.Array
import           Foreign.Storable (Storable, peek)

-- text
import Data.Text (Text)

-- managed
import Control.Monad.Managed (MonadManaged, using, managed)

-- vulkan-api
import qualified Graphics.Vulkan.Core_1_0 as Vulkan

-- haskan
import Graphics.Haskan.Logger (logI, showT)

alloc :: MonadManaged m => Text -> IO a -> (a -> IO b) -> m a
alloc resName create destroy =
  using
  ( managed
    ( bracket
      (logI ("allocate " <> resName) *> create)
      (\r -> logI ("deallocate " <> resName) *> (destroy r))
    )
  )

alloc_ :: MonadManaged m => Text -> IO a -> IO b -> m a
alloc_ resName create destroy = alloc resName create (\_ -> destroy)

allocaAndPeek :: (MonadIO m, Storable a) => (Vulkan.Ptr a -> IO Vulkan.VkResult) -> m a
allocaAndPeek f = liftIO $ Foreign.Marshal.Alloc.alloca (\ptr -> (f ptr >>= throwVkResult) *> Foreign.Storable.peek ptr)

allocaAndPeekVkResult :: (MonadIO m, Storable a) => (Vulkan.Ptr a -> IO Vulkan.VkResult) -> m (a, Vulkan.VkResult)
allocaAndPeekVkResult f = liftIO $ Foreign.Marshal.Alloc.alloca $ \ptr -> do
  res <- f ptr
  d <- Foreign.Storable.peek ptr
  pure (d, res)

allocaAndPeek_ :: (MonadIO m, Storable a) => (Vulkan.Ptr a -> IO ()) -> m a
allocaAndPeek_ f = liftIO $ Foreign.Marshal.Alloc.alloca (\ptr -> f ptr *> Foreign.Storable.peek ptr)

peekVkList
  :: (MonadIO m, Storable a, Integral a, Storable b)
  => (Vulkan.Ptr a -> Vulkan.Ptr b -> IO Vulkan.VkResult) -> m [b]
peekVkList vkGetList = liftIO $ do
  Foreign.Marshal.Alloc.alloca $ \pCount -> do
    vkGetList pCount Vulkan.VK_NULL >>= throwVkResult
    count <- Foreign.Storable.peek pCount
    Foreign.Marshal.Array.allocaArray (fromIntegral count) $ \ptr -> do
      vkGetList pCount ptr >>= throwVkResult
      Foreign.Marshal.Array.peekArray (fromIntegral count) ptr

peekVkList_
  :: (MonadIO m, Storable a, Integral a, Storable b)
  => (Vulkan.Ptr a -> Vulkan.Ptr b -> IO ()) -> m [b]
peekVkList_ vkGetList = liftIO $ do
  Foreign.Marshal.Alloc.alloca $ \pCount -> do
    vkGetList pCount Vulkan.VK_NULL
    count <- Foreign.Storable.peek pCount
    Foreign.Marshal.Array.allocaArray (fromIntegral count) $ \ptr -> do
      vkGetList pCount ptr
      Foreign.Marshal.Array.peekArray (fromIntegral count) ptr

throwVkResult :: (MonadFail m, MonadIO m) => Vulkan.VkResult -> m ()
throwVkResult Vulkan.VK_SUCCESS =
  return ()
throwVkResult res =
  fail ( show res )
