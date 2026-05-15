# Haskan2 — Critical Project Context (Survives Compaction)

## Core Principle
**NO WORKAROUNDS. EVER.** If a dependency is missing a feature, we implement it properly. If a tool is broken, we fix it. Never accept hacks, shortcuts, or "good enough" solutions.

## Build & Run
- **Build**: `~/bin/env-wrap cabal build exe:haskan2`
- **Run**: `~/bin/env-wrap cabal run exe:haskan2 -- -t 5 MODEL`
- **UV check**: `--uv-check-cube`, `--uv-check-sphere`, `--uv-check-plane`
- **Lights**: `--lights N` (1-8, default 3)
- **Day/Night**: `--day-night --time HOURS --time-speed FACTOR`

## Architecture
- **GHC 9.14.1**, Cabal-only for Haskell deps, Nix for system libs
- **FIR fork**: `3rdparty/fir/` — SPIR-V EDSL with extensions (math ops, spirv-opt, loop fixes)
- **Effects**: `effectful` over mtl; no IORef globals
- **Threading**: 3 threads (input, state update, render) + future physics thread, all via STM TVars
- **Prefix**: `~/bin/env-wrap` for commands needing project nix environment

## Current Status
- **M9 COMPLETE**: PBR deferred rendering, normal mapping, AO, emissive, IBL split-sum with BRDF LUT
- **M10 COMPLETE**: Multi-light, skybox, day/night cycle, volumetric clouds
- **FIR Math Ops COMPLETE**: 20+ vector/matrix operations (sinV, cosV, mixV, clampV, outerProduct, etc.)
- **FIR Optimization COMPLETE**: spirv-opt Phase 0 (596× size reduction), Phase 1.3 (vectorized IfF)
- **FIR Loop Codegen FIXED**: Three critical bugs in while loop CFG
- **Dear ImGui Phases 1-4 COMPLETE**: Vulkan backend, input forwarding, cloud debug panel
- **ImGui handle conversion FIXED**: vulkan-api → vulkan package via proper constructors + castPtr + zero

## Key Design Decisions
1. **glTF UV**: Matches Vulkan (0,0 = top-left). No `flipV`.
2. **Y-down**: Negative viewport height (`height = -h; y = h`), Vulkan 1.1+ core
3. **Backface culling**: `BACK_BIT` + `COUNTER_CLOCKWISE`
4. **Push constant**: 116 bytes — camera, debug, overlays, sun, rays, tint, ibl, cloudHeight
5. **Push constant packing**: FIR std430 `V 3 Float` = 12 bytes, alignment=16. NO tail padding after vec3.
6. **Vertex stride**: 60 bytes (pos 12 + uv 8 + norm 12 + tangent 16 + col 12)
7. **G-buffer**: position.a=metallic, normal.a=roughness, albedo.a=ao
8. **Normal encoding**: `* 0.5 + 0.5` in g-buffer, `* 2 - 1` in lighting
9. **Present mode**: `IMMEDIATE_KHR`
10. **Texture format**: `Rgba8 UNorm`; view `VK_FORMAT_R8G8B8A8_UNORM`
11. **JuicyPixels**: Row 0 at top; Vulkan stores row 0 at top. No V-flip.
12. **FIR optimization**: Always use `[SPIRV (Version 1 5), Optimize]` flags for shader compilation
13. **FIR if-then-else on Code types**: Broken (overlapping instances). Use branchless `step()` instead.
14. **Cloud pass**: Half-resolution, separate render pass, temporal accumulation via history blending
15. **ImGui backend**: `DearImGui.SDL.Vulkan`, sync in render loop, separate descriptor pool

## Camera
- **Distance**: 20.0 default, min 0.1, max 20.0
- **Animation**: Slerp interpolation, 0.1s duration
- **Elevation bounds**: `(-pi/2 + 0.01, pi/2 - 0.01)`
- **Pitch axis**: Local right axis from current forward (not world-X)

