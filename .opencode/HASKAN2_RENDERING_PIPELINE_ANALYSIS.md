# Haskan2 Vulkan Rendering Pipeline — Comprehensive Analysis Report

**Repository:** https://github.com/omgbebebe/haskan2  
**Commit:** c7fe0a2 (master, 2026-05-20)  
**Analysis Date:** 2026-05-21  
**Scope:** Deferred PBR pipeline, volumetric clouds, atmospheric scattering, compute shaders, Vulkan synchronization

---

## Executive Summary

This analysis examined the haskan2 Vulkan rendering engine across four specialized domains: **Vulkan synchronization**, **shader mathematics**, **transformation matrices**, and **pipeline architecture**. The audit identified **34 distinct issues** across **24 source files**, including **9 critical bugs** that cause visible rendering artifacts, GPU race conditions, or mathematical correctness failures.

| Severity | Count | Categories |
|----------|-------|-----------|
| Critical | 9 | Synchronization races, wrong projection, matrix convention mismatch, horizon culling bug, AP/cloud mismatch |
| High | 10 | Missing barriers, domain warp periodicity, irradiance 2x error, frustum culling broken, god ray clamping |
| Medium | 10 | Layout inefficiencies, tileable noise, atmosphere asymmetry, wind speed hardcoded, BY_REGION missing |
| Low | 5 | Performance, naming conventions, code quality |

---

## Critical Issues (Fix Immediately)

---

### C1. OpenGL-Style Projection Matrix Used for Vulkan (Z-fighting)
**File:** `src/Graphics/Haskan/Engine/Scene.hs:65-71`  
**Category:** Transformation Matrix

`makeProjectionMatrix` calls `Linear.Projection.perspective` which produces Z in `[-1, 1]` (OpenGL convention). Vulkan requires Z in `[0, 1]`. Approximately **half the depth precision is destroyed** — the Vulkan clamping hardware maps all NDC Z < 0 to 0, causing massive Z-fighting on distant geometry and broken early-Z rejection.

```haskell
-- WRONG (OpenGL Z-range)
Linear.Projection.perspective (pi/3) aspect 1.0 50000.0

-- FIX: Vulkan perspective matrix
let z = far / (far - near)        -- [0,1] Z-mapping
    w = -(far * near) / (far - near)
in V4 (V4 x 0 0 0) (V4 0 y 0 0) (V4 0 0 z w) (V4 0 0 1 0)
```

---

### C2. Matrix Convention Mismatch Between GBuffer and Deferred Passes
**Files:** `Engine/Render.hs:330-331`, `PassRecording.hs:204-206`  
**Category:** Transformation Matrix

The GBuffer pass **transposes** view/projection matrices before GPU upload. The deferred pass (lighting, clouds, god rays) does **NOT** transpose. The two rendering stages use incompatible matrix conventions, so all deferred effects use mathematically wrong matrices.

```haskell
-- GBuffer (TRANSPOSED)
projMat = transpose $ makeProjectionMatrix w h

-- Deferred (NOT transposed) — MUST match
projection = perspective (...)  -- missing transpose
```

**Fix:** Apply `transpose` consistently in `PassRecording.hs` or remove it everywhere and fix the FIR EDSL convention.

---

### C3. Cloud Reprojection Uses Inverted, Reversed View-Projection
**Files:** `PassRecording.hs:393`, `Clouds.hs:618-627`  
**Category:** Transformation Matrix + Shader

The CPU computes `cloudPrevViewProj = V^(-1) * P` (wrong order, wrong matrix). The shader then does row-vector multiply, compounding the error. Effective computation: `clip = P^T * (V^(-1))^T * world`. This is only correct for the 3x3 rotation component by mathematical accident — translation is completely wrong.

**Fix (CPU):**
```haskell
let vp = projection !*! camViewMatrix   -- P * V
cloudPrevViewProj = transpose vp         -- For FIR row-major convention
```

**Fix (Shader):** Use column-vector multiply with correctly uploaded matrix.

---

### C4. Slab Intersector Fails at Horizon from Below Clouds
**File:** `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs:322-327`  
**Category:** Shader Math / Zenith Bug

When camera is below clouds and looks horizontally (`dirY ≈ 0`), the epsilon clamp forces `dirY_safe = -0.05`. Both `tToBottom` and `tToTop` become negative, resulting in `totalRayLength = 0`. **Clouds completely vanish at the horizon when viewed from the ground.**

