# Task: M6 — Add BY_REGION Flag to Subpass Dependencies

## Severity
Medium

## Category
Pipeline Architecture

## Files
- `src/Graphics/Haskan/Vulkan/RenderPass.hs` (lines 77-201)

## Problem
No subpass dependencies include `VK_DEPENDENCY_BY_REGION_BIT`. On tiled GPUs, this forces global synchronization instead of per-region, reducing performance.

## Required Fix
Add `VK_DEPENDENCY_BY_REGION_BIT` to framebuffer-local dependencies.

## Verification
1. All framebuffer-local subpass dependencies include BY_REGION flag
2. External dependencies do NOT include BY_REGION (not framebuffer-local)
3. Validation layers pass
4. Performance improvement on tiled GPUs

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
