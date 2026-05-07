# Haskan2 Vulkan Synchronization: Fences, Barriers & Function Call Diagram

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              PER-FRAME-IN-FLIGHT (N=2)                           │
│                                                                                  │
│  Frame 0                    Frame 1                    Frame 0 (wrap)            │
│  ├─ fence[0]                ├─ fence[1]                ├─ fence[0]               │
│  ├─ imageAvailSem[0]        ├─ imageAvailSem[1]        ├─ imageAvailSem[0]       │
│  └─ renderDoneSem[0]        └─ renderDoneSem[1]        └─ renderDoneSem[0]       │
│                                                                                  │
│  Each frame-in-flight slot has EXCLUSIVE ownership of these 3 objects.          │
│  No other frame may use them until fence signals.                               │
└─────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────┐
│                           PER-SWAPCHAIN-IMAGE (M=3-4)                            │
│                                                                                  │
│  Image 0                    Image 1                    Image 2                   │
│  ├─ commandBuffer[0]        ├─ commandBuffer[1]        ├─ commandBuffer[2]       │
│  ├─ gBufferFramebuffer[0]   ├─ gBufferFramebuffer[1]   ├─ gBufferFramebuffer[2]  │
│  ├─ gBufferImageSet[0]      ├─ gBufferImageSet[1]      ├─ gBufferImageSet[2]     │
│  ├─ lightingFramebuffer[0]  ├─ lightingFramebuffer[1]  ├─ lightingFramebuffer[2] │
│  └─ lightingDescriptor[0]   └─ lightingDescriptor[1]   └─ lightingDescriptor[2]  │
│                                                                                  │
│  These are PURE DATA. Multiple frames can reference the same swapchain image     │
│  if the presentation engine has released it. Fences prevent concurrent access.   │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Function Call Sequence (One Frame)

