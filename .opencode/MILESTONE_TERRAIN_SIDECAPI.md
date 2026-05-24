# Terrain Diffusion — Sidecar API Integration

**Status**: Not started
**Priority**: P2 — feature milestone, no blockers
**Estimate**: 4-5 weeks
**Depends on**: terrain-diffusion Python package + pre-trained model weights
**Reference**: `.opencode/terrain_diffusion/` (design docs), `https://github.com/xandergos/terrain-diffusion`

---

## Overview

Integrate InfiniteDiffusion terrain generation into Haskan2 via a Python sidecar process. The terrain-diffusion package provides a Flask REST API (`GET /terrain`) that returns `int16` elevation + `float32` climate data for arbitrary bounding boxes. Haskan2 queries this API from Haskell, uploads heightmap tiles to Vulkan textures via staging buffers, and renders terrain with biome-aware procedural texturing.

### Data Flow

```
┌──────────────────────┐         HTTP GET /terrain          ┌─────────────────────────────┐
│  terrain-diffusion   │ ────── int16 elevation ──────────→ │  Haskan2 Render Engine      │
│  Python sidecar      │ ────── float32 climate (4ch) ────→ │  ┌─────────────────────────┐│
│  (Flask, CUDA)       │                                    │  │ Terrain Tile Cache (LRU) ││
│  xandergos/30m       │                                    │  └──────────┬──────────────┘│
└──────────────────────┘                                    │             │               │
                                                            │  ┌──────────▼──────────────┐│
                                                            │  │ Heightmap → Mesh        ││
                                                            │  │ (clipmap or tess shader)││
                                                            │  └──────────┬──────────────┘│
                                                            │             │               │
                                                            │  ┌──────────▼──────────────┐│
                                                            │  │ Biome Texturing (frag)  ││
                                                            │  │ slope + height + climate ││
                                                            │  └─────────────────────────┘│
                                                            └─────────────────────────────┘
```

### API Contract (from terrain-diffusion)

```
GET /terrain?i1=0&j1=0&i2=256&j2=256&scale=1

Response body (binary):
  - Elevation: int16 LE, shape (H, W), values in meters [-32768, 32767]
  - Climate: float32 LE, shape (H, W, 4), channels [temp, t_season, precip, p_cv]

Response headers:
  - X-Height: output height in pixels
  - X-Width: output width in pixels
```

### Model Options

| Model | Resolution | Coarse pixel | Use case |
|-------|-----------|-------------|----------|
| `xandergos/terrain-diffusion-30m` | 30 m/px | 7.7 km | Playable worlds, finer detail |
| `xandergos/terrain-diffusion-90m` | 90 m/px | 23 km | Realistic worldbuilding |

Recommend starting with **30m** for closer camera distances in Haskan2.

---

## Phase 1: Sidecar Process Management (3-4 days)

### Problem

Haskan2 needs to launch, monitor, and communicate with the Python terrain-diffusion API server as a managed subprocess.

### Tasks

1. **Nix integration**: Add Python + terrain-diffusion to `flake.nix` as a devShell package or separate derivation
   - `python3.withPackages (ps: [ ps.torch ps.flask ps.diffusers ... terrain-diffusion ])`
   - Alternatively: just require `pip install -r requirements.txt` and `python -m terrain_diffusion api` documented in README
2. **Haskell sidecar module**: `Graphics.Haskan.Terrain.Sidecar`
   ```haskell
   data TerrainSidecar = TerrainSidecar
     { scProcess    :: !ProcessHandle
     , scPort       :: !Int
     , scManager    :: !Manager        -- http-client Manager
     , scBaseURL    :: !String         -- "http://127.0.0.1:<port>"
     , scSeed       :: !(TVar (Maybe Int))
     , scReady      :: !(TVar Bool)
     }

   startSidecar :: Int -> Maybe Int -> IO TerrainSidecar
   -- ^ Launch python -m terrain_diffusion.api --port <port> --seed <seed>

   stopSidecar :: TerrainSidecar -> IO ()
   -- ^ Graceful shutdown, SIGTERM, wait

   isReady :: TerrainSidecar -> IO Bool
   -- ^ Poll GET /seed to check server is up
   ```
