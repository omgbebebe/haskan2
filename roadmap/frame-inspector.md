# Frame Inspector Design Document

## Goal

Provide a comprehensive, zero-overhead-when-disabled frame capture and analysis subsystem that enables debugging, profiling, and validation of every aspect of the rendering pipeline. The inspector must function correctly across all engine milestones — from the current single-mesh forward renderer to the final GPU-driven deferred pipeline.

## Why This Matters

Rendering bugs are the hardest to debug in a game engine because the failure is visual and the cause can be anywhere in the pipeline:

- **Resource binding errors** — wrong descriptor set, stale buffer, missing texture
- **Transform hierarchy bugs** — parent scale propagating incorrectly, gimbal lock in camera
- **Render graph miscompilation** — missing barrier, wrong image layout, pass ordering
- **GPU/CPU divergence** — what the CPU thinks it submitted vs. what the GPU executed
- **Performance cliffs** — unexpected pipeline stalls, memory bandwidth saturation

Without structured frame capture, you are debugging via `printf` of raw `M44` matrices. The Frame Inspector turns every frame into a queryable, diffable, serializable artifact.

## Current State

A minimal implementation exists in `Graphics.Haskan.Debug.FrameInspector`:

- **Trigger:** F12 key press sets a `TVar Bool`, sampled in `renderFrameLoop`
- **Capture:** CPU-side data — camera position/target, entity NDC vertices, projection/view matrices, frame number
- **Output:** Single markdown file per snapshot to `snapshots/frame-<N>.md`
- **ECS integration:** `extractDrawList` provides renderables; `EntityDebugInfo` includes world matrix, position, NDC vertices
- **Render graph awareness:** Deferred pipeline (g-buffer + lighting) captured; pass names in snapshot
- **Limitations:**
  - No GPU data (timestamps, pipeline statistics, occlusion queries)
  - No historical comparison or diff
  - Synchronous file I/O blocks the render thread
  - No automated triggers (validation error, frame time threshold)

## Integration Points (Current)

### ECS (Milestone 2)

`renderFrameLoop` captures entity data from `drawList`:
```haskell
entityDebugInfos = zipWith (\idx dc ->
  let modelMat = transpose $ dcWorldMatrix dc
      mvp = projMat !*! viewMat !*! modelMat
      ndcVerts = map (toNDC mvp) sampleLocalVerts
  in EntityDebugInfo { ediEntityId = idx, ... }
  ) [0..] drawList
```

### Render Graph (Milestone 3/4)

Graph compilation produces `CompiledGraph` with pass list. Capture records pass names (`"gbuffer"`, `"lighting"`).

### Resource Manager (Milestone 1)

Camera snapshot includes position, target, distance, azimuth, elevation. Render debug info includes frame number, entity count, projection matrix.

## Desired Final State

### Overview

The Frame Inspector is a **layer 3.5 subsystem** — it sits between the Render Graph (Layer 3) and the Scene/ECS (Layer 4), observing both without interfering. It is architected as a **capture → serialize → analyze** pipeline where each stage is independently replaceable.

```
┌─────────────────────────────────────────────────────────────────┐
│                      Frame Inspector Architecture                │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   ┌─────────────┐    ┌─────────────┐    ┌─────────────────┐   │
│   │   Capture   │───▶│  Serialize  │───▶│     Analyze     │   │
│   │   Layer     │    │   Layer     │    │     Layer       │   │
│   └─────────────┘    └─────────────┘    └─────────────────┘   │
│          │                  │                    │              │
│          ▼                  ▼                    ▼              │
│   ┌─────────────┐    ┌─────────────┐    ┌─────────────────┐   │
│   │ FrameContext│    │ SnapshotFmt │    │  FrameDatabase  │   │
│   │  (mutable)  │    │  (immutable)│    │  (queryable)    │   │
│   └─────────────┘    └─────────────┘    └─────────────────┘   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Core Design Principles

1. **Zero overhead when disabled** — The capture layer is a no-op unless a trigger fires. Hot path code should compile to nothing when inspector is not linked.
2. **Async I/O** — Serialization and file writing happen on a dedicated thread. The render thread only copies data into a lock-free ring buffer.
3. **Extensible backends** — Markdown for humans, JSON for tools, binary for replay, network for live profiling.
4. **ECS-native** — Renderables, lights, cameras are queried from the ECS World, not hardcoded.
5. **Render-graph aware** — Passes, barriers, resource transitions are part of the snapshot.

## Architecture

### 1. Capture Layer

The capture layer is a mutable `FrameContext` that accumulates data during a frame. It is owned by the render thread and cleared at frame start.

```haskell
data FrameContext = FrameContext
  { fcFrameNumber    :: !Word64
  , fcStartTime      :: !TimeSpec
  , fcCamera         :: !(TVar CameraSnapshot)  -- updated by ECS
  , fcRenderables    :: !(TVar (Vector RenderableRef))
  , fcPasses         :: !(TVar (Vector PassRef))
  , fcGpuQueries     :: !(TVar (Vector GpuQueryResult))
  , fcValidation     :: !(TVar (Vector Text))
  , fcMemoryStats    :: !(TVar MemorySnapshot)
  }
