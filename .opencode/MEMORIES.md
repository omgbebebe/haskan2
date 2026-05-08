# Haskan2 Project Memories

## Build Commands
- **Build:** `nix develop --command cabal build all`
- **Run:** `nix develop --command cabal run haskan2 -- [options] <model>`
- **Run with timeout:** `nix develop --command cabal run haskan2 -- -t 5 unit_cube.obj`
- **Run with log file:** `nix develop --command cabal run haskan2 -- --log-file /tmp/haskan.log -t 5 MODEL`
- **Help:** `nix develop --command cabal run haskan2 -- --help`

## Critical Vulkan Conventions

### Matrix Storage (Row-Major vs Column-Major)
**This is the #1 source of rendering bugs.**
- `linear`'s `M44` stores matrices **row-major** in Haskell memory
- Vulkan/GLSL/FIR reads `mat4` as **column-major** from uniform buffers
- **Always transpose before upload:** `Buffer.updateUniformBufferRegion` needs `Linear.Matrix.transpose` applied to model/view/projection matrices
- The shader computes `mvp = projection * view * model` (column vectors), which matches transposed row-major data read as column-major
- **Old broken code:** Used `transpose` in `projectionMatrix` and `orbitalToMatrix` definitions; now transposed only at upload time

### View Matrix
- Use `Linear.Projection.lookAt` instead of manual quaternion rotation math
- `lookAt` produces row-major, so it still needs transpose at upload
- `orbitalCameraPosition` computes camera position from azimuth/elevation/distance

### Front Face Winding
- OBJ loader produces **clockwise** triangle winding
- Pipeline must use `VK_FRONT_FACE_CLOCKWISE` with `VK_CULL_MODE_BACK_BIT`
- `COUNTER_CLOCKWISE` causes backfaces to render instead of front faces

## Validation & Resource Management

### Descriptor Pool Sizing
- `maxSets` must exactly match total descriptor set allocations
- Bug: allocated 4 stale sets + 2 frame sets from pool sized for 4 → `VK_ERROR_OUT_OF_DEVICE_MEMORY`
- Fix: size pool to `maxFramesInFlight` (2), remove stale allocations

### Descriptor Pool Types Must Match Layout
- Pool type must exactly match layout type
- Bug: `VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER` in pool vs `VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC` in layout
- Fix: pool uses `VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC`

### Fence/Semaphore Ordering
- **Fence wait/reset must happen BEFORE `vkAcquireNextImageKHR`**
- Bug: acquiring image with semaphore that still had pending signal → validation error
- Fix: move fence wait to start of `drawFrame`, before acquire

### Command Pool Flags
- Per-frame command buffer re-recording requires `VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT`
- Without this flag: `vkBeginCommandBuffer` fails with implicit reset validation error

### Device Feature Enablement
- **Always enable required features in `VkPhysicalDeviceFeatures` passed to `vkCreateDevice`**
- Wireframe geometry shader SPIR-V declares `Geometry` capability → requires `geometryShader = VK_TRUE`
- Bug: geometry shader used but feature not enabled → validation errors `VUID-VkShaderModuleCreateInfo-pCode-08740` and `VUID-VkPipelineShaderStageCreateInfo-stage-00704`, followed by driver UB and app hang after 3-4 seconds
- Fix: query `vkGetPhysicalDeviceFeatures`, create `VkPhysicalDeviceFeatures` with `geometryShader = VK_TRUE` if supported, pass pointer via `withPtr`

## CLI Options (optparse-applicative)
```
Usage: haskan2 MODEL [-t|--timeout SECONDS] [-T|--title TITLE] [--debug-socket PATH] [--log-file PATH]
```
- `MODEL` — positional, required (e.g. `unit_cube.obj`)
- `-t, --timeout SECONDS` — auto-exit after N seconds
- `-T, --title TITLE` — window title (default: "Haskan Demo")
- `--debug-socket PATH` — custom unix socket path for debug server
- `--log-file PATH` — write logs to file in addition to stdout