```
renderFrameLoop (Engine.hs:285)
│
├─> drawFrame (Render.hs:118)
│   │
│   ├─> vkWaitForFences(device, fence[frameNumber], timeout=MAX)
│   │   └─ PURPOSE: Stall CPU until GPU finished previous work using this
│   │      frame-in-flight slot. Without this: CPU overwrites command buffer
│   │      /uniforms while GPU reads them → race condition / corruption.
│   │   └─ PITFALL: Must happen BEFORE vkAcquireNextImageKHR. If reversed,
│   │      acquire could return image still being presented, then CPU waits
│   │      on fence that hasn't been submitted yet → deadlock or validation
│   │      error (VUID-vkAcquireNextImageKHR-semaphore-01779).
│   │
│   ├─> vkResetFences(device, fence[frameNumber])
│   │   └─ PURPOSE: Reset fence to unsignaled state so next submit can signal it.
│   │   └─ PITFALL: Must happen AFTER vkWaitForFences confirms it was signaled.
│   │      Resetting a signaled fence before waiting = race with GPU.
│   │   └─ PITFALL: Must happen BEFORE vkQueueSubmit. If submit happens first
│   │      and THEN reset, fence never gets reset → next frame skips wait.
│   │
│   ├─> vkAcquireNextImageKHR(swapchain, imageAvailSem[frameNumber])
│   │   └─ PURPOSE: Get index of next available swapchain image.
│   │      Signals imageAvailSem when image is ready for rendering.
│   │   └─ PITFALL: Semaphore must be in unsignaled state. If previous frame
│   │      hasn't finished presenting this image, acquire blocks or returns
│   │      VK_SUBOPTIMAL_KHR / VK_ERROR_OUT_OF_DATE_KHR.
│   │   └─ PITFALL: Cannot acquire more images than swapchain has without
│   │      presenting. Triple-buffering (3 images) + 2 frames in flight = OK.
│   │      But if you tried 4 frames in flight with 3 images = deadlock.
│   │
│   └─> renderImage (Render.hs:138) ── only if acquire succeeded
│       │
│       ├─> recordAction(imageIndex, frameNumber) ── CALLBACK to Engine.hs
│       │   │
│       │   ├─> CommandBuffer.withCommandBuffer(commandBuffer[imageIndex])
│       │   │   └─ PURPOSE: Begin recording. Implicitly resets buffer because
│       │   │      pool has VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT.
│       │   │   └─ PITFALL: Without RESET_COMMAND_BUFFER_BIT, vkBeginCommandBuffer
│       │   │      on already-recorded buffer = validation error.
│       │   │
│       │   ├─> buildDeferredGraph + compileGraph + execute
│       │   │   │
│       │   │   ├─> PASS: gbuffer ── RenderPass.withGBufferRenderPass
│       │   │   │   │
│       │   │   │   ├─> vkCmdBeginRenderPass(..., VK_SUBPASS_CONTENTS_INLINE)
│       │   │   │   │   └─ PURPOSE: Start g-buffer pass. Attachments transition:
│       │   │   │   │      initialLayout(SHADER_READ_ONLY_OPTIMAL)
│       │   │   │   │        → layout(COLOR_ATTACHMENT_OPTIMAL)
│       │   │   │   │      This is AUTOMATIC via render pass loadOp.
│       │   │   │   │   └─ BARRIER EQUIVALENT (handled by render pass):
│       │   │   │   │      srcStage: FRAGMENT_SHADER | srcAccess: SHADER_READ
│       │   │   │   │      dstStage: COLOR_ATTACHMENT_OUTPUT | dstAccess: COLOR_ATTACHMENT_WRITE
│       │   │   │   │      (from dependencyToExternal in previous frame)
│       │   │   │   │
│       │   │   │   ├─> vkCmdBindPipeline(gBufferPipeline)
│       │   │   │   ├─> FOR EACH entity:
│       │   │   │   │   ├─> vkCmdBindDescriptorSets(gBufferDescriptorSet + dynamicOffset)
│       │   │   │   │   ├─> vkCmdBindVertexBuffers + vkCmdBindIndexBuffer
│       │   │   │   │   └─> vkCmdDrawIndexed(indexCount)
│       │   │   │   │
│       │   │   │   └─> vkCmdEndRenderPass
│       │   │   │       └─ PURPOSE: End g-buffer pass. Subpass dependency triggers:
│       │   │   │          srcStage: COLOR_ATTACHMENT_OUTPUT | srcAccess: COLOR_ATTACHMENT_WRITE
│       │   │   │          dstStage: FRAGMENT_SHADER | dstAccess: SHADER_READ
│       │   │   │          Attachments transition: COLOR_ATTACHMENT_OPTIMAL
│       │   │   │            → finalLayout(SHADER_READ_ONLY_OPTIMAL)
│       │   │   │       └─ PITFALL: Without dependencyToExternal, layout stays
│       │   │   │          COLOR_ATTACHMENT_OPTIMAL. Lighting pass samples with
│       │   │   │          SHADER_READ_ONLY_OPTIMAL descriptor → validation error
│       │   │   │          VUID-vkCmdDraw-None-09600 (layout mismatch).
│       │   │   │       └─ PITFALL: If dependency srcAccessMask=0, driver may
│       │   │   │          not guarantee writes are visible before shader reads.
│       │   │   │
│       │   │   └─> PASS: lighting ── RenderPass.withLightingRenderPass
│       │   │       │
│       │   │       ├─> vkCmdBeginRenderPass(...)
│       │   │       │   └─ PURPOSE: Start lighting pass. Swapchain image transitions:
│       │   │       │      UNDEFINED → COLOR_ATTACHMENT_OPTIMAL (loadOp=CLEAR)
│       │   │       │   └─ BARRIER EQUIVALENT:
│       │   │       │      srcStage: COLOR_ATTACHMENT_OUTPUT | srcAccess: 0
│       │   │       │      dstStage: COLOR_ATTACHMENT_OUTPUT | dstAccess: COLOR_ATTACHMENT_WRITE
│       │   │       │      (from dependency in lighting render pass)
│       │   │       │
│       │   │       ├─> vkCmdBindPipeline(lightingPipeline)
│       │   │       ├─> vkCmdBindDescriptorSets(lightingDescriptorSet[imageIndex])
│       │   │       │   └─ NOTE: This descriptor set references g-buffer image views.
│       │   │       │      The images MUST be in SHADER_READ_ONLY_OPTIMAL at this point.
│       │   │       │   └─ PITFALL: If g-buffer pass hasn't completed yet (no
│       │   │       │      subpass dependency), lighting shader reads stale data
│       │   │       │      or gets validation error for wrong layout.
│       │   │       │
│       │   │       ├─> vkCmdDraw(3, 1, 0, 0) ── fullscreen triangle
│       │   │       │
│       │   │       └─> vkCmdEndRenderPass
│       │   │           └─ PURPOSE: End lighting pass. Swapchain image transitions:
│       │   │              COLOR_ATTACHMENT_OPTIMAL → PRESENT_SRC_KHR
│       │   │           └─ CRITICAL: This transition MUST complete before present.
│       │   │              The renderFinishedSem semaphore guarantees this.
│       │   │
│       │   └─> vkEndCommandBuffer
│       │
│       ├─> vkQueueSubmit(graphicsQueue, submitInfo, fence[frameNumber])
│       │   └─ PURPOSE: Submit command buffer to GPU. Signals renderDoneSem
│       │      when all commands complete. Signals fence[frameNumber] when
│       │      GPU is fully done with this frame's work.
│       │   └─ SUBMIT WAIT: imageAvailSem[frameNumber] at COLOR_ATTACHMENT_OUTPUT
│       │      └─ PURPOSE: Don't start color writes until swapchain image is ready.
│       │      └─ PITFALL: Wrong dstStageMask = GPU starts vertex shading while
│       │         image isn't ready, stalls at rasterization = wasted work.
│       │   └─ SUBMIT SIGNAL: renderDoneSem[frameNumber]
│       │      └─ PURPOSE: Tell presentation engine rendering is done.
│       │   └─ PITFALL: If renderDoneSem was indexed by imageIndex (old bug),
│       │      same semaphore could be signaled twice before presentation consumed
│       │      it → undefined behavior, GPU hang after 2-3 seconds.
│       │
│       └─> RETURN imageIndex
│
│   (back in Engine.hs)
│   ├─> presentFrame(ctx, imageIndex, renderDoneSem[frameNumber])
│   │   └─ PURPOSE: Present the rendered image to the display.
│   │   └─ PRESENT WAIT: renderDoneSem[frameNumber]
│   │      └─ PURPOSE: Don't present until rendering finished. Without this:
│   │         screen shows half-rendered frame (tearing / corruption).
│   │   └─ PITFALL: Using wrong semaphore index = waiting on semaphore that
│   │      was never signaled, or was already consumed → race / hang.
│   │   └─ PITFALL: If present queue ≠ graphics queue, need extra semaphore
│   │      and possibly ownership transfer barrier (not needed here, same queue).
│   │
│   └─> frameNumber' = (frameNumber + 1) `mod` maxFramesInFlight
│       └─ PURPOSE: Advance to next frame slot. Frame 0 and 1 alternate.
│       └─ PITFALL: With triple-buffering and VSync, frame 0 may run twice
│       │   before frame 1 if frame 1's fence hasn't signaled yet. The fence
│       │   wait handles this naturally.
│       └─ PITFALL: If maxFramesInFlight > swapchainImageCount, deadlock:
│           all frames waiting on acquire, none can present to free images.
│
└─> renderFrameLoop (...) ── RECURSE with frameNumber'
```

