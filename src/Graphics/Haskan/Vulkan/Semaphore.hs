{-# LANGUAGE OverloadedStrings #-}
module Graphics.Haskan.Vulkan.Semaphore where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Graphics.Haskan.Resources (alloc)
import Vulkan qualified as Vulkan
import Vulkan.Core10 qualified as Vulkan
import Vulkan.Core10.QueueSemaphore (SemaphoreCreateInfo (..))
import Vulkan.Zero (zero)

managedSemaphore :: (MonadManaged m) => Vulkan.Device -> m Vulkan.Semaphore
managedSemaphore dev =
  alloc
    "Vulkan Semaphore"
    (createSemaphore dev)
    (\ptr -> Vulkan.destroySemaphore dev ptr Nothing)

createSemaphore :: (MonadIO m) => Vulkan.Device -> m Vulkan.Semaphore
createSemaphore dev =
  let createInfo :: Vulkan.SemaphoreCreateInfo '[]
      createInfo = Vulkan.SemaphoreCreateInfo {next = (), flags = zero}
   in liftIO $ Vulkan.createSemaphore dev createInfo Nothing
