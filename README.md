# Haskan2

A research Vulkan rendering engine in Haskell. Deferred PBR shading, volumetric clouds, day/night cycle, glTF loading — with type-safe SPIR-V generation via FIR.

## Quick Start

```bash
# Enter development shell (GHC 9.14.1, Vulkan, SDL2)
nix develop

# Build everything
cabal build all

# Run with a glTF model
cabal run haskan2 -- glTF-Sample-Assets/Models/Avocado/glTF/Avocado.gltf

# Run with timeout (auto-exit after N seconds)
cabal run haskan2 -- -t 10 glTF-Sample-Assets/Models/Avocado/glTF/Avocado.gltf

# Run with log file
cabal run haskan2 -- --log-file /tmp/haskan.log -t 5 MODEL

# Day/night cycle
cabal run haskan2 -- --day-night --time 14.0 --time-speed 0.5 MODEL
```

## Controls

| Key | Action |
|-----|--------|
| Mouse drag | Rotate camera (orbital) |
| Mouse wheel | Zoom in/out |
| W/A/S/D | Move camera forward/left/back/right |
| F3 | Toggle wireframe overlay |
| G / Shift+G | Toggle axis arrows / ground plane |
| Shift+1..5 | Cloud genus presets (cumulus, stratus, etc.) |
| Shift+F1/F2/F3 | Cloud debug modes (density / height / raw noise) |
| F12 | Capture frame inspector snapshot |
| Shift+Q | Quit |

## Features

### Rendering
- **Deferred PBR** — G-buffer (position/metallic, normal/roughness, albedo/ao) + fullscreen lighting pass
- **IBL** — Split-sum specular with BRDF LUT, irradiance map, dynamic cubemap rotation
- **Normal mapping** — TBN tangent space, bindless texture array sampling
- **Multi-light** — Up to 8 directional lights with full PBR per light

### Atmosphere & Sky
- **Skybox** — HDR cubemap sampling in lighting shader via per-vertex frustum rays
- **Day/night cycle** — Continuous sun trajectory, sky tint, IBL intensity modulation
- **Volumetric clouds** — Ray-marched procedural clouds with:
  - Dynamic adaptive step count (8-32 steps)
  - Nested 4-step light march with Beer-Powder transmittance
  - Dual-lobe Henyey-Greenstein phase function
  - 2-octave domain warping
  - Wind-aware temporal reprojection
  - Blue noise dithering
  - 5 cloud genus presets
  - Half-resolution rendering with bilinear upsample

### Engine
- **glTF 2.0 loading** — Node hierarchy, PBR materials, textures
- **ECS** — Entity-component system with transform hierarchy
- **Dear ImGui** — In-game debug overlay with cloud parameter sliders
- **Frame inspector** — Camera, entity NDC, matrices to markdown
- **Debug server** — Unix socket for remote inspection (`--debug-socket PATH`)
- **Structured logging** — Multi-backend (stdout, stderr, file), per-backend levels

### Shader Pipeline (FIR)
- **Type-safe SPIR-V** — FIR EDSL catches binding errors, type mismatches at compile time
- **spirv-opt** — Integrated optimization (596× size reduction on complex shaders)
- **Extended math** — 20+ vector/matrix operations: sinV, cosV, mixV, clampV, reflectV, outerProduct, etc.
- **Loop support** — Fixed CFG codegen for while loops with phi nodes

## Architecture

Four-layer design:

```
Layer 4: Scene        -- ECS (World, EntityId, Transform, glTF import)
Layer 3: Render       -- Render graph (builder, compiler, deferred passes)
Layer 2: Resources    -- ResourceManager (MeshHandle, TextureHandle, registry)
Layer 1: GPU Commands -- Vulkan (command buffers, pipelines, synchronization)
```

Threading model: input loop → state update → render loop, all via STM TVars.

## Milestones

| # | Milestone | Status |
|---|-----------|--------|
| 1 | Resource Manager | Done |
| 2 | ECS Foundation | Done |
| 3 | Render Graph | Done |
| 4 | Deferred Rendering | Done |
| 5 | glTF Loading | Done |
| 6 | Advanced Shaders (geometry) | Done |
| 7 | Bindless Rendering | Partial (Texture2DArray + push constants) |
| 8 | GPU-Driven Rendering | Not started |
| 9 | PBR + IBL | Done |
| 10 | Multi-light + Sky + Day/Night + Clouds | Done |

## Tech Stack

| Component | Technology |
|-----------|-----------|
| Language | GHC 9.14.1 via Nix |
| Graphics | Vulkan 1.4 via `vulkan-api` |
| Shaders | FIR (Haskell EDSL → SPIR-V) |
| Window/Input | SDL2 |
| Math | `linear` (row-major, transposed for Vulkan column-major) |
| Assets | `gltf-loader` (patched fork) |
| UI | `dear-imgui` 2.4 (SDL + Vulkan backend) |
| Effects | `effectful` (logging subsystem) |

## Project Structure

```
src/Graphics/Haskan/
├── Engine.hs              -- Main loop, threading, state management
├── Camera.hs              -- Orbital camera with quaternion rotation
├── Input.hs               -- SDL → Action mapping
├── DayNight.hs            -- Sun trajectory, sky color computation
├── Logger.hs              -- Multi-backend structured logging
├── UI/
│   └── Backend.hs         -- Dear ImGui Vulkan backend integration
├── Scene/
│   ├── ECS.hs             -- Entity-component system
│   ├── Transform.hs       -- Local/world matrices
│   └── GLTF.hs            -- glTF import
├── Render/
│   ├── Graph.hs           -- Render graph builder + compiler
│   ├── Deferred.hs        -- G-buffer + lighting + cloud pass builder
│   └── RenderSystem.hs    -- Draw list extraction
├── Vulkan/
│   ├── Resources.hs       -- ResourceManager with handles
│   ├── Texture.hs         -- Texture loading, arrays
│   ├── Shaders/           -- FIR shader programs
│   │   └── Deferred/
│   │       ├── GBuffer.hs    -- G-buffer vertex/fragment
│   │       ├── Lighting.hs   -- PBR lighting + skybox + overlays
│   │       └── Clouds.hs     -- Volumetric cloud raymarching
│   └── ...
└── Assets/
    ├── Cache.hs
    └── TexturePreprocessor.hs
```

## License

MIT

### Dependency License Summary

All direct and transitive dependencies use permissive licenses compatible with MIT:

| Package | License |
|---------|---------|
| `base`, `containers`, `stm`, `text`, `vector`, `bytestring`, `mtl` | BSD-3-Clause |
| `lens` | BSD-2-Clause |
| `linear` | BSD-3-Clause |
| `vulkan-api`, `vulkan` | BSD-3-Clause |
| `sdl2` | BSD-3-Clause |
| `SDL2` (C library) | zlib |
| `JuicyPixels` | BSD-3-Clause |
| `dear-imgui` | BSD-3-Clause |
| `effectful` | BSD-3-Clause |
| `managed` | BSD-3-Clause |
| `optparse-applicative` | BSD-3-Clause |
| `fir` (submodule) | BSD-3-Clause |
| `gltf-loader` (patched fork) | MIT |
