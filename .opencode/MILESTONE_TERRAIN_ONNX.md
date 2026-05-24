# Terrain Diffusion — ONNX Runtime Native Integration

**Status**: Not started — deferred until Path A proves insufficient
**Priority**: P3 — optimization milestone, only if sidecar latency or Python dependency is unacceptable
**Estimate**: 8-12 weeks
**Depends on**: Path A (MILESTONE_TERRAIN_SIDECAPI.md) Phases 4-5 (mesh + texturing reusable)
**Reference**: `https://github.com/xandergos/terrain-diffusion`, `terrain_diffusion/onnx/export.py`

---

## Overview

Eliminate the Python sidecar by running terrain-diffusion inference natively via ONNX Runtime C API from Haskell. The terrain-diffusion repo provides an ONNX export utility that produces three models (coarse, base, decoder). Haskan2 calls ONNX Runtime directly via FFI, running inference on CUDA (same GPU as Vulkan renderer).

### Why This Exists

Path A (sidecar API) adds a Python process dependency and ~10ms HTTP overhead per tile. This is acceptable for most use cases (TTST is 660ms, 10ms HTTP is noise). Path B becomes necessary only if:
- Python process management is fragile in production
- Zero-latency tile generation is needed (sub-frame)
- Single-binary distribution is required (no Python)
- GPU memory sharing between ONNX Runtime (CUDA) and Vulkan is needed

### Architecture

```
┌──────────────────────────────────────────────────────────┐
│  Haskan2 Process                                         │
│                                                          │
│  ┌──────────────────┐    ┌───────────────────────────┐  │
│  │ Terrain Pipeline  │    │ ONNX Runtime (C API FFI)  │  │
│  │ (Haskell)         │    │                           │  │
│  │                   │    │  ┌─────┐  ┌─────┐  ┌───┐  │  │
│  │ 1. Generate noise │───→│  │base │→│decod│→│out│  │  │
│  │ 2. InfiniteDiff   │    │  │.onnx│  │er   │  │   │  │  │
│  │    loop (Haskell) │    │  └─────┘  └─────┘  └───┘  │  │
│  │ 3. Blending       │    │       CUDA EP (RTX 4090)  │  │
│  │ 4. Laplacian      │    └───────────┬───────────────┘  │
│  │ 5. Vulkan upload  │                │                  │
│  └──────────────────┘                │                  │
│                                      │ staging buffer   │
│  ┌──────────────────┐                │                  │
│  │ Vulkan Renderer   │←──────────────┘                  │
│  └──────────────────┘                                   │
└──────────────────────────────────────────────────────────┘
```

### Models (from ONNX export)

| Model | Input | Output | Image Size | Opset |
|-------|-------|--------|-----------|-------|
| `coarse_model.onnx` | x, noise_labels, cond_0..N | output | 64×64 | 17 |
| `base_model.onnx` | x, noise_labels, cond_0..N | output | 64×64 | 17 |
| `decoder_model.onnx` | x, noise_labels, cond_0..N | output | 512×512 | 17 |

Export command (one-time):
```
python -m terrain_diffusion.onnx.export xandergos/terrain-diffusion-30m --device cuda --verify --output ./onnx_models
```

**Critical note**: The ONNX export only covers the U-Net forward pass. The InfiniteDiffusion loop (window discovery, multi-step blending, Laplacian reconstruction) must be reimplemented in Haskell.

---

## Phase 1: ONNX Export + Verification (2-3 days)

### Tasks

1. **Export models**: Run `python -m terrain_diffusion.onnx.export` with CUDA verification
2. **Inspect models**: Use `onnx` Python package to dump input/output shapes and types
   ```python
   import onnx
   model = onnx.load("onnx_models/base_model.onnx")
   for inp in model.graph.input:
       print(inp.name, inp.type)
   for out in model.graph.output:
       print(out.name, out.type)
   ```
3. **Validate with ONNX Runtime Python**: Run inference from Python to establish ground truth
   ```python
   import onnxruntime as ort
   sess = ort.InferenceSession("onnx_models/base_model.onnx", providers=["CUDAExecutionProvider"])
   ```
4. **Benchmark inference time**: Measure single-tile latency for each model on RTX 4090
5. **Document model specs**: Input tensor shapes, dtypes, conditioning channels, noise schedule

### Deliverables

| Item | Location |
|------|----------|
| Three `.onnx` model files | `data/terrain/onnx/` |
| Model spec document | `.opencode/terrain_onnx_specs.md` |
| Inference benchmarks | Same document |

