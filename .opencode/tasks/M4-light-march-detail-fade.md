# Task: M4 — Fix Light March Detail Fade

## Severity
Medium

## Category
Shader Math

## Files
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` (lines 515-552)

## Problem
The light march sample reuses `effectiveDetail` computed from the primary step's distance. The light midpoint may be at a different distance and needs its own detail fade. Additionally, `finalLightDensity = ld * lightStepCount * lightStepSize` assumes uniform density along the light path — a rough approximation.

## Required Fix
Compute separate `lDetailFade` for the light sample based on `lDistFromCam`.

## Verification
1. Light march computes its own detail fade based on light sample distance
2. Does not reuse primary ray's detail fade
3. Visual test: lighting inside clouds is consistent at all distances
4. No detail popping on light-facing cloud surfaces

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