3. **Health check**: On startup, poll `GET /seed` with exponential backoff (max 30s)
4. **Error handling**: If sidecar dies, log error and optionally restart
5. **Seed management**: `POST /seed` to change world seed at runtime

### Dependencies

- `http-client`, `http-client-tls` (Hackage)
- `process` (base) for subprocess management
- `aeson` for JSON parsing
- `bytestring` for binary response parsing

### Deliverables

| Item | File |
|------|------|
| Sidecar lifecycle module | `src/Graphics/Haskan/Terrain/Sidecar.hs` |
| Nix python env (or doc) | `flake.nix` or README section |
| Seed query/set functions | `src/Graphics/Haskan/Terrain/Sidecar.hs` |

---

## Phase 2: Terrain Data Client (3-4 days)

### Problem

Query the API for elevation + climate data, parse binary response into Haskell types.

### Tasks

1. **Terrain client module**: `Graphics.Haskan.Terrain.Client`
   ```haskell
   data TerrainTile = TerrainTile
     { ttWidth     :: !Int
     , ttHeight    :: !Int
     , ttElevation :: !(Vector Int16)      -- row-major, meters
     , ttClimate   :: !(Vector Float)      -- (H,W,4), interleaved [temp,t_season,precip,p_cv]
     }

   queryTerrain :: TerrainSidecar -> Int -> Int -> Int -> Int -> Int -> IO (Either TerrainError TerrainTile)
   -- ^ queryTerrain sc i1 j1 i2 j2 scale
   ```
2. **Binary parsing**: Split response body at `H*W*2` bytes (elevation) / rest (climate)
   ```haskell
   parseTerrainResponse :: Int -> Int -> ByteString -> Either String TerrainTile
   parseTerrainResponse h w bs =
     let elevBytes = B.take (h * w * 2) bs
         climBytes = B.drop (h * w * 2) bs
         elevation = V.unsafeCast (V.pack (B.unpack elevBytes) :: Vector Word16) -- FIXME: proper LE int16
         climate = V.unsafeCast (V.pack (B.unpack climBytes) :: Vector Word8)     -- FIXME: proper LE float32
     in Right (TerrainTile w h elevation climate)
   ```
   Use `Data.ByteString.Lex.Int16` or manual `decodeInt16LE` loop. For float32: `Data.ByteString.Builder.Prim.floatLE` inverse, or `vec` package.
3. **Async tile requests**: Use `async` to prefetch neighboring tiles while camera moves
4. **Tile coordinate system**: Map Haskan2 world coordinates to terrain-diffusion tile grid indices
   - Scale parameter: `scale=4` gives 7.5m/px (30m / 4), sufficient for close-up terrain

### Deliverables

| Item | File |
|------|------|
| Terrain client with binary parsing | `src/Graphics/Haskan/Terrain/Client.hs` |
| Tile coordinate mapping | `src/Graphics/Haskan/Terrain/Client.hs` |
| Error types | `src/Graphics/Haskan/Terrain/Types.hs` |

---

## Phase 3: Terrain Tile Cache + Vulkan Upload (5-6 days)

### Problem

Cache fetched tiles in an LRU, upload elevation data to Vulkan textures for rendering.

### Tasks

1. **Tile cache**: `Graphics.Haskan.Terrain.Cache`
   ```haskell
   data TerrainCache = TerrainCache
     { tcTiles   :: !(TVar (Map (Int,Int) TerrainTile))
     , tcLRU     :: !(TVar [(Int,Int)])       -- eviction order
     , tcMaxSize :: !Int                       -- max cached tiles (default 64)
     , tcSidecar :: !TerrainSidecar
     }

   getOrFetchTile :: TerrainCache -> Int -> Int -> IO TerrainTile
   -- ^ Cache miss triggers async API query
   ```
