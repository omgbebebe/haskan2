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

## Current Status (2026-05-17)
- **M9 COMPLETE**: PBR deferred rendering, normal mapping, AO, emissive, IBL split-sum with BRDF LUT
- **M10 COMPLETE**: Multi-light, skybox, day/night cycle, volumetric clouds (250-step adaptive raymarch)
- **FIR Math Ops COMPLETE**: 20+ vector/matrix operations
- **FIR Optimization COMPLETE**: spirv-opt Phase 0 (596× size reduction), Phase 1.3 (vectorized IfF)
- **FIR Loop Codegen FIXED**: Three critical bugs in while loop CFG
- **FIR Array Literals COMPLETE**: TH `arrayLit`/`arrayLitE` with nested array support
- **Dear ImGui COMPLETE**: Vulkan backend, input forwarding, cloud debug panel, physics debug panel
- **Procedural Sky COMPLETE**: Compute-shader generated cubemap with Hosek-Wilkie scattering
- **Jolt Physics COMPLETE**: All 7 phases — Nix build, C wrapper, Haskell FFI, async thread, render sync, scene loading, ImGui panel

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
13. **FIR if-then-else on Code types**: Broken (overlapping instances). Use branchless `step()` instead.
14. **Cloud pass**: Half-resolution, 250-step adaptive raymarch, temporal history
15. **ImGui backend**: `DearImGui.SDL.Vulkan`, sync in render loop, separate descriptor pool
16. **Physics**: Jolt v5.5.0 via C wrapper, async thread, TVar state sync, `_physics_box` naming convention

## Camera
- **Distance**: 20.0 default, min 0.1, max 20.0
- **Animation**: Slerp interpolation, 0.1s duration
- **Elevation bounds**: `(-pi/2 + 0.01, pi/2 - 0.01)`
- **Pitch axis**: Local right axis from current forward (not world-X)

## Active Milestones & Plans
| File | Status | Description |
|------|--------|-------------|
| `MILESTONE_FIR_PIPELINE_FIXES.md` | In progress | Fix 1 (atomics) complete, Fix 2+4A (Choose/abs) already done, Fix 3 (spec constants codegen) complete, Fix 4B-4D pending |
| `MILESTONE_EEVEE_PARITY.md` | Not started | 5-phase EEVEE parity plan (~50-80 weeks, FIR fixes first) |
| `MILESTONE_CLOUD_SHADER_PRODUCTION.md` | Phase 7 pending | Cloud production quality, automated tests |
| `MILESTONE_CLOUD_LIGHTING_AMBIENT.md` | Not started | Height-graded ambient + multi-scattering |
| `MILESTONE_CLOUD_WEATHER_MAP.md` | Not started | 2D weather map texture for spatial cloud variation |
| `MILESTONE_DEAR_IMGUI.md` | Phases 5-7 pending | Status panel, rendering controls, physics panel |
| `MILESTONE_JOLT_PHYSICS.md` | Complete | Physics integration |
| `MILESTONE_FIR_IMPROVEMENTS.md` | Complete | Texture checking, layout gen, vector unpack QoL |
| `MILESTONE_FIR_GAPS.md` | Open issues | Choose overlap, abs, type inference cascades |
| `MILESTONE_FIR_MATH.md` | Complete | All 20 vector/matrix ops implemented |

## Active Issues (See `.opencode/PROJECT_STATE.md` for full audit)

### P0 — Critical
1. **FIR if-then-else/mixV on `Code` types**: Overlapping instances → branchless `step()` workarounds everywhere
2. **Dynamic sky regeneration no-op**: `needsSkyRegen` flag checked but handler is TODO. Day/night cycle doesn't update procedural sky.

### P1 — High
3. **Cloud flickering on camera vertical movement**: `dirY_safe` discontinuity + Y-axis warp aliasing
4. **Cloud push constant 216 bytes**: Exceeds Vulkan 128-byte minimum. Won't run on mobile/integrated.
5. **No `abs` for `Code` types**: `step()` workaround in 4+ places

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
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` — Cloud raymarching shader (most workarounds)
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/LightingProcedural.hs` — Lighting + skybox + debug modes
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/GBuffer.hs` — G-buffer shaders, normal mapping
- `src/Graphics/Haskan/UI/Backend.hs` — ImGui Vulkan backend, debug panels
- `src/Graphics/Haskan/Camera.hs` — Orbital camera, quaternion rotation, animation
- `src/Graphics/Haskan/DayNight.hs` — Sun trajectory, sky color, IBL intensity
- `src/Graphics/Haskan/Render/Deferred.hs` — Deferred graph builder, push constant packing
- `src/Graphics/Haskan/Vulkan/DeferredResources.hs` — Cloud extent, images, pipelines
- `src/Graphics/Haskan/Engine/Render.hs` — Render loop, ImGui init/shutdown, frame building, sky regen TODO
- `src/Graphics/Haskan/Engine/Render/Internal/PassRecording.hs` — Command buffer recording, ImGui overlay
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