---

## Phase 2: ONNX Runtime C API FFI (5-7 days)

### Tasks

1. **Nix dependency**: Add `onnxruntime` to `flake.nix`
   ```
   buildInputs = [ ... onnxruntime ];
   ```
2. **FFI bindings module**: `Graphics.Haskan.Terrain.ONNX.FFI`
   ```haskell
   -- Core session lifecycle
   newtype ORTSession = ORTSession (Ptr ())
   newtype ORTEnv     = ORTEnv (Ptr ())
   newtype ORTValue   = ORTValue (Ptr ())

   foreign import ccall "OrtCreateEnv"
     ortCreateEnv :: CInt -> CString -> Ptr (Ptr ORTEnv) -> IO CInt

   foreign import ccall "OrtCreateSession"
     ortCreateSession :: Ptr ORTEnv -> CString -> Ptr () -> IO CInt

   foreign import ccall "OrtRun"
     ortRun :: Ptr ORTSession -> Ptr () -> ... -> IO CInt

   -- Tensor creation from Haskell memory
   foreign import ccall "OrtCreateTensorWithDataAsOrtValue"
     ortCreateTensorWithDataAsOrtValue :: ... -> IO CInt
   ```
3. **High-level wrapper**: `Graphics.Haskan.Terrain.ONNX.Runtime`
   ```haskell
   data ONNXRuntime = ONNXRuntime
     { ortEnv       :: !ORTEnv
     , ortSession   :: !ORTSession  -- base model
     , ortDecoder   :: !ORTSession  -- decoder model
     , ortCoarse    :: !ORTSession  -- coarse model (optional, can use procedural)
     , ortMemInfo   :: !(Ptr ())
     }

   initONNXRuntime :: FilePath -> IO ONNXRuntime
   -- ^ Load all three models

   runInference :: ONNXRuntime -> Tensor Float -> Float -> [Tensor Float] -> IO (Tensor Float)
   -- ^ Run single U-Net forward pass: x, noise_sigma, conditions → denoised output
   ```
4. **Tensor types**: `Graphics.Haskan.Terrain.ONNX.Tensor`
   ```haskell
   data Tensor a = Tensor
     { tensorData   :: !(ForeignPtr a)    -- pinned memory for ONNX
     , tensorShape  :: ![Int]             -- e.g. [1, 4, 64, 64]
     , tensorDtype  :: !ONNXDtype         -- Float32
     }
   ```
5. **CUDA execution provider**: Configure ONNX Runtime to use CUDA
   ```haskell
   -- Session options: enable CUDA EP, set GPU device 0
   -- ONNX Runtime and Vulkan share the same GPU — no conflict
   -- ONNX Runtime uses CUDA, Vulkan uses Vulkan — different APIs, same device
   ```

### Deliverables

| Item | File |
|------|------|
| ONNX Runtime FFI bindings | `src/Graphics/Haskan/Terrain/ONNX/FFI.hs` |
| High-level runtime wrapper | `src/Graphics/Haskan/Terrain/ONNX/Runtime.hs` |
| Tensor types | `src/Graphics/Haskan/Terrain/ONNX/Tensor.hs` |
| Nix integration | `flake.nix` |
| Unit test: load model, run inference | `test/ONNXRuntimeSpec.hs` |

---

## Phase 3: InfiniteDiffusion Loop in Haskell (7-10 days)

### Problem

The ONNX export only covers U-Net inference. The InfiniteDiffusion algorithm (window discovery, blending, multi-step denoising, Laplacian reconstruction) must be reimplemented in Haskell.

### Tasks

1. **Noise generation**: Match the terrain-diffusion noise schedule
   ```haskell
   -- EDM2 noise schedule (from Karras et al.)
   computeNoiseSigma :: Int -> Int -> Float
   -- timestep t, total timesteps T → sigma value
   ```
2. **Coarse map generation**: Either reuse terrain-diffusion's procedural coarse generator or run coarse ONNX model
   - Procedural: Perlin noise with climate statistics (see `terrain_diffusion/inference/synthetic_map.py`)
   - ONNX: Run coarse model with random noise input
3. **InfiniteDiffusion window loop**:
   ```haskell
   infiniteDiffusionStep :: ONNXRuntime -> TileCoord -> Int -> [WindowContribution] -> IO (Tensor Float)
   -- For each blending timestep T down to 0:
   --   1. Discover overlapping windows (κ-computation)
   --   2. For each window: extract crop, run U-Net, weight output
   --   3. Blend: J_t[R] = A_t[R] / B_t[R]
   ```
