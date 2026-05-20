# Task: M1 — Fix Atmospheric Asymmetry in Cloud Shader

## Severity
Medium

## Category
Shader Math

## Files
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` (line 265)

## Problem
Using `abs(dirY)` makes optical depth symmetric: looking up and down have identical atmospheric density. Physically incorrect — looking down through the atmosphere should have more optical depth than looking up into space.

## Current Code
```haskell
cosThetaView = abs dirY
```

## Required Fix
Use signed optical depth: `cosThetaView = max 0.01 dirY` for upward rays only.

## Verification
1. Downward rays (dirY < 0) have higher optical depth than upward rays
2. No division by zero or negative values
3. Visual test: looking down through atmosphere appears denser than looking up
4. Horizon and zenith cases handled correctly

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