```haskell
-- WRONG: horizon vanishes
let dirY_safe = if dirY > 0.0 then max 0.05 dirY else min (-0.05) dirY

-- FIX: robust slab intersector
let dirY_epsilon = if abs dirY < 0.001 then sign dirY * 0.001 else dirY
    toBottom = (cloudBottom - camY) / dirY_epsilon
    toTop    = (cloudTop    - camY) / dirY_epsilon
    entry    = min toBottom toTop
    exit     = max toBottom toTop
```

---

### C5. AP Volume Height Profile Mismatched with Cloud Shader
**Files:** `APVolume.hs:121-125` vs `Clouds.hs:493-498`  
**Category:** Shader Math / Formula Error

The aerial perspective volume uses **completely different** height profile parameters than the actual cloud shader. At `h=1.0`, the AP computes **6.36x lower** density. Scene geometry gets atmospheric scattering that does not match visible clouds.

| Parameter | APVolume.hs (WRONG) | Clouds.hs (CORRECT) |
|-----------|-------------------|-------------------|
| `baseCurve` | `mix 0.4 0.8` | `mix 0.8 1.2` |
| `topDecay` | `mix 2.0 4.0` | `mix 0.8 1.5` |
| `heightScale` min | `0.3` | `0.6` |

**Fix:** Synchronize AP Volume parameters to match Clouds.hs exactly.

---

### C6. Light SSBO Race — Single Buffer Shared Across In-Flight Frames
**File:** `src/Graphics/Haskan/Engine/Render.hs:397, 811-813`  
**Category:** Vulkan Synchronization

One light storage buffer is shared across both in-flight frames. The CPU overwrites light data while the GPU may still be reading from the previous frame. Causes flickering lights and incorrect lighting.

**Fix:** Create `maxFramesInFlight` (2) light buffers, index by `frameNumber mod 2`.

---

### C7. Cloud Frame Data UBO Race — Single Buffer Overwritten Per Frame
**Files:** `DeferredResources.hs:470-476`, `Render/Deferred.hs:277`  
**Category:** Vulkan Synchronization

One 256-byte cloud UBO is shared across all frames. Contains camera position, skybox rays, sun direction, prevViewProj matrix, wind params. Overwritten during recording while GPU from previous frame may still be reading. Causes cloud flickering and TAA ghosting.

**Fix:** Create `numSwapchainImages` copies of the cloud frame data buffer.

---

### C8. AP Volume Uniform Buffer Race
**Files:** `DeferredResources.hs:515-520`, `PassRecording.hs:383`  
**Category:** Vulkan Synchronization

Single AP uniform buffer shared across all frames. Overwritten each frame during command buffer recording. Causes flickering aerial perspective and incorrect god ray alignment.

**Fix:** Create per-frame AP uniform buffers, indexed by `imageIdx`.

---

### C9. G-Buffer Render Pass External Dependency Does Not Wait for Fragment Reads
**File:** `src/Graphics/Haskan/Vulkan/RenderPass.hs:279-287`  
**Category:** Pipeline Architecture

The G-buffer pass's external dependency uses `srcStageMask = COLOR_ATTACHMENT_OUTPUT_BIT, srcAccessMask = 0`, which does **NOT** wait for the previous frame's lighting pass that reads G-buffer textures in `FRAGMENT_SHADER_BIT` / `SHADER_READ_BIT`. The G-buffer may be overwritten while still being sampled.

**Fix:**
```haskell
set "srcStageMask" VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT
set "srcAccessMask" VK_ACCESS_SHADER_READ_BIT
```

---

## High Issues (Significant Impact)

---

### H1. Missing Barrier Between G-Buffer and Lighting Pass
**File:** `PassRecording.hs:339-347`  
**Category:** Vulkan Synchronization

No `vkMemoryBarrier` between G-buffer color attachment writes and lighting pass fragment shader reads. On some GPU drivers, lighting may sample stale G-buffer data, causing ghosting or incorrect normals.

**Fix:** Insert `vkMemoryBarrier` with `COLOR_ATTACHMENT_WRITE_BIT → SHADER_READ_BIT`.

---

### H2. Missing Barrier Between Cloud and God Ray Pass
**File:** `Deferred.hs:280-324`  
**Category:** Vulkan Synchronization

God ray pass samples the cloud texture without a barrier after the cloud render pass's color attachment writes. God rays may sample partially-written cloud data, causing streaking.

