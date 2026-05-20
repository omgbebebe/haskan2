# Task: H10 — Fix Compute Cull Indirect Draw Buffer Race

## Severity
High

## Category
Pipeline Architecture

## Files
- `src/Graphics/Haskan/Engine/PassRecording.hs` (lines 315-338)

## Problem
The compute cull writes to a single indirect draw buffer shared across frames. With `maxFramesInFlight=2`, frame N+1's compute can overwrite while frame N's draw is still reading. The intra-frame barrier is not sufficient.

## Required Fix
Create `maxFramesInFlight` indirect draw buffers.

## Verification
1. Create 2 indirect draw buffers (one per in-flight frame)
2. Compute cull writes to buffer[frame mod 2]
3. Draw command reads from same buffer index
4. No overwrite while previous frame still reading
5. Validation layers pass
6. Visual test: no missing or duplicated draw calls

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