## Debug Commands
```bash
python3 scripts/debug_client.py get-state         # camera, running state
python3 scripts/debug_client.py get-render-state  # per-entity NDC vertices, matrices
python3 scripts/debug_client.py inspect           # trigger frame snapshot
python3 scripts/debug_client.py set-distance 50.0
python3 scripts/debug_client.py set-target 0 5 0
python3 scripts/debug_client.py set-angles 0.5 0.2
python3 scripts/debug_client.py key escape true   # inject key press
```

### G-Buffer Image Layout Transitions
- G-buffer images must be in `SHADER_READ_ONLY_OPTIMAL` when lighting pass samples them
- **Bug:** `initialLayout = UNDEFINED` but images were in `SHADER_READ_ONLY_OPTIMAL` after first frame → `VUID-vkCmdDraw-None-09600`
- **Fix:** Set `initialLayout = finalLayout = SHADER_READ_ONLY_OPTIMAL` in g-buffer render pass; add one-time `UNDEFINED → SHADER_READ_ONLY_OPTIMAL` barrier after image creation

### Semaphore Indexing
- **renderFinishedSemaphores** must be indexed by `imageIndex` (swapchain image), NOT `frameNumber`
- Each swapchain image needs its own semaphore because the presentation engine holds it until the image is recycled
- **Fences** are indexed by `frameNumber` (frame-in-flight slot) because they synchronize CPU-GPU per frame slot
- **imageAvailableSemaphores** are indexed by `frameNumber` because acquire signals per frame slot

### Semaphore Reuse Bug (GPU Hang After 2-3s) — ROOT CAUSE WAS LAYOUT MISMATCH
- **Symptom:** App hung after 2-3 seconds
- **Original incorrect diagnosis:** Semaphore indexed by imageIndex causes reuse
- **Actual root cause:** G-buffer `initialLayout = UNDEFINED` caused layout mismatch on frame 2+ when image was recycled
- **Fix:** Set `initialLayout = SHADER_READ_ONLY_OPTIMAL` to match actual post-render state
- **Correct indexing:** `renderFinishedSemaphores !! imageIndex`, `renderFinishedFences !! frameNumber`

## Architecture Notes
- **ECS:** Sparse-set based (`IntMap` per component type), 3 test entities at `(-2,0,0)`, `(0,0,0)`, `(2,0,0)`
- **Dynamic UBOs:** `VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC` with per-entity offsets
- **Per-frame recording:** Command buffers recorded each frame, indexed by swapchain image
- **Resource manager:** Typed handles (`MeshHandle`, `TextureHandle`) with STM registry
- **FrameInspector:** F12-triggered markdown snapshots with quaternion-based camera extraction

## Environment
- GHC 9.14.1 via `haskell.compiler.ghc9141` from nixpkgs-unstable
- Cabal-only for Haskell deps, system libs (Vulkan, SDL2) from nixpkgs
- Validation layers available system-wide: `VK_LAYER_KHRONOS_validation`

## Logging Subsystem (effectful)

Partial migration from IORef-based global logger to `effectful` effects library.

### Design
- `Logger` effect with dynamic dispatch — `logMessage level cat msg` via `send`
- `runLogger :: IOE :> es => [LogBackend] -> Eff (Logger : es) a -> Eff es a`
- `LogBackend` — per-backend name, min level, formatter, write function
- Backends: `stdoutBackend`, `stderrBackend`, `fileBackend`
- `defaultFormatter` — human-readable with timestamp; `jsonFormatter` — structured JSON

### Bridge for Mixed Codebase
- `logInfoIO`, `logDebugIO`, etc. — `MonadIO m =>` variants that write to global `IORef [LogBackend]`
- `setGlobalBackends` / `getGlobalBackends` — runtime backend configuration
- Used by `Engine.hs`, Vulkan wrappers, glTF loader, asset preprocessor (all remain `MonadIO`)