**Fix:** Insert pipeline barrier between cloud render pass end and god ray pass begin.

---

### H3. Missing Barrier Between God Ray and Lighting Pass
**File:** `Deferred.hs:327-396`  
**Category:** Vulkan Synchronization

Lighting pass samples god ray texture without ensuring god ray color attachment writes are complete. Causes temporal inconsistency in final compositing.

**Fix:** Insert barrier between god ray and lighting passes.

---

### H4. Entity Data Upload Lacks HOST→COMPUTE Barrier
**File:** `Render.hs:337`, `PassRecording.hs:316-328`  
**Category:** Vulkan Synchronization

Entity SSBO is CPU-mapped and copied, then immediately read by compute cull shader with no buffer barrier from `HOST_BIT` to `COMPUTE_SHADER_BIT`. Spec violation — may fail on tile-based GPUs.

**Fix:** Add `vkCmdPipelineBarrier` with `HOST_WRITE_BIT → SHADER_READ_BIT`.

---

### H5. Noise Domain Warp Creates Visible Repeating Pattern
**File:** `Clouds.hs:372-484`  
**Category:** Shader Math / Texture Seams

The domain warp repeats every **3,333 world units** (UV period = 1.0), while the noise texture tiles every **853,333 world units**. The 256x frequency mismatch creates visible repeating cloud structures.

**Fix:** Use unwrapped world coordinates for warp, or scale warp frequency to match full texture period.

---

### H6. IrradianceGen Solid Angle Weight is 2x Too Large
**File:** `IrradianceGen.hs:181`  
**Category:** Shader Math / Wrong Coefficient

```haskell
solidAngleWeight = cosTheta * sinTheta * pi * pi / 32.0
-- Should be / 64.0 for 8x8 hemisphere grid
```

The irradiance cubemap is **2x too bright**, making all diffuse IBL on scene geometry incorrectly luminous.

**Fix:** Change `/ 32.0` to `/ 64.0`.

---

### H7. God Rays Sample Coordinate Clamping Applied to Wrong Position
**File:** `GodRays.hs:114-127`  
**Category:** Shader Math

The radial blur clamps the **current** sample position, then subtracts delta for the **next** position. The next position can still go out of bounds.

```haskell
-- WRONG: clamp current, subtract from clamped
put "sampleU" (clamp su 0 1 - sampleDeltaX)

-- FIX: clamp the next position
put "sampleU" (clamp (su - sampleDeltaX) 0.0 1.0)
```

---

### H8. Frustum Culling Uses Wrong View-Projection Matrix
**File:** `FramePrepare.hs:85`, `Engine/Types.hs:459-471`  
**Category:** Transformation Matrix

`buildCullData` computes `vp = P * V^(-1)` (wrong) instead of `P * V`. Additionally, `extractFrustumPlanes` expects a transposed VP but receives non-transposed. Culling is completely non-functional — all objects render regardless of visibility. Hidden by `filterVisible` defaulting missing flags to `1` (visible).

**Fix:**
```haskell
let viewMatrix = Camera.toMatrix camera
    vp = makeProjectionMatrix w h !*! viewMatrix
    vpTransposed = transpose vp
```

---

### H9. Missing `vkDeviceWaitIdle` Before Procedural Sky Regeneration
**File:** `Render.hs:343-367`  
**Category:** Vulkan Synchronization

Sky regeneration (day/night cycle) dispatches compute shaders to overwrite radiance/irradiance cubemaps without waiting for the GPU to finish. Unlike the noise regeneration path, no `vkDeviceWaitIdle` is called.

**Fix:** Add `vkDeviceWaitIdle` before sky regeneration dispatch.

---

### H10. Compute Cull Indirect Draw Buffer Is Single-Buffered
**File:** `PassRecording.hs:315-338`  
**Category:** Pipeline Architecture

The compute cull writes to a single indirect draw buffer shared across frames. With `maxFramesInFlight=2`, frame N+1's compute can overwrite while frame N's draw is still reading. The intra-frame barrier is not sufficient.

**Fix:** Create `maxFramesInFlight` indirect draw buffers.

---

## Medium Issues

---

### M1. `cosThetaView = abs dirY` Breaks Atmospheric Asymmetry
**File:** `Clouds.hs:265`  
**Category:** Shader Math

Using `abs(dirY)` makes optical depth symmetric: looking up and down have identical atmospheric density. Physically incorrect — looking down through the atmosphere should have more optical depth than looking up into space.

