#!/usr/bin/env python3
"""Generate 3D cloud noise texture for Vulkan.

Usage:
    nix develop -c python scripts/generate_cloud_noise.py

Outputs:
    data/textures/cloud_noise/cloud_noise_128.raw — raw RGBA8 (128³)
    data/textures/cloud_noise/cloud_noise.ktx2 — KTX2 3D texture
    data/textures/cloud_noise/slices/ — PNG slices for inspection

Channel layout (production standard):
    R: Perlin-Worley blend (4 octaves Perlin + 4³ Worley) — macro cloud shape
    G: Worley 8³  — medium-frequency edge erosion
    B: Worley 16³ — high-frequency wispy detail
    A: Worley 32³ — ultra-high-frequency micro-detail

All noise is tileable (toroidal distance wrapping).

Shader usage:
    shape   = texture.r
    detail  = texture.g * 0.5 + texture.b * 0.25 + texture.a * 0.125
    density = max(0, shape - detail * erosion - threshold)
"""

import os
import struct
import time
import numpy as np
from PIL import Image
from scipy.ndimage import zoom

SIZE = 128
CHANNELS = 4

np.random.seed(42)


def generate_worley_3d_tileable(size, cells_per_axis):
    """Generate tileable 3D Worley (cellular) noise.

    One random feature point per cell, arranged in a cells_per_axis³ grid.
    Distance computed with toroidal wrapping for seamless tiling.

    Uses O(27 × N³) neighbor lookup instead of O(cells³ × N³) brute force.
    Runs in constant time regardless of cell count.

    Returns inverted distance: 1.0 at cell centers, 0.0 at boundaries.
    """
    num_points = cells_per_axis ** 3
    t0 = time.perf_counter()
    print(f"  Worley {cells_per_axis}³ ({num_points} cells)...", end="", flush=True)

    cell_size = 1.0 / cells_per_axis

    # One random point per cell, stored as 3D grid for direct lookup
    point_grid = np.random.rand(cells_per_axis, cells_per_axis, cells_per_axis, 3).astype(np.float32)
    # Convert jittered offsets to world-space positions
    for cx in range(cells_per_axis):
        for cy in range(cells_per_axis):
            for cz in range(cells_per_axis):
                point_grid[cx, cy, cz, 0] = (cx + point_grid[cx, cy, cz, 0]) * cell_size
                point_grid[cx, cy, cz, 1] = (cy + point_grid[cx, cy, cz, 1]) * cell_size
                point_grid[cx, cy, cz, 2] = (cz + point_grid[cx, cy, cz, 2]) * cell_size

    # Voxel coordinates
    x = np.linspace(0, 1, size, endpoint=False)
    y = np.linspace(0, 1, size, endpoint=False)
    z = np.linspace(0, 1, size, endpoint=False)
    xx, yy, zz = np.meshgrid(x, y, z, indexing='ij')

    # Which cell does each voxel belong to?
    cell_x = np.floor(xx * cells_per_axis).astype(int) % cells_per_axis
    cell_y = np.floor(yy * cells_per_axis).astype(int) % cells_per_axis
    cell_z = np.floor(zz * cells_per_axis).astype(int) % cells_per_axis

    min_dist = np.ones((size, size, size), dtype=np.float32) * 2.0

    # Only check 3×3×3 = 27 neighbor cells
    for di in range(-1, 2):
        for dj in range(-1, 2):
            for dk in range(-1, 2):
                ni = (cell_x + di) % cells_per_axis
                nj = (cell_y + dj) % cells_per_axis
                nk = (cell_z + dk) % cells_per_axis

                px = point_grid[ni, nj, nk, 0]
                py = point_grid[ni, nj, nk, 1]
                pz = point_grid[ni, nj, nk, 2]

                dx = np.minimum(np.abs(xx - px), 1.0 - np.abs(xx - px))
                dy = np.minimum(np.abs(yy - py), 1.0 - np.abs(yy - py))
                dz = np.minimum(np.abs(zz - pz), 1.0 - np.abs(zz - pz))
                dist = np.sqrt(dx * dx + dy * dy + dz * dz)
                min_dist = np.minimum(min_dist, dist)

    min_dist = min_dist / min_dist.max()
    elapsed = time.perf_counter() - t0
    print(f" {elapsed:.2f}s")
    return 1.0 - min_dist


def generate_perlin_3d_tileable(size, octaves=4):
    """Generate tileable 3D Perlin-like noise using numpy interpolation."""
    t0 = time.perf_counter()
    print(f"  Perlin fBm ({octaves} octaves)...", end="", flush=True)

    result = np.zeros((size, size, size), dtype=np.float32)
    amplitude = 1.0
    frequency = 1.0

    for _ in range(octaves):
        grid_size = max(2, int(frequency))
        grid = np.random.randn(grid_size, grid_size, grid_size).astype(np.float32)

        # Tile the grid for periodicity
        tiled_grid = np.tile(grid, (2, 2, 2))

        zoom_factor = (size * 2) / (grid_size * 2)
        interp = zoom(tiled_grid, zoom_factor, order=1)

        start = size // 2
        interp = interp[start:start+size, start:start+size, start:start+size]

        if interp.shape[0] > size:
            interp = interp[:size, :size, :size]
        elif interp.shape[0] < size:
            pad = size - interp.shape[0]
            interp = np.pad(interp, ((0, pad), (0, pad), (0, pad)), mode='wrap')

        result += interp * amplitude
        amplitude *= 0.5
        frequency *= 2

    result = (result - result.min()) / (result.max() - result.min() + 1e-8)
    elapsed = time.perf_counter() - t0
    print(f" {elapsed:.2f}s")
    return result


