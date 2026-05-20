# Task: C6 — Fix Light SSBO Race Condition

## Severity
Critical

## Category
Vulkan Synchronization

## Files
- `src/Graphics/Haskan/Engine/Render.hs` (lines 397, 811-813)

## Problem
One light storage buffer is shared across both in-flight frames. The CPU overwrites light data while the GPU may still be reading from the previous frame. Causes flickering lights and incorrect lighting.

## Required Fix
Create `maxFramesInFlight` (2) light buffers, index by `frameNumber mod 2`.

## Verification
1. Verify two distinct light SSBOs are created at initialization
2. Confirm frame N writes to buffer[N mod 2]
3. Confirm frame N+1 writes to buffer[(N+1) mod 2]
4. GPU should read from buffer it was submitted with, not overwritten data
5. Visual test: no light flickering under any scene conditions
6. Check with `maxFramesInFlight = 2` explicitly

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