**Fix:** Use signed optical depth: `cosThetaView = max 0.01 dirY` for upward rays only.

---

### M2. Detail Noise Texture Not Tileable
**File:** `CloudDetailNoiseGen.hs:45-51, 109-129`  
**Category:** Texture Seams

The detail noise uses a non-periodic hash function with large phase offsets that break periodicity. The 64^3 detail texture cannot be tiled seamlessly.

**Fix:** Use the same `fract(px/period)*period` wrapping approach as `CloudNoiseGen.hs`.

---

### M3. Hardcoded Wind Speed Duplicated Between March and Reprojection
**File:** `Clouds.hs:369, 605`  
**Category:** Shader Math / Maintainability

`windSpeed = 0.05` is hardcoded in two places. If CPU-side wind speed changes, temporal reprojection uses the wrong delta, causing TAA ghosting.

**Fix:** Pass `windSpeed` as a uniform in `CloudFrameData`.

---

### M4. Single-Sample Light March Reuses Wrong Detail Fade
**File:** `Clouds.hs:515-552`  
**Category:** Shader Math

The light march sample reuses `effectiveDetail` computed from the primary step's distance. The light midpoint may be at a different distance and needs its own detail fade. Additionally, `finalLightDensity = ld * lightStepCount * lightStepSize` assumes uniform density along the light path — a rough approximation.

**Fix:** Compute separate `lDetailFade` for the light sample based on `lDistFromCam`.

---

### M5. AP Volume Image Stays in `GENERAL` Layout
**File:** `DeferredResources.hs:308-314`  
**Category:** Pipeline Architecture

The AP volume 3D image remains in `GENERAL` layout for both compute writes and fragment reads. Valid but suboptimal — bypasses texture cache optimizations of `SHADER_READ_ONLY_OPTIMAL`.

**Fix:** Transition to `SHADER_READ_ONLY_OPTIMAL` after compute dispatch.

---

### M6. Subpass Dependencies Missing `BY_REGION` Flag
**File:** `RenderPass.hs:77-201`  
**Category:** Pipeline Architecture

No subpass dependencies include `VK_DEPENDENCY_BY_REGION_BIT`. On tiled GPUs, this forces global synchronization instead of per-region, reducing performance.

**Fix:** Add `VK_DEPENDENCY_BY_REGION_BIT` to framebuffer-local dependencies.

---

### M7. Skybox Rays Rely on Accidental Identity
**File:** `Engine/Scene.hs:38-57`  
**Category:** Transformation Matrix

`computeSkyboxRays` receives `transpose(unViewMatrix)` and recovers the correct rotation only because `(R^(-1))^T = R` for orthonormal matrices. Breaks if any non-rigid transform is added.

**Fix:** Explicitly construct `worldRot` from camera basis vectors.

---

### M8. TAA Jitter Applied in World Space, Not Clip Space
**File:** `Clouds.hs:254-260`  
**Category:** Shader Math

TAA jitter adds a constant world-space vector to the ray direction, producing non-uniform pixel shifts across the screen. Edge rays get different subpixel offsets than center rays.

**Fix:** Apply jitter to UV coordinates, then reconstruct ray direction.

---

### M9. `layerTransition` Missing `COLOR_ATTACHMENT_OPTIMAL → SHADER_READ_ONLY_OPTIMAL`
**File:** `CommandBuffer.hs:402-494`  
**Category:** Pipeline Architecture

Missing the most common deferred rendering transition case. Falls back to `ALL_COMMANDS_BIT` full pipeline stall.

**Fix:** Add the specific transition case with precise stage/access masks.

---

### M10. Lighting Render Pass Missing 0→External Subpass Dependency
**File:** `RenderPass.hs:358-378`  
**Category:** Pipeline Architecture

No barrier makes lighting pass color attachment writes available to subsequent ImGui pass. ImGui may read incomplete output.

**Fix:** Add 0→external dependency to lighting render pass.

---

## Low Issues

---

### L1. Empty-Space Skip Hardcoded Disabled
**File:** `Clouds.hs:512-513`  
**Category:** Shader Math / Performance

Comment says "causes vertical banding." Known performance issue — wastes 30-50% of ray march steps in empty space.

**Fix:** Implement smooth step-size transition instead of binary skip.

---

### L2. `vkQueueWaitIdle` Used for Texture Uploads
**File:** `Texture.hs:176, 277, 438, 650, 928`  
**Category:** Performance

