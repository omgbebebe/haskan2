# Task: C8 — Fix AP Volume Uniform Buffer Race

## Severity
Critical

## Category
Vulkan Synchronization

## Files
- `src/Graphics/Haskan/Engine/Render/DeferredResources.hs` (lines 515-520)
- `src/Graphics/Haskan/Engine/PassRecording.hs` (line 383)

## Problem
Single AP uniform buffer shared across all frames. Overwritten each frame during command buffer recording. Causes flickering aerial perspective and incorrect god ray alignment.

## Required Fix
Create per-frame AP uniform buffers, indexed by `imageIdx`.

## Verification
1. Create per-swapchain-image AP uniform buffers
2. Index by current `imageIdx` during recording
3. Each frame updates only its own AP buffer
4. Visual test: no AP flickering or god ray misalignment
5. Confirm buffer creation, update, and binding paths all use correct index

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
