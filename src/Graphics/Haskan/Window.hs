{-# LANGUAGE PatternSynonyms #-}

module Graphics.Haskan.Window where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Bits
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Coerce
import Data.Text (Text)
import Foreign.Ptr (castPtr)
import Graphics.Haskan.Logger (LogCategory (..), logInfoIO, showT)
import Graphics.Haskan.Resources (alloc, alloc_)
import SDL qualified
import SDL.Internal.Types (Window (..))
import SDL.Raw qualified as Raw
import SDL.Raw.Enum (pattern SDL_WINDOW_HIDDEN, pattern SDL_WINDOW_MINIMIZED)
-- import SDL.Raw.Video (createWindowFrom)
import SDL.Video.Vulkan qualified
import Vulkan qualified as Vk26

managedWindow ::
  (MonadManaged m) =>
  Text ->
  (Int, Int) ->
  m ([ByteString], SDL.Window)
managedWindow title (width, height) = do
  SDL.initialize @[] [SDL.InitVideo]
  window <-
    alloc
      "SDL Window"
      (createWindow title (width, height))
      -- (createWindowFrom 1)
      SDL.destroyWindow

  alloc_
    "Vulkan library"
    loadVulkanLibrary
    SDL.Video.Vulkan.vkUnloadLibrary

  windowExtensions <- windowExtensions window

  logInfoIO LogGeneral ("Window extensions: " <> showT windowExtensions)
  pure (windowExtensions, window)

loadVulkanLibrary :: (MonadIO m) => m ()
loadVulkanLibrary = SDL.Video.Vulkan.vkLoadLibrary Nothing

createWindow ::
  (MonadIO m) =>
  Text ->
  (Int, Int) ->
  m SDL.Window
createWindow title (width, height) = do
  liftIO $
    SDL.createWindow
      title
      ( SDL.defaultWindow
          { SDL.windowInitialSize =
              SDL.V2 (fromIntegral width) (fromIntegral height),
            SDL.windowGraphicsContext = SDL.VulkanContext,
            SDL.windowResizable = True,
            SDL.windowHighDPI = True,
            SDL.windowVisible = True
          }
      )

windowExtensions :: (MonadIO m) => SDL.Window -> m [ByteString]
windowExtensions window = liftIO $ traverse BS.packCString =<< SDL.Video.Vulkan.vkGetInstanceExtensions window

managedSurface ::
  (MonadManaged m) =>
  Vk26.Instance ->
  SDL.Window ->
  m Vk26.SurfaceKHR
managedSurface inst window =
  alloc
    "Surface"
    (createSurface inst window)
    (\ptr -> Vk26.destroySurfaceKHR inst ptr Nothing)

createSurface ::
  (MonadIO m) =>
  Vk26.Instance ->
  SDL.Window ->
  m Vk26.SurfaceKHR
createSurface inst window = liftIO $ Vk26.SurfaceKHR <$> SDL.Video.Vulkan.vkCreateSurface window (castPtr (Vk26.instanceHandle inst))

showWindow :: (MonadIO m) => SDL.Window -> m ()
showWindow window = liftIO (SDL.showWindow window)

isWindowVisible :: (MonadIO m) => SDL.Window -> m Bool
isWindowVisible window = do
  flags <- Raw.getWindowFlags (coerce window)
  pure $
    (flags .&. fromIntegral SDL_WINDOW_MINIMIZED) == 0
      && (flags .&. fromIntegral SDL_WINDOW_HIDDEN) == 0