2. **Vulkan heightmap texture**: Upload `int16` elevation to `R16_SINT` or `R16_UNORM` texture
   - Create staging buffer, `vkCmdCopyBufferToImage`
   - Elevation range: normalize to [0,1] for UNORM or keep raw meters for SINT
3. **Vulkan climate texture**: Upload 4-channel float32 to `RGBA32_SFLOAT` texture
   - One climate texture per tile (256×256×4×4 = 1MB per tile)
4. **Terrain resources in DeferredResources**:
   ```haskell
   , drTerrainHeightmaps   :: !(Map (Int,Int) (Vulkan.VkImage, Vulkan.VkImageView))
   , drTerrainClimateMaps  :: !(Map (Int,Int) (Vulkan.VkImage, Vulkan.VkImageView))
   , drTerrainActiveTile   :: !(TVar (Int,Int))  -- current camera tile
   ```
5. **Background tile fetcher thread**: ForkIO thread that:
   - Reads camera position from GameState TVar
   - Determines which tiles are visible (9-tile grid around camera)
   - Fetches missing tiles via cache
   - Uploads to Vulkan via staging buffer on main thread (Vulkan is single-threaded for queue submits)

### Deliverables

| Item | File |
|------|------|
| LRU tile cache | `src/Graphics/Haskan/Terrain/Cache.hs` |
| Vulkan texture upload for heightmap | `src/Graphics/Haskan/Terrain/Upload.hs` |
| Vulkan texture upload for climate | `src/Graphics/Haskan/Terrain/Upload.hs` |
| Background fetcher thread | `src/Graphics/Haskan/Engine/Terrain.hs` |
| DeferredResources extensions | `src/Graphics/Haskan/Vulkan/DeferredResources.hs` |

---

## Phase 4: Terrain Mesh Generation (5-7 days)

### Problem

Convert heightmap data into renderable geometry. Two approaches: tessellated plane mesh or clipmap.

### Approach A: Tessellated Grid Mesh (simpler, start here)

1. **Pre-allocated grid mesh**: NxN vertex buffer, updated from heightmap each frame
   - Vertex format: pos (V3 Float), uv (V2 Float), normal (V3 Float)
   - Index buffer: triangle strip or indexed triangles
2. **Compute shader displacement**: Vertex positions computed from heightmap texture sample
   - Avoids CPU-side vertex buffer updates
   - Vertex shader samples heightmap texture at grid position
3. **Normal computation**: Central differences from heightmap in compute shader or vertex shader
   ```glsl
   float hL = texture(heightmap, uv + vec2(-texelSize.x, 0)).r;
   float hR = texture(heightmap, uv + vec2( texelSize.x, 0)).r;
   float hD = texture(heightmap, uv + vec2(0, -texelSize.y)).r;
   float hU = texture(heightmap, uv + vec2(0,  texelSize.y)).r;
   vec3 normal = normalize(vec3(hL - hR, 2.0 * texelSize.x * worldScale, hD - hU));
   ```

### Approach B: GPU Clipmap (future optimization, not in this milestone)

Geometric clipmap (Losasso & Hoppe 2004) with nested grids at decreasing resolution. Requires more infrastructure but scales to infinite terrain without tile stitching artifacts.

### Tasks

1. **Terrain mesh module**: `Graphics.Haskan.Terrain.Mesh`
   ```haskell
   data TerrainMesh = TerrainMesh
     { tmVertexBuffer  :: !Vulkan.VkBuffer
     , tmIndexBuffer   :: !Vulkan.VkBuffer
     , tmVertexCount   :: !Int
     , tmIndexCount    :: !Int
     , tmExtent        :: !(V2 Int)  -- grid resolution
     }

   createTerrainGrid :: Int -> Int -> VulkanDevice -> IO TerrainMesh
   -- ^ createTerrainGrid width height = NxN grid mesh in XZ plane
   ```
