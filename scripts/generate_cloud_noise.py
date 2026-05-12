#!/usr/bin/env python3
"""Generate 3D cloud noise texture for Vulkan.

Usage:
    nix develop -c python scripts/generate_cloud_noise.py

Outputs:
    data/textures/cloud_noise/cloud_noise.ktx2 — KTX2 3D texture (128³ RGBA8)
    data/textures/cloud_noise/slices/ — PNG slices for inspection

Noise model:
    - 3 frequencies of tileable Worley (cellular): 4/8/16 cells per axis
    - Tileable Perlin FBM: detail erosion
    - All distances wrap toroidally for seamless tiling
    - No coverage mask — shape comes from low-freq Worley directly
"""

import os
import struct
import numpy as np
from PIL import Image

# Texture dimensions
SIZE = 128
CHANNELS = 4  # RGBA

# Seed for reproducibility
np.random.seed(42)


def generate_worley_3d_tileable(size, cells_per_axis):
    """Generate tileable 3D Worley (cellular) noise.

    One random feature point per cell, arranged in a cells_per_axis³ grid.
    Distance computed with toroidal wrapping for seamless tiling.
    
    Returns normalized distance to nearest point (0-1).
    Lower values = closer to cell center (cloud core).
    Higher values = cell boundary (gap between clouds).
    """
    num_points = cells_per_axis ** 3
    print(f"  Generating Worley noise ({cells_per_axis}³ = {num_points} points)...")

    # One random point per cell, jittered within cell bounds
    cell_size = 1.0 / cells_per_axis
    points = []
    for cx in range(cells_per_axis):
        for cy in range(cells_per_axis):
            for cz in range(cells_per_axis):
                px = (cx + np.random.rand()) * cell_size
                py = (cy + np.random.rand()) * cell_size
                pz = (cz + np.random.rand()) * cell_size
                points.append([px, py, pz])
    points = np.array(points, dtype=np.float32)

    # Grid coordinates
    x = np.linspace(0, 1, size, endpoint=False)
    y = np.linspace(0, 1, size, endpoint=False)
    z = np.linspace(0, 1, size, endpoint=False)
    xx, yy, zz = np.meshgrid(x, y, z, indexing='ij')
    coords = np.stack([xx, yy, zz], axis=-1)  # (size, size, size, 3)

    # Compute toroidal distance to nearest point
    min_dist = np.ones((size, size, size), dtype=np.float32) * 2.0

    for p in points:
        dx = np.minimum(np.abs(coords[..., 0] - p[0]), 1.0 - np.abs(coords[..., 0] - p[0]))
        dy = np.minimum(np.abs(coords[..., 1] - p[1]), 1.0 - np.abs(coords[..., 1] - p[1]))
        dz = np.minimum(np.abs(coords[..., 2] - p[2]), 1.0 - np.abs(coords[..., 2] - p[2]))
        dist = np.sqrt(dx**2 + dy**2 + dz**2)
        min_dist = np.minimum(min_dist, dist)

    # Normalize and invert: cell centers = high density
    min_dist = min_dist / min_dist.max()
    return 1.0 - min_dist


def generate_perlin_3d_tileable(size, octaves=4):
    """Generate tileable 3D Perlin-like noise using numpy interpolation."""
    print(f"  Generating tileable Perlin noise ({octaves} octaves)...")

    result = np.zeros((size, size, size), dtype=np.float32)
    amplitude = 1.0
    frequency = 1.0

    for _ in range(octaves):
        grid_size = max(2, int(frequency))
        grid = np.random.randn(grid_size, grid_size, grid_size).astype(np.float32)

        from scipy.ndimage import zoom
        # zoom with grid_size * 2 to create tileable texture via periodic boundary
        # Actually for tileable, we need to handle wrapping. Simplest: use mode='wrap' in zoom
        # But scipy zoom doesn't support mode. Instead, we tile the grid and crop.
        
        # Create periodic grid by tiling
        tiled_grid = np.tile(grid, (2, 2, 2))
        
        # Zoom the tiled grid
        zoom_factor = (size * 2) / (grid_size * 2)
        interp = zoom(tiled_grid, zoom_factor, order=1)
        
        # Extract the center tileable region
        start = size // 2
        interp = interp[start:start+size, start:start+size, start:start+size]
        
        # Ensure exact size
        if interp.shape[0] > size:
            interp = interp[:size, :size, :size]
        elif interp.shape[0] < size:
            pad = size - interp.shape[0]
            interp = np.pad(interp, ((0, pad), (0, pad), (0, pad)), mode='wrap')

        result += interp * amplitude
        amplitude *= 0.5
        frequency *= 2

    # Normalize to 0-1
    result = (result - result.min()) / (result.max() - result.min())
    return result


def save_slices(data, output_dir):
    """Save each Z-slice as PNG for inspection."""
    os.makedirs(output_dir, exist_ok=True)
    size = data.shape[0]

    for z in range(size):
        # Take R channel (density)
        slice_data = (data[:, :, z, 0] * 255).astype(np.uint8)
        img = Image.fromarray(slice_data, mode='L')
        img.save(os.path.join(output_dir, f"slice_{z:03d}.png"))

    print(f"  Saved {size} slices to {output_dir}")


