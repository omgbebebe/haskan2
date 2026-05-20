# Task: C2 — Fix Matrix Convention Mismatch Between GBuffer and Deferred Passes

## Severity
Critical

## Category
Transformation Matrix

## Files
- `src/Graphics/Haskan/Engine/Render.hs` (lines 330-331)
- `src/Graphics/Haskan/Engine/PassRecording.hs` (lines 204-206)

## Problem
The GBuffer pass **transposes** view/projection matrices before GPU upload. The deferred pass (lighting, clouds, god rays) does **NOT** transpose. The two rendering stages use incompatible matrix conventions, so all deferred effects use mathematically wrong matrices.

## Current Code
```haskell
-- GBuffer (TRANSPOSED)
projMat = transpose $ makeProjectionMatrix w h

-- Deferred (NOT transposed) — MUST match
projection = perspective (...)  -- missing transpose
```

## Required Fix
Apply `transpose` consistently in `PassRecording.hs` or remove it everywhere and fix the FIR EDSL convention. Either approach is acceptable, but it must be consistent across all passes.

## Verification
1. Verify that both GBuffer and deferred passes use the same matrix convention
2. Confirm deferred lighting, clouds, and god rays all use correct matrices
3. Check that no transpose is missing or double-applied
4. Visual inspection: deferred effects should align correctly with GBuffer geometry

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
