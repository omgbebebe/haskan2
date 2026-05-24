# UV Check Cube Invisible — Root Cause Analysis

## TL;DR

**The bindless fragment shader writes `out_position = Vec4 0 0 0 1` (zero world position). The lighting shader detects geometry using `|posX| + |posY| + |posZ| > 0.001`. Since all components are zero, `hasGeometry = False` and the lighting pass renders sky instead of the cube.**

## Root Cause: Zero Position + Lighting Geometry Detection

### The Chain of Failure

1. `--uv-check-cube` creates a textured entity → `dcMaterial = Just textureResource`
2. Draw list sorting puts it in `bindlessDraws` (has material) → `gbufferDraws = []`
3. G-buffer pass runs but draws nothing (clears all attachments to 0)
4. Bindless pass draws the cube, but the fragment shader writes:
   ```haskell
   put @"out_position" (Vec4 0 0 0 1)  -- Bindless.hs:97
   ```
5. Lighting shader reads g-buffer position:
   ```haskell
   let hasGeometry = abs posX + abs posY + abs posZ > 0.001  -- Lighting.hs:338, LightingProcedural.hs:345
   ```
6. With posX=posY=posZ=0: `hasGeometry = False` → sky is rendered → cube invisible

### Why glTF Models Work

glTF models go through the **G-buffer pass** (not the bindless pass). The G-buffer shader (`GBuffer.hs`) computes and writes the actual world position:
```haskell
put @"out_position" (Vec4 wx wy wz metallic)  -- real world coordinates
```
So `hasGeometry = True` and lighting works correctly.

The bindless pass is only used for textured UV-check primitives. glTF textured models also have materials, but they use the main g-buffer pipeline with entity SSBO — NOT the bindless pass. The bindless pass is essentially only active for UV-check modes.

## Secondary Issues (Present but Not the Root Cause)

### Issue 2: Descriptor Set Layout Mismatch

**Files**: `DeferredResources.hs:597,613,621`

The bindless pipeline layout is created with `managedDescriptorSetLayout` (3 bindings):
- Binding 0: UBO (descriptorCount=1)
- Binding 1: COMBINED_IMAGE_SAMPLER (descriptorCount=1024, PARTIALLY_BOUND, UPDATE_AFTER_BIND)
- Binding 2: SSBO (descriptorCount=1)

But the bound descriptor sets are allocated from `managedBindlessPassDescriptorSetLayout` (2 bindings):
- Binding 0: UBO (descriptorCount=1)
- Binding 1: COMBINED_IMAGE_SAMPLER (descriptorCount=1, no special flags)

VUID-vkCmdBindDescriptorSets-pDescriptorSets-01697 violation: the bound set is not compatible with the pipeline layout's descriptor set layout. Binding counts, descriptor counts, and flags all differ.

**On NVIDIA**, this likely doesn't cause rendering failure for the descriptors that ARE valid (bindings 0 and 1), but it's undefined behavior and would trigger validation errors.

### Issue 3: Non-Encoded Normals

**File**: `Bindless.hs:98`

The bindless shader writes raw normals without the `*0.5+0.5` encoding:
```haskell
put @"out_normal" (Vec4 (view @(Index 0) normal) (view @(Index 1) normal) (view @(Index 2) normal) 0)
```

The G-buffer shader encodes: `normal * 0.5 + 0.5`
The lighting shader decodes: `normal * 2 - 1`

With raw normals, the lighting shader double-decodes, producing wrong lighting. Roughness is also set to 0 (from normal.a=0), which causes NaN in the GGX NDF when NdotH=1.

### Issue 4: Missing Emissive Output

**File**: `Bindless.hs:63-99`

The bindless fragment shader declares only 3 outputs (locations 0-2) but the render pass has 4 color attachments. Location 3 (emissive) is not written. With `LOAD_OP_LOAD`, the cleared emissive value `(0.0, 0.5, 1.0, 1.0)` is preserved, giving the cube an unwanted blue emissive tint.

### Issue 5: Pipeline/Render Pass Cross-Use

**File**: `DeferredResources.hs:605`

The bindless pipeline is created against `gBufferRenderPass` but used with `bindlessRenderPass` at draw time. These are compatible per Vulkan spec (same attachment formats/structure), so this is cosmetic but confusing.

## Fix Plan

### Fix 1 (Required): Write Correct World Position in Bindless Shader

The bindless shader needs to compute and output the actual world position. This requires changes to both vertex and fragment shaders.

