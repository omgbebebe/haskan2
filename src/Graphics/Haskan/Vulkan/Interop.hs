{-# LANGUAGE Trustworthy #-}

module Graphics.Haskan.Vulkan.Interop
  ( -- * vulkan-api → vulkan package (existing, re-exported)
    toVulkanDevice,
    toVulkanInstance,
    toVulkanPhysicalDevice,
    toVulkanQueue,
    toVulkanCommandBuffer,
    toVulkanRenderPass,
    toVulkanDescriptorPool,

    -- * vulkan package → vulkan-api (new)
    fromVulkanDevice,
    fromVulkanPipeline,
    fromVulkanPipelineLayout,
    fromVulkanShaderModule,
    fromVulkanRenderPass,
    fromVulkanCommandBuffer,

    -- * Additional reverse conversions
    fromVulkanDescriptorPool,
    fromVulkanDescriptorSet,
    fromVulkanSampler,
    fromVulkanImageView,
    fromVulkanBuffer,
    fromVulkanDeviceMemory,
    fromVulkanImage,

    -- * Additional forward conversions
    toVulkanPipelineLayout,
    toVulkanShaderModule,
    toVulkanSampler,
  )
where

import Data.Coerce (coerce)
import Foreign.Ptr (castPtr)
-- vulkan-api
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Marshal (VkPtr (..))
-- vulkan package
import Vulkan.Core10.Handles qualified as Vk
import Vulkan.Zero qualified as Vk

-- ---------------------------------------------------------------------------
-- vulkan-api → vulkan package (re-exported from UI.Backend for convenience)
-- ---------------------------------------------------------------------------

toVulkanDevice :: Vulkan.VkDevice -> Vk.Device
toVulkanDevice ptr = Vk.Device (castPtr ptr) Vk.zero

toVulkanInstance :: Vulkan.VkInstance -> Vk.Instance
toVulkanInstance ptr = Vk.Instance (castPtr ptr) Vk.zero

toVulkanPhysicalDevice :: Vulkan.VkPhysicalDevice -> Vk.PhysicalDevice
toVulkanPhysicalDevice ptr = Vk.PhysicalDevice (castPtr ptr) Vk.zero

toVulkanQueue :: Vulkan.VkQueue -> Vk.Queue
toVulkanQueue ptr = Vk.Queue (castPtr ptr) Vk.zero

toVulkanCommandBuffer :: Vulkan.VkCommandBuffer -> Vk.CommandBuffer
toVulkanCommandBuffer ptr = Vk.CommandBuffer (castPtr ptr) Vk.zero

toVulkanRenderPass :: Vulkan.VkRenderPass -> Vk.RenderPass
toVulkanRenderPass = Vk.RenderPass . coerce

toVulkanDescriptorPool :: Vulkan.VkDescriptorPool -> Vk.DescriptorPool
toVulkanDescriptorPool = Vk.DescriptorPool . coerce

-- ---------------------------------------------------------------------------
-- vulkan package → vulkan-api
-- ---------------------------------------------------------------------------

fromVulkanDevice :: Vk.Device -> Vulkan.VkDevice
fromVulkanDevice = castPtr . Vk.deviceHandle

fromVulkanPipeline :: Vk.Pipeline -> Vulkan.VkPipeline
fromVulkanPipeline = VkPtr . coerce

fromVulkanPipelineLayout :: Vk.PipelineLayout -> Vulkan.VkPipelineLayout
fromVulkanPipelineLayout = VkPtr . coerce

fromVulkanShaderModule :: Vk.ShaderModule -> Vulkan.VkShaderModule
fromVulkanShaderModule = VkPtr . coerce

fromVulkanRenderPass :: Vk.RenderPass -> Vulkan.VkRenderPass
fromVulkanRenderPass = coerce

fromVulkanCommandBuffer :: Vk.CommandBuffer -> Vulkan.VkCommandBuffer
fromVulkanCommandBuffer = castPtr . Vk.commandBufferHandle

fromVulkanDescriptorPool :: Vk.DescriptorPool -> Vulkan.VkDescriptorPool
fromVulkanDescriptorPool = VkPtr . coerce

fromVulkanDescriptorSet :: Vk.DescriptorSet -> Vulkan.VkDescriptorSet
fromVulkanDescriptorSet = VkPtr . coerce

fromVulkanSampler :: Vk.Sampler -> Vulkan.VkSampler
fromVulkanSampler = VkPtr . coerce

fromVulkanImageView :: Vk.ImageView -> Vulkan.VkImageView
fromVulkanImageView = VkPtr . coerce

fromVulkanBuffer :: Vk.Buffer -> Vulkan.VkBuffer
fromVulkanBuffer = VkPtr . coerce

fromVulkanDeviceMemory :: Vk.DeviceMemory -> Vulkan.VkDeviceMemory
fromVulkanDeviceMemory = VkPtr . coerce

fromVulkanImage :: Vk.Image -> Vulkan.VkImage
fromVulkanImage = VkPtr . coerce

-- ---------------------------------------------------------------------------
-- Additional vulkan-api → vulkan package conversions
-- ---------------------------------------------------------------------------

toVulkanPipelineLayout :: Vulkan.VkPipelineLayout -> Vk.PipelineLayout
toVulkanPipelineLayout = Vk.PipelineLayout . coerce

toVulkanShaderModule :: Vulkan.VkShaderModule -> Vk.ShaderModule
toVulkanShaderModule = Vk.ShaderModule . coerce

toVulkanSampler :: Vulkan.VkSampler -> Vk.Sampler
toVulkanSampler = Vk.Sampler . coerce
