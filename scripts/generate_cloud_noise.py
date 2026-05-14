#!/usr/bin/env python3
"""Generate 3D cloud noise texture for Vulkan.

Usage:
    nix develop -c python scripts/generate_cloud_noise.py

Outputs:
    data/textures/cloud_noise/cloud_noise_128.raw — raw RGBA8 (128³)
    data/textures/cloud_noise/cloud_noise.ktx2 — KTX2 3D texture
    data/textures/cloud_noise/slices/ — PNG slices for inspection

Channel layout (matches shader in Clouds.hs):
    R: Perlin-Worley blend (4 octaves gradient Perlin + 4³ Worley) — macro cloud shape
    G: Worley 8³  — medium-frequency edge erosion
    B: Worley 16³ — high-frequency wispy detail
    A: Worley 32³ — ultra-high-frequency micro-detail

All noise is tileable (toroidal distance wrapping).

Shader usage (from Clouds.hs fragment shader):
    -- Domain-warped UVW sampled from this 3D texture
    noise = texture3D(cloud_noise, uvw)
    
    -- Detail channel: weighted combination of G/B/A
    detail = noise.g * 0.3 + noise.b * 0.15 + noise.a * 0.075
    
    -- Base density: shape * (1 - detail) with threshold
    density = max(0, noise.r * (1.0 - detail) - 0.15)
    
    -- Apply height mask (smoothstep at cloud bottom/top)
    density = density * heightMask * 4.0
"""

import os
import struct
import time
import numpy as np
from PIL import Image

SIZE = 128
CHANNELS = 4

np.random.seed(42)

# 12 gradient directions for 3D Perlin noise (edges of a cube)
_GRAD3 = np.array([
    [1,1,0], [-1,1,0], [1,-1,0], [-1,-1,0],
    [1,0,1], [-1,0,1], [1,0,-1], [-1,0,-1],
    [0,1,1], [0,-1,1], [0,1,-1], [0,-1,-1]
], dtype=np.float32)


def _fade(t):
    return t * t * t * (t * (t * 6 - 15) + 10)