```

**Capture points** (injected by the render graph compiler):

| Point | Data Captured | Trigger |
|-------|--------------|---------|
| `PreFrame` | Frame number, timestamp, memory baseline | Every frame (cheap) |
| `PrePass` | Pass name, inputs/outputs, expected barriers | Every frame (cheap) |
| `PreDraw` | EntityId, mesh handle, material handle, transform | Only if inspector active |
| `PostDraw` | GPU timestamp, triangle count, instance count | Only if inspector active |
| `PostPass` | Actual barriers inserted, image layout transitions | Only if inspector active |
| `PostFrame` | CPU frame time, present result, validation messages | Every frame (cheap) |

The render graph builder wraps each pass with capture hooks:

```haskell
-- In RenderGraph compiler
compilePass :: FrameContext -> RenderPassNode -> CompiledPass
compilePass ctx pass = pass { rpRecord = \cmd -> do
  capturePrePass ctx pass
  rpRecord pass cmd
  capturePostPass ctx pass
}
```

### 2. Serialize Layer

When the trigger fires (F12, validation error, or automated threshold), the `FrameContext` is frozen into an immutable `FrameSnapshot` and passed to the serializer.

```haskell
data FrameSnapshot = FrameSnapshot
  { fsMeta         :: !FrameMeta
  , fsCamera       :: !CameraSnapshot
  , fsScene        :: !SceneSnapshot
  , fsRenderGraph  :: !RenderGraphSnapshot
  , fsGpu          :: !GpuSnapshot
  , fsPerformance  :: !PerformanceSnapshot
  , fsMemory       :: !MemorySnapshot
  , fsValidation   :: !ValidationSnapshot
  }
```

**Serializer backends:**

```haskell
type Serializer = FrameSnapshot -> IO ()

data SnapshotFormat
  = MarkdownFmt    -- human readable, git diffable
  | JsonFmt        -- machine readable, tool ingest
  | BinaryFmt      -- compact, for frame replay
  | NetworkFmt     -- streaming to live profiler
```

The serializer runs on a **dedicated background thread** fed by a bounded queue:

```haskell
data InspectorConfig = InspectorConfig
  { icTrigger        :: TriggerMode
  , icFormat         :: SnapshotFormat
  , icOutputPath     :: FilePath
  , icMaxSnapshots   :: !Int        -- ring buffer of files
  , icAsyncQueueSize :: !Int        -- bounded, drop old on overflow
  }

data TriggerMode
  = ManualTrigger        -- F12 or explicit API call
  | ValidationError      -- any validation message
  | FrameTimeThreshold   -- CPU or GPU time exceeds limit
  | EveryNFrames Word64  -- periodic capture for profiling
  | AlwaysOn             -- every frame (debug builds only)
```

### 3. Analyze Layer

The analysis layer operates on persisted snapshots, not the live frame.

**Frame Database:**

```haskell
data FrameDatabase = FrameDatabase
  { dbSnapshots  :: !(Vector FrameSnapshot)  -- in-memory cache
  , dbIndex      :: !(HashMap Text [Int])    -- index by entity, pass, material
  , dbStats      :: !AggregatedStats
  }

