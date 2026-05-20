# Task: H6 — Fix IrradianceGen Solid Angle Weight

## Severity
High

## Category
Shader Math / Wrong Coefficient

## Files
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/IrradianceGen.hs` (line 181)

## Problem
```haskell
solidAngleWeight = cosTheta * sinTheta * pi * pi / 32.0
-- Should be / 64.0 for 8x8 hemisphere grid
```

The irradiance cubemap is **2x too bright**, making all diffuse IBL on scene geometry incorrectly luminous.

## Required Fix
Change `/ 32.0` to `/ 64.0`.

## Verification
1. Verify denominator is 64.0 for 8x8 hemisphere grid
2. Confirm irradiance cubemap brightness is correct
3. Visual test: diffuse IBL should not be overbright
4. Compare with reference implementation or analytical solution

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