2. **Heightmap displacement shader**: New FIR vertex shader that samples heightmap texture
3. **Normal generation**: Compute normals from heightmap gradient in vertex or geometry shader
4. **Terrain entity in ECS**: Register terrain mesh as a special entity with associated tile coords

### Deliverables

| Item | File |
|------|------|
| Terrain grid mesh creation | `src/Graphics/Haskan/Terrain/Mesh.hs` |
| Heightmap displacement vertex shader | `src/Graphics/Haskan/Vulkan/Shaders/Terrain/Displace.hs` |
| Normal computation | Same shader or compute pass |
| ECS terrain entity | `src/Graphics/Haskan/Scene/ECS.hs` extension |

---

## Phase 5: Biome-Aware Procedural Texturing (5-7 days)

### Problem

Texture terrain using elevation, slope, and climate data. No pre-baked textures — pure procedural.

### Tasks

1. **Terrain fragment shader**: `Graphics.Haskan.Vulkan.Shaders.Terrain.TerrainTexturing`
   - Inputs from vertex shader: world_pos, normal, elevation, climate (from texture)
   - Slope computation: `slope = 1.0 - normal.y`
   - Biome classification from climate (temp, precip)
2. **Material blending**: Height+slope driven material weights
   ```
   grass  = (1 - slope) * vegetation_density * (1 - snow_mask)
   rock   = slope * (1 - snow_mask)
   snow   = smoothstep(snow_line - 200, snow_line + 200, elevation)
   sand   = aridity * (1 - vegetation_density) * (1 - snow_mask)
   ```
3. **Triplanar sampling**: For cliff faces, sample noise/procedural texture from 3 planes
   - Use existing cloud noise infrastructure as noise source
   - Or: simple fBm computed in-shader (reuse hash functions from `CloudNoiseGen.hs`)
4. **Detail normal perturbation**: fBm-based micro-detail at sub-pixel scale
   - Parameters vary by biome (mountain: high amplitude, plains: low)
5. **PBR integration**: Output albedo, normal, roughness, metallic, AO to g-buffer
   - Grass: green albedo, rough=0.9, metallic=0.0
   - Rock: grey albedo, rough=0.85, metallic=0.0
   - Snow: white albedo, rough=0.6, metallic=0.0
   - Sand: tan albedo, rough=0.95, metallic=0.0

### Deliverables

| Item | File |
|------|------|
| Terrain texturing fragment shader | `src/Graphics/Haskan/Vulkan/Shaders/Terrain/TerrainTexturing.hs` |
| Biome classification functions | Same file or `Shaders/Terrain/Biome.hs` |
| PBR material output | Same shader |
| G-buffer integration | PassRecording.hs, DeferredResources.hs |

---

## Phase 6: Camera-Driven Tile Streaming (3-4 days)

### Problem

As camera moves across the world, stream new terrain tiles and evict old ones seamlessly.

### Tasks

1. **Tile visibility calculation**: From camera position + frustum, determine which tiles are visible
2. **Prefetch ring**: Fetch tiles in expanding ring around camera (1-ring first, then 2-ring)
3. **Tile stitching**: Handle seams between adjacent tiles — overlap by 1 vertex and interpolate
4. **LOD**: Use `scale` parameter for distance-based resolution
   - Close tiles: `scale=4` (7.5m/px)
   - Mid tiles: `scale=2` (15m/px)
   - Far tiles: `scale=1` (30m/px)
5. **Seamless transitions**: Crossfade between LOD levels during tile swaps

### Deliverables

| Item | File |
|------|------|
| Camera-to-tile mapping | `src/Graphics/Haskan/Terrain/Streaming.hs` |
| Prefetch ring logic | Same file |
| LOD system | Same file + `Client.hs` scale parameter |
| Tile stitching | `Mesh.hs` overlap logic |

