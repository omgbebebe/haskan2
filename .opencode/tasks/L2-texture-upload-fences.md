# Task: L2 — Replace vkQueueWaitIdle with Fence-Based Synchronization

## Severity
Low

## Category
Performance

## Files
- `src/Graphics/Haskan/Vulkan/Texture.hs` (lines 176, 277, 438, 650, 928)

## Problem
Synchronous `vkQueueWaitIdle` blocks CPU during texture uploads. Acceptable at load time but prevents pipelining.

## Required Fix
Replace with fence-based synchronization.

## Verification
1. All texture upload paths use fences instead of vkQueueWaitIdle
2. CPU does not block on GPU during uploads
3. Fences properly signaled and waited on
4. No memory leaks from fence objects
5. Validation layers pass

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
