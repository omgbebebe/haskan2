# Dear ImGui Integration Milestone

## Status

| Phase | Description | Status |
|-------|-------------|--------|
| 1 | Dependency & Build Setup | ✅ Complete |
| 2 | Vulkan Backend Initialization | ✅ Complete |
| 3 | Frame Integration + Input Forwarding | ✅ Complete |
| 4 | Input Focus Management | ✅ Merged into Phase 3 |
| 5 | Engine Status Panel | ✅ Complete (FPS, camera, time in Debug Panels) |
| 6 | Rendering Controls Panel | ✅ Complete (cloud, weather, debug modes) |
| 7 | Physics Controls Panel | ❌ Blocked (needs Jolt) |

**Commits**: `2cfa84d` (Phase 3 — input), `8ea368d` (Phase 4 — cloud panel)

## Objective
Integrate dear-imgui (Haskell bindings to Dear ImGui) as an in-game GUI overlay in Haskan2, running in the render loop with SDL+Vulkan backend.

## Key Properties
- **License**: BSD-3 — no contamination
- **Package**: `dear-imgui` 2.4.1 on Hackage / nixpkgs
- **Backend**: `DearImGui.SDL.Vulkan` — matches Haskan2's exact stack
- **Cabal flags**: `+sdl +vulkan -opengl3 -glfw`
- **Runs in**: Render loop (sync, not a separate thread — ImGui consumes input state and draws immediately)
- **Render pass**: Overlay after deferred lighting, before present

---

## Phase 1: Dependency & Build Setup
**Priority:** Critical — Blocks everything
**Estimate:** 2-3 hours
**Risk:** Low — Standard Haskell dependency

### Tasks
1. Add to `haskan2.cabal` `build-depends: dear-imgui >= 2.4`
2. Configure flags in `cabal.project`:
   ```
   package dear-imgui
     flags: +sdl +vulkan -opengl3 -glfw +use-wchar32 +use-imdrawidx32
   ```
3. Verify `nix develop --command cabal build all` succeeds
4. Check that `DearImGui.SDL.Vulkan` module is available
5. Verify `dear-imgui` links against the same SDL2 and Vulkan as Haskan2 (no version conflicts)

### Deliverables
- `dear-imgui` compiles and links with Haskan2

### Files
- `haskan2.cabal` — add dependency
- `cabal.project` — flags

---

## Phase 2: Vulkan Backend Initialization
**Priority:** Critical — ImGui needs Vulkan descriptor sets and render pass
**Estimate:** 4-6 hours
**Risk:** Medium — ImGui creates its own Vulkan resources, must coexist with Haskan2's deferred renderer

### Tasks
1. Create `Graphics.Haskan.UI.Backend` module:
   ```haskell
   data ImGuiBackend = ImGuiBackend
     { imguiContext   :: !ImGuiContext
     , imguiVulkan    :: !ImGuiVulkanBackend  -- descriptor pool, render pass
     }
   ```
2. Initialize ImGui context during render loop startup (after Vulkan device creation):
   ```haskell
   -- In renderLoop one-time init
   ctx <- createContext
   sdl2InitForVulkan window
   vulkanInit device physicalDevice queueFamilyIndex imageCount msaaSamples
                minImageCount swapChainFormat renderPass descriptorPool
   ```
3. ImGui needs:
   - A Vulkan descriptor pool (can share or create separate)
   - The render pass (use existing lighting pass or create a separate UI render pass)
   - Command buffer from Haskan2's existing pool
4. Decision: **Secondary render pass** vs **subpass in lighting pass**
   - Recommended: separate UI render pass after deferred lighting
   - Uses `VK_ATTACHMENT_LOAD_OP_LOAD` to preserve lighting output
   - ImGui draws on top as alpha-blended overlay

### Deliverables
- ImGui Vulkan backend initialized
- No conflicts with existing deferred pipeline resources

### Files
- `src/Graphics/Haskan/UI/Backend.hs` (new)
- `src/Graphics/Haskan/Engine/Render.hs` — init ImGui during startup

---

