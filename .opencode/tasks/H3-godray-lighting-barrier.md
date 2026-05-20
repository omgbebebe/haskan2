# Task: H3 — Add Missing Barrier Between God Ray and Lighting Pass

## Severity
High

## Category
Vulkan Synchronization

## Files
- `src/Graphics/Haskan/Engine/Render/Deferred.hs` (lines 327-396)

## Problem
Lighting pass samples god ray texture without ensuring god ray color attachment writes are complete. Causes temporal inconsistency in final compositing.

## Required Fix
Insert barrier between god ray and lighting passes with:
- `srcStageMask = COLOR_ATTACHMENT_OUTPUT_BIT`
- `srcAccessMask = COLOR_ATTACHMENT_WRITE_BIT`
- `dstStageMask = FRAGMENT_SHADER_BIT`
- `dstAccessMask = SHADER_READ_BIT`

## Verification
1. Barrier after god ray render pass end
2. Barrier before lighting pass god ray texture sampling
3. Correct image/layout transitions if applicable
4. Validation layers pass
5. Visual test: consistent god ray compositing

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
