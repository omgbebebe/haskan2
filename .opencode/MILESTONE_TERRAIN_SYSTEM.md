# Milestone: Terrain System — Production-Ready Procedural Terrain

## Goal
Replace the flat green ground plane with a production-quality terrain system: multi-tile streaming, GPU heightmap displacement, physics heightfield colliders, climate-driven rendering, and dynamic LOD.

---

## Phase 1: Multi-Tile Streaming & Caching
**Priority: P0 | Est: 1 session**

### 1.1 Dynamic tile fetch
- [ ] Create `Terrain/Streaming.hs` — tile coordinate management
  - Convert camera position (x,z) to tile indices
  - Determine visible tiles within configurable radius (e.g., 3×3 grid around camera)
  - Map tile indices to API bbox: each tile = 256 texels × scale world units
  - Support multiple scales: 1 (256m), 2 (128m), 4 (64m), 8 (32m per texel)
- [ ] TVar-based async fetch
  - `STM.TVar (Map TileId TerrainTile)` for loaded tiles
  - Background thread fetches tiles as camera moves
  - LRU eviction when tile count exceeds budget (e.g., 16 tiles)

### 1.2 Tile coordinate system
- [ ] Define `TileId = (Int, Int, Int)` — (tileX, tileZ, scale)
- [ ] `tileWorldSize = 256 * scale` — each tile covers this many world units
- [ ] `tileAt :: V2 Float -> TileId` — which tile contains a given world position
- [ ] Bilinear interpolation across tile boundaries

### 1.3 Climate texture validation
- [ ] Debug why climate texture appears white
  - Check API response: is climate data actually non-white?
  - Add `saveTerrainDebugImages` function to dump elevation/climate to PNG
  - Verify `VK_FORMAT_R32G32B32A32_SFLOAT` sampling returns expected values
  - Check if elevation data is all zeros → would produce flat green everywhere

---

## Phase 2: GPU Heightmap Displacement
**Priority: P0 | Est: 2-3 sessions**

### 2.1 Vertex shader terrain
- [ ] Create `Shaders/TerrainMesh.hs`
  - Vertex: read height from `elevation` texture, displace Y
  - Uniform: tile offset + world scale
  - Normal reconstruction from heightmap derivatives (central differencing)
- [ ] Generate terrain mesh grid
  - `Mesh.groundPlaneMeshGrid subdivisions size` already exists
  - 256×256 vertices per tile at highest LOD, fewer for distant tiles
  - Vertex format: position (x, z) + UV → height sampled in vertex shader

### 2.2 LOD system
- [ ] Quadtree or chunked LOD
  - Near camera: full 256×256 vertices (scale=8, 32m per texel)
  - Mid distance: 128×128 (scale=4, 64m per texel)
  - Far distance: 64×64 (scale=2, 128m per texel)
  - Horizon: single large tile (scale=1, 256m per texel)
- [ ] LOD transition: morphing or geomorphing to avoid popping
  - Or: simple distance-based fade with overlap
- [ ] Frustum culling for terrain tiles

### 2.3 Multi-tile rendering
- [ ] Render all visible tiles in single pass or per-tile draws
  - Option A: One large mesh with tile atlas (requires texture array or atlas)
  - Option B: Per-tile draw call with different UBO (simpler, fewer texture limits)
- [ ] Texture array for elevation: `VkImageType_2D_ARRAY`, 16 layers
  - Each layer = one tile's elevation texture
  - Vertex shader samples by tile index

---

## Phase 3: Physics Heightfield
**Priority: P1 | Est: 1-2 sessions**

### 3.1 Jolt heightfield shape
- [ ] C wrapper: `JPH_HeightFieldShape_Create` from float height array
- [ ] FFI bindings in `Graphics.Haskan.Physics.Jolt`
- [ ] Create static body with heightfield shape
  - Update body transform as camera moves (infinite terrain trick: body at camera xz, height offset)
  - Or: large fixed body, heightfield regenerated around camera each frame

### 3.2 Heightfield data pipeline
- [ ] Convert `Vector Int16` elevation to `Vector Float` (meters)
  - `heightMeters = fromIntegral elev * elevationScale` (API-dependent scale factor)
- [ ] Pass to physics thread via TVar
  - Physics thread samples height at entity positions for ground clamping

### 3.3 Vehicle physics (future)
- [ ] Jolt vehicle constraint
- [ ] Wheel raycast against heightfield

---

## Phase 4: Climate-Driven Rendering
**Priority: P1 | Est: 1-2 sessions**

### 4.1 Material variation
- [ ] Climate channels:
  - R: temperature → snow/ice vs grass/rock vs sand
  - G: moisture → lush vs dry vs desert
  - B: biome type → forest, tundra, savanna, etc.
  - A: slope roughness → smooth vs rocky
- [ ] Climate → albedo color mapping
  - Cold + moist = dark green forest
  - Hot + dry = sand/rock
  - Cold + dry = snow/ice
  - Temperate + moist = grassland
- [ ] Climate → roughness/metallic
  - Rock = high roughness, low metallic
  - Snow = high roughness, white
  - Wet ground = lower roughness

### 4.2 Procedural detail
- [ ] Normal map from height derivatives (already in vertex shader)
- [ ] Add noise-based micro-detail
  - Rock: high-frequency Worley noise for roughness
  - Grass: subtle color variation
  - Snow: sparkly specular