## Phase 3: Frame Integration
**Priority:** Critical — Wire ImGui into per-frame rendering
**Estimate:** 4-6 hours
**Risk:** Medium — Command buffer coordination with existing render passes

### Tasks
1. In `renderFrameLoop`, add ImGui new frame / render / draw:
   ```haskell
   -- After deferred lighting render pass ends
   vulkanNewFrame
   sdl2NewFrame
   newFrame

   -- Build UI (Phase 4 will fill this)
   buildUI gs

   -- Render ImGui draw data
   render
   drawData <- getDrawData
   vulkanRenderDrawData commandBuffer drawData

   -- Then present as usual
   ```
2. Handle window resize: ImGui needs to know about swapchain recreation
3. Forward SDL events to ImGui before Haskan2 processes them:
   ```haskell
   -- In inputLoop, after pollEvents:
   pollEventWithImGui  -- instead of pollEvent
   ```
   This ensures ImGui can capture mouse/keyboard when its windows are focused
4. Add `DearImGui.SDL.Vulkan` import and verify `sdl2NewFrame` / `vulkanNewFrame` ordering

### Deliverables
- ImGui "Demo Window" renders on top of Haskan2 scene
- Mouse clicks on ImGui widgets don't trigger camera movement
- Swapchain resize doesn't crash ImGui

### Files
- `src/Graphics/Haskan/Engine/Render.hs` — per-frame ImGui calls
- `src/Graphics/Haskan/Engine.hs` — SDL event forwarding (`pollEventWithImGui`)
- `src/Graphics/Haskan/UI/Backend.hs` — helper functions

---

## Phase 4: Input Forwarding & Focus Management
**Priority:** High — ImGui must not steal input when not focused
**Estimate:** 2-3 hours
**Risk:** Low

### Tasks
1. Check `wantCaptureMouse` / `wantCaptureKeyboard` from ImGui IO:
   ```haskell
   io <- getImGuiIO
   wantMouse <- wantCaptureMouse io
   wantKeyboard <- wantCaptureKeyboard io
   ```
2. When ImGui wants input, skip Haskan2's camera/input processing:
   ```haskell
   -- In stateUpdateLoop:
   unless wantMouse $ processCameraMovement events
   unless wantKeyboard $ processKeyBindings events
   ```
3. Pass `wantCaptureMouse` / `wantCaptureKeyboard` via TVar to state update thread

### Deliverables
- Clicking/draging ImGui widgets doesn't rotate camera
- Typing in ImGui text fields doesn't trigger Haskan2 keybindings
- When ImGui is not focused, all input goes to Haskan2 as before

### Files
- `src/Graphics/Haskan/Engine/Types.hs` — `imguiWantsMouse :: TVar Bool`, `imguiWantsKeyboard :: TVar Bool`
- `src/Graphics/Haskan/Engine/Update.hs` — skip camera when ImGui wants input

---

## Phase 5: Engine Status Panel
**Priority:** Medium — First useful UI
**Estimate:** 4-6 hours
**Risk:** Low

### Tasks
1. Create `Graphics.Haskan.UI.Panels.Status`:
   ```haskell
   statusPanel :: GameState cam -> ImGui ()
   statusPanel gs = do
     withWindowOpen "Engine Status" $ do
       -- FPS
       text $ pack $ printf "Render: %.1f FPS" renderFPS

       -- Camera
       cam <- liftIO $ readTVarIO (world gs)
       text $ pack $ printf "Camera: %.1f distance" (cameraDistance cam)

       -- Day/Night
       tod <- liftIO $ readTVarIO (gameTimeOfDay gs)
       text $ pack $ printf "Time of Day: %.2fh" tod

       -- Debug mode
       debug <- liftIO $ readTVarIO (debugMode gs)
       sliderFloat "Debug Mode" debug 0.0 15.0

       -- Toggles
       checkbox "Wireframe" (wireframeEnabled gs)
       checkbox "Axis Overlay" (axisOverlayEnabled gs)
       checkbox "Ground Plane" (groundPlaneEnabled gs)
   ```
2. Toggle panel visibility with `F12` key (or `Tab`)
3. Read all values from existing GameState TVars

