# Task: H9 — Add vkDeviceWaitIdle Before Procedural Sky Regeneration

## Severity
High

## Category
Vulkan Synchronization

## Files
- `src/Graphics/Haskan/Engine/Render.hs` (lines 343-367)

## Problem
Sky regeneration (day/night cycle) dispatches compute shaders to overwrite radiance/irradiance cubemaps without waiting for the GPU to finish. Unlike the noise regeneration path, no `vkDeviceWaitIdle` is called.

## Required Fix
Add `vkDeviceWaitIdle` before sky regeneration dispatch.

## Verification
1. `vkDeviceWaitIdle` called before any sky cubemap compute dispatch
2. GPU has finished all previous work using the cubemaps
3. No race between reading old cubemap and writing new one
4. Validation layers pass
5. Visual test: smooth day/night transition without flickering

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
