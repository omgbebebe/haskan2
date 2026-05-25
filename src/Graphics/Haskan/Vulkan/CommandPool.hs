{-# LANGUAGE OverloadedStrings #-}
module Graphics.Haskan.Vulkan.CommandPool where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Graphics.Haskan.Resources (alloc)
import Vulkan qualified as Vulkan
import Vulkan.Core10 qualified as Vulkan
import Vulkan.Core10.CommandPool (CommandPoolCreateInfo (..))
import Vulkan.Zero (zero)

managedCommandPool ::
  (MonadManaged m) =>
  Vulkan.Device ->
  Int ->
  m Vulkan.CommandPool
managedCommandPool dev qfi =
  alloc
    "Command pool"
    (createCommandPool dev qfi)
    (\ptr -> Vulkan.destroyCommandPool dev ptr Nothing)

createCommandPool ::
  (MonadIO m) =>
  Vulkan.Device ->
  Int ->
  m Vulkan.CommandPool
createCommandPool dev queueFamilyIndex = do
  let commandPoolCI :: Vulkan.CommandPoolCreateInfo
      commandPoolCI =
        Vulkan.CommandPoolCreateInfo
          { flags = Vulkan.COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT
          , queueFamilyIndex = fromIntegral queueFamilyIndex
          }
  liftIO $ Vulkan.createCommandPool dev commandPoolCI Nothing
