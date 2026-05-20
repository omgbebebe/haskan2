# Task: C1 — Fix Vulkan Projection Matrix (Z-fighting)

## Severity
Critical

## Category
Transformation Matrix

## Files
- `src/Graphics/Haskan/Engine/Scene.hs` (lines 65-71)

## Problem
`makeProjectionMatrix` calls `Linear.Projection.perspective` which produces Z in `[-1, 1]` (OpenGL convention). Vulkan requires Z in `[0, 1]`. Approximately **half the depth precision is destroyed** — the Vulkan clamping hardware maps all NDC Z < 0 to 0, causing massive Z-fighting on distant geometry and broken early-Z rejection.

## Current Code
```haskell
-- WRONG (OpenGL Z-range)
Linear.Projection.perspective (pi/3) aspect 1.0 50000.0
```

## Required Fix
Implement a Vulkan-compatible perspective matrix with Z in [0, 1]:
```haskell
let z = far / (far - near)        -- [0,1] Z-mapping
    w = -(far * near) / (far - near)
in V4 (V4 x 0 0 0) (V4 0 y 0 0) (V4 0 0 z w) (V4 0 0 1 0)
```

## Verification
1. Verify that `makeProjectionMatrix` produces Z values in [0, 1] range for all valid inputs
2. Test with near=1.0, far=50000.0, verify depth precision improves
3. Ensure no Z-fighting artifacts on distant geometry
4. Confirm early-Z rejection works correctly

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
