module Graphics.Haskan.Engine.Capabilities.Graphics
  ( MonadGraphics (..),
  )
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (Managed)
import Control.Monad.Reader (ReaderT, lift)
import Data.Word (Word32)
import Foreign.Storable (Storable)
import Graphics.Haskan.Vulkan.Render qualified as Render
import Graphics.Haskan.Vulkan.Types (RenderResult (..))
import Vulkan qualified as Vk26

class (Monad m) => MonadGraphics m where
  uploadStorageBuffer :: (Storable a) => Vk26.DeviceMemory -> Int -> [a] -> m ()
  uploadUniformBuffer :: (Storable a) => Vk26.DeviceMemory -> Int -> [a] -> m ()
  deviceWaitIdle :: m ()
  drawFrameGraphics :: Vk26.Semaphore -> Int -> (Word32 -> Int -> IO ()) -> m RenderResult
  presentFrameGraphics :: Word32 -> Vk26.Semaphore -> m Vk26.Result

instance MonadGraphics IO where
  uploadStorageBuffer _ _ _ = error "uploadStorageBuffer: not implemented in IO"
  uploadUniformBuffer _ _ _ = error "uploadUniformBuffer: not implemented in IO"
  deviceWaitIdle = error "deviceWaitIdle: not implemented in IO"
  drawFrameGraphics _ _ _ = error "drawFrameGraphics: not implemented in IO"
  presentFrameGraphics _ _ = error "presentFrameGraphics: not implemented in IO"

instance MonadGraphics Managed where
  uploadStorageBuffer _ _ _ = error "uploadStorageBuffer: not implemented in Managed"
  uploadUniformBuffer _ _ _ = error "uploadUniformBuffer: not implemented in Managed"
  deviceWaitIdle = error "deviceWaitIdle: not implemented in Managed"
  drawFrameGraphics _ _ _ = error "drawFrameGraphics: not implemented in Managed"
  presentFrameGraphics _ _ = error "presentFrameGraphics: not implemented in Managed"
