# Task: L3 — Fix Screenshot Capture GPU Stall

## Severity
Low

## Category
Performance

## Files
- `src/Graphics/Haskan/Vulkan/Screenshot.hs` (lines 44-50)

## Problem
`vkDeviceWaitIdle` for screenshot readback causes frame time spike.

## Required Fix
Use transfer queue + fence for non-blocking readback.

## Verification
1. Screenshot capture uses transfer queue
2. Fence-based synchronization (no vkDeviceWaitIdle)
3. No frame time spike during screenshot
4. Screenshot image is correct and complete
5. Validation layers pass

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