### Why Engine.hs stayed MonadIO
- `Managed` is CPS-based: `Managed a = ∀r. (a -> IO r) -> IO r`
- Any `MonadManaged` instance for `Eff` would need to extend the CPS callback scope, which is impossible
- Attempted orphan instance `using m = liftIO $ with m pure` destroyed resources immediately (create → return → destroy)
- Fixing this requires either replacing all `Managed` code with `resourcet-effectful` or restructuring the entire Vulkan layer
- Decision: keep `Engine.hs`/`renderLoop` in `Managed`/`MonadIO`; use `logInfoIO` bridge for logging

### MonadFail Removal
- Removed `MonadFail` constraints across codebase
- Replaced `fail` with `error` in: `Resources.hs`, `Texture.hs`, `Memory.hs`, `Buffer.hs`, `ObjLoader.hs`, `PieLoader.hs`, `GLTF.hs`
- `Fail :> es` effect available via `Effectful.Fail` for new code that needs structured failure

### Build Note
- Added `allow-newer: monad-control:transformers-compat` to `cabal.project` to resolve `effectful` diamond dependency with `vector-sized`/`adjunctions` chain
- `effectful` in library `build-depends` only (not executable — `Main.hs` runs in plain `IO`)

## Debugging Tips
- **Get library sources for reference:** `cabal get <package_name>` (e.g. `cabal get linear`) downloads source to `./linear-1.23.3/` — useful for checking type signatures and implementation details without leaving the project directory.

## Asset Preprocessor Subsystem

### New Modules
- `Graphics.Haskan.Assets.Cache` — file-based cache keyed by djb2 hash of `(sourceBytes <> configFingerprint)`. Stores under `.haskan2-cache/textures/` and `meshes/`
- `Graphics.Haskan.Assets.InternalFormat` — `InternalTexture`, `InternalMesh`, `TextureMetadata`, `TextureFormat` (RGBA8 variants), versioned cache header
- `Graphics.Haskan.Assets.TexturePreprocessor` — `TextureConfig` (resize to PoT, target format, mips placeholder), bilinear resize, serialize/deserialize, cache-aware `loadTextureCached`

### Design Decisions
- Cache key = hash of raw source + config fingerprint (format, dimensions, mips flag)
- Internal texture format: 24-byte header + raw RGBA8 bytes
- `nextPowerOfTwo` with bilinear `resizeImage` for array compatibility
- `StrictData` on all records

### Done
- `loadTextureCached` / `loadTextureBytesCached` wired into `Texture.createTextureResource` and `Texture.createTextureFromBytesCached`. Cache directory `.haskan2-cache/textures/` confirmed populated.

### Pending Integration
- Add mesh preprocessing skeleton (vertex format normalization, index optimization)
- Add cache eviction / size limit policy
- Parallel batch preprocessing for model loading

## Bindless Rendering: Current vs Future

### What We Have Now (Texture2DArray)
- FIR patch adds `Texture2DArray` type synonym (arrayed 2D sampled image)
- Coordinates are `vec3(u, v, layer)` — layer selects array slice
- All layers must have **identical dimensions** — this is a Vulkan/Texture2DArray constraint
- Material index passed via push constant in fragment shader
- Descriptor set layout uses `UPDATE_AFTER_BIND` + `PARTIALLY_BOUND` flags

### What True Bindless Requires (Future Work)
Reference: `.opencode/fir_bindless.research.md`

True bindless descriptor indexing is **fundamentally different** from Texture2DArray:

| Aspect | Texture2DArray (Current) | True Bindless (Future) |
|--------|--------------------------|------------------------|
| Array type | Single image, N layers | N separate descriptors in runtime array |
| Dimensions | All layers identical | Each descriptor can have different size |
| SPIR-V type | `OpTypeImage Dim=2D Arrayed=1` | `OpTypeRuntimeArray` of image descriptors |
| Coordinate | `vec3(u,v,layer)` | Dynamic index + standard `vec2` sampling |
| Non-uniform | Not needed (single image) | Requires `NonUniform` decoration propagation |
| Capability | `Shader` + `SampledImageArray` | `RuntimeDescriptorArray` + `SampledImageArrayNonUniformIndexing` |

