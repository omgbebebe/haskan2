module Graphics.Haskan.Events where

-- sdl2
import qualified SDL

-- haskan
import Graphics.Haskan.Resources (MonadManaged, alloc_)

managedEvents :: MonadManaged m => m ()
managedEvents =
  alloc_ "SDL Events" (SDL.initialize @[] [SDL.InitEvents]) SDL.quit
