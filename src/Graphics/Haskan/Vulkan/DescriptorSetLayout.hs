{-# LANGUAGE TemplateHaskell #-}
module Graphics.Haskan.Vulkan.DescriptorSetLayout
  ( managedDescriptorSetLayout,
    createDescriptorSetLayout,
    managedLightingDescriptorSetLayout,
    createLightingDescriptorSetLayout,
    managedCloudDescriptorSetLayout,
    createCloudDescriptorSetLayout,
    managedBindlessDescriptorSetLayout,
    createBindlessDescriptorSetLayout,
    managedComputeDescriptorSetLayout,
    createComputeDescriptorSetLayout,
    maxBindlessTextures,
    layoutBinding,
  )
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Bits ((.|.))
import Foreign (castPtr)
import Graphics.Haskan.Resources (alloc, allocaAndPeek)
import Graphics.Haskan.Vulkan.DescriptorSetLayout.TH (descriptorSetLayoutBindings)
import Graphics.Haskan.Vulkan.Shaders.Compute.Cull qualified as Cull
import Graphics.Haskan.Vulkan.Shaders.Deferred.Clouds (CloudFragmentDefs)
import Graphics.Haskan.Vulkan.Shaders.Deferred.Lighting qualified as Lighting
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Core_1_2 qualified as Vulkan12
import Graphics.Vulkan.Marshal (withPtr)
import Graphics.Vulkan.Marshal.Create (set, setListRef, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan
import Language.Haskell.TH (Exp (VarE), mkName)

maxBindlessTextures :: Int
maxBindlessTextures = 1024

-- | Helper to construct a single VkDescriptorSetLayoutBinding.
layoutBinding :: Int -> Int -> Vulkan.VkDescriptorType -> Vulkan.VkShaderStageFlags -> Vulkan.VkDescriptorSetLayoutBinding
layoutBinding binding count descriptorType stageFlags =
  Vulkan.createVk
    ( set @"binding" (fromIntegral binding)
        &* set @"descriptorType" descriptorType
        &* set @"descriptorCount" (fromIntegral count)
        &* set @"stageFlags" stageFlags
        &* set @"pImmutableSamplers" Vulkan.VK_NULL
    )

-- Descriptor type helpers (avoid pattern synonym issues in TH splices).
vkCombinedImageSampler :: Vulkan.VkDescriptorType
vkCombinedImageSampler = Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER

vkUniformBuffer :: Vulkan.VkDescriptorType
vkUniformBuffer = Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER

vkStorageBuffer :: Vulkan.VkDescriptorType
vkStorageBuffer = Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER

-- Stage flag helpers (avoid pattern synonym issues in TH splices).
vkFragmentBit :: Vulkan.VkShaderStageFlags
vkFragmentBit = Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT

vkVertexFragmentBits :: Vulkan.VkShaderStageFlags
vkVertexFragmentBits = Vulkan.VK_SHADER_STAGE_VERTEX_BIT .|. Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT

vkComputeBit :: Vulkan.VkShaderStageFlags
vkComputeBit = Vulkan.VK_SHADER_STAGE_COMPUTE_BIT

managedDescriptorSetLayout :: (MonadManaged m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
managedDescriptorSetLayout dev =
  alloc
    "DescriptorSetLayout"
    (createDescriptorSetLayout dev)
    (\ptr -> Vulkan.vkDestroyDescriptorSetLayout dev ptr Vulkan.vkNullPtr)

createDescriptorSetLayout :: (MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
createDescriptorSetLayout dev = do
  let viewProjBinding =
        Vulkan.createVk
          ( set @"binding" 0
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
              &* set @"descriptorCount" 1
              &* set @"stageFlags" Vulkan.VK_SHADER_STAGE_VERTEX_BIT
              &* set @"pImmutableSamplers" Vulkan.VK_NULL
          )
      textureBinding =
        Vulkan.createVk
          ( set @"binding" 1
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"descriptorCount" (fromIntegral maxBindlessTextures)
              &* set @"stageFlags" Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT
              &* set @"pImmutableSamplers" Vulkan.VK_NULL
          )
      entityBinding =
        Vulkan.createVk
          ( set @"binding" 2
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
              &* set @"descriptorCount" 1
              &* set @"stageFlags" (Vulkan.VK_SHADER_STAGE_VERTEX_BIT .|. Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT)
              &* set @"pImmutableSamplers" Vulkan.VK_NULL
          )
      -- Binding flags for binding 1: partially bound (allows unused descriptors in array)
      bindingFlags :: Vulkan12.VkDescriptorBindingFlags
      bindingFlags = Vulkan12.VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT
      bindingFlagsCreateInfo :: Vulkan12.VkDescriptorSetLayoutBindingFlagsCreateInfo
      bindingFlagsCreateInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan12.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"bindingCount" 3
              &* setListRef @"pBindingFlags" [Vulkan.VK_ZERO_FLAGS, bindingFlags, Vulkan.VK_ZERO_FLAGS] -- binding 0: no flags, binding 1: partially bound, binding 2: no flags
          )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
              &* set @"pNext" (castPtr $ Vulkan.unsafePtr bindingFlagsCreateInfo)
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"bindingCount" 3
              &* setListRef @"pBindings" [viewProjBinding, textureBinding, entityBinding]
          )
   in liftIO $ withPtr bindingFlagsCreateInfo $ \_bfcPtr ->
        withPtr createInfo $ \ciPtr ->
          allocaAndPeek (Vulkan.vkCreateDescriptorSetLayout dev ciPtr Vulkan.vkNullPtr)

managedLightingDescriptorSetLayout :: (MonadManaged m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
managedLightingDescriptorSetLayout dev =
  alloc
    "LightingDescriptorSetLayout"
    (createLightingDescriptorSetLayout dev)
    (\ptr -> Vulkan.vkDestroyDescriptorSetLayout dev ptr Vulkan.vkNullPtr)

createLightingDescriptorSetLayout :: (MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
createLightingDescriptorSetLayout dev = do
  let bindings = $(descriptorSetLayoutBindings (\_b -> pure (VarE (mkName "vkFragmentBit"))) Nothing ''Lighting.FragmentDefs)
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"bindingCount" (fromIntegral (length bindings))
              &* setListRef @"pBindings" bindings
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorSetLayout dev ciPtr Vulkan.vkNullPtr)
          )

-- | Cloud descriptor set layout: env cubemap + 3D noise texture
managedCloudDescriptorSetLayout :: (MonadManaged m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
managedCloudDescriptorSetLayout dev =
  alloc
    "CloudDescriptorSetLayout"
    (createCloudDescriptorSetLayout dev)
    (\ptr -> Vulkan.vkDestroyDescriptorSetLayout dev ptr Vulkan.vkNullPtr)

createCloudDescriptorSetLayout :: (MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
createCloudDescriptorSetLayout dev = do
  let bindings = $(descriptorSetLayoutBindings (\b -> if b == 4 then pure (VarE (mkName "vkVertexFragmentBits")) else pure (VarE (mkName "vkFragmentBit"))) Nothing ''CloudFragmentDefs)
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"bindingCount" (fromIntegral (length bindings))
              &* setListRef @"pBindings" bindings
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorSetLayout dev ciPtr Vulkan.vkNullPtr)
          )

-- | Bindless descriptor set layout: one array of textures with
-- UPDATE_AFTER_BIND + PARTIALLY_BOUND.
managedBindlessDescriptorSetLayout :: (MonadManaged m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
managedBindlessDescriptorSetLayout dev =
  alloc
    "BindlessDescriptorSetLayout"
    (createBindlessDescriptorSetLayout dev)
    (\ptr -> Vulkan.vkDestroyDescriptorSetLayout dev ptr Vulkan.vkNullPtr)

createBindlessDescriptorSetLayout :: (MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
createBindlessDescriptorSetLayout dev = do
  let textureBinding =
        Vulkan.createVk
          ( set @"binding" 0
              &* set @"descriptorType" Vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
              &* set @"descriptorCount" (fromIntegral maxBindlessTextures)
              &* set @"stageFlags" Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT
              &* set @"pImmutableSamplers" Vulkan.VK_NULL
          )
      -- Binding flags: partially bound + update after bind
      bindingFlags :: Vulkan12.VkDescriptorBindingFlags
      bindingFlags =
        Vulkan12.VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT
          .|. Vulkan12.VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT
      bindingFlagsCreateInfo :: Vulkan12.VkDescriptorSetLayoutBindingFlagsCreateInfo
      bindingFlagsCreateInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan12.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"bindingCount" 1
              &* setListRef @"pBindingFlags" [bindingFlags]
          )
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
              &* set @"pNext" (castPtr $ Vulkan.unsafePtr bindingFlagsCreateInfo)
              &* set @"flags" Vulkan12.VK_DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT
              &* set @"bindingCount" 1
              &* setListRef @"pBindings" [textureBinding]
          )
   in liftIO $ withPtr bindingFlagsCreateInfo $ \_bfcPtr ->
        withPtr createInfo $ \ciPtr ->
          allocaAndPeek (Vulkan.vkCreateDescriptorSetLayout dev ciPtr Vulkan.vkNullPtr)

-- | Compute culling descriptor set layout: 2 SSBOs + 1 UBO.
managedComputeDescriptorSetLayout :: (MonadManaged m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
managedComputeDescriptorSetLayout dev =
  alloc
    "ComputeDescriptorSetLayout"
    (createComputeDescriptorSetLayout dev)
    (\ptr -> Vulkan.vkDestroyDescriptorSetLayout dev ptr Vulkan.vkNullPtr)

createComputeDescriptorSetLayout :: (MonadIO m) => Vulkan.VkDevice -> m Vulkan.VkDescriptorSetLayout
createComputeDescriptorSetLayout dev = do
  let bindings = $(descriptorSetLayoutBindings (\_b -> pure (VarE (mkName "vkComputeBit"))) Nothing ''Cull.Defs)
      createInfo =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"flags" Vulkan.VK_ZERO_FLAGS
              &* set @"bindingCount" (fromIntegral (length bindings))
              &* setListRef @"pBindings" bindings
          )
   in liftIO $
        withPtr
          createInfo
          ( \ciPtr ->
              allocaAndPeek (Vulkan.vkCreateDescriptorSetLayout dev ciPtr Vulkan.vkNullPtr)
          )