---

## Phase 7: ImGui Terrain Panel (2-3 days)

### Problem

Debug/control panel for terrain system.

### Tasks

1. **Terrain panel in ImGui**:
   - Current seed display + change seed input
   - Camera world position → tile coordinate display
   - Cached tile count + LRU stats
   - Sidecar status (running/stopped/restarting)
   - Force-refresh current tile button
   - Terrain wireframe toggle
   - Biome debug overlay (color by biome type)
   - Height range display (min/max elevation in current view)
2. **Terrain debug modes**: Shader uniform to select debug visualization
   - 0: Normal rendering
   - 1: Elevation heatmap (blue=low, red=high)
   - 2: Slope map
   - 3: Biome classification (grass=green, rock=grey, snow=white, sand=yellow)
   - 4: Climate temperature channel
   - 5: Climate precipitation channel

### Deliverables

| Item | File |
|------|------|
| Terrain ImGui panel | `src/Graphics/Haskan/UI/TerrainPanel.hs` |
| Debug mode shader uniform | `TerrainTexturing.hs` |
| Debug visualizations | Same shader, conditional branches |

---

## Summary: Effort & Timeline

| Phase | Task | Est. Days | Risk | Dependencies |
|-------|------|----------|------|-------------|
| 1 | Sidecar process management | 3-4d | Low | Python + terrain-diffusion pip install |
| 2 | Terrain data client | 3-4d | Low | Phase 1 |
| 3 | Tile cache + Vulkan upload | 5-6d | Medium | Phase 2, Vulkan staging buffers |
| 4 | Terrain mesh generation | 5-7d | Medium | Phase 3, FIR vertex shader |
| 5 | Biome-aware texturing | 5-7d | Medium | Phase 4, FIR fragment shader |
| 6 | Camera-driven streaming | 3-4d | Medium | Phase 3+4 |
| 7 | ImGui terrain panel | 2-3d | Low | Phase 5+6, dear-imgui |
| **Total** | | **~26-35 days** | | |

## Execution Order

```
Week 1: Phase 1 + Phase 2 (sidecar + client)
  - Get Python API running, query from Haskell, parse binary

Week 2-3: Phase 3 (cache + Vulkan upload)
  - LRU cache, staging buffer upload, background fetcher

Week 3-4: Phase 4 (mesh generation)
  - Grid mesh, heightmap displacement shader, normals

Week 4-5: Phase 5 (texturing)
  - Biome shader, PBR output, triplanar noise

Week 5: Phase 6 (streaming)
  - Camera-driven LOD, prefetch ring

Week 5-6: Phase 7 (ImGui)
  - Debug panel, visualization modes
```

## Open Questions

- Tile size: 256×256 at scale=4 (7.5m/px) means ~1.9km × 1.9km per tile. Is this good for Haskan2 camera distances?
- Memory budget: 64 cached tiles × (256² × 2 bytes elevation + 256² × 16 bytes climate) ≈ 72MB CPU + 72MB GPU VRAM. Acceptable?
- Terrain Y-scale: elevation in meters, but Haskan2 world units? Need a configurable vertical scale factor.
- Water: terrain-diffusion drops water tiles below sea level (`--drop-water-pct`). Do we render water separately?

## Success Criteria

1. Python sidecar launches and responds within 10 seconds
2. Terrain tiles fetched and displayed within TTST + upload time (< 1s per tile)
3. Smooth camera movement across tile boundaries (no visible seams)
4. Biome-aware texturing: grass on flats, rock on slopes, snow at altitude, sand in arid regions
5. PBR deferred rendering works with terrain geometry (shadows, lighting, reflections)
6. Terrain debug panel functional in ImGui
7. No frame drops when tiles are being fetched in background
8. `spirv-val` passes on all terrain shaders