---

## Fence Deep Dive

### What Fences Do
Fences are **CPU-GPU synchronization primitives**. They have two states:
- **Unsignaled** (default): GPU work is in progress or not yet submitted
- **Signaled**: GPU has completed all work associated with this fence

### Fence Lifecycle (Per Frame)

```
Frame N begins:
  fence[N] must be SIGNALED (from previous use) or we deadlock in vkWaitForFences
  │
  ├─> vkWaitForFences(fence[N], timeout=MAX) ── CPU BLOCKS here
  │   └─ "GPU, are you done with frame N's slot?"
  │   └─ If yes: returns immediately (fence already signaled)
  │   └─ If no: CPU sleeps until GPU finishes
  │
  ├─> vkResetFences(fence[N])
  │   └─ "Mark this slot as IN USE again"
  │   └─ Now fence[N] is UNSIGNALED
  │
  ... (record commands, submit to GPU) ...
  │
  ├─> vkQueueSubmit(..., fence[N])
  │   └─ "GPU, signal this fence when you're done with everything"
  │   └─ Fence remains UNSIGNALED until GPU processes entire submission
  │
  Frame N ends. Next time slot N is used (N+2 frames later), the fence
  will be SIGNALED because GPU has finished by then.
```

### Fence Pitfalls

| Pitfall | Symptom | Fix |
|---------|---------|-----|
| Wait after acquire | Validation error / deadlock | Wait BEFORE acquire |
| Reset before wait | Race: reset while GPU still signaling | Wait confirmed, THEN reset |
| Submit before reset | Fence never reset, next wait returns immediately | Reset before submit |
| Fence per image instead of per frame | Same fence waited on before image recycled | One fence per frame-in-flight |
| Timeout too short | Spurious failures on slow frames | Use MAX_UINT64 |
| Not checking result | Silent hangs | Always check vkWaitForFences return |

---

## Semaphore Deep Dive

### What Semaphores Do
Semaphores are **GPU-GPU synchronization primitives** (also used for GPU→present engine). They coordinate work across different queue operations without CPU involvement.

### Semaphore Types in Haskan2