4. **Sparse accumulator**: Maintain A_t (numerator) and B_t (denominator) for blending
   ```haskell
   data SparseAccumulator = SparseAccumulator
     { saNumerator   :: !(IORef (Vector Float))   -- A_t
     , saDenominator :: !(IORef (Vector Float))   -- B_t
     }
   ```
5. **Laplacian reconstruction**: Downsample + blur + residual combination
   ```haskell
   laplacianReconstruct :: Tensor Float -> Tensor Float -> IO (Tensor Float)
   -- L_hat = blur(downsample(L+H, 8x))
   -- final = L_hat + H
   -- Apply inverse signed-sqrt: sign(x) * x^2
   ```
6. **Signed sqrt transform**:
   ```haskell
   signedSqrt :: Float -> Float
   signedSqrt z = signum z * sqrt (abs z)

   inverseSignedSqrt :: Float -> Float
   inverseSignedSqrt x = signum x * x * x
   ```

### Deliverables

| Item | File |
|------|------|
| Noise schedule | `src/Graphics/Haskan/Terrain/ONNX/Schedule.hs` |
| InfiniteDiffusion loop | `src/Graphics/Haskan/Terrain/ONNX/Pipeline.hs` |
| Sparse accumulator | `src/Graphics/Haskan/Terrain/ONNX/Accumulator.hs` |
| Laplacian reconstruction | `src/Graphics/Haskan/Terrain/ONNX/Laplacian.hs` |
| Coarse map generation | `src/Graphics/Haskan/Terrain/ONNX/Coarse.hs` |
| Integration test: generate one tile | `test/TerrainPipelineSpec.hs` |

---

## Phase 4: GPU Memory Pipeline (5-7 days)

### Problem

Transfer ONNX Runtime output tensors to Vulkan textures without going through CPU staging.

### Background

ONNX Runtime with CUDA EP produces output tensors in GPU memory (CUDA). Vulkan textures live in GPU memory (Vulkan). Direct CUDA→Vulkan transfer requires:
- CUDA-Vulkan interop via external memory (`VK_KHR_external_memory`)
- OR: accept the CPU round-trip (CUDA→CPU→Vulkan staging) as acceptable overhead

### Tasks

1. **CPU staging path (initial)**: Copy ONNX output from CUDA to CPU, then upload to Vulkan via staging buffer
   ```haskell
   -- Simple, works everywhere, ~1-2ms for 256×256×2 bytes
   tensorToVulkan :: Tensor Float -> VulkanDevice -> Vulkan.VkImage -> IO ()
   ```
2. **CUDA-Vulkan interop path (optional optimization)**:
   - Export CUDA memory as Vulkan external memory handle
   - `vkImportMemoryFdKHR` with CUDA-allocated memory
   - Requires `VK_KHR_external_memory_fd` and `cudaExternalMemory` APIs
   - Complex but eliminates CPU round-trip
3. **Benchmark both paths**: Measure transfer time for typical tile size (512×512 × float32)
4. **Decide**: If CPU staging < 2ms, keep it simple. If > 5ms, implement interop.

### Deliverables

| Item | File |
|------|------|
| CPU staging upload | `src/Graphics/Haskan/Terrain/ONNX/Upload.hs` |
| Benchmark results | `.opencode/terrain_onnx_specs.md` |
| Optional CUDA-Vulkan interop | `src/Graphics/Haskan/Terrain/ONNX/Interop.hs` |

---

## Phase 5: Integration + Migration from Path A (3-5 days)

### Tasks

1. **Backend abstraction**: Both Path A and Path B should expose the same interface
   ```haskell
   class TerrainBackend b where
     queryTile :: b -> Int -> Int -> Int -> IO TerrainTile
     setSeed   :: b -> Int -> IO ()
     shutdown  :: b -> IO ()

   data SidecarBackend = ...    -- Path A
   data ONNXBackend = ...       -- Path B
   ```
2. **Runtime backend selection**: Config flag or compile-time switch
   ```
   --terrain-backend=sidecar  (default)
   --terrain-backend=onnx
   ```
3. **Reuse Path A rendering**: Phases 4-5 from MILESTONE_TERRAIN_SIDECAPI.md (mesh + texturing) are backend-agnostic. Both paths produce `TerrainTile` with elevation + climate data.
4. **Validation**: Generate same seed with both backends, compare outputs pixel-by-pixel

