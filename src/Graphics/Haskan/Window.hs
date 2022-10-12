module Graphics.Haskan.Window where

-- base
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Coerce

-- text
import Data.Text (Text)

-- bytestring
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS

-- managed
import Control.Monad.Managed (MonadManaged)

-- sdl2
import qualified SDL
import qualified SDL.Video.Vulkan

-- vulkan-api
import qualified Graphics.Vulkan as Vulkan
import qualified Graphics.Vulkan.Ext as Vulkan

-- haskan
import Graphics.Haskan.Resources (alloc, alloc_)
import Graphics.Haskan.Logger (logI, showT)

managedWindow
  :: MonadManaged m
  => Text
  -> (Int, Int)
  -> m ([ByteString], SDL.Window)
managedWindow title (width, height) = do
  SDL.initialize @[] [SDL.InitVideo]
  window <- alloc "SDL Window"
    (createWindow title (width, height))
    SDL.destroyWindow

  alloc_ "Vulkan library"
    loadVulkanLibrary
    SDL.Video.Vulkan.vkUnloadLibrary

  windowExtensions <- windowExtensions window

  logI ("Window extensions: " <> showT windowExtensions)
  pure (windowExtensions, window)

loadVulkanLibrary :: MonadIO m => m ()
loadVulkanLibrary = SDL.Video.Vulkan.vkLoadLibrary Nothing

createWindow
  :: MonadIO m
  => Text
  -> (Int, Int)
  -> m SDL.Window
createWindow title (width, height) = do
  liftIO $ SDL.createWindow
    title
    (SDL.defaultWindow
     { SDL.windowInitialSize =
         SDL.V2 (fromIntegral width) (fromIntegral height)
     , SDL.windowGraphicsContext = SDL.VulkanContext
     , SDL.windowResizable       = True
     , SDL.windowHighDPI         = True
     , SDL.windowVisible         = False
     }
    )

windowExtensions :: MonadIO m => SDL.Window -> m [ByteString]
windowExtensions window = liftIO $ traverse BS.packCString =<< SDL.Video.Vulkan.vkGetInstanceExtensions window

managedSurface
  :: MonadManaged m
  => Vulkan.VkInstance
  -> SDL.Window
  -> m Vulkan.VkSurfaceKHR
managedSurface inst window = alloc "Surface"
  (createSurface inst window)
  (\ptr -> Vulkan.vkDestroySurfaceKHR (coerce inst) ptr Vulkan.vkNullPtr)

createSurface
  :: MonadIO m
  => Vulkan.VkInstance
  -> SDL.Window
  -> m Vulkan.VkSurfaceKHR
createSurface inst window = liftIO $ Vulkan.VkPtr <$> SDL.Video.Vulkan.vkCreateSurface window (coerce inst)

showWindow :: MonadIO m => SDL.Window -> m ()
showWindow window = liftIO (SDL.showWindow window)
