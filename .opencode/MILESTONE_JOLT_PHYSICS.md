# Jolt Physics Integration Milestone

## Objective
Integrate Jolt Physics as an async subsystem in Haskan2 for non-realtime sliding-window simulation and future realtime use.

## Architecture

```
Input Loop (main) ──TVar──> State Update (forkIO) ──TVar──> Physics Thread (forkIO) ──TVar──> Render Loop (forkIO)
                               camera, flags              forces, step commands             body transforms
```

Physics thread follows the same STM TVar pattern as the existing state update loop. Render loop reads body transforms via `readTVarIO` — zero coupling.

## Key Properties
- **License**: MIT — no contamination
- **C++17**, SSE4.1/AVX optional, deterministic simulation
- **Double precision** mode available (`JPH_DOUBLE_PRECISION`)
- **Stateful**: `PhysicsSystem::Update(dt, steps, ...)` — step any amount, state persists between calls
- **Multicore**: Jolt uses its own `JobSystemThreadPool` — give it `hardware_concurrency - 2` threads
- **Bindings**: Use `joltc` (C API) or write thin C wrapper (~500 LOC)

---

## Phase 1: Nix Build Integration
**Priority:** Critical — Blocks everything
**Estimate:** 4-6 hours
**Risk:** Medium — C++17 CMake in Nix, linking with GHC

### Tasks
1. Add Jolt Physics as a Nix dependency in `flake.nix`
   - Clone https://github.com/jrouwe/JoltPhysics as a fixed-output derivation or use `fetchFromGitHub`
   - Build as static library (`libJolt.a`) with CMake
   - Compile flags: `-DCMAKE_POSITION_INDEPENDENT_CODE=ON`, consider `-DJPH_DOUBLE_PRECISION=ON`
2. Verify GHC can link against it via `cabal` `extra-libraries` / `extra-lib-dirs`
3. Write a minimal Haskell FFI test: `foreign import ccall` to a C wrapper function, call from GHCi
4. Add Jolt headers to `extra-include-dirs` in `cabal.project` or `haskan2.cabal`

### Deliverables
- `nix develop --command cabal build all` succeeds with Jolt linked
- `c_joltInit` FFI call returns success from Haskell

### Files
- `flake.nix` — Jolt derivation
- `haskan2.cabal` — `extra-libraries: Jolt`, `extra-include-dirs`
- `src/Graphics/Haskan/Physics/Jolt/FFI.hs` — initial FFI module (new)

---

## Phase 2: Thin C Wrapper
**Priority:** Critical — Surface area for Haskell FFI
**Estimate:** 4-6 hours
**Risk:** Low — Mechanical wrapping

### Tasks
1. Write `jolt_wrapper.h` / `jolt_wrapper.cpp` exposing these functions:

```c
// Lifecycle
void* joltCreateWorld(int maxBodies, int maxBodyPairs, int maxContactConstraints);
void joltDestroyWorld(void* world);

// Stepping
void joltUpdate(void* world, float deltaTime, int collisionSteps);

// Body management
int   joltCreateBoxBody(void* world, float hx, float hy, float hz, float mass, float px, float py, float pz);
int   joltCreateSphereBody(void* world, float radius, float mass, float px, float py, float pz);
int   joltCreateStaticPlane(void* world, float nx, float ny, float nz, float dist);
void  joltRemoveBody(void* world, int bodyId);

// State queries
void  joltGetPosition(void* world, int bodyId, float* outX, float* outY, float* outZ);
void  joltGetRotation(void* world, int bodyId, float* outX, float* outY, float* outZ, float* outW);
void  joltGetLinearVelocity(void* world, int bodyId, float* outX, float* outY, float* outZ);
int   joltIsActive(void* world, int bodyId);

// State mutations
void  joltSetPosition(void* world, int bodyId, float x, float y, float z);
void  joltSetLinearVelocity(void* world, int bodyId, float x, float y, float z);
void  joltAddForce(void* world, int bodyId, float fx, float fy, float fz);
void  joltAddImpulse(void* world, int bodyId, float fx, float fy, float fz);
```

2. Implement each function using Jolt C++ API (see HelloWorld.cpp pattern)
3. Use `BodyInterface` for all body operations (locking variant for thread safety)
4. Compile as `libjolt_wrapper.a`

### Deliverables
- C wrapper compiles and links
- All functions tested via a standalone C `main()`