-- Queries
dbDiff :: FrameDatabase -> Int -> Int -> FrameDiff
dbEntityHistory :: FrameDatabase -> EntityId -> [EntitySnapshot]
dbPassTimeline :: FrameDatabase -> PassName -> [(Word64, GpuSnapshot)]
```

**Analysis tools:**

| Tool | Input | Output |
|------|-------|--------|
| `frame-diff` | Two snapshots | What changed: entity count, pass costs, memory delta |
| `entity-tracker` | EntityId + frame range | Position, visibility, material history |
| `pass-profiler` | PassName + N frames | Min/max/avg GPU time, triangle throughput |
| `validation-replay` | Snapshot sequence | First frame where validation error appeared |

## Data Types (Evolution)

### Camera Snapshot

```haskell
data CameraSnapshot = CameraSnapshot
  { csPosition       :: !(V3 Float)
  , csForward        :: !(V3 Float)
  , csUp             :: !(V3 Float)
  , csFov            :: !Float
  , csAspect         :: !Float
  , csNearFar        :: !(Float, Float)
  , csViewMatrix     :: !(M44 Float)
  , csProjMatrix     :: !(M44 Float)
  , csFrustumPlanes  :: ![V4 Float]       -- extracted for culling debug
  }
```

*Evolution:* Add frustum planes for visibility debugging, exposure/ISO for HDR pipeline.

### Renderable Snapshot

```haskell
data RenderableSnapshot = RenderableSnapshot
  { rsEntityId       :: !EntityId         -- ECS reference
  , rsName           :: !Text
  , rsWorldMatrix    :: !(M44 Float)
  , rsLocalMatrix    :: !(M44 Float)      -- before parent transform
  , rsScale          :: !(V3 Float)
  , rsVisible        :: !Bool
  , rsMaterial       :: !MaterialHandle   -- Layer 2 handle
  , rsMesh           :: !MeshHandle       -- Layer 2 handle
  , rsIndexCount     :: !Int
  , rsVertexCount    :: !Int
  , rsAABB           :: !(V3 Float, V3 Float)  -- world-space bounds
  , rsLayer          :: !RenderLayer      -- opaque, transparent, decal, etc.
  }
```

*Evolution:* ECS-native — queried from `World` instead of hardcoded. Includes AABB for frustum culling verification.

### Render Graph Snapshot

```haskell
data RenderGraphSnapshot = RenderGraphSnapshot
  { rgsPasses        :: ![PassSnapshot]
  , rgsResources     :: ![ResourceSnapshot]
  , rgsBarriers      :: ![BarrierSnapshot]
  }

data PassSnapshot = PassSnapshot
  { psName           :: !Text
  , psType           :: !PassType          -- GBuffer, Lighting, Forward, PostProcess
  , psInputs         :: ![ResourceId]
  , psOutputs        :: ![ResourceId]
  , psDrawCalls      :: !Int
  , psGpuTimeMs      :: !(Maybe Float)     -- from timestamp query
  , psTriangleCount  :: !Int
  , psViewport       :: !(V2 Float, V2 Float)
  , psScissor        :: !(V2 Float, V2 Float)
  }

data BarrierSnapshot = BarrierSnapshot
  { bsSrcStage       :: !PipelineStageFlags
  , bsDstStage       :: !PipelineStageFlags
  , bsImageBarriers  :: ![ImageMemoryBarrierSnapshot]
  }
```

*Evolution:* Essential for Milestone 3 (Render Graph). Without this, debugging pass ordering and missing barriers is guesswork.

### GPU Snapshot

```haskell
data GpuSnapshot = GpuSnapshot
  { gsFrameTimeGpu   :: !(Maybe Float)     -- from timestamp queries
  , gsPipelineStats  :: !(Maybe PipelineStatistics)
  , gsOcclusion      :: !(Maybe OcclusionResults)
  , gsMeshShading    :: !(Maybe MeshShaderStats)  -- Milestone 8
  }

data PipelineStatistics = PipelineStatistics
  { psInputVertices      :: !Word64
  , psInputPrimitives    :: !Word64
  , psVertexShaderInvocs :: !Word64
  , psFragmentShaderInvocs :: !Word64
  , psComputeShaderInvocs  :: !Word64
  }
```

*Evolution:* GPU timestamps require `VK_EXT_calibrated_timestamps` or `VK_KHR_synchronization2`. Pipeline statistics require a query pool. These are optional features gated by device capability checks.

### Memory Snapshot

```haskell
data MemorySnapshot = MemorySnapshot
  { msDeviceLocalUsed    :: !Word64        -- VRAM
  , msDeviceLocalTotal   :: !Word64
  , msHostVisibleUsed    :: !Word64        -- Staging / mapped
  , msHostVisibleTotal   :: !Word64
  , msLargestAllocations :: ![AllocationInfo]
  }

