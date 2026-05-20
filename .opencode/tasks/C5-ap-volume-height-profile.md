# Task: C5 — Fix AP Volume Height Profile Mismatch

## Severity
Critical

## Category
Shader Math / Formula Error

## Files
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/APVolume.hs` (lines 121-125)
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` (lines 493-498)

## Problem
The aerial perspective volume uses **completely different** height profile parameters than the actual cloud shader. At `h=1.0`, the AP computes **6.36x lower** density. Scene geometry gets atmospheric scattering that does not match visible clouds.

## Parameter Mismatch
| Parameter | APVolume.hs (WRONG) | Clouds.hs (CORRECT) |
|-----------|-------------------|-------------------|
| `baseCurve` | `mix 0.4 0.8` | `mix 0.8 1.2` |
| `topDecay` | `mix 2.0 4.0` | `mix 0.8 1.5` |
| `heightScale` min | `0.3` | `0.6` |

## Required Fix
Synchronize AP Volume parameters to match Clouds.hs exactly. Both files must use identical values for:
- `baseCurve`
- `topDecay`
- `heightScale`

## Verification
1. Compare both files side-by-side and ensure all height profile parameters match
2. Verify AP volume density at h=1.0 equals cloud shader density
3. Visual test: scene geometry atmospheric scattering should match cloud appearance
4. No visible mismatch between ground fog and cloud bottoms

## Requirement
NO WORKAROUNDS, NO HACKS, NO SIMPLIFIED IMPLEMENTATION ARE ALLOWED! IF YOU CANNOT IMPLEMENT ANY FIX THEN STOP AND REPORT
