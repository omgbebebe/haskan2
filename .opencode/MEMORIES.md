# Haskan2 — Critical Project Context (Survives Compaction)

## Core Principle
**NO WORKAROUNDS. EVER.** If a dependency is missing a feature, we implement it properly. If a tool is broken, we fix it. Never accept hacks, shortcuts, or "good enough" solutions.

## Build & Run
- **Build**: `~/bin/env-wrap cabal build exe:haskan2`
- **Run**: `LD_LIBRARY_PATH=3rdparty/jolt-wrapper:$LD_LIBRARY_PATH ~/bin/env-wrap cabal run exe:haskan2 -- ARGS`
- **Physics test**: `~/bin/env-wrap cabal run test:haskan2-test`
- **UV check**: `--uv-check-cube`, `--uv-check-sphere`, `--uv-check-plane`
- **Lights**: `--lights N` (1-8, default 3)
- **Day/Night**: `--day-night --time HOURS --time-speed FACTOR`
- **Cloud test**: `--cloud-test`
- **Procedural sky**: `--procedural-sky`

## Architecture
- **GHC 9.14.1**, Cabal-only for Haskell deps, Nix for system libs
- **FIR fork**: `3rdparty/fir/` — SPIR-V EDSL with extensions (math ops, spirv-opt, loop fixes, array literals)
- **Effects**: `effectful` over mtl; no IORef globals
- **Threading**: 4 threads (input, state update, physics, render) via STM TVars
- **Prefix**: `~/bin/env-wrap` for commands needing project nix environment

## Current Status (2026-05-19)
- **M9 COMPLETE**: PBR deferred rendering, normal mapping, AO, emissive, IBL split-sum with BRDF LUT
- **M10 COMPLETE**: Multi-light, skybox, day/night cycle, volumetric clouds (96-step adaptive raymarch)
- **FIR Math Ops COMPLETE**: 20+ vector/matrix operations
- **FIR Optimization COMPLETE**: spirv-opt Phase 0 (596× size reduction), Phase 1.3 (vectorized IfF)
- **FIR Loop Codegen FIXED**: Three critical bugs in while loop CFG
- **FIR Array Literals COMPLETE**: TH `arrayLit`/`arrayLitE` with nested array support
- **Dear ImGui COMPLETE**: Vulkan backend, input forwarding, cloud debug panel, physics debug panel
- **Procedural Sky COMPLETE**: Compute-shader generated cubemap with Hosek-Wilkie scattering
- **Jolt Physics COMPLETE**: All 7 phases — Nix build, C wrapper, Haskell FFI, async thread, render sync, scene loading, ImGui panel
- **Cloud Ghosting FIXED**: Per-swapchain-image VP ring buffer eliminates temporal reprojection mismatch
- **God Ray Render Pass COMPLETE**: 32-sample radial blur on cloud opacity mask, between cloud and lighting passes
- **Sunset Colors FIXED**: Directional color temperature (warmth = sunProximity × horizonFactor) — orange/red near sun at dusk, deep blue away from sun

- **AP Volume Phase 1-2 COMPLETE**: 3D aerial perspective volume compute shader (64×32×64 RGBA16F) with raymarched scattering, samples cloud noise texture, writes to 3D storage image, read by lighting pass
- **Compile-time Shader Compilation**: Template Haskell `compileShader` runs FIR→SPIR-V during `cabal build`. Build fails immediately on shader errors, not deferred to runtime.
- **Tileable Noise FIXED**: Cloud noise (256³) and weather map (512²) generators now use period-based hashing. Frequencies are powers of 2 (2, 8, 16, 32 for noise; configurable for weather). Eliminates hard world-axis seams when sampler REPEAT wraps.
- **Cloud Debug Modes FIXED**: Shift+F1/F2/F3 now show actual internal values:
  - F1: Weather map (R=coverage, G=cloud type, B=storm intensity)
  - F2: Height profile (parametric curve at un-dithered entry point)
  - F3: Raw 3D noise (R channel of cloud_noise at entry point)
  - Previously showed final composited sky color channels (identical white/grey)
- **God Ray Push Constant Fix**: Pipeline layout was missing `VkPushConstantRange` declaration (44 bytes, FRAGMENT_BIT) — pre-existing bug exposed by validation layer.
- **Image Layout Transition Fixes**: Added initial transitions for cloud images, cloud history images, and g-buffer images from UNDEFINED→SHADER_READ_ONLY_OPTIMAL. Changed cloud render pass initialLayout from UNDEFINED to SHADER_READ_ONLY_OPTIMAL.
- **AP Volume Uniform Struct**: `V 4 (V 4 Float)` → 4 separate `V 4 Float` fields (`invViewProj0-3`). FIR cannot compute alignment for nested vectors in Struct.
- **AP Volume Pipeline Barrier**: Memory barrier after compute dispatch (COMPUTE_SHADER/SHADER_WRITE → FRAGMENT_SHADER/SHADER_READ).
- **Lighting Descriptor Pool**: Increased `lightingTexturesPerSet` from 9 to 10 (added ap_volume 3D texture binding).
- **AP Volume Image Layout**: Descriptor sets use `VK_IMAGE_LAYOUT_GENERAL` for sampling (same layout as compute writes, avoids transition).