### 4.3 Water plane
- [ ] Sea level = fixed Y (e.g., 0.0 meters)
- [ ] Areas below sea level = water
  - Separate render pass or discard in terrain shader
  - Water shader: simple transparent blue with specular

---

## Phase 5: Terrain Texture Streaming
**Priority: P2 | Est: 2-3 sessions**

### 5.1 Texture atlas / array
- [ ] `VkImageType_2D_ARRAY` for elevation textures
  - 16-32 layers, dynamic update
  - Update individual layers as tiles stream in
- [ ] Same for climate textures
- [ ] Descriptor set update: only changed layers

### 5.2 Async GPU upload
- [ ] Staging buffer per tile
  - Copy tile data to staging buffer on main thread
  - `vkCmdCopyBufferToImage` in command buffer
  - No CPU→GPU stalls

### 5.3 Mipmaps
- [ ] Generate mipmaps for elevation/climate textures
  - Compute shader or `vkCmdBlitImage` chain
  - LOD transitions use appropriate mip level

---

## Phase 6: Advanced Features
**Priority: P2-P3 | Est: 3-5 sessions**

### 6.1 Erosion & detail
- [ ] Hydraulic erosion simulation (compute shader)
  - Flow map from climate moisture + slope
  - Sediment deposition
  - Thermal erosion (talus angle)
- [ ] Procedural rock scattering
  - Climate + slope → rock density
  - Instanced rendering for rocks/boulders

### 6.2 Vegetation
- [ ] Climate-driven vegetation placement
  - Forest density from moisture + temperature
  - Grass coverage from moisture
  - Tree instancing via compute shader
- [ ] Wind animation for vegetation
  - Vertex shader displacement based on wind direction/speed

### 6.3 Atmospheric integration
- [ ] Aerial perspective for distant terrain
  - Existing AP volume already handles this
  - Ensure terrain shader outputs depth for AP volume sampling
- [ ] Fog in valleys
  - Height-based fog density
  - Climate moisture drives fog amount

### 6.4 Terrain editing (future)
- [ ] Brush-based height editing
  - Modify elevation texture in compute shader
  - Re-upload to GPU
  - Save back to sidecar API

---

## Files to Create/Modify

### New modules
```
src/Graphics/Haskan/Terrain/
  Streaming.hs       — Tile coordinate, fetch, cache management
  LOD.hs             — LOD level selection, mesh generation
  Physics.hs         — Heightfield shape creation, body management
  Climate.hs         — Climate → material mapping functions
  Debug.hs           — Save elevation/climate to PNG for debugging

src/Graphics/Haskan/Vulkan/Shaders/
  TerrainMesh.hs     — Vertex-displaced terrain shader
  Water.hs           — Simple water plane shader
```

### Modified modules
```
src/Graphics/Haskan/Terrain/
  Client.hs          — Add streaming fetch, tile cache
  Texture.hs         — Multi-tile upload, texture array

src/Graphics/Haskan/Vulkan/
  Texture.hs         — 2D array texture creation, layer upload
  DeferredResources.hs — Terrain mesh pipeline, texture array descriptors
  DescriptorSetLayout.hs — Terrain mesh descriptor layout (texture array)
  DescriptorSet.hs — Update texture array layers
  GraphicsPipeline.hs — Terrain mesh graphics pipeline (with vertex input)

src/Graphics/Haskan/Engine/Render/
  Internal/PassRecording.hs — Render terrain mesh tiles
  Internal/Setup.hs — Load terrain mesh shader modules

src/Graphics/Haskan/Physics/Jolt/
  [C wrapper] — HeightFieldShape bindings
  [Haskell] — Heightfield body creation
```

---

## Open Questions

1. **API scale factor**: What is the real-world meters-per-texel for each scale? Need to verify with API documentation.
2. **Climate data range**: What are valid ranges for temperature, moisture, biome values? Currently assuming 0-1 but may be different.
3. **Tile streaming budget**: How many tiles can we keep in GPU memory? 16? 32? Depends on texture size (256² R16 = 128KB, RGBA32F climate = 1MB per tile).
4. **Physics heightfield size**: Jolt heightfields have max size. May need to split into chunks or use infinite terrain trick.
5. **Elevation units**: API returns int16. Is it meters? Decimeters? Need scale factor.

---

## Success Criteria
- [ ] Camera can fly across terrain, tiles stream in seamlessly
- [ ] Terrain shows elevation variation (hills, valleys) not flat plane
- [ ] Physics bodies rest on terrain surface (no floating/sinking)
- [ ] Climate drives visible color variation (green forests, brown deserts, white snow)
- [ ] 60 FPS maintained with 3×3 tile grid at scale=4
- [ ] No validation errors

---

## Related Documents
- `.opencode/MEMORIES.md` — Session history, design decisions
- `.opencode/MILESTONE_TERRAIN_SIDECAPI.md` — Original terrain sidecar API design
- `.opencode/MILESTONE_JOLT_PHYSICS.md` — Physics integration details
- `src/Graphics/Haskan/Terrain/Client.hs` — Current HTTP client
- `src/Graphics/Haskan/Vulkan/Shaders/Deferred/TerrainOverlay.hs` — Current overlay shader