```
imageAvailableSem[frame] ── vkAcquireNextImageKHR ──┐
                                                     │ (wait)
                                                     ▼
                                           vkQueueSubmit
                                           waitStage: COLOR_ATTACHMENT_OUTPUT
                                           │
                                           │ (signal)
                                           ▼
renderFinishedSem[frame] ── vkQueueSubmit ──┐
                                            │ (wait)
                                            ▼
                                  vkQueuePresentKHR
```

### Why `imageAvailableSem` is Needed
Without it, the graphics queue could start writing to a swapchain image before the presentation engine has finished reading it for display. The `vkAcquireNextImageKHR` call + semaphore ensures:
1. Presentation engine signals when it releases the image
2. Graphics queue waits on that signal before any color attachment output

### Why `renderFinishedSem` is Needed
Without it, `vkQueuePresentKHR` could execute before the graphics queue finishes rendering. The presentation engine would display a partially-rendered frame or old data. The semaphore ensures:
1. Graphics queue signals when all rendering commands complete
2. Presentation engine waits on that signal before reading the image

### Semaphore Pitfalls

| Pitfall | Symptom | Fix |
|---------|---------|-----|
| Index by imageIndex | GPU hang after 2-3s (semaphore reuse) | Index by frameNumber |
| Reuse semaphore without waiting | Validation error / undefined behavior | One semaphore per frame-in-flight |
| Wait stage too early | GPU stalls unnecessarily | Use LATEST possible stage (COLOR_ATTACHMENT_OUTPUT for rendering) |
| Missing wait in submit | Image not ready when rendering starts | Always include imageAvailableSem wait |
| Missing wait in present | Tearing / partial frames | Always include renderFinishedSem wait |
| Binary semaphore signaled twice | Undefined behavior, GPU hang | Never signal binary semaphore twice without wait |

---

## Barrier Deep Dive

### What Barriers Do
Barriers are **execution and memory dependencies** within a command buffer. They ensure:
1. **Execution dependency**: Previous commands finish before subsequent commands begin
2. **Memory dependency**: Memory writes from previous commands are visible to subsequent commands

### Barrier Types in Haskan2

#### 1. Render Pass Subpass Dependencies (Automatic)

**G-Buffer Pass - Before (EXTERNAL → 0):**
```
srcSubpass: EXTERNAL (anything before this render pass)
dstSubpass: 0 (our subpass)
srcStageMask: COLOR_ATTACHMENT_OUTPUT
srcAccessMask: 0 (nothing to wait for)
dstStageMask: COLOR_ATTACHMENT_OUTPUT | EARLY_FRAGMENT_TESTS
dstAccessMask: COLOR_ATTACHMENT_WRITE | DEPTH_STENCIL_ATTACHMENT_WRITE
```
**Purpose**: Ensure previous frame's present has finished before we start writing g-buffer.

**G-Buffer Pass - After (0 → EXTERNAL):**
```
srcSubpass: 0 (our subpass)
dstSubpass: EXTERNAL (anything after this render pass)
srcStageMask: COLOR_ATTACHMENT_OUTPUT
srcAccessMask: COLOR_ATTACHMENT_WRITE
dstStageMask: FRAGMENT_SHADER
dstAccessMask: SHADER_READ
```
**Purpose**: CRITICAL - Ensures g-buffer color attachment writes complete before lighting fragment shader reads them. Also handles layout transition `COLOR_ATTACHMENT_OPTIMAL → SHADER_READ_ONLY_OPTIMAL`.

**Lighting Pass - Before (EXTERNAL → 0):**
```
srcSubpass: EXTERNAL
dstSubpass: 0
srcStageMask: COLOR_ATTACHMENT_OUTPUT
srcAccessMask: 0
dstStageMask: COLOR_ATTACHMENT_OUTPUT
dstAccessMask: COLOR_ATTACHMENT_WRITE
```
**Purpose**: Ensure previous frame's present finished before writing to swapchain image.

#### 2. Image Memory Barriers (Explicit)

**Initial G-Buffer Transition (DeferredResources.hs):**
```
Old Layout: UNDEFINED
New Layout: SHADER_READ_ONLY_OPTIMAL
srcStage: TOP_OF_PIPE
srcAccess: 0
dstStage: FRAGMENT_SHADER
dstAccess: SHADER_READ
```
**Purpose**: Transition newly-created g-buffer images from `UNDEFINED` (creation state) to `SHADER_READ_ONLY_OPTIMAL` before first use. Without this, the first frame's render pass `initialLayout` would need to be `UNDEFINED` → `COLOR_ATTACHMENT_OPTIMAL`, but we need `SHADER_READ_ONLY_OPTIMAL` for subsequent frames.

