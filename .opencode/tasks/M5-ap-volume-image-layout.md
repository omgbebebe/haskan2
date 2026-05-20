# Task: M5 — Fix AP Volume Image Layout

## Severity
Medium

## Category
Pipeline Architecture

## Files
- `src/Graphics/Haskan/Engine/Render/DeferredResources.hs` (lines 308-314)

## Problem
The AP volume 3D image remains in `GENERAL` layout for both compute writes and fragment reads. Valid but suboptimal — bypasses texture cache optimizations of `SHADER_READ_ONLY_OPTIMAL`.

## Required Fix
Transition to `SHADER_READ_ONLY_OPTIMAL` after compute dispatch.

## Verification
1. AP volume transitions from GENERAL to SHADER_READ_ONLY_OPTIMAL after compute
2. Fragment shader samples from SHADER_READ_ONLY_OPTIMAL layout
3. Correct image memory barrier with proper stage masks
4. Validation layers pass
5. Performance: potential texture cache improvement

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