def save_raw_binary(data, filepath):
    """Save as raw binary file (RGBA8, size³)."""
    data_uint8 = (data * 255).astype(np.uint8)
    data_bytes = data_uint8.tobytes()

    with open(filepath, 'wb') as f:
        f.write(data_bytes)

    print(f"  Saved raw binary: {filepath} ({len(data_bytes)} bytes)")


def save_ktx2(data, filepath):
    """Save as minimal KTX2 file."""
    print(f"  Saving KTX2: {filepath}")

    size = data.shape[0]
    data_uint8 = (data * 255).astype(np.uint8)
    pixel_data = data_uint8.tobytes()

    identifier = b'\xabKTX 20\xbb\r\n\x1a\n'
    vkFormat = 37  # VK_FORMAT_R8G8B8A8_UNORM
    typeSize = 1
    pixelWidth = size
    pixelHeight = size
    pixelDepth = size
    layerCount = 0
    faceCount = 1
    levelCount = 1
    supercompressionScheme = 0
    dfdByteOffset = 0
    dfdByteLength = 0
    kvdByteOffset = 0
    kvdByteLength = 0
    sgdByteOffset = 0
    sgdByteLength = 0

    levelByteOffset = 104
    levelByteLength = len(pixel_data)
    uncompressedByteLength = len(pixel_data)

    with open(filepath, 'wb') as f:
        f.write(identifier)
        f.write(struct.pack('<I', vkFormat))
        f.write(struct.pack('<I', typeSize))
        f.write(struct.pack('<I', pixelWidth))
        f.write(struct.pack('<I', pixelHeight))
        f.write(struct.pack('<I', pixelDepth))
        f.write(struct.pack('<I', layerCount))
        f.write(struct.pack('<I', faceCount))
        f.write(struct.pack('<I', levelCount))
        f.write(struct.pack('<I', supercompressionScheme))
        f.write(struct.pack('<I', dfdByteOffset))
        f.write(struct.pack('<I', dfdByteLength))
        f.write(struct.pack('<I', kvdByteOffset))
        f.write(struct.pack('<I', kvdByteLength))
        f.write(struct.pack('<Q', sgdByteOffset))
        f.write(struct.pack('<Q', sgdByteLength))
        f.write(struct.pack('<Q', levelByteOffset))
        f.write(struct.pack('<Q', levelByteLength))
        f.write(struct.pack('<Q', uncompressedByteLength))
        f.write(pixel_data)

    print(f"  Saved KTX2: {filepath} ({os.path.getsize(filepath)} bytes)")


def main():
    print(f"Generating 3D cloud noise texture ({SIZE}³)...")

    # 1. Low-freq Worley: 4 cells per axis = cloud body / shape
    worley_low = generate_worley_3d_tileable(SIZE, cells_per_axis=4)

    # 2. Mid-freq Worley: 8 cells per axis = detail layer 1
    worley_mid = generate_worley_3d_tileable(SIZE, cells_per_axis=8)

    # 3. High-freq Worley: 16 cells per axis = detail layer 2
    worley_high = generate_worley_3d_tileable(SIZE, cells_per_axis=16)

    # 4. Tileable Perlin FBM = detail layer 3
    perlin = generate_perlin_3d_tileable(SIZE, octaves=4)

    print("  Packing channels...")

    # Create RGBA texture
    # R = low-freq Worley (cloud body / shape)
    # G = mid-freq Worley (detail 1)
    # B = high-freq Worley (detail 2)
    # A = Perlin (detail 3)
    texture = np.zeros((SIZE, SIZE, SIZE, CHANNELS), dtype=np.float32)
    texture[..., 0] = worley_low
    texture[..., 1] = worley_mid
    texture[..., 2] = worley_high
    texture[..., 3] = perlin

    # Output paths
    out_dir = "data/textures/cloud_noise"
    os.makedirs(out_dir, exist_ok=True)
    os.makedirs(f"{out_dir}/slices", exist_ok=True)

    save_slices(texture, f"{out_dir}/slices")
    save_raw_binary(texture, f"{out_dir}/cloud_noise_{SIZE}.raw")
    save_ktx2(texture, f"{out_dir}/cloud_noise.ktx2")

    print(f"\nDone! Output in {out_dir}/")
    print(f"  - cloud_noise_{SIZE}.raw: raw binary (loadable as 3D texture)")
    print(f"  - cloud_noise.ktx2: KTX2 format")
    print(f"  - slices/: PNG slices for inspection")
    print(f"\nNoise stats:")
    print(f"  Worley low  (4³):  [{worley_low.min():.3f}, {worley_low.max():.3f}]")
    print(f"  Worley mid  (8³):  [{worley_mid.min():.3f}, {worley_mid.max():.3f}]")
    print(f"  Worley high (16³): [{worley_high.min():.3f}, {worley_high.max():.3f}]")
    print(f"  Perlin:            [{perlin.min():.3f}, {perlin.max():.3f}]")


if __name__ == "__main__":
    main()
