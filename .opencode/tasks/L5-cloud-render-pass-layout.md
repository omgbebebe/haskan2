# Task: L5 — Fix Cloud Render Pass Initial Layout

## Severity
Low

## Category
Robustness

## Files
- `src/Graphics/Haskan/Vulkan/RenderPass.hs` (lines 470-480)

## Problem
Assumes cloud image is in `SHADER_READ_ONLY_OPTIMAL` before render pass. Use `UNDEFINED` with `loadOp = CLEAR` for robustness.

## Required Fix
Change initial layout to `UNDEFINED` and set `loadOp = CLEAR`.

## Verification
1. Render pass initial layout is UNDEFINED
2. loadOp is CLEAR (not LOAD)
3. No dependency on previous image layout
4. Validation layers pass
5. Visual test: cloud render pass works regardless of previous state

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
