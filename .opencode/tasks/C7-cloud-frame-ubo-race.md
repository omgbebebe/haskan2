# Task: C7 — Fix Cloud Frame Data UBO Race

## Severity
Critical

## Category
Vulkan Synchronization

## Files
- `src/Graphics/Haskan/Engine/Render/DeferredResources.hs` (lines 470-476)
- `src/Graphics/Haskan/Engine/Render/Deferred.hs` (line 277)

## Problem
One 256-byte cloud UBO is shared across all frames. Contains camera position, skybox rays, sun direction, prevViewProj matrix, wind params. Overwritten during recording while GPU from previous frame may still be reading. Causes cloud flickering and TAA ghosting.

## Required Fix
Create `numSwapchainImages` copies of the cloud frame data buffer.

## Verification
1. Create per-swapchain-image cloud frame UBOs (not single shared buffer)
2. Index by current `imageIdx` during command buffer recording
3. Ensure buffer updates only touch the buffer for the current frame
4. Visual test: no cloud flickering or TAA ghosting
5. Verify buffer size and alignment are correct for all copies

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
