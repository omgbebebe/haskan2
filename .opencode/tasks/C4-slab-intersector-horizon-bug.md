# Task: C4 — Fix Slab Intersector Horizon Bug

## Severity
Critical

## Category
Shader Math / Zenith Bug

## Files
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` (lines 322-327)

## Problem
When camera is below clouds and looks horizontally (`dirY ≈ 0`), the epsilon clamp forces `dirY_safe = -0.05`. Both `tToBottom` and `tToTop` become negative, resulting in `totalRayLength = 0`. **Clouds completely vanish at the horizon when viewed from the ground.**

## Current Code
```haskell
-- WRONG: horizon vanishes
let dirY_safe = if dirY > 0.0 then max 0.05 dirY else min (-0.05) dirY
```

## Required Fix
Implement robust slab intersector that handles near-horizontal rays:
```haskell
let dirY_epsilon = if abs dirY < 0.001 then sign dirY * 0.001 else dirY
    toBottom = (cloudBottom - camY) / dirY_epsilon
    toTop    = (cloudTop    - camY) / dirY_epsilon
    entry    = min toBottom toTop
    exit     = max toBottom toTop
```

## Verification
1. Test camera below clouds, looking exactly horizontally (dirY = 0)
2. Verify clouds are visible at the horizon
3. Test edge cases: dirY = 0.001, dirY = -0.001, dirY = 0.0
4. Ensure no division by zero or negative ray lengths
5. Visual test: clouds should render correctly from ground level at all viewing angles

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
