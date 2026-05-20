# Task: H1 — Add Missing Barrier Between G-Buffer and Lighting Pass

## Severity
High

## Category
Vulkan Synchronization

## Files
- `src/Graphics/Haskan/Engine/PassRecording.hs` (lines 339-347)

## Problem
No `vkMemoryBarrier` between G-buffer color attachment writes and lighting pass fragment shader reads. On some GPU drivers, lighting may sample stale G-buffer data, causing ghosting or incorrect normals.

## Required Fix
Insert `vkMemoryBarrier` with:
- `srcStageMask = COLOR_ATTACHMENT_OUTPUT_BIT`
- `srcAccessMask = COLOR_ATTACHMENT_WRITE_BIT`
- `dstStageMask = FRAGMENT_SHADER_BIT`
- `dstAccessMask = SHADER_READ_BIT`

## Verification
1. Barrier inserted after G-buffer render pass end
2. Barrier before lighting pass begins
3. Correct stage and access masks
4. Validation layers pass without synchronization warnings
5. Visual test: no ghosting or stale G-buffer sampling

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
