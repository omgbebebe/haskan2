# Task: M2 — Fix Detail Noise Texture Tileability

## Severity
Medium

## Category
Texture Seams

## Files
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/CloudDetailNoiseGen.hs` (lines 45-51, 109-129)

## Problem
The detail noise uses a non-periodic hash function with large phase offsets that break periodicity. The 64^3 detail texture cannot be tiled seamlessly.

## Required Fix
Use the same `fract(px/period)*period` wrapping approach as `CloudNoiseGen.hs`.

## Verification
1. Detail noise wraps seamlessly at texture boundaries
2. Same wrapping logic as `CloudNoiseGen.hs`
3. Visual test: no visible seams in cloud detail when tiled
4. Hash function uses periodic coordinates

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