### Files
- `3rdparty/jolt-wrapper/jolt_wrapper.h` (new)
- `3rdparty/jolt-wrapper/jolt_wrapper.cpp` (new)
- `3rdparty/jolt-wrapper/Makefile` or CMakeLists (new)

---

## Phase 3: Haskell FFI Layer
**Priority:** High — Haskell-side bindings
**Estimate:** 3-4 hours
**Risk:** Low

### Tasks
1. Create `Graphics.Haskan.Physics.Jolt.FFI` with `foreign import ccall` for all wrapper functions
2. Create `Graphics.Haskan.Physics.Jolt.Types`:
   ```haskell
   newtype JoltWorld = JoltWorld (Ptr ())
   newtype BodyId = BodyId Int
   data BodyState = BodyState
     { bsPosition :: !(V3 Float)
     , bsRotation :: !(Quaternion Float)
     , bsVelocity :: !(V3 Float)
     , bsActive   :: !Bool
     }
   ```
3. Create `Graphics.Haskan.Physics.Jolt.World` — high-level API wrapping FFI:
   ```haskell
   createWorld :: Int -> IO JoltWorld
   destroyWorld :: JoltWorld -> IO ()
   stepWorld :: JoltWorld -> Float -> IO ()
   createBoxBody :: JoltWorld -> V3 Float -> Float -> V3 Float -> IO BodyId
   getBodyState :: JoltWorld -> BodyId -> IO BodyState
   setBodyForce :: JoltWorld -> BodyId -> V3 Float -> IO ()
   ```
4. Use `Foreign.Ptr`, `Foreign.Marshal.Alloc`, `Foreign.Storable` for interop
5. Use `bracket` for world lifecycle

### Deliverables
- Pure Haskell API over Jolt, no C types leaking
- Unit test: create world, add body, step, read position

### Files
- `src/Graphics/Haskan/Physics/Jolt/FFI.hs` (new)
- `src/Graphics/Haskan/Physics/Jolt/Types.hs` (new)
- `src/Graphics/Haskan/Physics/Jolt/World.hs` (new)
- `test/PhysicsJoltSpec.hs` (new)

---

## Phase 4: Async Physics Thread
**Priority:** High — Core integration
**Estimate:** 6-8 hours
**Risk:** Medium — Thread lifecycle, STM coordination

### Tasks
1. Extend `GameState` in `Engine/Types.hs`:
   ```haskell
   , physicsWorld       :: TVar (Maybe JoltWorld)
   , physicsState       :: TVar PhysicsSnapshot
   , pendingPhysicsStep :: TVar Bool
   , physicsTimeWindow  :: TVar Float
   , physicsBodyIds     :: TVar [BodyId]
   ```
2. Create `PhysicsSnapshot`:
   ```haskell
   data PhysicsSnapshot = PhysicsSnapshot
     { snapshotBodies :: !(IntMap BodyState)
     , snapshotTime   :: !Float
     }
   ```
3. Create `Graphics.Haskan.Engine.Physics` with `physicsLoop`:
   ```haskell
   physicsLoop :: JoltWorld -> GameState cam -> IO ()
   physicsLoop world gs = forever $ do
     shouldStep <- atomically $ do
       step <- readTVar (pendingPhysicsStep gs)
       when step $ writeTVar (pendingPhysicsStep gs) False
       pure step

     when shouldStep $ do
       window <- readTVarIO (physicsTimeWindow gs)
       -- Fixed substeps: 60Hz equivalent
       let steps = max 1 (round (window * 60))
       stepWorld world window steps

       bids <- readTVarIO (physicsBodyIds gs)
       states <- IntMap.fromList <$> forM bids (\(BodyId i) -> do
         s <- getBodyState world (BodyId i)
         pure (i, s))

       atomically $ writeTVar (physicsState gs) (PhysicsSnapshot states window)

     threadDelay (1_000_000 `div` 120)  -- 120Hz polling
   ```
4. Fork `physicsLoop` alongside `stateUpdateLoop` in `Engine.hs`
5. Wire `pendingPhysicsStep` to input (e.g., `Space` key or ImGui button)

### Deliverables
- Physics thread runs independently from render
- `Space` key triggers one time-window step
- Body positions update in GameState TVars