data AllocationInfo = AllocationInfo
  { aiResourceType   :: !Text              -- "texture", "buffer", "acceleration_structure"
  , aiSize           :: !Word64
  , aiName           :: !Text              -- debug name via VK_EXT_debug_utils
  }
```

*Evolution:* Requires integration with the Resource Manager (Milestone 1). The allocator must track per-allocation metadata.

### Validation Snapshot

```haskell
data ValidationSnapshot = ValidationSnapshot
  { vsMessages       :: ![ValidationMessage]
  , vsSeverityCounts :: !(HashMap Severity Int)
  }

data ValidationMessage = ValidationMessage
  { vmSeverity       :: !Severity
  , vmLayer          :: !Text
  , vmMessage        :: !Text
  , vmObjectHandles  :: ![Word64]          -- affected Vulkan objects
  }
```

*Evolution:* Replaces the current `[Text]` list. Integrates with `VK_EXT_debug_utils` for object naming.

## Integration Points

### ECS (Milestone 2)

The inspector queries the ECS World to build `SceneSnapshot`:

```haskell
buildSceneSnapshot :: World -> IO SceneSnapshot
buildSceneSnapshot world = do
  entities <- queryEntities world (Has meshComponent .&. Has transformComponent .&. Has visibilityComponent)
  for entities $ \eid -> do
    mesh <- getComponent world eid meshComponent
    xform <- getComponent world eid transformComponent
    vis  <- getComponent world eid visibilityComponent
    pure $ RenderableSnapshot eid (entityName world eid) (transformMatrix xform) ...
```

This replaces the hardcoded `[RenderableSnapshot]` in `renderFrameLoop`.

### Render Graph (Milestone 3)

The render graph compiler injects capture hooks:

```haskell
compileGraph :: FrameContext -> RenderGraph -> CompiledGraph
compileGraph ctx graph = graph
  { cgPreFrame  = capturePreFrame ctx
  , cgPostFrame = capturePostFrame ctx
  , cgPasses    = map (injectPassCapture ctx) (cgPasses graph)
  }
```

### Resource Manager (Milestone 1)

The Resource Manager provides allocation metadata for `MemorySnapshot`:

```haskell
data ResourceManager = ResourceManager
  { rmAllocations    :: !(TVar (HashMap Handle AllocationInfo))
  , rmAllocator      :: !VulkanMemoryAllocator  -- or dedicated pool
  }

-- Called on every allocation/free
recordAllocation :: ResourceManager -> Handle -> AllocationInfo -> IO ()
recordAllocation rm h info = STM.atomically $ modifyTVar' (rmAllocations rm) (HashMap.insert h info)
```

## Performance Budget

| Operation | Cost | Mitigation |
|-----------|------|------------|
| `PreFrame` capture | ~100 ns | Just read atomics |
| `PreDraw` capture | ~500 ns | Only if inspector active; copy transform pointer |
| `PostFrame` serialization | ~1-5 ms | Async on background thread |
| File I/O (Markdown) | ~10-50 ms | Async; drop if queue full |
| File I/O (Binary) | ~1-5 ms | Memory-mapped ring buffer |
| GPU timestamp readback | ~1 μs | Async query pool readback |

**Total render thread overhead when active:** <1 μs per draw call, <100 μs per frame.

**Total overhead when inactive:** Zero. The capture points are eliminated by the compiler when `icTrigger = ManualTrigger` and no trigger is armed.

## Output Formats

### Markdown (Current)

Human-readable, git-diffable. Best for code review and bug reports. Current implementation is adequate; future work adds collapsible sections for large scenes.

### JSON

```json
{
  "frame": 1847,
  "timestamp": "2026-05-07T12:33:01.234Z",
  "camera": {
    "position": [-17.26, 7.52, -6.74],
    "forward": [0.86, -0.38, 0.34]
  },
  "scene": {
    "entity_count": 1473,
    "renderables": [...]
  }
}
```

Machine-ingestible. Enables external tools: flame graphs, timeline viewers, automated regression detection.

### Binary (Frame Replay)

Compact, schema-versioned format for reconstructing a frame offline. Stores raw GPU resources (buffer contents, texture data) to replay without the original assets. This is the foundation for a **standalone frame replay tool** — essential for debugging GPU crashes on user machines.

### Network (Live Profiler)

Stream snapshots to a web-based profiler via WebSocket. The profiler shows:

- Real-time frame time graph
- Pass cost breakdown (GPU flame graph)
- Entity count over time
- Memory allocation timeline

## Trigger Modes Detail

### Manual Trigger (F12)

Current behavior. User presses F12 → next completed frame is captured. Suitable for ad-hoc debugging.

### Validation Error Trigger

Any `ValidationMessage` with severity >= `Warning` automatically captures the current frame and the previous 3 frames (ring buffer). Essential for catching use-after-free, synchronization errors, and layout mismatches.

### Threshold Trigger

```haskell
data ThresholdConfig = ThresholdConfig
  { tcCpuFrameTimeMs :: !Float
  , tcGpuFrameTimeMs :: !Maybe Float
  , tcDrawCallCount  :: !Maybe Int
  , tcMemoryUsedMb   :: !Maybe Float
  }
