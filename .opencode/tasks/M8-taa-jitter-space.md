# Task: M8 — Fix TAA Jitter Coordinate Space

## Severity
Medium

## Category
Shader Math

## Files
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` (lines 254-260)

## Problem
TAA jitter adds a constant world-space vector to the ray direction, producing non-uniform pixel shifts across the screen. Edge rays get different subpixel offsets than center rays.

## Required Fix
Apply jitter to UV coordinates, then reconstruct ray direction.

## Verification
1. Jitter applied in UV/screen space, not world space
2. All pixels get uniform subpixel offset
3. Edge rays have same shift magnitude as center rays
4. Visual test: TAA jitter is uniform across entire screen
5. No perspective-dependent jitter artifacts

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