### FIR Changes Needed for True Bindless
- AST extensions for `RuntimeArray` / `Bindless` type constructors
- `nonUniform` combinator to annotate divergent indices
- `NonUniform` decoration propagation through access chain to final resource operand (VUID-RuntimeSpirv-None-10148)
- `OpTypeRuntimeArray` emission in SPIR-V backend
- Capability tracking for `RuntimeDescriptorArray` and per-type non-uniform indexing capabilities

## M8 Progress — GPU-Driven Compute Culling

### Cull Compute Shader (`Shaders/Compute/Cull.hs`)
- Fixed FIR optic/type errors:
  - `gl_GlobalInvocationID` via `~(Vec3 idx _ _) <- get` pattern
  - `AnIndex Word32` (not `@Word32`) for runtime array indexing
  - `use @(Name "..." :.: AnIndex Word32) idx` pattern for SSBO array access
  - Wrapped `visibleFlags` in `Struct '["flags" ':-> Array MaxEntities Word32]` (FIR requires SSBOs to be structs or arrays of structs)
  - Moved `use @(Name "cullData" ...)` out of polymorphic helper `testAllPlanes` into concrete `program` to resolve `Binding.Has` type family
  - `pure (Lit ())` for `Program` monad unit (not `pure ()`)
- Manually unrolled `testAllPlanes` (FIR does not support general recursion)
- `testPlane` uses AABB-frustum plane test (select p-vertex, dot product)

### Compute Pipeline Infrastructure
- `DescriptorSetLayout.hs`: `managedComputeDescriptorSetLayout` — 3 bindings (SSBO entities, SSBO visibleFlags, UBO cullData), all `COMPUTE_BIT`
- `DescriptorPool.hs`: `managedComputeDescriptorPool` — 2 SSBO slots + 1 UBO slot, `maxSets = 1`
- `DescriptorSet.hs`: `updateComputeDescriptorSets` — writes all 3 buffer infos
- `ComputePipeline.hs` already existed for test shader

### Engine Integration
- `Engine.hs` compiles cull shader: `FIR.compileTo "data/shaders/fir/cull_comp.spv" ... CullShaders.program`
- Creates compute pipeline layout + pipeline + descriptor set
- Creates SSBO/UBO buffers:
  - Entity SSBO: 4096 entries, 128 bytes/entry (124-byte struct + 4 bytes array padding), dummy data
  - Visible flags SSBO: 4096 Word32s, initialized to 0
  - Cull data UBO: 128 bytes (std140), dummy frustum planes + entity count
- Defined `ComputeEntityData` and `ComputeCullData` Storable types matching FIR layouts
- `ComputeCullResources` record groups all compute resources
- Wired `vkCmdBindPipeline(COMPUTE)` + `vkCmdBindDescriptorSets` + `vkCmdDispatch` before deferred graph in `renderFrameLoop`
- Recursive `renderFrameLoop` call updated to pass `ComputeCullResources`

### Remaining M8 Work
1. ~~Populate entity SSBO with real transforms/AABBs each frame~~ (done)
2. ~~Populate cull data UBO with actual frustum planes each frame~~ (done)
3. ~~Read back visible flags SSBO after dispatch~~ (done)
4. ~~Filter `drawList` to visible-only entities before g-buffer pass~~ (done)
5. Benchmark CPU-driven vs GPU-culled draw loop
6. Phase 2: merge meshes, generate `VkDrawIndexedIndirectCommand` in compute, single `vkCmdDrawIndexedIndirect`

