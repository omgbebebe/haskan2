# Task: H8 — Fix Frustum Culling Matrix

## Severity
High

## Category
Transformation Matrix

## Files
- `src/Graphics/Haskan/Engine/FramePrepare.hs` (line 85)
- `src/Graphics/Haskan/Engine/Types.hs` (lines 459-471)

## Problem
`buildCullData` computes `vp = P * V^(-1)` (wrong) instead of `P * V`. Additionally, `extractFrustumPlanes` expects a transposed VP but receives non-transposed. Culling is completely non-functional — all objects render regardless of visibility. Hidden by `filterVisible` defaulting missing flags to `1` (visible).

## Required Fix
```haskell
let viewMatrix = Camera.toMatrix camera
    vp = makeProjectionMatrix w h !*! viewMatrix
    vpTransposed = transpose vp
```

## Verification
1. Verify `vp = P * V` (not `P * V^(-1)`)
2. Confirm transpose matches `extractFrustumPlanes` expectation
3. Test culling: objects outside frustum should not render
4. Fix `filterVisible` to not default missing flags to visible
5. Performance test: verify culling reduces draw calls

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