### Deliverables
- Status panel shows real-time engine state
- Debug mode slider works
- Toggle checkboxes work
- Panel togglable via keyboard

### Files
- `src/Graphics/Haskan/UI/Panels/Status.hs` (new)
- `src/Graphics/Haskan/UI/Build.hs` (new — orchestrates all panels)

---

## Phase 6: Rendering Controls Panel
**Priority:** Medium — Useful tuning controls
**Estimate:** 3-4 hours
**Risk:** Low

### Tasks
1. Lighting controls:
   - Number of lights (1-8)
   - Per-light intensity, color, direction
   - IBL intensity slider
2. Sky/atmosphere controls:
   - Time of day slider
   - Time speed multiplier
   - Sky tint color picker
3. Cloud controls:
   - Coverage threshold
   - Height mask bounds
   - Debug mode selector (density / height / raw noise)

### Deliverables
- All runtime-tunable parameters accessible via UI
- No need to restart for parameter changes

### Files
- `src/Graphics/Haskan/UI/Panels/Lighting.hs` (new)
- `src/Graphics/Haskan/UI/Panels/Atmosphere.hs` (new)
- `src/Graphics/Haskan/UI/Panels/Clouds.hs` (new)

---

## Phase 7: Physics Controls Panel (requires Jolt milestone)
**Priority:** Medium — Depends on Jolt milestone
**Estimate:** 3-4 hours
**Risk:** Low

### Tasks
1. Physics panel:
   - "Time Window" slider (0.1s — 60s)
   - "Step" button — triggers `pendingPhysicsStep` TVar
   - "Auto-step" toggle — continuous stepping
   - "Reset" button — restore initial state
   - Body count / active count display
2. Per-body inspector (select body by clicking in viewport):
   - Position, rotation, velocity
   - Mass, friction, restitution
   - Apply force/impulse buttons

### Deliverables
- Full sliding-window physics control via UI

### Files
- `src/Graphics/Haskan/UI/Panels/Physics.hs` (new, requires Jolt milestone)

---

## Summary: Effort & Timeline

| Phase | Task | Est. Hours | Risk | Dependencies |
|-------|------|-----------|------|--------------|
| 1 | Dependency setup | 2h | Low | None |
| 2 | Vulkan backend init | 5h | Medium | Phase 1 |
| 3 | Frame integration | 5h | Medium | Phase 2 |
| 4 | Input focus management | 3h | Low | Phase 3 |
| 5 | Status panel | 5h | Low | Phase 3 |
| 6 | Rendering controls | 4h | Low | Phase 5 |
| 7 | Physics panel | 4h | Low | Phase 5 + Jolt |
| **Total** | | **~28h** | | |

## Recommended Order
1. **Phase 1** (deps) — trivial, start here
2. **Phase 2+3** (Vulkan init + frame integration) — hardest part, do together
3. **Phase 4** (input focus) — must work before panels are useful
4. **Phase 5** (status panel) — first visible result
5. **Phase 6** (rendering controls) — polish
6. **Phase 7** (physics panel) — requires Jolt milestone

## Key Technical Decisions
1. **Separate UI render pass** (recommended) vs subpass in lighting pass
   - Separate is cleaner: `VK_ATTACHMENT_LOAD_OP_LOAD`, alpha blend
   - ImGui generates its own command buffer draws
2. **Descriptor pool**: ImGui needs ~1000 descriptor sets. Create a separate pool to avoid starving the deferred renderer.
3. **Font atlas**: ImGui generates a font texture at init. Upload to GPU via existing texture infrastructure.
4. **Vsync**: ImGui benefits from vsync for smooth widget rendering. Haskan2 uses `IMMEDIATE_KHR` present mode — may cause ImGui tearing. Consider `MAILBOX_KHR` when ImGui is active.

## Open Questions
- Should ImGui render at full resolution or half resolution? (Full res recommended — text quality matters)
- How to handle ImGui + existing debug socket UI coexistence?
- Which key to toggle ImGui panel? (`F12`? `Tab`? `` ` ``?)