def generate_perlin_3d_tileable(size, octaves=4):
    """Generate tileable 3D Perlin gradient noise with fBm.

    Uses proper gradient interpolation (not value noise), with the
    6t^5-15t^4+10t^3 fade curve for C2-smooth results.
    Tileable via modular gradient grid indexing.
    """
    t0 = time.perf_counter()
    print(f"  Perlin fBm ({octaves} octaves)...", end="", flush=True)

    coords = np.linspace(0, 1, size, endpoint=False, dtype=np.float32)
    xx, yy, zz = np.meshgrid(coords, coords, coords, indexing='ij')

    result = np.zeros((size, size, size), dtype=np.float32)
    amplitude = 1.0
    total_amp = 0.0
    grid_size = 2

    for _ in range(octaves):
        grad_idx = np.random.randint(0, 12, (grid_size, grid_size, grid_size))
        gx = _GRAD3[grad_idx, 0]
        gy = _GRAD3[grad_idx, 1]
        gz = _GRAD3[grad_idx, 2]

        px = xx * grid_size
        py = yy * grid_size
        pz = zz * grid_size

        ix = np.floor(px).astype(np.int32) % grid_size
        iy = np.floor(py).astype(np.int32) % grid_size
        iz = np.floor(pz).astype(np.int32) % grid_size

        fx = px - np.floor(px)
        fy = py - np.floor(py)
        fz = pz - np.floor(pz)

        u = _fade(fx)
        v = _fade(fy)
        w = _fade(fz)

        ix1 = (ix + 1) % grid_size
        iy1 = (iy + 1) % grid_size
        iz1 = (iz + 1) % grid_size

        def dot(ci, cj, ck, dx, dy, dz):
            return gx[ci, cj, ck] * dx + gy[ci, cj, ck] * dy + gz[ci, cj, ck] * dz

        n000 = dot(ix,  iy,  iz,  fx,     fy,     fz)
        n100 = dot(ix1, iy,  iz,  fx - 1, fy,     fz)
        n010 = dot(ix,  iy1, iz,  fx,     fy - 1, fz)
        n110 = dot(ix1, iy1, iz,  fx - 1, fy - 1, fz)
        n001 = dot(ix,  iy,  iz1, fx,     fy,     fz - 1)
        n101 = dot(ix1, iy,  iz1, fx - 1, fy,     fz - 1)
        n011 = dot(ix,  iy1, iz1, fx,     fy - 1, fz - 1)
        n111 = dot(ix1, iy1, iz1, fx - 1, fy - 1, fz - 1)

        x00 = n000 + u * (n100 - n000)
        x10 = n010 + u * (n110 - n010)
        x01 = n001 + u * (n101 - n001)
        x11 = n011 + u * (n111 - n011)

        y0 = x00 + v * (x10 - x00)
        y1 = x01 + v * (x11 - x01)

        z0 = y0 + w * (y1 - y0)

        result += z0 * amplitude
        total_amp += amplitude
        amplitude *= 0.5
        grid_size *= 2

    result /= total_amp
    result = (result - result.min()) / (result.max() - result.min() + 1e-8)
    elapsed = time.perf_counter() - t0
    print(f" {elapsed:.2f}s")
    return result


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

    point_grid = np.random.rand(cells_per_axis, cells_per_axis, cells_per_axis, 3).astype(np.float32)
    for cx in range(cells_per_axis):
        for cy in range(cells_per_axis):
            for cz in range(cells_per_axis):
                point_grid[cx, cy, cz, 0] = (cx + point_grid[cx, cy, cz, 0]) * cell_size
                point_grid[cx, cy, cz, 1] = (cy + point_grid[cx, cy, cz, 1]) * cell_size
                point_grid[cx, cy, cz, 2] = (cz + point_grid[cx, cy, cz, 2]) * cell_size

    x = np.linspace(0, 1, size, endpoint=False)
    y = np.linspace(0, 1, size, endpoint=False)
    z = np.linspace(0, 1, size, endpoint=False)
    xx, yy, zz = np.meshgrid(x, y, z, indexing='ij')

    cell_x = np.floor(xx * cells_per_axis).astype(int) % cells_per_axis
    cell_y = np.floor(yy * cells_per_axis).astype(int) % cells_per_axis
    cell_z = np.floor(zz * cells_per_axis).astype(int) % cells_per_axis

    min_dist = np.ones((size, size, size), dtype=np.float32) * 2.0

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

    perlin = generate_perlin_3d_tileable(SIZE, octaves=4)
    worley_low = generate_worley_3d_tileable(SIZE, cells_per_axis=4)
    worley_mid = generate_worley_3d_tileable(SIZE, cells_per_axis=8)
    worley_high = generate_worley_3d_tileable(SIZE, cells_per_axis=16)
    worley_ultra = generate_worley_3d_tileable(SIZE, cells_per_axis=32)

    print("  Packing channels...")

    perlin_worley = np.clip(perlin * 0.65 + worley_low * 0.35, 0, 1)

    texture = np.zeros((SIZE, SIZE, SIZE, CHANNELS), dtype=np.float32)
    texture[..., 0] = perlin_worley
    texture[..., 1] = worley_mid
    texture[..., 2] = worley_high
    texture[..., 3] = worley_ultra

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
    print(f"\nShader usage (from Clouds.hs):")
    print(f"  detail  = texture.g * 0.3 + texture.b * 0.15 + texture.a * 0.075")
    print(f"  density = max(0, texture.r * (1.0 - detail) - 0.15) * heightMask * 4.0")

    total = time.perf_counter() - t_start
    print(f"\nTotal: {total:.2f}s")


if __name__ == "__main__":
    main()