```

When any threshold is exceeded, capture the offending frame plus the next frame (to see recovery).

### Periodic Trigger

Capture every N frames. Used for profiling to build statistical distributions. The serializer writes to a rolling file set (`frame-0000.bin`, `frame-0001.bin`, ...) and overwrites old files when `icMaxSnapshots` is reached.

## Milestone Integration

| Milestone | Inspector Feature Added |
|-----------|------------------------|
| **1 — Resource Manager** | `MemorySnapshot` from allocator metadata; handles in `RenderableSnapshot` |
| **2 — ECS** | `SceneSnapshot` queried from `World`; `EntityId` tracking |
| **3 — Render Graph** | `RenderGraphSnapshot` with passes, barriers, resource transitions |
| **4 — Deferred Rendering** | Multiple pass captures (GBuffer, Lighting, Composite); `PassType` enum |
| **5 — GLTF Loading** | Material parameters, skinning matrices, animation state in snapshot |
| **6 — Advanced Shaders** | Shader variant key, specialization constants, push constant values |
| **7 — Bindless Rendering** | Bindless descriptor index ranges, texture heap utilization |
| **8 — GPU-Driven** | Mesh shader stats, compute cull results, indirect draw buffer contents |

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Async queue overflow | Missed snapshots | Bounded queue with `DropOldest` policy; warn when dropping |
| File I/O latency | Frame stutter | Dedicated thread; write to `/tmp` or RAM disk first |
| GPU timestamp unavailability | Missing perf data | Graceful fallback to CPU time only; check device features |
| Binary format churn | Unreplayable old snapshots | Schema versioning; migration tool per major version |
| Memory bloat from large scenes | OOM in debug builds | Streaming serialization; flush per-entity instead of buffering all |

## Future Work (Post-Milestone 8)

1. **Ray Tracing Capture** — Store acceleration structures, shader binding tables, hit/miss shaders per ray
2. **VR/Multi-View** — Per-eye snapshots with view-dependent culling results
3. **Deterministic Replay** — Seed RNG state, capture input history, replay exact frame sequence
4. **Machine Learning Ingest** — Train anomaly detection on `FrameSnapshot` sequences to auto-flag performance regressions
5. **Collaborative Debugging** — Share snapshot URLs (hosted or P2P) for remote team debugging

## Appendix: Current → Final Migration Path

### Phase 1: Now (Current)
- Fix `fmtF` precision, camera position extraction, index count ✅
- Add `Camera` class methods for position/forward ✅
- Hardcoded renderables in `renderFrameLoop` ✅

### Phase 2: Milestone 1 Integration
- `ResourceManager` provides `AllocationInfo` for `MemorySnapshot`
- `RenderableSnapshot` uses `MeshHandle`/`MaterialHandle` instead of raw `VkBuffer`

### Phase 3: Milestone 2 Integration
- Replace hardcoded renderables with ECS query
- `EntityId` becomes primary key in snapshots

### Phase 4: Milestone 3 Integration
- Render graph compiler injects capture hooks
- `RenderGraphSnapshot` captures pass ordering and barriers

### Phase 5: Async Serialization
- Background thread + bounded queue
- JSON serializer alongside Markdown

### Phase 6: GPU Data
- Timestamp queries, pipeline statistics
- `GpuSnapshot` populated from query pool readback

### Phase 7: Analysis Tools
- `FrameDatabase` in-memory cache
- `frame-diff` CLI tool

### Phase 8: Live Profiler
- WebSocket streaming
- Real-time visualization

---

*Document version: 1.0*
*Target engine version: Final (post-Milestone 8)*
*Last updated: 2026-05-07*