### Files
- `src/Graphics/Haskan/Engine/Physics.hs` (new)
- `src/Graphics/Haskan/Engine/Types.hs` — extended GameState
- `src/Graphics/Haskan/Engine.hs` — fork physics thread
- `src/Graphics/Haskan/Input.hs` — physics trigger key

---

## Phase 5: Render Integration
**Priority:** High — Visual feedback
**Estimate:** 6-8 hours
**Risk:** Medium — ECS transform update

### Tasks
1. In render loop, read `physicsState` TVar
2. For each body in snapshot, update entity transform in ECS:
   ```haskell
   PhysicsSnapshot bodies _ <- readTVarIO (physicsState gs)
   forM_ (IntMap.toList bodies) $ \(entityIdx, bs) -> do
     let mat = mkTransformation (bsRotation bs) (bsPosition bs)
     updateEntityTransform entityIdx mat
   ```
3. Create debug visualization: axis-aligned bounding boxes for physics bodies
4. Add render mode: wireframe physics bodies overlay (togglable via `P` key)

### Deliverables
- Physics bodies visible in viewport after stepping
- Bodies move correctly when time windows are advanced
- Debug overlay for collision shapes

### Files
- `src/Graphics/Haskan/Engine/Render.hs` — read physics TVar, update ECS
- `src/Graphics/Haskan/Scene/ECS.hs` — transform update from physics
- `src/Graphics/Haskan/Engine/Render/Internal/PassRecording.hs` — debug overlay (optional)

---

## Phase 6: Scene Loading & Physics Material
**Priority:** Medium — Usability
**Estimate:** 4-6 hours
**Risk:** Low

### Tasks
1. Define physics properties in scene description (JSON/glTF extension):
   ```json
   {
     "physics": {
       "type": "box",
       "mass": 1.0,
       "restitution": 0.5,
       "friction": 0.8,
       "static": false
     }
   }
   ```
2. Auto-create Jolt bodies from glTF scene nodes during load
3. Support static environment bodies (ground plane, walls)
4. Support dynamic bodies with initial velocity

### Deliverables
- Load a glTF scene with physics-enabled bodies
- Static floor + dynamic objects
- Initial state visible before first step

### Files
- `src/Graphics/Haskan/Scene/GLTF.hs` — parse physics extension
- `src/Graphics/Haskan/Engine/Physics.hs` — create bodies from scene data

---

## Phase 7: Sliding Window UI (requires dear-imgui milestone)
**Priority:** Medium — Depends on dear-imgui milestone
**Estimate:** 3-4 hours
**Risk:** Low

### Tasks
1. ImGui panel for physics controls:
   - "Time Window" slider (0.1s — 60s)
   - "Step" button
   - "Auto-step" toggle
   - Body count / active count display
   - Per-body inspector (position, velocity, mass)
2. Wire UI state to GameState TVars

### Deliverables
- Full physics control panel in ImGui overlay

### Files
- `src/Graphics/Haskan/Engine/UI/PhysicsPanel.hs` (new, requires dear-imgui)

---

## Summary: Effort & Timeline

| Phase | Task | Est. Hours | Risk | Dependencies |
|-------|------|-----------|------|--------------|
| 1 | Nix build integration | 5h | Medium | None |
| 2 | Thin C wrapper | 5h | Low | Phase 1 |
| 3 | Haskell FFI layer | 4h | Low | Phase 2 |
| 4 | Async physics thread | 7h | Medium | Phase 3 |
| 5 | Render integration | 7h | Medium | Phase 4 |
| 6 | Scene loading | 5h | Low | Phase 4 |
| 7 | Sliding window UI | 4h | Low | Phase 5 + dear-imgui |
| **Total** | | **~37h** | | |

## Recommended Order
1. **Phase 1** (Nix) — unblocks everything, highest risk
2. **Phase 2+3** (C wrapper + FFI) — can be done together
3. **Phase 4** (async thread) — core integration, uses existing STM patterns
4. **Phase 5** (render) — see physics in action
5. **Phase 6** (scene loading) — usability
6. **Phase 7** (UI) — polish, requires dear-imgui milestone

## Open Questions
- Double precision or single? (Double avoids precision issues at large coordinates, but `linear` uses `Float` in current ECS)
- Use existing `joltc` C bindings or write custom wrapper? (Custom wrapper is simpler, fewer dependencies)
- Jolt thread count: `hardware_concurrency - 2` on RTX 4090 system?
