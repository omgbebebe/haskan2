# Task: L4 — Optimize View Matrix Inverse

## Severity
Low

## Category
Performance / Stability

## Files
- `src/Graphics/Haskan/Camera/Types.hs` (lines 13-16)

## Problem
General 4x4 inverse computed 3+ times per frame. View matrix is rigid — analytical inverse is free.

## Required Fix
Use `V^(-1) = T(pos) * R^T` (translation by position, transpose rotation).

## Verification
1. Analytical inverse produces same result as `inv44` for valid view matrices
2. Performance: faster than general 4x4 inverse
3. Numerically stable — no division by near-singular matrix
4. Used correctly wherever view inverse is needed

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
