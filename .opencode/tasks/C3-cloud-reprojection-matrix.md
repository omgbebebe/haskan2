# Task: C3 — Fix Cloud Reprojection Matrix

## Severity
Critical

## Category
Transformation Matrix + Shader

## Files
- `src/Graphics/Haskan/Engine/PassRecording.hs` (line 393)
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` (lines 618-627)

## Problem
The CPU computes `cloudPrevViewProj = V^(-1) * P` (wrong order, wrong matrix). The shader then does row-vector multiply, compounding the error. Effective computation: `clip = P^T * (V^(-1))^T * world`. This is only correct for the 3x3 rotation component by mathematical accident — translation is completely wrong.

## Required Fix
**CPU Fix:**
```haskell
let vp = projection !*! camViewMatrix   -- P * V
cloudPrevViewProj = transpose vp         -- For FIR row-major convention
```

**Shader Fix:** Use column-vector multiply with correctly uploaded matrix.

## Verification
1. Verify `cloudPrevViewProj` computes `P * V` (not `V^(-1) * P`)
2. Confirm transpose is applied consistently with FIR convention
3. Test temporal reprojection — clouds should not ghost or jitter incorrectly
4. Check that camera translation correctly affects reprojection

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
