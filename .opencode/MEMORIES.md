# Haskan2 Project Memories

## Build Commands
- **Build:** `nix develop --command cabal build all`
- **Run:** `nix develop --command cabal run haskan2 -- [options] <model>`
- **Run with timeout:** `nix develop --command cabal run haskan2 -- -t 5 unit_cube.obj`
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

## CLI Options (optparse-applicative)
```
Usage: haskan2 MODEL [-t|--timeout SECONDS] [-T|--title TITLE] [--debug-socket PATH]
```
- `MODEL` — positional, required (e.g. `unit_cube.obj`)
- `-t, --timeout SECONDS` — auto-exit after N seconds
- `-T, --title TITLE` — window title (default: "Haskan Demo")
- `--debug-socket PATH` — custom unix socket path for debug server

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

## Debugging Tips
- **Get library sources for reference:** `cabal get <package_name>` (e.g. `cabal get linear`) downloads source to `./linear-1.23.3/` — useful for checking type signatures and implementation details without leaving the project directory.