def save_slices(data, output_dir):
    """Save Z-slices as PNG for visual inspection."""
    os.makedirs(output_dir, exist_ok=True)
    size = data.shape[0]

    z_mid = size // 2
    for ch, name in enumerate(["R_perlin-worley", "G_worley8", "B_worley16", "A_worley32"]):
        slice_data = (data[:, :, z_mid, ch] * 255).clip(0, 255).astype(np.uint8)
        img = Image.fromarray(slice_data, mode='L')
        img.save(os.path.join(output_dir, f"mid_{name}.png"))

    for z in range(size):
        slice_data = (data[:, :, z, 0] * 255).clip(0, 255).astype(np.uint8)
        img = Image.fromarray(slice_data, mode='L')
        img.save(os.path.join(output_dir, f"slice_{z:03d}.png"))

    print(f"  Saved {size + 4} images to {output_dir}")


def save_raw_binary(data, filepath):
    """Save as raw binary (RGBA8, size³)."""
    data_uint8 = (data * 255).clip(0, 255).astype(np.uint8)
    data_bytes = data_uint8.tobytes()
    with open(filepath, 'wb') as f:
        f.write(data_bytes)
    print(f"  Saved raw: {filepath} ({len(data_bytes)} bytes)")


def save_ktx2(data, filepath):
    """Save as KTX2 (VK_FORMAT_R8G8B8A8_UNORM)."""
    print(f"  Saving KTX2: {filepath}")

    size = data.shape[0]
    data_uint8 = (data * 255).clip(0, 255).astype(np.uint8)
    pixel_data = data_uint8.tobytes()

    identifier = b'\xabKTX 20\xbb\r\n\x1a\n'

    with open(filepath, 'wb') as f:
        f.write(identifier)
        f.write(struct.pack('<I', 37))       # vkFormat
        f.write(struct.pack('<I', 1))        # typeSize
        f.write(struct.pack('<I', size))     # pixelWidth
        f.write(struct.pack('<I', size))     # pixelHeight
        f.write(struct.pack('<I', size))     # pixelDepth
        f.write(struct.pack('<I', 0))        # layerCount
        f.write(struct.pack('<I', 1))        # faceCount
        f.write(struct.pack('<I', 1))        # levelCount
        f.write(struct.pack('<I', 0))        # supercompressionScheme
        f.write(struct.pack('<I', 0))        # dfdByteOffset
        f.write(struct.pack('<I', 0))        # dfdByteLength
        f.write(struct.pack('<I', 0))        # kvdByteOffset
        f.write(struct.pack('<I', 0))        # kvdByteLength
        f.write(struct.pack('<Q', 0))        # sgdByteOffset
        f.write(struct.pack('<Q', 0))        # sgdByteLength
        # Level index
        f.write(struct.pack('<Q', 104))
        f.write(struct.pack('<Q', len(pixel_data)))
        f.write(struct.pack('<Q', len(pixel_data)))
        f.write(pixel_data)

    print(f"  Saved KTX2: {filepath} ({os.path.getsize(filepath)} bytes)")


def main():
    t_start = time.perf_counter()
    print(f"Generating tileable 3D cloud noise ({SIZE}³)...")

    # R: Perlin base blended with low-freq Worley — macro cloud shape
    perlin = generate_perlin_3d_tileable(SIZE, octaves=4)
    worley_low = generate_worley_3d_tileable(SIZE, cells_per_axis=4)

    # G: Worley 8³ — medium-frequency edge erosion
    worley_mid = generate_worley_3d_tileable(SIZE, cells_per_axis=8)

    # B: Worley 16³ — high-frequency wispy detail
    worley_high = generate_worley_3d_tileable(SIZE, cells_per_axis=16)

    # A: Worley 32³ — ultra-high-frequency micro-detail
    worley_ultra = generate_worley_3d_tileable(SIZE, cells_per_axis=32)

    print("  Packing channels...")

    # Perlin-Worley blend: billowy Perlin shapes that respect cellular boundaries
    perlin_worley = np.clip(perlin * 0.65 + worley_low * 0.35, 0, 1)

    texture = np.zeros((SIZE, SIZE, SIZE, CHANNELS), dtype=np.float32)
    texture[..., 0] = perlin_worley  # R: macro shape
    texture[..., 1] = worley_mid     # G: med erosion
    texture[..., 2] = worley_high    # B: fine detail
    texture[..., 3] = worley_ultra   # A: micro detail

    out_dir = "data/textures/cloud_noise"
    os.makedirs(out_dir, exist_ok=True)
    os.makedirs(f"{out_dir}/slices", exist_ok=True)

    save_slices(texture, f"{out_dir}/slices")
    save_raw_binary(texture, f"{out_dir}/cloud_noise_{SIZE}.raw")
    save_ktx2(texture, f"{out_dir}/cloud_noise.ktx2")

    print(f"\nDone! Output in {out_dir}/")
    print(f"\nNoise stats:")
    print(f"  R Perlin-Worley:  [{perlin_worley.min():.3f}, {perlin_worley.max():.3f}]")
    print(f"  G Worley 8³:      [{worley_mid.min():.3f}, {worley_mid.max():.3f}]")
    print(f"  B Worley 16³:     [{worley_high.min():.3f}, {worley_high.max():.3f}]")
    print(f"  A Worley 32³:     [{worley_ultra.min():.3f}, {worley_ultra.max():.3f}]")
    print(f"\nShader usage:")
    print(f"  shape   = texture.r")
    print(f"  detail  = texture.g * 0.5 + texture.b * 0.25 + texture.a * 0.125")
    print(f"  density = max(0, shape - detail * erosion - threshold)")

    total = time.perf_counter() - t_start
    print(f"\nTotal: {total:.2f}s")


if __name__ == "__main__":
    main()