## Key Design Decisions
1. **glTF UV**: Matches Vulkan (0,0 = top-left). No `flipV`.
2. **Y-down**: Negative viewport height (`height = -h; y = h`), Vulkan 1.1+ core
3. **Backface culling**: `BACK_BIT` + `COUNTER_CLOCKWISE`
4. **Push constant**: 116 bytes (lighting), 216 bytes (clouds — exceeds Vulkan minimum 128)
5. **Push constant packing**: FIR std430 `V 3 Float` = 12 bytes, alignment=16. NO tail padding after vec3.
6. **Vertex stride**: 60 bytes (pos 12 + uv 8 + norm 12 + tangent 16 + col 12)
7. **G-buffer**: position.a=metallic, normal.a=roughness, albedo.a=ao
8. **Normal encoding**: `* 0.5 + 0.5` in g-buffer, `* 2 - 1` in lighting
9. **Present mode**: `IMMEDIATE_KHR`
10. **Texture format**: `Rgba8 UNorm`; view `VK_FORMAT_R8G8B8A8_UNORM`
11. **JuicyPixels**: Row 0 at top; Vulkan stores row 0 at top. No V-flip.
12. **FIR optimization**: Always use `[SPIRV (Version 1 5), Optimize]` flags for shader compilation
13. **FIR if-then-else on `Code` types**: Scalar `if` works via `OpSelect`. **BUT** intermediate `Code Float` bindings (e.g. `let mask = if x then 0.0 else 1.0`) can trigger GHC solver limit (`solveWanteds: too many iterations`) in complex shaders. **Workaround**: inline the conditional into each branch rather than binding an intermediate.
14. **Cloud pass**: Half-resolution, 250-step adaptive raymarch, temporal history
15. **ImGui backend**: `DearImGui.SDL.Vulkan`, sync in render loop, separate descriptor pool
16. **Physics**: Jolt v5.5.0 via C wrapper, async thread, TVar state sync, `_physics_box` naming convention
17. **FIR Struct matrix fields**: Must be declared as separate `V 4 Float` rows, NOT `V 4 (V 4 Float)`. FIR cannot compute Extended alignment for nested vectors.
18. **3D image layout for compute+graphics**: Use `GENERAL` for both compute writes and fragment sampler reads. No layout transitions needed between passes.
19. **Compile-time shader compilation**: `Graphics.Haskan.Vulkan.Shaders.Compile` module triggers all 20 shader compilations via TH. Import it (or import it from Setup.hs) to enforce build-time validation. Runtime `compileAllShaders` still runs but overwrites pre-compiled files.
20. **Tileable noise periods**: Hash coordinates must wrap with `fract(px / period) * period`. Frequencies must be powers of 2 for seamless tiling in power-of-2 textures.

## Camera
- **Distance**: 20.0 default, min 0.1, max 20.0
- **Animation**: Slerp interpolation, 0.1s duration
- **Elevation bounds**: `(-pi/2 + 0.01, pi/2 - 0.01)`
- **Pitch axis**: Local right axis from current forward (not world-X)

## Active Milestones & Plans
| File | Status | Description |
|------|--------|-------------|
| `MILESTONE_FIR_PIPELINE_FIXES.md` | Complete | Fix 1 (atomics), Fix 2+4A (Choose/abs), Fix 3 (spec constants codegen + runtime), Fix 4B-4D (type errors/debug printf/group ops) all done |
| `MILESTONE_EEVEE_PARITY.md` | Not started | 5-phase EEVEE parity plan (~50-80 weeks, FIR fixes first) |
| `MILESTONE_CLOUD_SHADER_PRODUCTION.md` | Phase 7 pending | Cloud production quality, automated tests |
| `MILESTONE_CLOUD_LIGHTING_AMBIENT.md` | Not started | Height-graded ambient + multi-scattering |
| `MILESTONE_CLOUD_WEATHER_MAP.md` | **Complete** | 2D weather map texture for spatial cloud variation — tileable hash, domain warp, coverage/type/height channels |
| `MILESTONE_DEAR_IMGUI.md` | Phases 5-7 pending | Status panel, rendering controls, physics panel |
| `MILESTONE_JOLT_PHYSICS.md` | Complete | Physics integration |
| `MILESTONE_FIR_IMPROVEMENTS.md` | Complete | Texture checking, layout gen, vector unpack QoL |
| `MILESTONE_FIR_GAPS.md` | Open issues | Choose overlap, abs, type inference cascades |
| `MILESTONE_FIR_MATH.md` | Complete | All 20 vector/matrix ops implemented |
| **AP Volume** | **Phase 2 Complete** | 3D aerial perspective volume compute + lighting integration |
| `MILESTONE_MESH_SHADER_CDLOD.md` | **Phases 1-4 Complete** | FIR mesh shader foundation, host pipeline, CDLOD data structures, terrain mesh+fragment shaders |