**Vertex shader** — add world position output:
```haskell
type VertexDefs =
  '[ "in_position" ':-> Input '[Location 0] (V 3 Float),
     "in_uv" ':-> Input '[Location 1] (V 2 Float),
     "in_normal" ':-> Input '[Location 2] (V 3 Float),
     "out_uv" ':-> Output '[Location 0] (V 2 Float),
     "out_normal" ':-> Output '[Location 1] (V 3 Float),
     "out_worldPos" ':-> Output '[Location 2] (V 3 Float),  -- NEW
     "ubo" ':-> Uniform ...,
     "perDraw" ':-> PushConstant ...,
     "main" ':-> EntryPoint '[] Vertex
   ]

vertex = shader do
  ...
  let worldPos = model !*^ Vec4 x y z 1
  put @"out_worldPos" (Vec3 (view @(Index 0) worldPos) (view @(Index 1) worldPos) (view @(Index 2) worldPos))
  ...
```

**Fragment shader** — receive world position, encode normals, output all 4 MRTs:
```haskell
type FragmentDefs =
  '[ "in_uv" ':-> Input '[Location 0] (V 2 Float),
     "in_normal" ':-> Input '[Location 1] (V 3 Float),
     "in_worldPos" ':-> Input '[Location 2] (V 3 Float),  -- NEW
     "out_position" ':-> Output '[Location 0] (V 4 Float),
     "out_normal" ':-> Output '[Location 1] (V 4 Float),
     "out_albedo" ':-> Output '[Location 2] (V 4 Float),
     "out_emissive" ':-> Output '[Location 3] (V 4 Float),  -- NEW
     ...
   ]

fragment = shader do
  ...
  worldPos <- get @"in_worldPos"
  let -- Encode normals: * 0.5 + 0.5
      encN = Vec3 ((nx + 1) * 0.5) ((ny + 1) * 0.5) ((nz + 1) * 0.5)
  put @"out_position" (Vec4 (view @(Index 0) worldPos) (view @(Index 1) worldPos) (view @(Index 2) worldPos) 0.0)
  put @"out_normal" (Vec4 (view @(Index 0) encN) (view @(Index 1) encN) (view @(Index 2) encN) 0.5)  -- roughness=0.5
  put @"out_albedo" (Vec4 texR texG texB 1.0)  -- ao=1
  put @"out_emissive" (Vec4 0 0 0 1)  -- no emissive
```

### Fix 2 (Recommended): Fix Descriptor Set Layout Mismatch

Move `bindlessPassDescriptorSetLayout` creation before the pipeline layout, and use it for the pipeline layout:

**`DeferredResources.hs`**:
```haskell
-- Create bindless pass descriptor set layout FIRST
bindlessPassDescriptorSetLayout <- DescriptorSetLayout.managedBindlessPassDescriptorSetLayout device

-- Use it for pipeline layout
bindlessPipelineLayout <- PipelineLayout.managedPipelineLayoutWithPushConstants
  device [bindlessPassDescriptorSetLayout] [bindlessPushConstantRange]
```

### Fix 3 (Optional): Push Metallic/Roughness via Push Constants

Extend the push constant struct to include metallic and roughness:
```haskell
Struct '[ "model" ':-> M 4 4 Float
        , "materialIndex" ':-> Word32
        , "metallicFactor" ':-> Float
        , "roughnessFactor" ':-> Float
        ]
```

Push constant range: 64 + 4 + 4 + 4 = 76 bytes (update from 68 to 76).

Update the host-side push data in `Deferred.hs:279-286`:
```haskell
pushData = map realToFrac
  [ m00, m01, m02, m03
  , m10, m11, m12, m13
  , m20, m21, m22, m23
  , m30, m31, m32, m33
  , fromIntegral matIdx
  , dcMetallicFactor drawCall
  , dcRoughnessFactor drawCall
  ] :: [Float]  -- 19 floats = 76 bytes
```

And update the push constant range in `DeferredResources.hs:595` from 68 to 76.

## Priority

| Fix | Priority | Impact |
|-----|----------|--------|
| Fix 1: World position | **P0** | Makes cube visible |
| Fix 2: Descriptor layout | P1 | Eliminates validation errors, correct UB |
| Fix 3: Metallic/roughness | P2 | Correct PBR material properties |
| Fix 4: Encode normals | **P1** | Correct lighting (included in Fix 1) |
| Fix 5: Emissive output | P2 | Prevents blue tint (included in Fix 1) |

Fix 1 + Fix 2 should be applied together. Fix 3 can be done separately.
