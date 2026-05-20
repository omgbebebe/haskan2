# Task: M9 — Add Missing Image Layout Transition

## Severity
Medium

## Category
Pipeline Architecture

## Files
- `src/Graphics/Haskan/Vulkan/CommandBuffer.hs` (lines 402-494)

## Problem
Missing `COLOR_ATTACHMENT_OPTIMAL → SHADER_READ_ONLY_OPTIMAL` transition case. Falls back to `ALL_COMMANDS_BIT` full pipeline stall.

## Required Fix
Add the specific transition case with precise stage/access masks.

## Verification
1. Transition case added for COLOR_ATTACHMENT_OPTIMAL → SHADER_READ_ONLY_OPTIMAL
2. Uses precise stage and access masks (not ALL_COMMANDS_BIT)
3. Validation layers pass
4. Performance: reduced pipeline stalls

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
