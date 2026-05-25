{-# LANGUAGE RankNTypes #-}

module Graphics.Haskan.Resources
  ( alloc,
    alloc_,
    MonadManaged,
    allocaAndPeek,
    allocaAndPeek_,
    allocaAndPeekVkResult,
    peekVkList,
    peekVkList_,
    throwVkResult,
  )
where

import Control.Exception (bracket)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged, managed, using)
import Data.Text (Text)
import Foreign.Marshal.Alloc qualified
import Foreign.Marshal.Array qualified
import Foreign.Ptr (Ptr)
import Foreign.Storable (Storable, peek)
import Graphics.Vulkan.Core_1_0 qualified as Vulkan

alloc :: (MonadManaged m) => Text -> IO a -> (a -> IO b) -> m a
alloc resName create destroy =
  using
    ( managed
        ( bracket
            create
            destroy
        )
    )

alloc_ :: (MonadManaged m) => Text -> IO a -> IO b -> m a
alloc_ resName create destroy = alloc resName create (const destroy)

allocaAndPeek :: (MonadIO m, Storable a) => (Ptr a -> IO b) -> m a
allocaAndPeek f = liftIO $ Foreign.Marshal.Alloc.alloca (\ptr -> f ptr *> peek ptr)

allocaAndPeek_ :: (MonadIO m, Storable a) => (Ptr a -> IO ()) -> m a
allocaAndPeek_ f = liftIO $ Foreign.Marshal.Alloc.alloca (\ptr -> f ptr *> peek ptr)

allocaAndPeekVkResult :: (MonadIO m, Storable a) => (Ptr a -> IO Vulkan.VkResult) -> m (a, Vulkan.VkResult)
allocaAndPeekVkResult f = liftIO $ Foreign.Marshal.Alloc.alloca $ \ptr -> do
  res <- f ptr
  d <- peek ptr
  pure (d, res)

throwVkResult :: (MonadIO m) => Vulkan.VkResult -> m ()
throwVkResult Vulkan.VK_SUCCESS =
  return ()
throwVkResult res =
  error (show res)

peekVkList ::
  (MonadIO m, Storable a, Integral a, Storable b) =>
  (Ptr a -> Ptr b -> IO Vulkan.VkResult) ->
  m [b]
peekVkList vkGetList = liftIO $ do
  Foreign.Marshal.Alloc.alloca $ \pCount -> do
    vkGetList pCount Vulkan.VK_NULL >>= throwVkResult
    count <- peek pCount
    Foreign.Marshal.Array.allocaArray (fromIntegral count) $ \ptr -> do
      vkGetList pCount ptr >>= throwVkResult
      Foreign.Marshal.Array.peekArray (fromIntegral count) ptr

peekVkList_ ::
  (MonadIO m, Storable a, Integral a, Storable b) =>
  (Ptr a -> Ptr b -> IO ()) ->
  m [b]
peekVkList_ vkGetList = liftIO $ do
  Foreign.Marshal.Alloc.alloca $ \pCount -> do
    vkGetList pCount Vulkan.VK_NULL
    count <- peek pCount
    Foreign.Marshal.Array.allocaArray (fromIntegral count) $ \ptr -> do
      vkGetList pCount ptr
      Foreign.Marshal.Array.peekArray (fromIntegral count) ptr
