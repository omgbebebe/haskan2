# Task: C9 — Fix G-Buffer Render Pass External Dependency

## Severity
Critical

## Category
Pipeline Architecture

## Files
- `src/Graphics/Haskan/Vulkan/RenderPass.hs` (lines 279-287)

## Problem
The G-buffer pass's external dependency uses `srcStageMask = COLOR_ATTACHMENT_OUTPUT_BIT, srcAccessMask = 0`, which does **NOT** wait for the previous frame's lighting pass that reads G-buffer textures in `FRAGMENT_SHADER_BIT` / `SHADER_READ_BIT`. The G-buffer may be overwritten while still being sampled.

## Current Code
```haskell
-- WRONG: does not wait for fragment shader reads
set "srcStageMask" VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
set "srcAccessMask" 0
```

## Required Fix
```haskell
set "srcStageMask" VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT
set "srcAccessMask" VK_ACCESS_SHADER_READ_BIT
```

## Verification
1. Verify external dependency waits for fragment shader stage
2. Confirm `srcAccessMask` includes `SHADER_READ_BIT`
3. Ensure G-buffer is not overwritten while lighting pass still reads it
4. Test with validation layers enabled — no synchronization errors
5. Visual test: no ghosting or tearing in deferred lighting

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