## Active Milestones & Plans
| File | Status | Description |
|------|--------|-------------|
| `MILESTONE_CLOUD_SHADER_PRODUCTION.md` | Phase 7 pending | Cloud production quality, automated tests |
| `MILESTONE_CLOUD_LIGHTING_AMBIENT.md` | Not started | Height-graded ambient + multi-scattering |
| `MILESTONE_CLOUD_WEATHER_MAP.md` | Not started | 2D weather map texture for spatial cloud variation |
| `MILESTONE_DEAR_IMGUI.md` | Phases 5-7 pending | Status panel, rendering controls, physics panel |
| `MILESTONE_JOLT_PHYSICS.md` | Not started | Physics integration |
| `MILESTONE_FIR_IMPROVEMENTS.md` | Complete | Texture checking, layout gen, vector unpack QoL |
| `MILESTONE_FIR_GAPS.md` | Open issues | Choose overlap, abs, type inference cascades |
| `FIR_OPTIMIZATION_REPORT.md` | Complete | Phase 0 + 1.3 done, 1.1/1.2 cancelled |
| `CLOUD_PIPELINE_BUG_REPORT.md` | Open bugs | Flickering (dirY dead zone), side pixelation |
| `CLOUD_SHADER_AUDIT.md` | Complete | Production-ready audit of all cloud phases |
| `fir_bindless.research.md` | Research | Future: bindless descriptors in FIR |
| `MILESTONE_FIR_MATH.md` | Complete | All 20 vector/matrix ops implemented |

## Open Issues
1. **Cloud Shader SSA Dominance**: `spirv-val` reports dominance violation in nested loop merge blocks. Pre-existing, needs phi fix or shader restructuring.
2. **FIR Choose overlap**: `if-then-else` / `mixV` on `Code` types fails with overlapping instances. Workaround: branchless `step()`. See `MILESTONE_FIR_GAPS.md` Issues 2 & 5.
3. **FIR Gaps**: No `abs` for Code types, vector/scalar operator confusion, type inference cascades. See `MILESTONE_FIR_GAPS.md`.
4. **IBL dynamic sky**: HDRI has baked sun at horizon; rotating looks like lighthouse. Need better HDRI or procedural sky.
5. **Cloud flickering**: dirY dead zone in slab intersector causes step count discontinuity. See `CLOUD_PIPELINE_BUG_REPORT.md`.

## Critical Files
- `src/Graphics/Haskan/Engine.hs` — Main loop, ECS, deferred graph, input polling with ImGui
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Lighting.hs` — Lighting + skybox + overlays + debug modes
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` — Cloud raymarching shader
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/GBuffer.hs` — G-buffer shaders, normal mapping
- `src/Graphics/Haskan/UI/Backend.hs` — ImGui Vulkan backend, handle conversion, cloud debug panel
- `src/Graphics/Haskan/Camera.hs` — Orbital camera, quaternion rotation, animation
- `src/Graphics/Haskan/DayNight.hs` — Sun trajectory, sky color, IBL intensity
- `src/Graphics/Haskan/Render/Deferred.hs` — Deferred graph builder, push constant packing
- `src/Graphics/Haskan/Vulkan/DeferredResources.hs` — Cloud extent, images, pipelines
- `src/Graphics/Haskan/Engine/Render.hs` — Render loop, ImGui init/shutdown, frame building
- `src/Graphics/Haskan/Engine/Render/Internal/PassRecording.hs` — Command buffer recording, ImGui overlay
- `src/Graphics/Haskan/Engine/Types.hs` — GameState with TVars
- `src/Graphics/Haskan/Input.hs` — Key bindings (F1-F9 debug, Shift+F1-3 cloud debug, overlays)
- `src/Graphics/Haskan/Vulkan/DescriptorSetLayout.hs` — All descriptor layouts (manual, candidate for FIR TH)
- `3rdparty/fir/` — FIR fork with math ops, spirv-opt, loop fixes

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
- FIR improvements: compile-time texture reference checking (`CheckImageExists`), `unpackV2/V3/V4` functions, test suite (3 golden tests)
- TH descriptor set layout generation: `DescriptorSetLayout.TH` module with per-binding stage flags API
- Migrated cloud, lighting, and compute descriptor set layouts to TH
- Main/bindless layout kept manual (requires `VkDescriptorBindingFlags` pNext chain for `PARTIALLY_BOUND_BIT`)

## Environment
- **OS**: NixOS, **GPU**: NVIDIA RTX 4090, **Vulkan**: 1.4.312
- **Descriptor indexing**: nonUniform=True, updateAfterBind=True, partiallyBound=True, runtimeArray=True