**Alternative: Per-Frame Explicit Barrier (NOT USED):**
```
Old Layout: COLOR_ATTACHMENT_OPTIMAL
New Layout: SHADER_READ_ONLY_OPTIMAL
srcStage: COLOR_ATTACHMENT_OUTPUT
srcAccess: COLOR_ATTACHMENT_WRITE
dstStage: FRAGMENT_SHADER
dstAccess: SHADER_READ
```
This would be needed if g-buffer and lighting were in the SAME command buffer without a render pass boundary. But we use separate render passes with subpass dependencies instead.

### Barrier Pitfalls

| Pitfall | Symptom | Fix |
|---------|---------|-----|
| Missing srcAccessMask | Writes not visible, shader reads stale data | Always specify what previous operation wrote |
| Wrong stage masks | Unnecessary stalls or insufficient synchronization | Use most specific stages possible |
| Layout mismatch (descriptor vs actual) | VUID-vkCmdDraw-None-09600 | Ensure image layout matches descriptor layout |
| Missing dependency between passes | Lighting reads before g-buffer writes complete | Add subpass dependency or explicit barrier |
| UNDEFINED initialLayout after first frame | Validation error | Match initialLayout to actual initial state, or transition first |

---

## Race Conditions Summary

### Race 1: CPU vs GPU (Command Buffer)
**Scenario**: Frame N+2 starts before frame N's GPU work finishes.
**Mitigation**: `vkWaitForFences(fence[N])` before recording commands for slot N.
**Without fix**: CPU overwrites command buffer while GPU reads it → corruption / crash.

### Race 2: CPU vs GPU (Uniform Buffer)
**Scenario**: Frame N+2 updates UBO before frame N's GPU read finishes.
**Mitigation**: Same fence wait. Also using `maxFramesInFlight` UBO regions.
**Without fix**: Entity moves between frames in single frame's view → jitter.

### Race 3: Present vs Graphics (Swapchain Image)
**Scenario**: Graphics queue writes to image while presentation engine reads it.
**Mitigation**: `imageAvailableSem` waited at `COLOR_ATTACHMENT_OUTPUT` stage.
**Without fix**: Tearing, partial frames, or validation error.

### Race 4: G-Buffer Write vs Lighting Read
**Scenario**: Lighting fragment shader samples g-buffer before g-buffer pass completes.
**Mitigation**: Subpass dependency `0 → EXTERNAL` with `COLOR_ATTACHMENT_WRITE → SHADER_READ`.
**Without fix**: Lighting reads stale/corrupt g-buffer data (flickering, wrong colors).

### Race 5: Rendering vs Presentation
**Scenario**: `vkQueuePresentKHR` executes before rendering commands complete.
**Mitigation**: `renderFinishedSem` waited by present operation.
**Without fix**: Shows previous frame or partially rendered frame.

### Race 6: Semaphore Reuse (The 2-3 Second Hang)
**Scenario**: `renderFinishedSem[imageIndex]` signaled again before presentation consumed it.
**Trigger**: Swapchain image 0 acquired, rendered, presented. Before presentation finishes,
image 0 is acquired again (FIFO mode), same semaphore signaled again.
**Mitigation**: Index semaphores by `frameNumber`, not `imageIndex`.
**Without fix**: Undefined behavior → GPU hang, driver reset, or black screen.

---

## Key Invariants

1. **Fence invariant**: `vkWaitForFences` + `vkResetFences` must bracket each frame's usage of a slot.
2. **Semaphore invariant**: A binary semaphore must be waited on exactly once between signals.
3. **Layout invariant**: Image layout in descriptor must match actual image subresource layout at draw time.
4. **Command buffer invariant**: Buffer must not be recorded while GPU may be executing it.
5. **Image count invariant**: `maxFramesInFlight <= swapchainImageCount` to prevent acquire deadlock.

---

## Quick Reference: What to Use When

| Problem | Solution | Location |
|---------|----------|----------|
| Don't overwrite CB while GPU reads | `vkWaitForFences` | `drawFrame` start |
| Don't render before image ready | `imageAvailableSem` wait | `vkQueueSubmit` |
| Don't present before render done | `renderFinishedSem` wait | `vkQueuePresentKHR` |
| G-buffer writes → lighting reads | Subpass dependency `0 → EXTERNAL` | `RenderPass.hs` |
| Image layout transitions | `initialLayout`/`finalLayout` + subpass deps | `RenderPass.hs` |
| Fresh image creation layout | Explicit `vkCmdPipelineBarrier` | `DeferredResources.hs` |
| Per-frame CB reset | `VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT` | `CommandPool.hs` |
