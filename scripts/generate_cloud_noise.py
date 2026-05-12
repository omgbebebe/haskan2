#!/usr/bin/env python3
"""Generate 3D cloud noise texture for Vulkan.

Usage:
    nix develop -c python scripts/generate_cloud_noise.py

Outputs:
    data/textures/cloud_noise/cloud_noise.ktx2 — KTX2 3D texture (128³ RGBA8)
    data/textures/cloud_noise/slices/ — PNG slices for inspection

Noise model:
    - Worley noise (cellular): creates separated cloud puffs
    - Perlin FBM: adds detail within puffs
    - Coverage mask: large-scale cloud region control
    - Curl noise: optional domain warp for organic shapes
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


def generate_worley_3d(size, num_points=32):
    """Generate 3D Worley (cellular) noise.

    Returns distance to nearest random point (normalized 0-1).
    Lower values = closer to cell center (cloud core).
    Higher values = cell boundary (gap between clouds).
    """
    print(f"  Generating Worley noise ({num_points} points)...")

    # Random point positions
    points = np.random.rand(num_points, 3)

    # Grid coordinates
    x = np.linspace(0, 1, size, endpoint=False)
    y = np.linspace(0, 1, size, endpoint=False)
    z = np.linspace(0, 1, size, endpoint=False)
    xx, yy, zz = np.meshgrid(x, y, z, indexing='ij')

    coords = np.stack([xx, yy, zz], axis=-1)  # (size, size, size, 3)

    # Compute distance to nearest point (with toroidal wrapping)
    min_dist = np.ones((size, size, size), dtype=np.float32)

    for p in points:
        # Toroidal distance (noise repeats)
        dx = np.minimum(np.abs(coords[..., 0] - p[0]), 1 - np.abs(coords[..., 0] - p[0]))
        dy = np.minimum(np.abs(coords[..., 1] - p[1]), 1 - np.abs(coords[..., 1] - p[1]))
        dz = np.minimum(np.abs(coords[..., 2] - p[2]), 1 - np.abs(coords[..., 2] - p[2]))
        dist = np.sqrt(dx**2 + dy**2 + dz**2)
        min_dist = np.minimum(min_dist, dist)

    # Normalize
    return min_dist / min_dist.max()


def generate_perlin_3d(size, octaves=3):
    """Generate 3D Perlin-like noise using numpy interpolation."""
    print(f"  Generating Perlin noise ({octaves} octaves)...")

    result = np.zeros((size, size, size), dtype=np.float32)
    amplitude = 1.0
    frequency = 1.0

    for _ in range(octaves):
        # Random grid
        grid_size = max(2, int(frequency))
        grid = np.random.randn(grid_size, grid_size, grid_size).astype(np.float32)

        # Interpolate to full size
        from scipy.ndimage import zoom
        interp = zoom(grid, size / grid_size, order=1)
        # Crop or pad to exact size
        if interp.shape[0] > size:
            interp = interp[:size, :size, :size]
        elif interp.shape[0] < size:
            pad = size - interp.shape[0]
            interp = np.pad(interp, ((0, pad), (0, pad), (0, pad)), mode='edge')

        result += interp * amplitude
        amplitude *= 0.5
        frequency *= 2

    # Normalize to 0-1
    result = (result - result.min()) / (result.max() - result.min())
    return result


def generate_coverage_3d(size):
    """Large-scale coverage mask (very low frequency)."""
    print("  Generating coverage mask...")

    grid_size = 4
    grid = np.random.rand(grid_size, grid_size, grid_size).astype(np.float32)

    from scipy.ndimage import zoom
    coverage = zoom(grid, size / grid_size, order=1)
    coverage = coverage[:size, :size, :size]

    # Smooth it
    coverage = (coverage - coverage.min()) / (coverage.max() - coverage.min())
    return coverage


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
    """Save as minimal KTX2 file.

    KTX2 header:
    - identifier: 12 bytes (magic)
    - vkFormat: 4 bytes (VK_FORMAT_R8G8B8A8_UNORM = 37)
    - typeSize: 4 bytes (1 for 8-bit)
    - pixelWidth: 4 bytes
    - pixelHeight: 4 bytes
    - pixelDepth: 4 bytes
    - layerCount: 4 bytes
    - faceCount: 4 bytes
    - levelCount: 4 bytes
    - supercompressionScheme: 4 bytes
    - dfdByteOffset: 4 bytes
    - dfdByteLength: 4 bytes
    - kvdByteOffset: 4 bytes
    - kvdByteLength: 4 bytes
    - sgdByteOffset: 8 bytes
    - sgdByteLength: 8 bytes
    Total header: 80 bytes

    Level index:
    - For each mip level: byteOffset(8), byteLength(8), uncompressedByteLength(8)
    For single level: 24 bytes

    Then pixel data.
    """
    print(f"  Saving KTX2: {filepath}")

    size = data.shape[0]
    data_uint8 = (data * 255).astype(np.uint8)
    pixel_data = data_uint8.tobytes()

    # KTX2 magic identifier
    identifier = b'\xabKTX 20\xbb\r\n\x1a\n'

    # Header fields
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

    # Level index (single level)
    # Header is 80 bytes, level index is 24 bytes
    # Data starts at 80 + 24 = 104
    levelByteOffset = 104
    levelByteLength = len(pixel_data)
    uncompressedByteLength = len(pixel_data)

    with open(filepath, 'wb') as f:
        # Identifier
        f.write(identifier)
        # Header
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
        # Level index
        f.write(struct.pack('<Q', levelByteOffset))
        f.write(struct.pack('<Q', levelByteLength))
        f.write(struct.pack('<Q', uncompressedByteLength))
        # Pixel data
        f.write(pixel_data)

    print(f"  Saved KTX2: {filepath} ({os.path.getsize(filepath)} bytes)")


def main():
    print(f"Generating 3D cloud noise texture ({SIZE}³)...")

    # 1. Worley noise — separated cell structures (cloud puffs)
    worley = generate_worley_3d(SIZE, num_points=48)
    # Invert: cell centers are low distance = high density
    worley = 1.0 - worley

    # 2. Perlin FBM — detail within puffs
    perlin = generate_perlin_3d(SIZE, octaves=3)

    # 3. Coverage mask — large-scale cloud region control
    coverage = generate_coverage_3d(SIZE)

    # 4. Combine
    # Channel R: cloud density
    #   = Worley (puff shape) * Perlin (detail) * Coverage (region mask)
    # Channel G: coverage mask (for shader use)
    # Channel B: detail noise (for shader use)
    # Channel A: unused / reserved
    print("  Combining noise layers...")

    density = worley * perlin * coverage

    # Normalize
    density = (density - density.min()) / (density.max() - density.min())

    # Create RGBA texture
    texture = np.zeros((SIZE, SIZE, SIZE, CHANNELS), dtype=np.float32)
    texture[..., 0] = density  # R: density
    texture[..., 1] = coverage  # G: coverage
    texture[..., 2] = perlin  # B: detail
    texture[..., 3] = worley  # A: worley shape

    # Output paths
    out_dir = "data/textures/cloud_noise"
    os.makedirs(out_dir, exist_ok=True)
    os.makedirs(f"{out_dir}/slices", exist_ok=True)

    # Save in multiple formats
    save_slices(texture, f"{out_dir}/slices")
    save_raw_binary(texture, f"{out_dir}/cloud_noise_{SIZE}.raw")
    save_ktx2(texture, f"{out_dir}/cloud_noise.ktx2")

    print(f"\nDone! Output in {out_dir}/")
    print(f"  - cloud_noise_{SIZE}.raw: raw binary (loadable as 3D texture)")
    print(f"  - cloud_noise.ktx2: KTX2 format")
    print(f"  - slices/: PNG slices for inspection")
    print(f"\nNoise stats:")
    print(f"  Worley range: [{worley.min():.3f}, {worley.max():.3f}]")
    print(f"  Perlin range: [{perlin.min():.3f}, {perlin.max():.3f}]")
    print(f"  Coverage range: [{coverage.min():.3f}, {coverage.max():.3f}]")
    print(f"  Final density range: [{density.min():.3f}, {density.max():.3f}]")


if __name__ == "__main__":
    main()