## Active Issues (See `.opencode/PROJECT_STATE.md` for full audit)

### P0 — Critical
1. **FIR if-then-else/mixV on `Code` types**: Overlapping instances → branchless `step()` workarounds everywhere
2. **Dynamic sky regeneration no-op**: `needsSkyRegen` flag checked but handler is TODO. Day/night cycle doesn't update procedural sky.

### P1 — High
3. ~~**Cloud ghosting in lighting pass**~~ **FIXED 2026-05-19**: See session entry below. Root cause was per-swapchain-image VP mismatch, not god ray sampling.
4. **Cloud push constant 216 bytes**: Exceeds Vulkan 128-byte minimum. Won't run on mobile/integrated.
5. **No `abs` for `Code` types**: `step()` workaround in 4+ places
6. ~~**Zenith solid color**~~ **FIXED 2026-05-19**: Removed `fract()` from noise UVs; sampler REPEAT handles tiling seamlessly. Horizon epsilon increased to 0.05.
7. ~~**Cloud density tiling seams**~~ **FIXED 2026-05-19 (latest)**: Hash functions now wrap coordinates with `fract(px/period)*period`. Frequencies are powers of 2 for seamless tiling.
8. ~~**Cloud debug modes misleading**~~ **FIXED 2026-05-19 (latest)**: Debug modes 13/14/15 now show actual weather map, height profile, and raw noise (not final sky color channels).

### P2 — Medium
6. Blue noise tileability unverified
7. Render graph dependencies not declared (`rpInputs = []`)
8. Missing explicit COLOR_ATTACHMENT → TRANSFER barrier
9. FIR type inference cascade errors
10. IBL dynamic sky — HDRI baked sun looks like lighthouse when rotated

