# Task: M3 — Remove Hardcoded Wind Speed Duplication

## Severity
Medium

## Category
Shader Math / Maintainability

## Files
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` (lines 369, 605)

## Problem
`windSpeed = 0.05` is hardcoded in two places. If CPU-side wind speed changes, temporal reprojection uses the wrong delta, causing TAA ghosting.

## Required Fix
Pass `windSpeed` as a uniform in `CloudFrameData`.

## Verification
1. `windSpeed` passed from CPU via UBO, not hardcoded
2. Both ray march and reprojection use same wind speed value
3. Changing CPU wind speed updates both paths
4. Visual test: no TAA ghosting when wind speed changes

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