### Deliverables

| Item | File |
|------|------|
| TerrainBackend typeclass | `src/Graphics/Haskan/Terrain/Backend.hs` |
| CLI flag for backend selection | `src/Graphics/Haskan/Engine.hs` |
| Validation test | `test/TerrainBackendCompareSpec.hs` |

---

## Phase 6: Performance Optimization (3-5 days)

### Tasks

1. **Batched inference**: Run multiple windows through U-Net in one ONNX session call
   - ONNX Runtime supports dynamic batch axis (exported with `dynamic_axes`)
   - Batch size 4-16 depending on GPU VRAM budget
2. **Tile precomputation**: Background thread pre-generates tiles ahead of camera movement
3. **VRAM budget**: ONNX Runtime model weights + CUDA context uses ~2-4GB. Verify coexistence with Vulkan renderer
   ```
   RTX 4090: 24GB VRAM
   Vulkan renderer: ~4-6GB (deferred + clouds + AP volume)
   ONNX Runtime: ~2-4GB (three U-Nets)
   Remaining: ~14-18GB for terrain textures
   ```
4. **Warm-up**: Pre-load ONNX models at startup, run one dummy inference to compile CUDA kernels

### Deliverables

| Item | File |
|------|------|
| Batched inference | `src/Graphics/Haskan/Terrain/ONNX/Runtime.hs` |
| VRAM budget analysis | `.opencode/terrain_onnx_specs.md` |
| Startup warm-up | `src/Graphics/Haskan/Terrain/ONNX/Runtime.hs` |

---

## Summary: Effort & Timeline

| Phase | Task | Est. Days | Risk | Dependencies |
|-------|------|----------|------|-------------|
| 1 | ONNX export + verification | 2-3d | Low | Python + terrain-diffusion |
| 2 | ONNX Runtime FFI | 5-7d | High | Nix onnxruntime, C API FFI |
| 3 | InfiniteDiffusion loop | 7-10d | High | Phase 2, algorithm reimplementation |
| 4 | GPU memory pipeline | 5-7d | Medium | Phase 3, CUDA-Vulkan interop |
| 5 | Integration + migration | 3-5d | Low | Path A phases 4-5 done |
| 6 | Performance optimization | 3-5d | Medium | Phase 5 |
| **Total** | | **~25-37 days** | | |

## Execution Order

```
Week 1-2: Phase 1 + Phase 2 (export + FFI)
  - Export models, write C API bindings, run inference from Haskell

Week 2-4: Phase 3 (InfiniteDiffusion loop)
  - Highest risk: reimplement blending algorithm
  - Start with T=0 (no blending), then T=1, then T=2

Week 4-5: Phase 4 (memory pipeline)
  - CPU staging first, measure, decide on interop

Week 5-6: Phase 5 (integration)
  - Backend abstraction, swap Path A for Path B

Week 6-7: Phase 6 (optimization)
  - Batching, VRAM tuning, warm-up
```

## Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|-----------|
| ONNX Runtime C API instability | High | Pin version in Nix, test thoroughly |
| InfiniteDiffusion loop correctness | High | Compare against Python output pixel-by-pixel |
| CUDA + Vulkan on same GPU | Medium | ONNX Runtime CUDA EP and Vulkan use different contexts; works on NVIDIA but test early |
| VRAM contention (24GB shared) | Medium | Profile VRAM usage; reduce batch size if needed |
| FIR limitations for terrain shaders | Low | Shaders are same as Path A; no new shader complexity |
| Haskell GC pressure from tensor data | Low | Use pinned ForeignPtr, avoid unnecessary copies |

## Decision Criteria (when to start Path B)

Only start this milestone if **any** of:
1. Sidecar HTTP latency > 50ms (unlikely at 660ms TTST)
2. Python process crashes > once per session
3. Single-binary distribution required
4. Need sub-frame tile generation (camera moves faster than HTTP allows)
5. GPU memory sharing between inference and rendering is critical

If Path A works well for 3+ months, de-prioritize this indefinitely.

## Success Criteria

1. No Python process required — pure Haskell + ONNX Runtime binary
2. Tile generation latency ≤ Python sidecar (660ms TTST)
3. Generated terrain matches Python output (max abs diff < 1e-3)
4. VRAM usage within 18GB (leaves 6GB headroom on RTX 4090)
5. No frame drops during terrain generation (background thread)
6. Same rendering quality as Path A (reuse mesh + texturing code)