## Critical Files
- `src/Graphics/Haskan/Engine.hs` — Main loop, ECS, deferred graph, input polling with ImGui
- `src/Graphics/Haskan/Engine/Physics.hs` — Physics thread lifecycle
- `src/Graphics/Haskan/Engine/Types.hs` — GameState with TVars, PhysicsBodySpec
- `src/Graphics/Haskan/Vulkan/Shaders/Compute/APVolume.hs` — AP volume compute shader (raymarched scattering)
- `src/Graphics/Haskan/Vulkan/Shaders/Compute/APVolumeUniforms.hs` — AP volume uniform struct definition
- `src/Graphics/Haskan/Vulkan/Shaders/Compute/CloudNoiseGen.hs` — Tileable 3D cloud noise generator
- `src/Graphics/Haskan/Vulkan/Shaders/Compute/WeatherMapGen.hs` — Tileable 2D weather map generator
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/GodRays.hs` — God ray radial blur shader
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` — Cloud raymarching + analytic sky + debug modes
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/LightingProcedural.hs` — Lighting + skybox + AP volume sampling
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Lighting.hs` — Lighting + skybox + AP volume sampling (non-procedural)
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/GBuffer.hs` — G-buffer shaders, normal mapping
- `src/Graphics/Haskan/Vulkan/Shaders/TH.hs` — Template Haskell compile-time shader compilation
- `src/Graphics/Haskan/Vulkan/Shaders/Compile.hs` — Triggers all 20 shader compilations at build time
- `src/Graphics/Haskan/UI/Backend.hs` — ImGui Vulkan backend, debug panels
- `src/Graphics/Haskan/Camera.hs` — Orbital camera, quaternion rotation, animation
- `src/Graphics/Haskan/DayNight.hs` — Sun trajectory, sky color, IBL intensity
- `src/Graphics/Haskan/Render/Deferred.hs` — Deferred graph builder, push constant packing, cloud debug data
- `src/Graphics/Haskan/Vulkan/DeferredResources.hs` — Cloud extent, images, pipelines, AP volume resources
- `src/Graphics/Haskan/Engine/Render.hs` — Render loop, ImGui init/shutdown, frame building, sky regen TODO
- `src/Graphics/Haskan/Engine/Render/Internal/PassRecording.hs` — Command buffer recording, AP volume dispatch + barrier
- `src/Graphics/Haskan/Scene/ECS.hs` — Entity component system
- `src/Graphics/Haskan/Scene/GLTF.hs` — glTF loading, physics body creation from naming convention
- `src/Graphics/Haskan/Input.hs` — Key bindings
- `3rdparty/fir/` — FIR fork with math ops, spirv-opt, loop fixes, array literals
- `3rdparty/jolt-wrapper/` — C wrapper for Jolt Physics v5.5.0

## Vulkan Interop: vulkan-api ↔ vulkan package
- `vulkan-api` handles are type synonyms: `type VkDevice = Ptr VkDevice_T`
- `vulkan` package handles are data types: `Device (Ptr Device_T) DeviceCmds`
- dear-imgui uses `vulkan` package, only touches `*Handle` accessors
- **Conversion**: `Vk.Device (castPtr ptr) Vk.zero` — `castPtr` for phantom type, `zero` for unused Cmds
- **Never use**: `unsafeCoerce` (wrong heap layout), `undefined` for Cmds (strict field, crashes)

## Session History (condensed)

### 2026-05-19 (latest): AP Volume Integration + Compile-Time Shaders + Tileable Noise
- **AP Volume compute shader**: 64×32×64 RGBA16F 3D texture, local size 4×4×4, dispatch 16×8×16 workgroups.
  - `APVolume.hs`: Raymarched scattering with cloud noise sampling, Beer-Lambert transmittance, Henyey-Greenstein phase function
  - `APVolumeUniforms.hs`: Camera pos, 4× invViewProj rows, sun dir/color, cloud base/top, time, near/far
  - Wired into lighting pass (both `Lighting.hs` and `LightingProcedural.hs`) at binding 9/10
  - Samples 3D texture at `(uvX, uvY, depthT)` where `depthT = log(dist/near) / log(far/near)`
  - Applies: `final = sceneColor * (1.0 - alpha) + rgb`
- **AP Volume infrastructure**:
  - `DescriptorSetLayout.hs`: TH-generated layout with StorageImage + Texture3D + Uniform
  - `DescriptorPool.hs`: Pool with storage image, sampler, and UBO slots
  - `DeferredResources.hs`: 3D image creation, memory allocation, view, initial layout transition to GENERAL
  - `PassRecording.hs`: Dispatch after g-buffer pass + memory barrier (COMPUTE→FRAGMENT)
  - `Setup.hs`: Shader compilation to `ap_volume_comp.spv`
- **Compile-time shader compilation**:
  - `Graphics.Haskan.Vulkan.Shaders.TH`: `compileShader` TH function using `FIR.compileTo` in `runIO`
  - `Graphics.Haskan.Vulkan.Shaders.Compile`: imports all 20 shader modules, calls `$(compileShader ...)` for each
  - `Setup.hs:85`: imports `Compile` module to trigger build-time compilation
  - `haskan2.cabal`: added `text-short` dependency, exposed `Shaders.TH` and `Shaders.Compile`
  - Build fails immediately with `[Shader Compile Error] path: message` if any shader is invalid
- **Tileable noise fix**:
  - `CloudNoiseGen.hs`: Added `period` parameter to hash functions. Frequencies changed to 2.0, 8.0, 16.0, 32.0 (powers of 2).
  - `WeatherMapGen.hs`: Same tileable hash approach for 2D weather map.
  - Hash wraps coordinates: `fract(px / period) * period` before hashing.
  - Eliminates hard seams when sampler REPEAT wraps texture boundaries.
- **Cloud debug modes fixed**:
  - Added `debugMode` field to `CloudFrameData` struct
  - Pass `dpdDebugMode` from host to cloud UBO
  - Debug values computed at un-dithered entry point (`tNear`, not `tEntry`) for consistent visualization
  - Shift+F1: Weather map RGB (coverage, cloud type, storm intensity)
  - Shift+F2: Height profile (parametric curve value)
  - Shift+F3: Raw noise (cloud_noise R channel)
- **Validation fixes**:
  - God ray pipeline layout: added `VkPushConstantRange` (44 bytes, FRAGMENT_BIT)
  - Cloud history images: initial transition UNDEFINED→SHADER_READ_ONLY_OPTIMAL
  - G-buffer images: initial transition UNDEFINED→SHADER_READ_ONLY_OPTIMAL
  - Cloud images: initial transition UNDEFINED→SHADER_READ_ONLY_OPTIMAL
  - Cloud render pass: `initialLayout` changed from UNDEFINED to SHADER_READ_ONLY_OPTIMAL
  - AP volume descriptor sets: use `GENERAL` layout for combined image sampler binding
  - Lighting descriptor pool: `lightingTexturesPerSet` 9→10
- **AP Volume uniform struct fix**: `V 4 (V 4 Float)` caused `primTySizeAndAli: cannot compute Extended size & alignment for Vector {size=4, eltTy=Vector...}`. Changed to 4 separate `V 4 Float` fields.

### 2026-05-19 (later): God Ray Render Pass + Sunset Color Fix
- **God ray render pass**: Implemented proper 32-sample radial blur between cloud and lighting passes:
  - `GodRays.hs`: 32-sample loop with exponential decay (decay=0.95), samples `cloud_result` alpha as occlusion mask
  - Full Vulkan infrastructure: images, framebuffers, pipeline, descriptor sets (1 sampler binding for cloud_result)
  - Render graph: inserted between cloud and lighting passes
  - `LightingProcedural.hs`: samples `god_ray` texture at binding 9, composites additively with sky
- **God ray half-screen bug**: Vertex shader had `x = if vid == 0 then (-1.0) else 3.0` — when vid=2, x=3.0, y=3.0. The large triangle only covered ~half the screen.
  - **Fix**: `x = if vid == 1 then 3.0 else (-1.0); y = if vid == 2 then 3.0 else (-1.0)` — produces correct (-1,-1), (3,-1), (-1,3) large triangle
- **Sunset/dusk blue→red fix**: `env_map` cubemap sampling returned black/very dark in cloud pass. Reverted to analytic sky with directional color temperature:
  - `warmth = sunProximity * horizonFactor`
  - `sunProximity = max(0, dot(viewDir, sunDir))` — 1.0 when looking directly at sun
  - `horizonFactor = 1.0 - clamp((sunElev + 0.1) / 0.4, 0, 1)` — 1.0 when sun near horizon
  - At sunset looking at sun: warmth ≈ 1.0, colorTemp = (1.0, 0.55, 0.25) → orange/red
  - At sunset looking away: warmth ≈ 0, no tint → pure Rayleigh scattering → deep blue
  - At noon: horizonFactor ≈ 0, no tint → natural blue sky
- **LightingProcedural.hs**: Added `god_ray` texture at binding 9, replaced hardcoded `godRayR=0` with sampled values

### 2026-05-19: Cloud Ghosting — ROOT CAUSE FOUND AND FIXED
- **True root cause**: `prevViewProj` and `prevTime` were single TVars overwritten every frame, but cloud history textures are per-swapchain-image. With `numSwapchainImages=3` and `maxFramesInFlight=2`, history could be 2+ frames old while VP was only 1 frame old. Temporal reprojection used wrong matrix → displaced ghost.
- **Fix**: Changed `rePrevViewProj`/`rePrevTime` from `TVar` to `[TVar]` arrays sized to `numSwapchainImages`. Read/write moved into `buildRecordAction` and indexed by `imageIdx` (actual swapchain image), matching history texture age exactly.
- **Secondary fixes** (individually correct but insufficient alone):
  - `Clouds.hs`: Removed `fract()` from noise UVs — sampler `REPEAT` handles tiling without hard-edge discontinuities
  - `Clouds.hs`: Horizon epsilon `0.001 → 0.05` — smooths tangent-ray singularity
  - `Clouds.hs`: Dither scaled by `min 1.0 (totalRayLength / 2000.0)` — reduces pixelation at zenith
  - `LightingProcedural.hs`: God rays masked to sky-only (geometry gets no god ray contribution)
- **FIR type inference workaround**: Intermediate `Code Float` binding `let mask = if hasGeometry then 0.0 else 1.0` triggered `solveWanteds: too many iterations` in LightingProcedural.hs. Fixed by inlining: `final = if hasGeometry then gamx else skyR + godRayR`.
- **Blend factor reduced**: `dpdBlendFactor 0.92 → 0.3` (effective blend ~9% vs ~28%). With correct VP match, less blend needed.

### 2026-05-18: Cloud Black Screen Root Cause + Validation Fixes
- **Root cause of black screen**: `FormatDefault` type family in FIR mapped `Floating (16 ': _)` → `Half`. Vulkan requires `Float` (32-bit) sampled type for ALL SFLOAT image formats (VUID-SampledType-04471). Shader reads returned undefined → black.
  - **Fix**: `3rdparty/fir/src/FIR/Syntax/Synonyms.hs:339` — removed `Half` case, all `Floating` formats now map to `Float`
- **Cubemap format mismatch**: `env_map`/`irradiance_map` declared as `RGBA8 UNorm` but Vulkan images are `R16G16B16A16_SFLOAT`. Changed to `RGBA16 F` in Clouds.hs, Lighting.hs, LightingProcedural.hs
- **Removed redundant `convert` calls**: Clouds.hs, Lighting.hs, LightingProcedural.hs had `Half→Float` conversions that became identity after FormatDefault fix
- **NaN density bug**: `hPct = min 1.0 (h / heightScale)` allowed negative values. `negative ** 0.4` = NaN, poisoning transmittance accumulation. **Fix**: `clamp (h / heightScale) 0.0 1.0`
- **Density remap fix**: Old formula `clamp((noise - (1-coverage)) / coverage)` amplified noise too aggressively (division by small coverage). **Fix**: `max 0.0 (noise - (1.0 - combinedCoverage))` — sparse threshold
- **Same fixes applied to light density** (`lhPct` clamp + remap)
- **Validation fixes**: moved history copy outside render pass, added pre-dispatch cubemap layout transitions, fixed `lightingTexturesPerSet 7→8`
- **God ray UV clamping**: `sampleX/Y = clamp(...)` prevents `cloud_result` sampling outside [0,1]
- **maxNoiseLod 4→2**: prevents sampling 16³ blocky mip at zenith
- **Empty-space skip disabled**: causes vertical banding artifacts (step-size jumps)

### 2026-05-18 (later): Ghosting Investigation — SUPERCEDED
- **Previous analysis was wrong.** See 2026-05-19 entry for true root cause (per-swapchain-image VP mismatch).
- **What we got right**: God ray mask to sky-only, `fract()` removal, horizon epsilon — all individually correct secondary fixes.
- **What was wrong**: Ghosting was NOT caused by god ray sampling, nearest-neighbor aliasing, or UV clamping. It was temporal reprojection using a 1-frame-old VP matrix against a 2+-frame-old history texture.
- **Reference**: `.opencode/CLOUD_GHOSTING_ANALYSIS.md` contains full diagnostic trail.

### 2026-05-12: FIR Math + IBL Rotation + Clouds
- Added GLSL math to FIR: clamp, mix, step, smoothstep, fract + 20 vector ops
- IBL cubemap rotation via sun azimuth in push constant
- Clouds blocked by SPIR-V bloat → unblocked by spirv-opt integration

### 2026-05-12 (later): FIR Optimization + Clouds Completion
- spirv-opt Phase 0: 10.9MB → 18.3KB (596× reduction)
- Phase 1.3: Vectorized SelectionF (forward-compatible)
- Phase 1.1/1.2 cancelled (spirv-opt handles it)
- M10.4 clouds: hash noise, fBm, spherical UV, height mask, sun shading

### 2026-05-13: Cloud Modularization + Push Constant Fix
- Cloud shader extracted to separate module + render pass
- Quarter-res rendering, temporal accumulation
- Push constant layout mismatch (std430 vec3 = 12 bytes, no tail padding)

### 2026-05-14: FIR Loop Codegen Fixes
- Three bugs: OpLoopMerge timing, ID remap, block ordering
- Test infrastructure: tasty-based runner, 11 validation tests

### 2026-05-15: Dear ImGui Integration
- Phases 1-4: dependency setup, Vulkan backend, input forwarding, cloud debug panel
- Handle conversion fix: proper constructors with castPtr + zero

### 2026-05-15 (later): FIR QoL + TH Descriptor Set Migration
- FIR improvements: compile-time texture reference checking, `unpackV2/V3/V4`, test suite
- TH descriptor set layout generation
- Migrated cloud, lighting, and compute descriptor set layouts to TH

### 2026-05-16: Procedural Sky + Jolt Physics
- Procedural sky compute shaders: RadianceGen, IrradianceGen, SkyLUTGen
- Fixed scattering model, cubemap formats, sun trajectory
- Jolt Physics Phases 1-7: full integration from Nix to ImGui panel
- Physics thread with TVar sync, render integration, scene description

### 2026-05-17: Cloud Quality + Documentation
- Fixed cloud voxel aliasing: 250 steps (was 62), step size 20m (was 80m)
- Reverted mistaken full-res cloud change; half-res + dense steps is correct
- Updated project documentation and state audit

## Environment
- **OS**: NixOS, **GPU**: NVIDIA RTX 4090, **Vulkan**: 1.4.312
- **Descriptor indexing**: nonUniform=True, updateAfterBind=True, partiallyBound=True, runtimeArray=True
- **LD_LIBRARY_PATH**: Must include `3rdparty/jolt-wrapper/` for `libjolt_wrapper.so`

### 2026-05-24: Mesh Shader + CDLOD Terrain (Phases 1-4)
- **FIR Mesh Shader Foundation** (Phase 1):
  - Fixed SPIR-V values: `MeshShadingEXT` = 5283, `OpSetMeshOutputsEXT` = 5295, `OutputPrimitivesEXT` = 5270, `OutputTrianglesEXT` = 5298
  - Added `MeshShaderBuiltins` with flat arrays for per-primitive outputs (`gl_PrimitiveTriangleIndicesEXT`, `gl_CullPrimitiveEXT`)
  - Added `setMeshOutputsEXT` and `meshShader` functions to `FIR.Syntax.Program`
  - Made `ShaderModule` polymorphic in stage type
  - `HelloMesh` example compiles and passes `spirv-val --target-env vulkan1.4`
- **Host-Side Mesh Pipeline** (Phase 2):
  - `Graphics.Haskan.Vulkan.Interop`: vulkan-api ↔ vulkan package handle conversions (`toVulkanDevice`, `fromVulkanPipeline`, etc.)
  - `Graphics.Haskan.Vulkan.MeshPipeline`: `createMeshPipeline` using `vulkan` package, no vertex input, mesh+fragment stages
  - `cmdDrawMeshTasksEXT` wrapper for dispatching mesh workgroups
  - Device creation: optional `VK_EXT_mesh_shader` extension enable
  - `DeviceCapabilities`: queries extension support via `enumerateDeviceExtensionProperties`
- **CDLOD Data Structures** (Phase 3):
  - `Graphics.Haskan.Terrain.CDLOD`: quadtree, node selection, frustum culling, morph factor computation
  - `defaultCDLODConfig`: 8×8 patches, 4 LOD levels, 8192m world, 0.25 morph zone ratio
  - `Graphics.Haskan.Terrain.NodeSSBO`: `TerrainNodeGPU` Storable struct (32 bytes, 16-byte aligned)
- **Terrain Mesh Shaders** (Phase 4):
  - `Graphics.Haskan.Vulkan.Shaders.Deferred.TerrainMesh`: FIR mesh + fragment shaders
  - Mesh shader: reads node SSBO via `gl_WorkgroupID`, emits 8×8 grid (64 vertices, 98 triangles) per workgroup
  - Fragment shader: UV-based color output
  - Build-time compilation via TH in `Graphics.Haskan.Vulkan.Shaders.Compile`
  - Integrated into `ShaderModules` in render setup
  - Per-vertex outputs declared as `Array 64` to satisfy Vulkan validation
- **Project structure**: Moved `vulkan-3.26.6/` to `reference_sources/` (available on Hackage), removed from `cabal.project`

- **Mesh Terrain Pipeline Integration** (IN PROGRESS):
  - `meshTerrainEnabled` flag added to `EngineConfig` — skips old ground plane ECS entity when true
  - `DeferredResources` extended with mesh terrain fields: `drTerrainMeshPipeline`, `drTerrainMeshPipelineLayout`, `drTerrainMeshDescriptorSets`, `drTerrainMeshNodeBuffer`/`NodeMemory`
  - `managedTerrainMeshDescriptorSetLayout` — SSBO (binding 0, mesh stage) + heightmap texture (binding 1, mesh stage) + climate texture (binding 2, fragment stage)
  - `managedMeshPipelineWithBlending` — alpha-blended mesh pipeline using `vulkan-api` (not `vulkan` package)
  - `vkCmdDrawMeshTasksEXT` dynamically loaded via `vkGetDeviceProcAddr` (cached in `IORef`)
  - Per-frame CDLOD: `buildCDLODTree` → `extractFrustumPlanes` → `selectVisibleNodes` → `packNodesToSSBO` → upload to SSBO → `cmdDrawMeshTasksEXT`
  - `vkMeshBit` workaround: `vulkan-api` lacks `VK_SHADER_STAGE_MESH_BIT_EXT`, using `VkShaderStageFlagBits 0x00000080`
  - **Heightmap sampling in mesh shader**: Samples `R16 SNorm` elevation texture at world position, displaces Y by `elevRaw * 32767.0 * heightScale`
  - **Fragment shader**: Samples `RGBA32 F` climate texture at world position, applies simple diffuse+ambient lighting
  - TODO: Geomorphing, enable mesh terrain by default, test on actual hardware

### 2026-05-25: Runtime Validation Fixes — Mesh Shader Descriptor Sets + Device Features
- **TerrainMesh.hs descriptor set mismatch**: Shaders used `DescriptorSet 1` but pipeline layout only had one set at index 0.
  - **Fix**: Changed all bindings in `MeshDefs` and `FragmentDefs` from `DescriptorSet 1` to `DescriptorSet 0`.
  - **Root cause of stale SPIR-V**: `cabal` doesn't track SPIR-V files as build outputs. Deleted `.spv` files weren't regenerated because cabal thought everything was "up to date". Required `rm -rf dist-newstyle/build/.../haskan2-0.1.0.0` to force full rebuild.
- **Mesh shader feature validation errors**: `multiviewMeshShader` and `primitiveFragmentShadingRateMeshShader` were enabled by default in `PhysicalDeviceMeshShaderFeaturesEXT` but their prerequisite features (`multiview`, `primitiveFragmentShadingRate`) were not enabled.
  - **Fix**: `Device.hs:105-113` — explicitly set `multiviewMeshShader = False` and `primitiveFragmentShadingRateMeshShader = False` after querying device features.
- **Remaining issues**:
  - 3× `Undefined-Value-StorageImage-FormatMismatch-ImageView` warnings (pre-existing env_map format mismatch)
  - 10× `VUID-vkDestroyDevice-device-05137` buffer/image leaks at shutdown (**pre-existing** — confirmed present in logs before mesh shader changes; `Managed` monad cleanup order issue with nested `with` blocks inside `liftIO`)
  - `DeferredResources.hs:652-655` had duplicate terrain mesh descriptor pool/set allocation — removed

### 2026-05-25: FIR Mesh Shader Arrayness + Fragment Location Fix
- **Root cause**: `fir` library cached old `Arrayness.hs` — cabal didn't detect file changes in `3rdparty/fir/src/FIR/Validation/Arrayness.hs`. The `MeshShaderExecutionInfo` pattern WAS correct but wasn't compiled into the cached `fir` library.
  - **Fix**: Forced rebuild with `touch` + `cabal build fir --ghc-options="-fforce-recomp"`. Confirmed debug `TypeError` pattern fires, proving cached build was stale.
- **TerrainMesh.hs fragment shader locations**: Were still at old values `0, 256, 512, 768` instead of matching mesh shader outputs `0, 1, 2, 3`.
  - **Fix**: Changed `FragmentDefs` locations to `0, 1, 2, 3` to match `MeshDefs` outputs.
- **Validation**: All 30 SPIR-V shaders pass `spirv-val --target-env vulkan1.2`. `haskan2` library compiles clean (119 modules).
- **FIR `Arrayness.hs` mesh shader pattern** (confirmed working):
  ```haskell
  Arrayness SPIRV.Output decs
    ( SPIRV.MeshShaderExecutionInfo ( SPIRV.MeshShaderDetails maxVertices _ ) )
      = 'ImplicitArrayness maxVertices
  ```
  - This strips the implicit `Array N` wrapper from mesh shader per-vertex outputs for location counting.

### 2026-05-24: Terrain Sidecar API Integration (Phase 1)
- **HTTP client**: `Graphics.Haskan.Terrain.Client` — fetches binary tiles from `localhost:7777/terrain?i1=&j1=&i2=&j2=&scale=`
  - Response: `X-Height`/`X-Width` headers + body = H×W int16 LE elevation + H×W×4 float32 LE climate
  - `TerrainTile { ttWidth, ttHeight, ttElevation :: Vector Int16, ttClimate :: Vector Float }`
  - Uses `http-client` Hackage dependency (already in cabal), NOT local package
- **GPU texture upload**: `Graphics.Haskan.Vulkan.Texture`
  - `createTerrainElevationTexture` — `Vector Int16` → `VK_FORMAT_R16_SNORM` 2D texture
  - `createTerrainClimateTexture` — `Vector Float` → `VK_FORMAT_R32G32B32A32_SFLOAT` 2D texture
  - Generic `uploadTextureWithFormatVector :: Storable a => ...` for any storable vector type
- **Render state**: `TerrainTextures` in `SkyNoiseState`, loaded at init via `loadTerrainTextures`
- **FIR shaders**: `Graphics.Haskan.Vulkan.Shaders.Deferred.TerrainOverlay`
  - Vertex: fullscreen triangle, reads camera/frustum rays from UBO
  - Fragment: ray-plane intersection (Y=0), samples elevation + climate, outputs RGBA with alpha
  - Tile scale: 2560×2560 world units (10× texture resolution), centered at origin
  - Elevation-based procedural color (green→brown→grey→white) outside valid climate data
- **Vulkan pipeline integration**:
  - `RenderPass.hs`: `createTerrainOverlayRenderPass` with `LOAD_OP_LOAD` (preserves lighting output)
  - `GraphicsPipeline.hs`: `createFullscreenPipelineWithBlending` — `src_alpha / one_minus_src_alpha`
  - `DescriptorSetLayout.hs`: TH-generated from `TerrainFragmentDefs`, binding 2 is `VK_VERTEX_FRAGMENT_BITS`
  - `DescriptorPool.hs`/`DescriptorSet.hs`: terrain pool + update functions + frame data UBO binding
  - `DeferredResources.hs`: terrain pipeline, framebuffers (swapchain images), UBO, descriptor sets
  - `PassRecording.hs`: terrain pass after lighting, before ImGui; writes camera+frustum to UBO; pipeline barrier `PRESENT_SRC_KHR` → `COLOR_ATTACHMENT_OPTIMAL`
- **Validation fixes**:
  - Descriptor stage flags: terrain UBO binding 2 accessible to both vertex and fragment stages
  - Image layout barrier: explicit transition from `PRESENT_SRC_KHR` before terrain render pass
- **Build**: all 114 modules compile, SPIR-V shaders validated at build time
- **Status**: Green flat plane visible at ground level; API data fetches successfully. Climate/elevation sampling verified working.
