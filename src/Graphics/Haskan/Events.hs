module Graphics.Haskan.Events where

import Graphics.Haskan.Resources (MonadManaged, alloc_)
import SDL qualified

managedEvents :: (MonadManaged m) => m ()
managedEvents =
  alloc_ "SDL Events" (SDL.initialize @[] [SDL.InitEvents]) SDL.quit
