{-# LANGUAGE OverloadedStrings #-}

module Graphics.Haskan.Vulkan.ShaderModule where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.ByteString.Char8 qualified as BC
import Graphics.Haskan.Resources (alloc)
import Vulkan qualified as Vulkan
import Vulkan.Core10 qualified as Vulkan
import Vulkan.Core10.Shader (ShaderModuleCreateInfo (..))
import Vulkan.Zero (zero)

managedShaderModule :: (MonadManaged m) => Vulkan.Device -> FilePath -> m Vulkan.ShaderModule
managedShaderModule dev path =
  alloc
    "ShaderModule"
    (createShaderModule dev path)
    (\ptr -> Vulkan.destroyShaderModule dev ptr Nothing)

createShaderModule :: (MonadIO m) => Vulkan.Device -> FilePath -> m Vulkan.ShaderModule
createShaderModule dev path = liftIO $ do
  bytes <- BC.readFile path
  let createInfo :: Vulkan.ShaderModuleCreateInfo '[]
      createInfo =
        Vulkan.ShaderModuleCreateInfo
          { next = (),
            flags = zero,
            code = bytes
          }
  Vulkan.createShaderModule dev createInfo Nothing
