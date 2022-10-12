module Graphics.Haskan.Vulkan.Buffer.Vertex where

import qualified Graphics.Haskan.Vulkan.Buffer as Buffer

managedVertexBuffer :: MonadManaged m => Vulkan.VkDevice -> m Vulkan.VkBuffer
managedVertexBuffer dev = Buffer.managedBuffer dev Vulkan.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT
