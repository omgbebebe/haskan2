# Milestone: Migrate from vulkan-api to vulkan-3.26.6

## Objective

Replace the deprecated `vulkan-api` package (Graphics.Vulkan.*) with `vulkan-3.26.6` (Vulkan.*) across all 59 source files. The project currently uses both packages with an interop bridge — this migration eliminates `vulkan-api` entirely and removes the Interop.hs shim.

## Why

- `vulkan-api` is unmaintained, pinned to `>=1.4.0 && <1.4.1`
- `vulkan` package is actively maintained (v3.26.6), covers Vulkan 1.0–1.3 + 200+ extensions
- Already required for mesh shaders (`VK_EXT_mesh_shader`) and dear-imgui
- Two Vulkan binding packages with handle conversion is fragile; single package is simpler
- `vulkan` package returns Haskell types directly — eliminates `allocaAndPeek`, `throwVkResult`, `peekVkList` helpers

## Scope

| Metric | Count |
|--------|-------|
| Files importing `vulkan-api` | 59 |
| Files already using `vulkan` package | 4 (Interop, MeshPipeline, DeviceCapabilities, Backend) |
| Custom helpers to eliminate | 6 (allocaAndPeek, allocaAndPeek_, allocaAndPeekVkResult, peekVkList, peekVkList_, throwVkResult) |
| Interop conversion functions | 15 (8 forward, 7 reverse) |
| Vulkan commands used | ~60 distinct vk* functions |

---

## API Pattern Mapping

### 1. Handle Types

| vulkan-api | vulkan-3.26.6 | Notes |
|------------|---------------|-------|
| `type VkDevice = Ptr VkDevice_T` | `data Device = Device { deviceHandle :: Ptr Device_T, deviceCmds :: DeviceCmds }` | Dispatchable: carries function pointer table |
| `type VkInstance = Ptr VkInstance_T` | `data Instance = Instance { instanceHandle :: Ptr Instance_T, instanceCmds :: InstanceCmds }` | Same |
| `type VkPhysicalDevice = Ptr VkPhysicalDevice_T` | `data PhysicalDevice = PhysicalDevice { physicalDeviceHandle :: Ptr PhysicalDevice_T, instanceCmds :: InstanceCmds }` | Same |
| `type VkQueue = Ptr VkQueue_T` | `data Queue = Queue { queueHandle :: Ptr Queue_T, deviceCmds :: DeviceCmds }` | Same |
| `type VkCommandBuffer = Ptr VkCommandBuffer_T` | `data CommandBuffer = CommandBuffer { commandBufferHandle :: Ptr CommandBuffer_T, deviceCmds :: DeviceCmds }` | Same |
| `type VkBuffer = Ptr VkBuffer_T` | `newtype Buffer = Buffer Word64` | Non-dispatchable: just a newtype |
| `type VkImage = Ptr VkImage_T` | `newtype Image = Image Word64` | Same |
| `type VkPipeline = Ptr VkPipeline_T` | `newtype Pipeline = Pipeline Word64` | Same |
| `type VkRenderPass = Ptr VkRenderPass_T` | `newtype RenderPass = RenderPass Word64` | Same |
| `type VkSwapchainKHR = Ptr VkSwapchainKHR_T` | `newtype SwapchainKHR = SwapchainKHR Word64` | In `Vulkan.Extensions.Handles` |
| `type VkSurfaceKHR = Ptr VkSurfaceKHR_T` | `newtype SurfaceKHR = SurfaceKHR Word64` | In `Vulkan.Extensions.Handles` |

**Key implication**: Dispatchable handles need both `castPtr` (for the pointer) and the `*Cmds` field. Since `vulkan` commands extract function pointers from `Cmds`, we must propagate `Cmds` from device/instance creation down to all child objects.

### 2. Struct Creation

**vulkan-api** — mutable builder pattern:
```haskell
import Graphics.Vulkan.Marshal.Create (createVk, set, setListRef, (&*))

Vulkan.createVk
  $ set @"sType" Vulkan.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
  &* set @"pNext" Vulkan.VK_NULL
  &* set @"usage" Vulkan.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT
  &* set @"size" size
  &* set @"sharingMode" Vulkan.VK_SHARING_MODE_EXCLUSIVE
```

**vulkan-3.26.6** — pure record construction with `Zero` defaults:
```haskell
import Vulkan.Core10.Buffer (BufferCreateInfo)
import Vulkan.Zero (zero)

BufferCreateInfo
  { next  = Nothing
  , flags = zero
  , size  = size
  , usage = BUFFER_USAGE_VERTEX_BUFFER_BIT
  , sharingMode       = SHARING_MODE_EXCLUSIVE
  , queueFamilyIndices = mempty
  }
```

| vulkan-api | vulkan-3.26.6 |
|------------|---------------|
| `createVk $ set @"sType" X &* set @"pNext" VK_NULL &* ...` | `X { next = Nothing, ... }` (sType auto-set by `Zero`) |
| `set @"fieldName" value` | `fieldName = value` |
| `setListRef @"name" [a,b,c]` | `name = Vector.fromList [a,b,c]` |
| `setStrRef @"name" str` | `name = ByteString.packCString str` |
| `setStrListRef @"name" strs` | `name = Vector.map ByteString.packCString strs` |
| `setVkRef @"name" handle` | `name = handle` (direct field) |
| `set @"pNext" VK_NULL` | `next = Nothing` or `next = ()` |
| `set @"pNext" (castPtr ptr)` | `next = (extensionStruct, ())` — typed chain |
| `&*` chaining | Record syntax — no chaining needed |

### 3. Marshaling & Result Handling

| vulkan-api Pattern | vulkan-3.26.6 Equivalent |
|---|---|
| `withPtr struct $ \ptr -> vkCmd ptr` | `withCStruct struct $ \ptr -> ...` or pass struct directly (most commands accept Haskell types) |
| `allocaAndPeek (vkCreateX dev ci nullPtr)` | `createX dev ci Nothing` — returns `io X` directly |
| `allocaAndPeek_ (vkGetX dev)` | `getX dev` — returns `io X` directly |
| `allocaAndPeekVkResult (vkCreateX ...)` | `createX ...` — throws `VulkanException` on error |
| `peekVkList_ (vkEnumerateX dev)` | `enumerateX dev` — returns `io (Vector X)` |
| `throwVkResult` | Not needed — commands throw `VulkanException` internally |
| `VkResult` checking | Automatic via `checkResult` in every command |
| `getField @"fieldName" struct` | Direct record field access: `fieldName struct` |
| `getStringField @"deviceName" props` | `deviceName props :: ByteString` |

### 4. Vulkan Commands

| vulkan-api | vulkan-3.26.6 | Notes |
|---|---|---|
| `vkCreateBuffer dev ci nullPtr` (returns VkResult + out ptr) | `createBuffer dev ci Nothing :: io Buffer` | Returns handle directly, throws on error |
| `vkDestroyBuffer dev buffer nullPtr` | `destroyBuffer dev buffer Nothing` | Same pattern |
| `vkAllocateMemory dev ai nullPtr` | `allocateMemory dev ai Nothing :: io DeviceMemory` | Same |
| `vkMapMemory dev mem 0 size 0` (out ptr) | `mapMemory dev mem 0 size zero :: io (Ptr ())` | Returns pointer directly |
| `vkCmdBindPipeline cmdBuf PIPELINE_BIND_POINT_GRAPHICS pipeline` | `cmdBindPipeline cmdBuf PIPELINE_BIND_POINT_GRAPHICS pipeline` | Same signature, `MonadIO io` |
| `vkCmdDraw cmdBuf vertexCount instanceCount firstVertex firstInstance` | `cmdDraw cmdBuf vertexCount instanceCount firstVertex firstInstance` | Same |
| `vkCmdPipelineBarrier cmdBuf src dst 0 [] [] barriers` | `cmdPipelineBarrier cmdBuf src dst zero mempty mempty barriers` | Vectors instead of count+ptr |
| `vkGetPhysicalDeviceQueueFamilyProperties dev` (writes to pre-alloced) | `getPhysicalDeviceQueueFamilyProperties dev :: IO (Vector QueueFamilyProperties)` | Returns vector |
| `vkEnumeratePhysicalDevices inst` | `enumeratePhysicalDevices inst :: IO (Vector PhysicalDevice)` | Returns vector |
| `vkCreateGraphicsPipelines dev nullPtr 1 ciPtr nullPtr` | `createGraphicsPipelines dev Nothing (Vector SomeStruct GraphicsPipelineCreateInfo) :: io (Vector Pipeline)` | Returns vector, handles count internally |
| `vkQueueSubmit queue 1 submitInfoPtr fence` | `queueSubmit queue (Vector SomeStruct SubmitInfo) fence` | Vector instead of count+ptr |

### 5. Extension Struct Chains

**vulkan-api** — manual `pNext` pointer manipulation:
```haskell
withPtr diFeatures $ \diPtr -> do
  let features2 = createVk
        $ set @"sType" VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2
        &* set @"pNext" (castPtr diPtr)
        &* set @"features" baseFeatures
  withPtr features2 $ \f2Ptr -> ...
```

**vulkan-3.26.6** — typed chain via `Chain` type family:
```haskell
import Vulkan.CStruct.Extends (SomeStruct(..))

let diFeatures = PhysicalDeviceDescriptorIndexingFeatures
      { next = ()
      , shaderSampledImageArrayNonUniformIndexing = True
      , descriptorBindingSampledImageUpdateAfterBind = True
      , ...
      }
    createInfo = DeviceCreateInfo
      { next = (diFeatures, ())
      , flags = zero
      , ...
      }
-- Or with SomeStruct for dynamic chains:
SomeStruct createInfo
```

### 6. Enums

| vulkan-api | vulkan-3.26.6 |
|---|---|
| `VK_FORMAT_R8G8B8A8_UNORM` | `FORMAT_R8G8B8A8_UNORM` |
| `VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL` | `IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL` |
| `VK_BUFFER_USAGE_VERTEX_BUFFER_BIT` | `BUFFER_USAGE_VERTEX_BUFFER_BIT` |
| `VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO` | Set automatically by `Zero` instance; rarely needed explicitly |
| `VK_ZERO_FLAGS` | `zero` |
| `VK_TRUE` / `VK_FALSE` | `True` / `False` |
| `VkBool32` | `Bool` (auto-converted) |
| `VkFlagMask` types | `Word32` newtypes with `Bits` instance |

### 7. Resource Management

| vulkan-api (custom Managed) | vulkan-3.26.6 (built-in brackets) |
|---|---|
| `alloc "name" create destroy` | `withXxx device ci Nothing $ \xxx -> ...` |
| Manual `Managed` monad | `with*` bracket functions provided per resource type |

The existing `Graphics.Haskan.Resources` module provides `alloc`, `allocaAndPeek`, etc. on top of vulkan-api. After migration, most of these become unnecessary — the `vulkan` package provides `with*` bracket functions. The `Managed`-based `alloc` pattern can be preserved by wrapping `with*` calls.

---

## Module Import Mapping

| vulkan-api | vulkan-3.26.6 | What's in it |
|---|---|---|
| `Graphics.Vulkan` | `Vulkan` | Re-export hub |
| `Graphics.Vulkan.Core_1_0` | `Vulkan.Core10` + `Vulkan.Core10.*` | Core types, handles, commands |
| `Graphics.Vulkan.Core_1_1` | `Vulkan.Core11` + `Vulkan.Core11.*` | Vulkan 1.1 promoted extensions |
| `Graphics.Vulkan.Core_1_2` | `Vulkan.Core12` + `Vulkan.Core12.*` | Descriptor indexing, etc. |
| `Graphics.Vulkan.Ext` | `Vulkan.Extensions.VK_EXT_*` | Individual extension modules |
| `Graphics.Vulkan.Marshal` | Not needed | `ToCStruct`/`withCStruct` replaces `withPtr` |
| `Graphics.Vulkan.Marshal.Create` | Not needed | Record construction replaces `createVk`/`set` |
| `Graphics.Vulkan.Marshal.Internal` | Not needed | `FromCStruct` replaces `getStringField` |
| — | `Vulkan.Zero` | `zero` for all types |
| — | `Vulkan.CStruct` | `ToCStruct`/`FromCStruct` classes |
| — | `Vulkan.CStruct.Extends` | `SomeStruct`, `Chain`, `Extendss` |
| — | `Vulkan.Exception` | `VulkanException`, `checkResult` |
| — | `Vulkan.Core10.Handles` | All handle types |
| — | `Vulkan.Core10.Enums.*` | All enum types (99 modules) |

---

## Phase Breakdown

### Phase 1: Foundation Types & Resources Module
**Priority:** Critical — Blocks all other phases
**Estimate:** 8-12 hours
**Risk:** Medium — Touches every file indirectly

The core types (`VulkanContext`, `StaticRenderContext`, `RenderContext`, `BufferResource`, `MeshResource`, `TextureResource`) and the `Resources.hs` helper module are imported by nearly everything. Must be migrated first.

#### Tasks

1. **Migrate `Graphics.Haskan.Vulkan.Types`**
   - Replace `VkDevice` → `Device`, `VkPhysicalDevice` → `PhysicalDevice`, `VkQueue` → `Queue`, `VkCommandBuffer` → `CommandBuffer`, `VkSurfaceKHR` → `SurfaceKHR`, `VkSwapchainKHR` → `SwapchainKHR`, `VkImage` → `Image`, `VkFence` → `Fence`, `VkSemaphore` → `Semaphore`, `VkPipeline` → `Pipeline`, `VkPipelineLayout` → `PipelineLayout`, `VkRenderPass` → `RenderPass`, `VkFramebuffer` → `Framebuffer`, `VkDescriptorSet` → `DescriptorSet`, `VkCommandPool` → `CommandPool`, `VkExtent2D` → `Extent2D`
   - `Vulkan.Word32` → `Word32` (standard Haskell)
   - Files: `src/Graphics/Haskan/Vulkan/Types.hs`

2. **Migrate `Graphics.Haskan.Resources` (custom helpers)**
   - Replace `allocaAndPeek` → direct function calls (vulkan package returns values)
   - Replace `allocaAndPeek_` → direct function calls
   - Replace `allocaAndPeekVkResult` → direct function calls (throws on error)
   - Replace `peekVkList` / `peekVkList_` → direct calls (returns `Vector`)
   - Replace `throwVkResult` → not needed (automatic)
   - Replace `alloc` → wrap `with*` bracket functions into `Managed` if desired, or switch to `ResourceT`/bracket pattern
   - Files: `src/Graphics/Haskan/Resources.hs`

3. **Migrate `Graphics.Haskan.Vulkan.Resources` (resource types)**
   - `BufferResource`: `VkBuffer` → `Buffer`, `VkDeviceMemory` → `DeviceMemory`
   - `MeshResource`: same
   - `TextureResource`: `VkImage` → `Image`, `VkImageView` → `ImageView`, `VkDeviceMemory` → `DeviceMemory`
   - Files: `src/Graphics/Haskan/Vulkan/Resources.hs`

4. **Migrate `Graphics.Haskan.Vulkan.VertexFormat`**
   - Enum conversions for vertex format types
   - Files: `src/Graphics/Haskan/Vulkan/VertexFormat.hs`

#### Deliverables
- Types.hs compiles with vulkan-3.26.6 types only
- Resources.hs helpers replaced or removed
- Resource types use new handle types

---

### Phase 2: Core Vulkan Infrastructure
**Priority:** Critical
**Estimate:** 12-16 hours
**Risk:** Medium — Instance/Device creation has complex extension chains

#### Tasks

1. **Migrate `Instance.hs`**
   - `vkCreateInstance` → `createInstance`
   - `vkEnumerateInstanceExtensionProperties` → `enumerateInstanceExtensionProperties`
   - `vkEnumerateInstanceLayerProperties` → `enumerateInstanceLayerProperties`
   - `createVk` struct → `InstanceCreateInfo` record
   - Debug messenger setup
   - Files: `src/Graphics/Haskan/Vulkan/Instance.hs`

2. **Migrate `PhysicalDevice.hs`**
   - `vkEnumeratePhysicalDevices` → `enumeratePhysicalDevices` (returns `Vector PhysicalDevice`)
   - `vkGetPhysicalDeviceSurfaceCapabilitiesKHR` → `getPhysicalDeviceSurfaceCapabilitiesKHR`
   - `vkGetPhysicalDeviceSurfacePresentModesKHR` → `getPhysicalDeviceSurfacePresentModesKHR`
   - `vkGetPhysicalDeviceSurfaceFormatsKHR` → `getPhysicalDeviceSurfaceFormatsKHR`
   - Device selection logic
   - Files: `src/Graphics/Haskan/Vulkan/PhysicalDevice.hs`

3. **Migrate `Device.hs`**
   - `vkCreateDevice` → `createDevice`
   - `VkDeviceQueueCreateInfo` → `DeviceQueueCreateInfo` record
   - `VkDeviceCreateInfo` → `DeviceCreateInfo` record with typed chain
   - `VkPhysicalDeviceFeatures2` → `PhysicalDeviceFeatures2` record
   - `VkPhysicalDeviceDescriptorIndexingFeatures` → `PhysicalDeviceDescriptorIndexingFeatures` record
   - `vkGetPhysicalDeviceFeatures2` → `getPhysicalDeviceFeatures2`
   - `vkGetPhysicalDeviceQueueFamilyProperties` → `getPhysicalDeviceQueueFamilyProperties`
   - `vkGetDeviceQueue` → `getDeviceQueue`
   - Extension chain: `pNext` pointer chain → Haskell `Chain` type
   - Files: `src/Graphics/Haskan/Vulkan/Device.hs`

4. **Migrate `DeviceCapabilities.hs`**
   - Already partially uses `vulkan` package via `enumerateDeviceExtensionProperties`
   - Remove remaining `vulkan-api` imports
   - Files: `src/Graphics/Haskan/Vulkan/DeviceCapabilities.hs`

5. **Migrate `Window.hs`**
   - `vkCreateXcbSurfaceKHR` → `createXcbSurfaceKHR` or SDL surface creation
   - `VkSurfaceKHR` handle type change
   - `vkDestroySurfaceKHR` → `destroySurfaceKHR`
   - `VkPtr` pattern → direct handle
   - Files: `src/Graphics/Haskan/Window.hs`

#### Deliverables
- Instance, PhysicalDevice, Device, Surface creation works with vulkan-3.26.6
- All device feature queries and extension enable works
- Queue retrieval works

---

### Phase 3: Memory & Buffer Management
**Priority:** High
**Estimate:** 6-8 hours
**Risk:** Low — Straightforward 1:1 mapping

#### Tasks

1. **Migrate `Memory.hs`**
   - `vkGetPhysicalDeviceMemoryProperties` → `getPhysicalDeviceMemoryProperties`
   - `vkAllocateMemory` → `allocateMemory`
   - `vkFreeMemory` → `freeMemory`
   - `findMemoryType` logic stays the same (just different struct field access)
   - `getField @"size"` → `.size`
   - Files: `src/Graphics/Haskan/Vulkan/Memory.hs`

2. **Migrate `Buffer.hs`**
   - `vkCreateBuffer` → `createBuffer`
   - `vkDestroyBuffer` → `destroyBuffer`
   - `vkGetBufferMemoryRequirements` → `getBufferMemoryRequirements`
   - `vkBindBufferMemory` → `bindBufferMemory`
   - `vkMapMemory` / `vkUnmapMemory` → `mapMemory` / `unmapMemory`
   - All `createVk` struct patterns → record construction
   - Files: `src/Graphics/Haskan/Vulkan/Buffer.hs`

#### Deliverables
- Buffer creation, memory allocation, data upload works
- All buffer types: vertex, index, uniform, storage

---

### Phase 4: Image & Texture Infrastructure
**Priority:** High
**Estimate:** 10-14 hours
**Risk:** Medium — Texture upload has complex copy/blit commands

#### Tasks

1. **Migrate `ImageView.hs`**
   - `vkCreateImageView` → `createImageView`
   - `vkDestroyImageView` → `destroyImageView`
   - `VkImageViewCreateInfo` → `ImageViewCreateInfo`
   - Files: `src/Graphics/Haskan/Vulkan/ImageView.hs`

2. **Migrate `Texture.hs`**
   - `vkCreateImage` → `createImage`
   - `vkDestroyImage` → `destroyImage`
   - `vkGetImageMemoryRequirements` → `getImageMemoryRequirements`
   - `vkBindImageMemory` → `bindImageMemory`
   - `vkCreateSampler` → `createSampler`
   - `vkDestroySampler` → `destroySampler`
   - `vkCmdCopyBufferToImage` → `cmdCopyBufferToImage`
   - `vkCmdBlitImage` → `cmdBlitImage`
   - `vkCmdPipelineBarrier` → `cmdPipelineBarrier` (for layout transitions)
   - Staging buffer pattern stays the same
   - Files: `src/Graphics/Haskan/Vulkan/Texture.hs`

3. **Migrate `Terrain/Texture.hs`**
   - `createTerrainElevationTexture` / `createTerrainClimateTexture`
   - `uploadTextureWithFormatVector` — same pattern, new API
   - Files: `src/Graphics/Haskan/Terrain/Texture.hs`

#### Deliverables
- Texture loading from file works
- Terrain elevation/climate textures upload correctly
- Sampler creation works

---

### Phase 5: Pipeline Infrastructure
**Priority:** High
**Estimate:** 12-16 hours
**Risk:** Medium — Graphics pipeline create info is the most complex struct in Vulkan

#### Tasks

1. **Migrate `ShaderModule.hs`**
   - `vkCreateShaderModule` → `createShaderModule`
   - `vkDestroyShaderModule` → `destroyShaderModule`
   - Files: `src/Graphics/Haskan/Vulkan/ShaderModule.hs`

2. **Migrate `PipelineLayout.hs`**
   - `vkCreatePipelineLayout` → `createPipelineLayout`
   - `vkDestroyPipelineLayout` → `destroyPipelineLayout`
   - `VkPushConstantRange` → `PushConstantRange` record
   - Files: `src/Graphics/Haskan/Vulkan/PipelineLayout.hs`

3. **Migrate `GraphicsPipeline.hs`**
   - `vkCreateGraphicsPipelines` → `createGraphicsPipelines`
   - `vkDestroyPipeline` → `destroyPipeline`
   - `VkGraphicsPipelineCreateInfo` → `GraphicsPipelineCreateInfo` with `SomeStruct`
   - `VkPipelineShaderStageCreateInfo` → `PipelineShaderStageCreateInfo`
   - `VkPipelineVertexInputStateCreateInfo` → `PipelineVertexInputStateCreateInfo`
   - `VkPipelineInputAssemblyStateCreateInfo` → `PipelineInputAssemblyStateCreateInfo`
   - `VkPipelineViewportStateCreateInfo` → `PipelineViewportStateCreateInfo`
   - `VkPipelineRasterizationStateCreateInfo` → `PipelineRasterizationStateCreateInfo`
   - `VkPipelineMultisampleStateCreateInfo` → `PipelineMultisampleStateCreateInfo`
   - `VkPipelineColorBlendStateCreateInfo` → `PipelineColorBlendStateCreateInfo`
   - `VkPipelineDepthStencilStateCreateInfo` → `PipelineDepthStencilStateCreateInfo`
   - `VkPipelineDynamicStateCreateInfo` → `PipelineDynamicStateCreateInfo`
   - All blend attachment state records
   - Files: `src/Graphics/Haskan/Vulkan/GraphicsPipeline.hs`

4. **Migrate `ComputePipeline.hs`**
   - `vkCreateComputePipelines` → `createComputePipelines`
   - `VkComputePipelineCreateInfo` → `ComputePipelineCreateInfo`
   - Files: `src/Graphics/Haskan/Vulkan/ComputePipeline.hs`

5. **Migrate `MeshPipeline.hs`**
   - Already uses `vulkan` package directly
   - Remove Interop.hs dependency, use native handles
   - Files: `src/Graphics/Haskan/Vulkan/MeshPipeline.hs`

6. **Migrate `RenderPass.hs`**
   - `vkCreateRenderPass` → `createRenderPass`
   - `vkDestroyRenderPass` → `destroyRenderPass`
   - `VkRenderPassCreateInfo` → `RenderPassCreateInfo`
   - `VkAttachmentDescription` → `AttachmentDescription`
   - `VkAttachmentReference` → `AttachmentReference`
   - `VkSubpassDescription` → `SubpassDescription`
   - `VkSubpassDependency` → `SubpassDependency`
   - `vkCmdBeginRenderPass` / `vkCmdEndRenderPass` → `cmdBeginRenderPass` / `cmdEndRenderPass`
   - `VkRenderPassBeginInfo` → `RenderPassBeginInfo`
   - Files: `src/Graphics/Haskan/Vulkan/RenderPass.hs`

7. **Migrate `Framebuffer.hs`**
   - `vkCreateFramebuffer` → `createFramebuffer`
   - `vkDestroyFramebuffer` → `destroyFramebuffer`
   - `VkFramebufferCreateInfo` → `FramebufferCreateInfo`
   - Files: `src/Graphics/Haskan/Vulkan/Framebuffer.hs`

8. **Migrate `Specialization.hs`**
   - Specialization constant structs
   - Files: `src/Graphics/Haskan/Vulkan/Specialization.hs`

#### Deliverables
- All pipeline types (graphics, compute, mesh) create successfully
- Render passes and framebuffers work
- Shader modules load

---

### Phase 6: Descriptor Management
**Priority:** High
**Estimate:** 8-10 hours
**Risk:** Medium — TH-generated layouts need careful migration

#### Tasks

1. **Migrate `DescriptorSetLayout.hs`**
   - `vkCreateDescriptorSetLayout` → `createDescriptorSetLayout`
   - `vkDestroyDescriptorSetLayout` → `destroyDescriptorSetLayout`
   - `VkDescriptorSetLayoutBinding` → `DescriptorSetLayoutBinding`
   - `VkDescriptorSetLayoutCreateInfo` → `DescriptorSetLayoutCreateInfo`
   - `VkDescriptorSetLayoutBindingFlagsCreateInfo` (Vulkan 1.2) → `DescriptorSetLayoutBindingFlagsCreateInfo`
   - TH-generated layout bindings — update `layoutBinding` helper to produce new struct type
   - Files: `src/Graphics/Haskan/Vulkan/DescriptorSetLayout.hs`, `src/Graphics/Haskan/Vulkan/DescriptorSetLayout/TH.hs`

2. **Migrate `DescriptorPool.hs`**
   - `vkCreateDescriptorPool` → `createDescriptorPool`
   - `vkDestroyDescriptorPool` → `destroyDescriptorPool`
   - `VkDescriptorPoolSize` → `DescriptorPoolSize`
   - `VkDescriptorPoolCreateInfo` → `DescriptorPoolCreateInfo`
   - Files: `src/Graphics/Haskan/Vulkan/DescriptorPool.hs`

3. **Migrate `DescriptorSet.hs`**
   - `vkAllocateDescriptorSets` → `allocateDescriptorSets`
   - `vkUpdateDescriptorSets` → `updateDescriptorSets`
   - `VkDescriptorSetAllocateInfo` → `DescriptorSetAllocateInfo`
   - `VkWriteDescriptorSet` → `WriteDescriptorSet`
   - `VkDescriptorImageInfo` → `DescriptorImageInfo`
   - `VkDescriptorBufferInfo` → `DescriptorBufferInfo`
   - Files: `src/Graphics/Haskan/Vulkan/DescriptorSet.hs`

#### Deliverables
- All descriptor set layouts (cloud, lighting, compute, bindless, terrain, etc.) create correctly
- Descriptor pool allocation works
- Descriptor set updates write correct bindings

---

### Phase 7: Command Recording & Synchronization
**Priority:** High
**Estimate:** 8-10 hours
**Risk:** Low — Mostly 1:1 function mapping

#### Tasks

1. **Migrate `CommandPool.hs`**
   - `vkCreateCommandPool` → `createCommandPool`
   - `vkDestroyCommandPool` → `destroyCommandPool`
   - Files: `src/Graphics/Haskan/Vulkan/CommandPool.hs`

2. **Migrate `CommandBuffer.hs`**
   - `vkAllocateCommandBuffers` → `allocateCommandBuffers`
   - `vkFreeCommandBuffers` → `freeCommandBuffers`
   - `vkBeginCommandBuffer` → `beginCommandBuffer`
   - `vkEndCommandBuffer` → `endCommandBuffer`
   - `vkResetCommandBuffer` → `resetCommandBuffer`
   - `vkCmdCopyBuffer` → `cmdCopyBuffer`
   - `vkCmdCopyBufferToImage` → `cmdCopyBufferToImage`
   - `vkCmdCopyImage` → `cmdCopyImage`
   - `vkCmdCopyImageToBuffer` → `cmdCopyImageToBuffer`
   - `vkCmdBlitImage` → `cmdBlitImage`
   - `vkCmdPipelineBarrier` → `cmdPipelineBarrier`
   - `vkCmdBindPipeline` → `cmdBindPipeline`
   - `vkCmdBindDescriptorSets` → `cmdBindDescriptorSets`
   - `vkCmdDraw` → `cmdDraw`
   - `vkCmdDrawIndexed` → `cmdDrawIndexed`
   - `vkCmdDrawIndexedIndirect` → `cmdDrawIndexedIndirect`
   - `vkCmdDispatch` → `cmdDispatch`
   - `vkCmdBindVertexBuffers` → `cmdBindVertexBuffers`
   - `vkCmdBindIndexBuffer` → `cmdBindIndexBuffer`
   - `vkCmdPushConstants` → `cmdPushConstants`
   - Single-time command helper pattern
   - Files: `src/Graphics/Haskan/Vulkan/CommandBuffer.hs`

3. **Migrate `Fence.hs`**
   - `vkCreateFence` → `createFence`
   - `vkDestroyFence` → `destroyFence`
   - `vkWaitForFences` → `waitForFences`
   - `vkResetFences` → `resetFences`
   - Files: `src/Graphics/Haskan/Vulkan/Fence.hs`

4. **Migrate `Semaphore.hs`**
   - `vkCreateSemaphore` → `createSemaphore`
   - `vkDestroySemaphore` → `destroySemaphore`
   - Files: `src/Graphics/Haskan/Vulkan/Semaphore.hs`

#### Deliverables
- Command buffer allocation and recording works
- All vkCmd* calls use new API
- Synchronization primitives work

---

### Phase 8: Swapchain & Render Loop
**Priority:** High
**Estimate:** 8-10 hours
**Risk:** Medium — Swapchain recreation, present mode

#### Tasks

1. **Migrate `Swapchain.hs`**
   - `vkCreateSwapchainKHR` → `createSwapchainKHR`
   - `vkDestroySwapchainKHR` → `destroySwapchainKHR`
   - `vkGetSwapchainImagesKHR` → `getSwapchainImagesKHR`
   - `vkAcquireNextImageKHR` → `acquireNextImageKHR`
   - `vkQueuePresentKHR` → `queuePresentKHR`
   - `VkSwapchainCreateInfoKHR` → `SwapchainCreateInfoKHR`
   - `VkPresentInfoKHR` → `PresentInfoKHR`
   - Files: `src/Graphics/Haskan/Vulkan/Swapchain.hs`

2. **Migrate `Render.hs` (Vulkan module)**
   - `vkQueueSubmit` → `queueSubmit`
   - `vkQueueWaitIdle` → `queueWaitIdle`
   - `vkDeviceWaitIdle` → `deviceWaitIdle`
   - Frame submission and presentation
   - Files: `src/Graphics/Haskan/Vulkan/Render.hs`

#### Deliverables
- Swapchain creation and image acquisition works
- Frame presentation works
- Render loop runs without errors

---

### Phase 9: Application Layer Integration
**Priority:** High
**Estimate:** 16-20 hours
**Risk:** High — Largest surface area, many interdependent modules

These files combine multiple Vulkan subsystems. Each depends on Phases 2-8.

#### Tasks

1. **Migrate `DeferredResources.hs`**
   - Largest single file: creates all deferred rendering resources
   - G-buffer images, cloud images, AP volume, god ray, terrain
   - Descriptor sets, pipelines, framebuffers for all passes
   - Depends on all prior phases
   - Files: `src/Graphics/Haskan/Vulkan/DeferredResources.hs`

2. **Migrate `Render/Deferred.hs`**
   - Render graph builder
   - Push constant packing (uses `pokeByteArray` — unchanged)
   - Command buffer recording orchestration
   - Files: `src/Graphics/Haskan/Render/Deferred.hs`

3. **Migrate `Engine/Render/Internal/PassRecording.hs`**
   - All per-frame command buffer recording
   - G-buffer, cloud, AP volume dispatch, god ray, lighting, terrain, ImGui
   - Highest density of `vkCmd*` calls
   - Files: `src/Graphics/Haskan/Engine/Render/Internal/PassRecording.hs`

4. **Migrate `Engine/Render.hs`**
   - Main render loop
   - ImGui init/shutdown
   - Frame building
   - Files: `src/Graphics/Haskan/Engine/Render.hs`

5. **Migrate `Engine/Render/Internal/Setup.hs`**
   - One-time render setup
   - Shader module creation, pipeline creation, resource allocation
   - Files: `src/Graphics/Haskan/Engine/Render/Internal/Setup.hs`

6. **Migrate `Engine/Render/Internal/FramePrepare.hs`**
   - Per-frame preparation
   - Files: `src/Graphics/Haskan/Engine/Render/Internal/FramePrepare.hs`

7. **Migrate `Engine.hs`**
   - Main loop, ECS, input polling
   - Files: `src/Graphics/Haskan/Engine.hs`

8. **Migrate `Engine/Scene.hs`**
   - Scene initialization
   - Files: `src/Graphics/Haskan/Engine/Scene.hs`

9. **Migrate `UI/Backend.hs`**
   - Dear ImGui Vulkan backend
   - Already uses `vulkan` package — remove duplicated `toVulkan*` functions from Backend.hs
   - Use native handles (no interop conversion needed)
   - Files: `src/Graphics/Haskan/UI/Backend.hs`

10. **Migrate remaining files**
    - `Scene/GLTF.hs` — glTF loading
    - `Scene/ECS.hs` — entity component system
    - `Resources.hs` — resource loading
    - `Render/Forward.hs` — forward renderer (if used)
    - `Render/Graph.hs` — render graph
    - `Render/RenderSystem.hs` — render system
    - `Render/ShaderProgram.hs` — shader program
    - `Render/Bindless.hs` — bindless descriptors
    - `Vertex.hs` — vertex definition
    - `Debug/CloudExport.hs` — cloud debug export
    - `Debug/FrameInspector.hs` — frame inspector
    - `Debug/Screenshot.hs` — screenshot capture
    - `Engine/Render/Internal/Screenshot.hs` — screenshot implementation
    - `Engine/Capabilities/Graphics.hs` — graphics capabilities
    - Files: 14+ files

#### Deliverables
- Full application compiles and runs
- All render passes produce correct output
- Debug tools (screenshot, cloud export, frame inspector) work

---

### Phase 10: Cleanup
**Priority:** Medium
**Estimate:** 4-6 hours
**Risk:** Low

#### Tasks

1. **Delete `Interop.hs`**
   - No longer needed — all code uses `vulkan` package natively
   - Files: `src/Graphics/Haskan/Vulkan/Interop.hs` (delete)

2. **Remove `vulkan-api` from cabal**
   - Remove `vulkan-api >=1.4.0 && <1.4.1` from library and test-suite deps
   - Keep `vulkan >=3.0 && <4.0` (or tighten to `>=3.26 && <4.0`)
   - Files: `haskan2.cabal`

3. **Remove or simplify `Graphics.Haskan.Resources`**
   - If `alloc` is still used (via Managed), keep the wrapper around `with*` brackets
   - Remove `allocaAndPeek`, `allocaAndPeek_`, `allocaAndPeekVkResult`, `peekVkList`, `peekVkList_`, `throwVkResult` — all unused
   - Files: `src/Graphics/Haskan/Resources.hs`

4. **Update MEMORIES.md**
   - Remove "Vulkan Interop: vulkan-api ↔ vulkan package" section
   - Update build commands if any changed
   - Remove vulkan-api references throughout
   - Files: `.opencode/MEMORIES.md`

5. **Full verification**
   - `~/bin/env-wrap cabal clean && ~/bin/env-wrap cabal build exe:haskan2`
   - `~/bin/env-wrap cabal run test:haskan2-test`
   - Run application with `--lights 3` and verify rendering
   - Vulkan validation layers clean (no errors)

#### Deliverables
- Zero imports from `Graphics.Vulkan.*`
- Zero references to `vulkan-api` in cabal
- Clean build + clean validation

---

## File Impact Summary

### Highest Impact (most vulkan-api usage, migrate carefully)
| File | vulkan-api Refs | Key Patterns |
|------|----------------|--------------|
| `Vulkan/DeferredResources.hs` | ~200 | Creates all rendering resources |
| `Engine/Render/Internal/PassRecording.hs` | ~150 | All vkCmd* recording |
| `Vulkan/DescriptorSetLayout.hs` | ~130 | TH + struct creation |
| `Vulkan/DescriptorSet.hs` | ~120 | Descriptor updates |
| `Render/Deferred.hs` | ~100 | Render graph, push constants |
| `Vulkan/Texture.hs` | ~100 | Image creation, sampler, layout transitions |
| `Engine/Render/Internal/Setup.hs` | ~100 | One-time setup |
| `Vulkan/GraphicsPipeline.hs` | ~90 | Pipeline creation |
| `Vulkan/RenderPass.hs` | ~80 | Render pass creation |
| `Vulkan/CommandBuffer.hs` | ~80 | Command helpers |
| `Vulkan/Device.hs` | ~70 | Device creation, feature chain |

### Medium Impact
| File | vulkan-api Refs |
|------|----------------|
| `Vulkan/Buffer.hs` | ~50 |
| `Vulkan/DescriptorPool.hs` | ~50 |
| `Engine/Render.hs` | ~50 |
| `Engine.hs` | ~40 |
| `Vulkan/ComputePipeline.hs` | ~40 |
| `Vulkan/ImageView.hs` | ~40 |
| `Vulkan/Swapchain.hs` | ~40 |
| `Scene/GLTF.hs` | ~40 |
| `UI/Backend.hs` | ~40 |

### Lower Impact (fewer vulkan-api refs, mostly type changes)
The remaining ~35 files have 5-30 refs each — mostly handle types in function signatures and `VkDevice` parameters.

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Extension struct chain type errors | High | Medium | Start with `'[]` chain (no extensions), add extensions incrementally |
| `SomeStruct` wrapping for pipeline creation | High | Low | `SomeStruct` is well-documented in vulkan package |
| `Zero` instance missing for a type | Low | Low | All core types have `Zero` instances |
| dear-imgui compatibility | Low | High | dear-imgui already uses `vulkan` package natively |
| Descriptor binding flags (Vulkan 1.2) | Medium | Medium | `Vulkan.Core12.DescriptorSetLayout` has the binding flags |
| Managed/bracket pattern mismatch | Medium | Low | Wrap `with*` in existing `alloc` helper |
| Cabal flag/conditional for migration | Low | Low | Big-bang migration per file, no conditional compilation |

---

## Migration Strategy

### Recommended: Bottom-Up, Per-Module

1. Start with leaf modules (types, memory, buffer)
2. Work up to mid-level (image, pipeline, descriptor)
3. Finish with top-level (render loop, engine, debug)
4. Each module migrated independently, compilation checked after each

### Not Recommended: Big-Bang

Migrating all 59 files at once would create an unresolvable web of type errors. The interdependencies are too deep.

### Testing Per Phase

After each phase:
1. `cabal build exe:haskan2` — must compile
2. Fix type errors before proceeding to next phase
3. Only run the full application after Phase 9

---

## Estimated Timeline

| Phase | Est. Hours | Cumulative |
|-------|-----------|------------|
| 1. Foundation Types | 10h | 10h |
| 2. Core Infrastructure | 14h | 24h |
| 3. Memory & Buffer | 7h | 31h |
| 4. Image & Texture | 12h | 43h |
| 5. Pipeline Infrastructure | 14h | 57h |
| 6. Descriptor Management | 9h | 66h |
| 7. Commands & Sync | 9h | 75h |
| 8. Swapchain & Render Loop | 9h | 84h |
| 9. Application Layer | 18h | 102h |
| 10. Cleanup | 5h | 107h |
| **Total** | **~107h** | |

At ~4h/day: ~27 working days (~5.5 weeks)

---

## Success Criteria

- [ ] Zero imports from `Graphics.Vulkan.*` anywhere in the project
- [ ] `vulkan-api` removed from `haskan2.cabal`
- [ ] `Interop.hs` deleted
- [ ] `cabal clean && cabal build exe:haskan2` succeeds
- [ ] Application runs with PBR deferred rendering, clouds, terrain
- [ ] Vulkan validation layers report zero errors
- [ ] All debug tools work (screenshot, cloud export, frame inspector)
- [ | dear-imgui panels render correctly
- [ ] No performance regression (frame time within 5% of baseline)

---

## Related Documents
- `.opencode/MEMORIES.md` — Project context
- `.opencode/MILESTONE_MESH_SHADER_CDLOD.md` — Previous vulkan package integration
- `reference_sources/vulkan-3.26.6/` — New package source
- `src/Graphics/Haskan/Vulkan/Interop.hs` — Current bridge between packages
