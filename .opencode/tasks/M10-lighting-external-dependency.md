# Task: M10 — Add Lighting Render Pass External Dependency

## Severity
Medium

## Category
Pipeline Architecture

## Files
- `src/Graphics/Haskan/Vulkan/RenderPass.hs` (lines 358-378)

## Problem
No barrier makes lighting pass color attachment writes available to subsequent ImGui pass. ImGui may read incomplete output.

## Required Fix
Add 0→external dependency to lighting render pass with:
- `srcStageMask = COLOR_ATTACHMENT_OUTPUT_BIT`
- `srcAccessMask = COLOR_ATTACHMENT_WRITE_BIT`
- `dstStageMask = FRAGMENT_SHADER_BIT`
- `dstAccessMask = SHADER_READ_BIT`

## Verification
1. Lighting render pass has 0→external subpass dependency
2. Correct stage and access masks
3. Validation layers pass
4. Visual test: ImGui renders correctly over final image

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