### Fixes Applied (2026-05-08)
- Added `BlockArguments` to `haskan2.cabal` default-extensions to resolve `liftIO $ do` parse error
- Added missing imports: `Control.Lens ((^.))`, `Linear.V3/V4` lens accessors, `Foreign.Ptr (Ptr, castPtr)`, `Linear ((^+^), (^-^))`
- Fixed debug NDC positions `do` block indentation (`STM.atomically` aligned with `let`)
- Fixed `V4` element type: `(1 :: Foreign.C.CFloat)` instead of bare `1`
- Fixed `DrawCall` field: `dcMesh` instead of non-existent `dcMeshHandle`
- Fixed `allocaAndPeek` usage: `allocaAndPeek` already calls `throwVkResult` internally
- Fixed `vp` matrix type: explicit `(realToFrac <$> <$>)` to get `M44 Float` for `extractFrustumPlanes`
- **Fixed gltf-loader index truncation bug**: `meshPrimitiveIndices` was hardcoded to `Vector Word16`. ABeautifulGame's board mesh uses `UNSIGNED_INT` (5125) with 277,248 indices. Indices > 65535 were silently truncated, corrupting geometry. Changed to `Vector Word32` throughout: `Gltf.hs`, `BufferAccessor.hs`, `Decoders.hs`.
- **Removed auto-added ground plane for glTF models**: was clashing with scene geometry
- **Fixed autozoom**: `computeWorldSpaceBounds` reads ECS entities + transforms, computes actual world-space AABBs via `transformAABB`. `adjustCameraForScene` now sets camera target to bbox center and uses FOV-based distance: `distance = max(nearPlane + R, R / sin(FOV/2) * padding)` where R = diagonal/2. Works for tiny models (Avocado: 0.46) to normal models (ABeautifulGame: 5.81).

### Key Files Changed
- `src/Graphics/Haskan/Vulkan/Shaders/Compute/Cull.hs` — frustum culling compute shader
- `src/Graphics/Haskan/Vulkan/DescriptorSetLayout.hs` — compute descriptor set layout
- `src/Graphics/Haskan/Vulkan/DescriptorPool.hs` — compute descriptor pool
- `src/Graphics/Haskan/Vulkan/DescriptorSet.hs` — `updateComputeDescriptorSets`
- `src/Graphics/Haskan/Engine.hs` — compute pipeline creation, buffer allocation, dispatch wiring

## Critical Context
- Build: `nix develop --command cabal build all`
- Run: `nix develop --command cabal run haskan2 -- -t 5 MODEL`
- `linear` `M44` row-major → transpose before `updateUniformBufferRegion`
- Camera: `OrbitalCamera`, WASD XY plane, wheel zoom
- Present mode: `IMMEDIATE_KHR`
- Shader texture format: `Rgba8 UNorm`; view `VK_FORMAT_R8G8B8A8_UNORM`
- Vulkan raw `4211000` = 1.4.312; `vulkaninfo` reports 1.4.341
- Cold start ABeautifulGame ~12s; warm ~0.4s
- Cache dir: `.haskan2-cache/textures/`
- Capabilities: `RuntimeDescriptorArray`=5302, `SampledImageArrayNonUniformIndexing`=65; `NonUniform`=5300 (not 5309)
- `EmptyDataDeriving` required for `Image`; boot files resolve `FIR.Prim.Image` ↔ `FIR.Prim.Types` cycle
- FIR `Base` layout = std430 (storage buffers, push constants); `Extended` layout = std140 (uniform buffers)
- FIR struct array stride = `NextAligned(structSize, structAlignment)` under Base layout
- `EntityData` struct size = 124, array stride = 128; `CullData` struct size = 128 (std140 rounded up)
- FIR shaders do not support general recursion; loops must be unrolled manually
- `Program` monad `do` blocks: `let` for `view` on `Code` values, `<-` for `use`/`assign` monadic actions
- `pure (Lit ())` for unit in `Program`, not `pure ()`
