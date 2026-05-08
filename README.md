# Haskan2

A research Vulkan rendering engine in Haskell. Deferred shading, glTF loading, geometry shaders, texture arrays — with type-safe SPIR-V generation via FIR.

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

# Run with an OBJ model
cabal run haskan2 -- data/models/unit_cube.obj
```

## Controls

| Key | Action |
|-----|--------|
| Mouse move | Rotate camera (orbital) |
| Mouse wheel | Zoom in/out |
| W/A/S/D | Move camera forward/left/back/right |
| F3 | Toggle wireframe overlay |
| F12 | Capture frame inspector snapshot |
| Shift+Q | Quit |

## Features

- **Deferred rendering** — G-buffer (position/normal/albedo) + fullscreen lighting pass
- **glTF 2.0 loading** — Node hierarchy, materials, textures via `gltf-loader`
- **Geometry shader wireframe** — Runtime toggle (F3) over solid geometry
- **Texture arrays** — All scene textures packed into `Texture2DArray`, material index pushed per draw
- **Asset cache** — Preprocessed textures cached under `.haskan2-cache/`
- **Frame inspector** — F12 captures camera, entity NDC vertices, matrices to markdown
- **Debug server** — Unix socket for remote camera/scene inspection (`--debug-socket PATH`)
- **Structured logging** — Multi-backend logging (stdout, stderr, file) via `effectful` effects library with per-backend levels and formatters. Engine uses bridge functions; `Eff` integration deferred for Vulkan layer due to `Managed` incompatibility.

## Architecture

Four-layer design:

```
Layer 4: Scene        -- ECS (World, EntityId, Transform, glTF import)
Layer 3: Render       -- Render graph (builder, compiler, deferred passes)
Layer 2: Resources    -- ResourceManager (MeshHandle, TextureHandle, registry)
Layer 1: GPU Commands -- Vulkan (command buffers, pipelines, synchronization)
```

See [`roadmap/ARCHITECTURE.md`](roadmap/ARCHITECTURE.md) for details.

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

See [`roadmap/`](roadmap/) for full milestone documentation.

## Tech Stack

- **GHC 9.14.1** via Nix flake
- **Vulkan 1.4** via `vulkan-api` Haskell bindings
- **FIR** — Haskell EDSL for SPIR-V shader compilation (patched for `Texture2DArray`)
- **SDL2** — Window, input, event loop
- **linear** — Row-major matrices (transposed for Vulkan column-major)
- **gltf-loader** — Patched fork for glTF JSON/binary parsing
- **effectful** — Extensible effects library used for logging subsystem. Engine core remains `MonadIO`/`Managed` due to CPS-based resource bracket incompatibility.

## Project Structure

```
src/Graphics/Haskan/
├── Engine.hs              -- Main loop, threading, state management
├── Camera.hs              -- Orbital camera with quaternion rotation
├── Input.hs               -- SDL → Action mapping
├── Logger.hs              -- effectful-based multi-backend logging
├── Scene/
│   ├── ECS.hs             -- Entity-component system
│   ├── Transform.hs       -- Local/world matrices
│   └── GLTF.hs            -- glTF import
├── Render/
│   ├── Graph.hs           -- Render graph builder + compiler
│   ├── Deferred.hs        -- G-buffer + lighting pass builder
│   ├── RenderSystem.hs    -- Draw list extraction
│   └── ShaderProgram.hs   -- Multi-stage shader program
├── Vulkan/                -- All Vulkan wrappers
│   ├── Resources.hs       -- ResourceManager with handles
│   ├── Texture.hs         -- Texture loading, arrays
│   ├── Shaders/           -- FIR shader programs
│   └── ...
└── Assets/                -- Asset preprocessor
    ├── Cache.hs
    └── TexturePreprocessor.hs
```

## License

MIT

### Dependency License Summary

All direct and transitive dependencies use permissive licenses compatible with MIT:

| Package | License | Compatible |
|---------|---------|------------|
| `base`, `containers`, `stm`, `text`, `vector`, `bytestring`, `directory`, `filepath`, `mtl`, `unordered-containers`, `contravariant`, `scientific` | BSD-3-Clause | Yes |
| `lens` | BSD-2-Clause | Yes |
| `linear` | BSD-3-Clause | Yes |
| `vulkan-api` | BSD-3-Clause | Yes |
| `sdl2` (Haskell bindings) | BSD-3-Clause | Yes |
| `SDL2` (C library) | zlib | Yes |
| `JuicyPixels` | BSD-3-Clause | Yes |
| `megaparsec` | BSD-2-Clause | Yes |
| `aeson` | BSD-3-Clause | Yes |
| `optparse-applicative` | BSD-3-Clause | Yes |
| `fast-logger` | BSD-3-Clause | Yes |
| `network` | BSD-3-Clause | Yes |
| `clock` | BSD-3-Clause | Yes |
| `managed` | BSD-3-Clause | Yes |
| `effectful` | BSD-3-Clause | Yes |
| `tasty`, `tasty-hunit` | MIT | Yes |
| `fir` (submodule) | BSD-3-Clause | Yes |
| `gltf-loader` (patched fork) | MIT | Yes |
| `gltf-codec` | BSD-3-Clause | Yes |

**Test assets** (`glTF-Sample-Assets/`) carry their own per-model licenses (CC-BY-4.0, CC0, Apache-2.0, etc.) and are not linked into the executable.
