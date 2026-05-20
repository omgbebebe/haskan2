# Task: H4 — Add HOST→COMPUTE Barrier for Entity Data Upload

## Severity
High

## Category
Vulkan Synchronization

## Files
- `src/Graphics/Haskan/Engine/Render.hs` (line 337)
- `src/Graphics/Haskan/Engine/PassRecording.hs` (lines 316-328)

## Problem
Entity SSBO is CPU-mapped and copied, then immediately read by compute cull shader with no buffer barrier from `HOST_BIT` to `COMPUTE_SHADER_BIT`. Spec violation — may fail on tile-based GPUs.

## Required Fix
Add `vkCmdPipelineBarrier` with:
- `srcStageMask = HOST_BIT`
- `srcAccessMask = HOST_WRITE_BIT`
- `dstStageMask = COMPUTE_SHADER_BIT`
- `dstAccessMask = SHADER_READ_BIT`

## Verification
1. Buffer barrier added after CPU memcpy to entity SSBO
2. Barrier before compute cull dispatch
3. Correct stage and access masks
4. Validation layers pass
5. Test on tile-based GPU if available

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