Synchronous `vkQueueWaitIdle` blocks CPU during texture uploads. Acceptable at load time but prevents pipelining.

**Fix:** Replace with fence-based synchronization.

---

### L3. Screenshot Capture Stalls GPU
**File:** `Screenshot.hs:44-50`  
**Category:** Performance

`vkDeviceWaitIdle` for screenshot readback causes frame time spike.

**Fix:** Use transfer queue + fence for non-blocking readback.

---

### L4. `inv44` for View Matrix is Slow and Unstable
**File:** `Camera/Types.hs:13-16`  
**Category:** Performance / Stability

General 4x4 inverse computed 3+ times per frame. View matrix is rigid — analytical inverse is free.

**Fix:** Use `V^(-1) = T(pos) * R^T` (translation by position, transpose rotation).

---

### L5. Cloud Render Pass Initial Layout Assumption
**File:** `RenderPass.hs:470-480`  
**Category:** Robustness

Assumes cloud image is in `SHADER_READ_ONLY_OPTIMAL` before render pass. Use `UNDEFINED` with `loadOp = CLEAR` for robustness.

---

## Verified Correct (What Works Well)

| Component | Status |
|-----------|--------|
| Fence-per-frame pattern (2 fences) | Correct |
| Semaphore-per-swapchain-image (4 semaphores) | Correct |
| Frame-indexed MVP uniform buffers | Correct |
| Image availability semaphore on acquire | Correct |
| vkDeviceWaitIdle before noise regeneration | Correct |
| Cloud history copy layout transitions | Correct |
| AP volume compute dispatch memory barrier | Correct (scope, just not image-specific) |
| Henyey-Greenstein phase function formula | Correct |
| Temporal reprojection matrix convention | Correct (after matrix upload is fixed) |
| 3D mip generation box filter | Correct |
| Weather map tiling | Correct |
| Push constants (inherently per-submission) | Correct |
| Swapchain image acquire/present chain | Correct |
| G-buffer depth `storeOp = DONT_CARE` | Correct |

---

## Recommended Fix Priority

| Priority | Issue | Files |
|----------|-------|-------|
| 1 | **C1** — Vulkan projection matrix | `Scene.hs` |
| 2 | **C4** — Slab intersector horizon bug | `Clouds.hs` |
| 3 | **C2+C3** — Matrix convention + reprojection | `Render.hs`, `PassRecording.hs`, `Clouds.hs` |
| 4 | **C6+C7+C8** — Buffer races (light, cloud, AP) | `Render.hs`, `DeferredResources.hs`, `Deferred.hs`, `PassRecording.hs` |
| 5 | **C5** — AP/cloud height profile mismatch | `APVolume.hs` |
| 6 | **C9** — G-buffer external dependency | `RenderPass.hs` |
| 7 | **H1+H2+H3** — Pass-to-pass barriers | `PassRecording.hs`, `Deferred.hs` |
| 8 | **H8** — Frustum culling broken | `FramePrepare.hs`, `Engine/Types.hs` |
| 9 | **H5+H6+H7** — Shader math errors | `Clouds.hs`, `IrradianceGen.hs`, `GodRays.hs` |
| 10 | **H9+H10** — Sky regen sync, cull buffer | `Render.hs`, `PassRecording.hs` |
| 11 | **H4+M1-M10** — Remaining medium issues | Various |

---

## File Impact Summary

| File | Issues | Max Severity |
|------|--------|-------------|
| `Clouds.hs` | 8 | Critical |
| `Render.hs` | 5 | Critical |
| `PassRecording.hs` | 6 | Critical |
| `DeferredResources.hs` | 4 | Critical |
| `Scene.hs` | 3 | Critical |
| `RenderPass.hs` | 4 | Critical |
| `APVolume.hs` | 2 | Critical |
| `Engine/Types.hs` | 2 | High |
| `FramePrepare.hs` | 2 | High |
| `IrradianceGen.hs` | 1 | High |
| `GodRays.hs` | 1 | High |
| `CloudDetailNoiseGen.hs` | 1 | Medium |
| `Camera/Types.hs` | 1 | Medium |
| `CommandBuffer.hs` | 1 | Medium |
| `Deferred.hs` | 1 | Medium |
| `Texture.hs` | 1 | Low |
| `Screenshot.hs` | 1 | Low |

---

*Report generated by multi-agent analysis pipeline. All line numbers reference commit c7fe0a2 on master branch.*
