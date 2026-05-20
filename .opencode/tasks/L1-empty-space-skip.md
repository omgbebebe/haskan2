# Task: L1 — Implement Smooth Empty-Space Skip

## Severity
Low

## Category
Shader Math / Performance

## Files
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` (lines 512-513)

## Problem
Empty-space skip hardcoded disabled. Comment says "causes vertical banding." Known performance issue — wastes 30-50% of ray march steps in empty space.

## Required Fix
Implement smooth step-size transition instead of binary skip.

## Verification
1. Empty-space skip enabled with smooth transition
2. No vertical banding artifacts
3. Performance improvement: 30-50% fewer ray march steps in empty regions
4. Visual quality preserved — no popping or artifacts

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
