{-# LANGUAGE DuplicateRecordFields #-}

module Graphics.Haskan.Vulkan.Types where

import Data.Word (Word32)
import Vulkan qualified

data VulkanContext = VulkanContext
  { vcDevice :: !Vulkan.Device,
    vcPhysicalDevice :: !Vulkan.PhysicalDevice,
    vcQueue :: !Vulkan.Queue,
    vcCommandBuffer :: !Vulkan.CommandBuffer
  }

data StaticRenderContext = StaticRenderContext
  { surface :: Vulkan.SurfaceKHR,
    physicalDevice :: Vulkan.PhysicalDevice,
    device :: Vulkan.Device,
    graphicsQueueFamilyIndex :: QueueFamilyIndex,
    presentQueueFamilyIndex :: QueueFamilyIndex
  }
  deriving (Show)

data RenderContext = RenderContext
  { device :: Vulkan.Device,
    swapchain :: Vulkan.SwapchainKHR,
    swapchainImages :: [Vulkan.Image],
    graphicsCommandBuffers :: [Vulkan.CommandBuffer],
    graphicsQueueHandler :: Vulkan.Queue,
    presentQueueHandler :: Vulkan.Queue,
    renderFinishedFences :: [Vulkan.Fence],
    renderFinishedSemaphores :: [Vulkan.Semaphore],
    rcPipelineLayout :: !Vulkan.PipelineLayout,
    rcGraphicsPipeline :: !Vulkan.Pipeline,
    rcRenderPass :: !Vulkan.RenderPass,
    rcFramebuffers :: ![Vulkan.Framebuffer],
    rcDescriptorSets :: ![Vulkan.DescriptorSet],
    rcSurfaceExtent :: !Vulkan.Extent2D,
    rcGraphicsCommandPool :: !Vulkan.CommandPool
  }
  deriving (Show)

type QueueFamilyIndex = Int

type ImageIndex = Word32

data RenderResult
  = FrameOk ImageIndex
  | FrameSuboptimal ImageIndex
  | FrameOutOfDate
  | FrameTimeout
  | FrameFailed String
  deriving (Eq, Show)
