# Task: H2 — Add Missing Barrier Between Cloud and God Ray Pass

## Severity
High

## Category
Vulkan Synchronization

## Files
- `src/Graphics/Haskan/Engine/Render/Deferred.hs` (lines 280-324)

## Problem
God ray pass samples the cloud texture without a barrier after the cloud render pass's color attachment writes. God rays may sample partially-written cloud data, causing streaking.

## Required Fix
Insert pipeline barrier between cloud render pass end and god ray pass begin with:
- `srcStageMask = COLOR_ATTACHMENT_OUTPUT_BIT`
- `srcAccessMask = COLOR_ATTACHMENT_WRITE_BIT`
- `dstStageMask = FRAGMENT_SHADER_BIT`
- `dstAccessMask = SHADER_READ_BIT`

## Verification
1. Barrier inserted after cloud render pass
2. Barrier before god ray pass sampling
3. Image memory barrier for cloud texture if needed
4. Validation layers pass
5. Visual test: no cloud streaking in god rays

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
