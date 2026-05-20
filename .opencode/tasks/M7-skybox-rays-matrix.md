# Task: M7 — Fix Skybox Rays Matrix Construction

## Severity
Medium

## Category
Transformation Matrix

## Files
- `src/Graphics/Haskan/Engine/Scene.hs` (lines 38-57)

## Problem
`computeSkyboxRays` receives `transpose(unViewMatrix)` and recovers the correct rotation only because `(R^(-1))^T = R` for orthonormal matrices. Breaks if any non-rigid transform is added.

## Required Fix
Explicitly construct `worldRot` from camera basis vectors.

## Verification
1. Skybox rays computed from explicit camera basis vectors
2. Does not rely on transpose(inverse) identity
3. Works with any valid view matrix, including non-rigid transforms
4. Visual test: skybox aligned correctly with camera rotation

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
