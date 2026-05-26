{-# LANGUAGE OverloadedStrings #-}

module Graphics.Haskan.Vulkan.Fence where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Graphics.Haskan.Resources (alloc)
import Vulkan qualified as Vulkan
import Vulkan.Core10 qualified as Vulkan
import Vulkan.Core10.Fence (FenceCreateInfo (..))
import Vulkan.Zero (zero)

managedFence :: (MonadManaged m) => Vulkan.Device -> m Vulkan.Fence
managedFence dev =
  alloc
    "Vulkan Fence"
    (createFence dev)
    (\ptr -> Vulkan.destroyFence dev ptr Nothing)

createFence :: (MonadIO m) => Vulkan.Device -> m Vulkan.Fence
createFence dev =
  let createInfo :: Vulkan.FenceCreateInfo '[]
      createInfo =
        Vulkan.FenceCreateInfo
          { next = (),
            flags = Vulkan.FENCE_CREATE_SIGNALED_BIT
          }
   in liftIO $ Vulkan.createFence dev createInfo Nothing
