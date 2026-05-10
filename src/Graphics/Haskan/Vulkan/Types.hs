{-# LANGUAGE DuplicateRecordFields #-}

module Graphics.Haskan.Vulkan.Types where

import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan

data StaticRenderContext = StaticRenderContext
  { surface :: Vulkan.VkSurfaceKHR,
    physicalDevice :: Vulkan.VkPhysicalDevice,
    device :: Vulkan.VkDevice,
    graphicsQueueFamilyIndex :: QueueFamilyIndex,
    presentQueueFamilyIndex :: QueueFamilyIndex
  }
  deriving (Show)

data RenderContext = RenderContext
  { device :: Vulkan.VkDevice,
    swapchain :: Vulkan.VkSwapchainKHR,
    swapchainImages :: [Vulkan.VkImage],
    graphicsCommandBuffers :: [Vulkan.VkCommandBuffer],
    graphicsQueueHandler :: Vulkan.VkQueue,
    presentQueueHandler :: Vulkan.VkQueue,
    renderFinishedFences :: [Vulkan.VkFence],
    renderFinishedSemaphores :: [Vulkan.VkSemaphore],
    -- Pipeline resources for dynamic command buffer recording
    rcPipelineLayout :: !Vulkan.VkPipelineLayout,
    rcGraphicsPipeline :: !Vulkan.VkPipeline,
    rcRenderPass :: !Vulkan.VkRenderPass,
    rcFramebuffers :: ![Vulkan.VkFramebuffer],
    rcDescriptorSets :: ![Vulkan.VkDescriptorSet],
    rcSurfaceExtent :: !Vulkan.VkExtent2D,
    rcGraphicsCommandPool :: !Vulkan.VkCommandPool
  }
  deriving (Show)

type QueueFamilyIndex = Int

type ImageIndex = Vulkan.Word32

data RenderResult
  = FrameOk ImageIndex
  | FrameSuboptimal ImageIndex
  | FrameOutOfDate
  | FrameFailed String
  deriving (Eq, Show)
