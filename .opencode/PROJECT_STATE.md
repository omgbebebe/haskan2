# Haskan2 — Project State Audit (2026-05-17)

## Completed Milestones

| Milestone | Status | Commit |
|-----------|--------|--------|
| M9: PBR Deferred Rendering | ✅ Complete | Pre-master |
| M10: Multi-light, Skybox, Day/Night, Clouds | ✅ Complete | Multiple |
| FIR Math Ops (20+ vector/matrix) | ✅ Complete | a868e1d |
| FIR Optimization (spirv-opt Phase 0, 1.3) | ✅ Complete | a868e1d |
| FIR Loop Codegen Fixes | ✅ Complete | a868e1d |
| Dear ImGui Integration (Phases 1-4) | ✅ Complete | Multiple |
| Procedural Sky Generation | ✅ Complete | 6f988e6 |
| FIR Array Literal TH Helpers | ✅ Complete | 43966f8 (FIR), 3b5bc65 |
| **Jolt Physics Integration** | **✅ COMPLETE (all 7 phases)** | 3f0dbfd..624f0b4 |

## Jolt Physics — Fully Delivered

All 7 phases committed and pushed to master:

1. **Phase 1**: Nix derivation `jolt-physics` v5.5.0 (`shell.flake.nix`)
2. **Phase 2**: C wrapper `3rdparty/jolt-wrapper/` (monolithic `libjolt_wrapper.so`, LTO workaround)
3. **Phase 3**: Haskell FFI layer (`Physics.Jolt.{FFI,Types,World}`)
4. **Phase 4**: Async physics thread (`physicsLoop` in `Engine.Physics`, TVar state publishing)
5. **Phase 5**: Render integration (sync physics bodies → ECS transforms in `runFrame`)
6. **Phase 6**: Scene description via `_physics_box` naming convention in glTF nodes
7. **Phase 7**: ImGui debug panel (auto-step toggle, time-scale slider 0–5x)

Integration test: `test/Tests.hs` — box falls onto plane, passes.

## Fixed Bugs (Recent)

| Bug | File | Fix | Commit |
|-----|------|-----|--------|
| Procedural sky black below horizon | `RadianceGen.hs`, `IrradianceGen.hs`, `SkyLUTGen.hs` | `abs dirY` instead of `max 0 dirY` | a868e1d |
| Double tonemapping (HDR→LDR→HDR) | `RadianceGen.hs`, `IrradianceGen.hs`, `Clouds.hs` | Output HDR, single Reinhard in lighting | a868e1d |
| Cloud density ×4.0 too high | `Clouds.hs` | Removed multiplier | Pre-d1857c7 |
| Cloud tone mapping missing | `Lighting.hs`, `LightingProcedural.hs` | Added Reinhard + sqrt gamma | Pre-d1857c7 |
| Cloud step count too low (62 steps) | `Clouds.hs` | `max 32 (min 256 (totalRayLength / 20))` | 9e0ddbd |
| Cloud half-res pixelation (misdiagnosed) | `DeferredResources.hs` | Reverted to half-res; actual fix was step count | 9e0ddbd |
| `libjolt_wrapper.so` not in LD_LIBRARY_PATH | `shell.flake.nix` | Added wrapper dir to shellHook | 8176f1c |
| Vulkan cubemap face directions | `RadianceGen.hs` | Fixed face index formulas per Vulkan spec | a868e1d |
| Light SSBO not bound | `DeferredResources.hs` | Pass `mLightBuffer` to descriptor updates | a868e1d |
| `layerTransitionAll` missing GENERAL catch-all | `CommandBuffer.hs` | Added catch-all pattern | f05c197 |
| FIR `if-then-else` on `Code` types | Workaround | Branchless `step()` throughout clouds | Ongoing |

## Remaining Bugs & Tech Debt

### P0 — Critical

1. **FIR `if-then-else` / `mixV` on `Code` types fails** (`MILESTONE_FIR_GAPS.md` Issues 2 & 5)
   - `Choose` overlapping instances error
   - Workaround: branchless `step()` everywhere in `Clouds.hs`
   - Impact: Shaders are unreadable, hard to maintain
   - Fix: Add `IncoherentInstances` or dedicated `Select` primop

2. **Dynamic sky regeneration is a no-op** (`Engine/Render.hs:324`)
   - `needsSkyRegen` flag checked every frame, handler is TODO comment
   - Day/night cycle changes sun push constant but cubemap stays at initial state
   - Impact: Procedural sky doesn't animate with time-of-day
   - Fix: Re-dispatch compute shaders when `needsSkyRegen` is true

### P1 — High

3. **Cloud flickering on forward/backward camera movement** (`CLOUD_PIPELINE_BUG_REPORT.md` Bug 1)
   - `dirY_safe` clamping causes step count discontinuity when camera elevation changes
   - Y-axis domain warp amplitude (150) still causes aliasing
   - Impact: Clouds shimmer when moving camera vertically
   - Fix: Smooth `dirY_safe` transition, reduce Y warp to ~75

