# Task: H7 — Fix God Ray Sample Coordinate Clamping

## Severity
High

## Category
Shader Math

## Files
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/GodRays.hs` (lines 114-127)

## Problem
The radial blur clamps the **current** sample position, then subtracts delta for the **next** position. The next position can still go out of bounds.

## Current Code
```haskell
-- WRONG: clamp current, subtract from clamped
put "sampleU" (clamp su 0 1 - sampleDeltaX)
```

## Required Fix
```haskell
-- FIX: clamp the next position
put "sampleU" (clamp (su - sampleDeltaX) 0.0 1.0)
```

## Verification
1. Verify clamp is applied to the result of subtraction, not before
2. Test with samples near texture edges
3. Visual test: no god ray sampling artifacts at screen edges
4. Confirm all sample coordinates stay in [0, 1] range

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
