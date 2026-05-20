# Task: H5 — Fix Noise Domain Warp Periodicity

## Severity
High

## Category
Shader Math / Texture Seams

## Files
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` (lines 372-484)

## Problem
The domain warp repeats every **3,333 world units** (UV period = 1.0), while the noise texture tiles every **853,333 world units**. The 256x frequency mismatch creates visible repeating cloud structures.

## Required Fix
Use unwrapped world coordinates for warp, or scale warp frequency to match full texture period.

## Verification
1. Calculate warp period and noise texture period
2. Ensure they match or warp uses non-repeating coordinates
3. Visual test: no visible repeating cloud patterns
4. Test over large distances (10,000+ world units)

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
