{-# language  DuplicateRecordFields #-}
module Graphics.Haskan.Vulkan.Types where

-- vulkan-api
import qualified Graphics.Vulkan as Vulkan

data StaticRenderContext
  = StaticRenderContext { surface :: Vulkan.VkSurfaceKHR
                        , physicalDevice :: Vulkan.VkPhysicalDevice
                        , device :: Vulkan.VkDevice
                        , graphicsQueueFamilyIndex :: QueueFamilyIndex
                        , presentQueueFamilyIndex :: QueueFamilyIndex
                        } deriving Show

data RenderContext
  = RenderContext { device :: Vulkan.VkDevice
                  , swapchain :: Vulkan.VkSwapchainKHR
                  , graphicsCommandBuffers :: [Vulkan.VkCommandBuffer]
                  , graphicsQueueHandler :: Vulkan.VkQueue
                  , presentQueueHandler :: Vulkan.VkQueue
                  , renderFinishedFences :: [Vulkan.VkFence]
                  , renderFinishedSemaphores :: [Vulkan.VkSemaphore]
                  } deriving Show

type QueueFamilyIndex = Int
type ImageIndex = Vulkan.Word32

data RenderResult
  = FrameOk ImageIndex
  | FrameSuboptimal ImageIndex
  | FrameOutOfDate
  | FrameFailed String
  deriving (Eq, Show)