4. **Cloud push constant exceeds Vulkan minimum** (128 bytes)
   - Cloud push constant is 216 bytes. Mobile/integrated GPUs may crash.
   - Impact: Won't run on Intel/AMD integrated graphics
   - Fix: Migrate cloud pass data to per-frame UBO

5. **No `abs` for `Code` types** (`MILESTONE_FIR_GAPS.md` Issue 3)
   - Workaround: `step 0.0 x * x + step x 0.0 * (0.0 - x)`
   - Impact: 4+ instances in `Clouds.hs`, unreadable
   - Fix: Add `abs` to `GLSLMath` type class

### P2 — Medium

6. **Blue noise tileability unverified** (`MILESTONE_CLOUD_SHADER_PRODUCTION.md` Issue 9)
   - 64×64 blue noise may not tile correctly at screen edges
   - Impact: Subtle discontinuities at screen edges
   - Fix: Verify or regenerate with toroidal void-and-cluster

7. **Render graph dependencies not declared** (`Render/Deferred.hs`)
   - `rpInputs = []`, `rpOutputs = []` for all passes
   - Impact: Framework can't auto-insert barriers
   - Fix: Populate dependency lists

8. **Missing explicit COLOR_ATTACHMENT → TRANSFER barrier**
   - `layerTransition` uses `ALL_COMMANDS_BIT` catch-all
   - Impact: Safe but slower than necessary
   - Fix: Add explicit case

9. **FIR type inference cascade errors** (`MILESTONE_FIR_GAPS.md` Issue 6)
   - Single `+` vs `^+^` mistake produces 50+ cascading errors
   - Impact: Developer productivity
   - Fix: Better error messages in FIR

10. **IBL dynamic sky** — HDRI has baked sun at horizon
    - Rotating cubemap looks like lighthouse
    - Impact: Procedural sky is the workaround, but it's static
    - Fix: Dynamic cubemap regeneration (ties to bug #2)

### P3 — Low / Polish

11. **Weather map not spatially varying enough**
    - 512×512 weather map provides macro variation but looks repetitive
    - Impact: Cloud formations look similar across scenes
    - Fix: Higher resolution or multi-octave weather map

12. **Cloud history buffer temporal reprojection may not accumulate**
    - `prevViewProj` matrix wired but accumulation formula unclear
    - Impact: Temporal stability may be suboptimal
    - Fix: Verify reprojection math in `Clouds.hs:500-510`

13. **Physics: Only `_physics_box` naming convention supported**
    - No `_physics_sphere`, `_physics_plane`, or glTF physics extension
    - Impact: Limited body types in scenes
    - Fix: Extend `Scene/GLTF.hs` processNode

14. **Physics: No collision shape debug visualization**
    - Can't see physics bounds in viewport
    - Impact: Hard to debug physics scenes
    - Fix: Wireframe overlay for physics bodies

15. **FIR `lerp` synonym missing** (`MILESTONE_FIR_GAPS.md` Issue 1)
    - Trivial fix, low priority

## Architecture Decisions (Current)

1. **Physics thread**: `forkIOWithHandler`, 60Hz, publishes `IntMap BodyState` via TVar
2. **Scene description**: `nodeName` suffix `_physics_box` → `PhysicsBodySpec` → Jolt body
3. **Clouds**: Half-res, 250 steps max, adaptive step size, temporal history
4. **Procedural sky**: Startup compute dispatch, static until dynamic regen implemented
5. **Build**: `~/bin/env-wrap cabal build exe:haskan2`, requires `LD_LIBRARY_PATH` for jolt-wrapper

## Open Questions

1. **Performance**: Clouds at 250 steps + half-res = ~1000 FPS on RTX 4090. Acceptable for now?
2. **Mobile**: Push constant size (216 bytes) will break on mobile. UBO migration needed before mobile support.
3. **FIR upstream**: Should we maintain our fork indefinitely or try to upstream changes?

## Files to Monitor

- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/Clouds.hs` — Most complex shader, most workarounds
- `src/Graphics/Haskan/Engine/Render.hs` — Dynamic sky TODO at line 324
- `3rdparty/fir/src/FIR/Syntax/AST.hs` — Choose instances for if-then-else fix
- `src/Graphics/Haskan/Engine/Physics.hs` — Physics thread lifecycle
- `src/Graphics/Haskan/Scene/GLTF.hs` — Scene loading, physics body creation

## Next Recommended Work

1. **Fix FIR if-then-else** (4-6h) — Biggest readability win
2. **Dynamic sky regeneration** (2-3h) — Enables day/night with procedural sky
3. **Cloud flickering fix** (1h) — Smooth dirY_safe + reduce warp
4. **Cloud push constant → UBO** (4-6h) — Required for mobile/compatibility
5. **Physics shape debug viz** (2-3h) — Wireframe boxes in render pass
