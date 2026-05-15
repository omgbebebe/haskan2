#!/usr/bin/env python3
"""Generate 2D weather map texture for cloud spatial variation.

Usage:
    python scripts/generate_weather_map.py

Outputs:
    data/textures/weather/weather_map.raw      — raw RGBA8 (512²)
    data/textures/weather/weather_map.png      — PNG for inspection
    data/textures/weather/weather_map_r.png    — R channel (coverage)
    data/textures/weather/weather_map_g.png    — G channel (cloud type)
    data/textures/weather/weather_map_b.png    — B channel (storm darkness)

Channel layout (matches shader in Clouds.hs):
    R: Coverage  — 0.0 = clear sky, 1.0 = thick overcast
    G: Cloud type — 0.0 = stratus (low, flat), 1.0 = cumulonimbus (towering)
    B: Storm     — 0.0 = calm, 1.0 = dark storm bellies
    A: Reserved  — 0.5 (unused)

The weather map covers ~20km at scale 0.00005 (1/20000).
At 512 pixels, that's ~40m per pixel.
"""

import os
import struct
import time
import numpy as np
from PIL import Image

SIZE = 512
CHANNELS = 4

np.random.seed(42)

# 4 gradient directions for 2D Perlin noise (edges of a square)
_GRAD2 = np.array([
    [1, 0], [-1, 0], [0, 1], [0, -1],
    [1, 1], [-1, 1], [1, -1], [-1, -1]
], dtype=np.float32)


def _fade(t):
    """Perlin fade curve: 6t⁵ - 15t⁴ + 10t³."""
    return t * t * t * (t * (t * 6 - 15) + 10)


def generate_perlin_2d_tileable(size, octaves, persistence=0.5):
    """Generate tileable 2D Perlin gradient noise with fBm.

    Uses proper gradient interpolation with fade curve.
    Tileable via modular gradient grid indexing.
    """
    t0 = time.perf_counter()
    print(f"  Perlin 2D fBm ({octaves} octaves, persistence={persistence})...", end="", flush=True)

    coords = np.linspace(0, 1, size, endpoint=False, dtype=np.float32)
    xx, yy = np.meshgrid(coords, coords, indexing='ij')

    result = np.zeros((size, size), dtype=np.float32)
    amplitude = 1.0
    total_amp = 0.0
    grid_size = 2

    for _ in range(octaves):
        grad_idx = np.random.randint(0, 8, (grid_size, grid_size))
        gx = _GRAD2[grad_idx, 0]
        gy = _GRAD2[grad_idx, 1]

        px = xx * grid_size
        py = yy * grid_size

        ix = np.floor(px).astype(np.int32) % grid_size
        iy = np.floor(py).astype(np.int32) % grid_size

        fx = px - np.floor(px)
        fy = py - np.floor(py)

        u = _fade(fx)
        v = _fade(fy)

        ix1 = (ix + 1) % grid_size
        iy1 = (iy + 1) % grid_size

        def dot(ci, cj, dx, dy):
            return gx[ci, cj] * dx + gy[ci, cj] * dy

        n00 = dot(ix,  iy,  fx,     fy)
        n10 = dot(ix1, iy,  fx - 1, fy)
        n01 = dot(ix,  iy1, fx,     fy - 1)
        n11 = dot(ix1, iy1, fx - 1, fy - 1)

        nx0 = n00 + u * (n10 - n00)
        nx1 = n01 + u * (n11 - n01)

        n = nx0 + v * (nx1 - nx0)

        result += n * amplitude
        total_amp += amplitude
        amplitude *= persistence
        grid_size *= 2

    # Normalize to [0, 1]
    result = (result - result.min()) / (result.max() - result.min() + 1e-8)
    elapsed = time.perf_counter() - t0
    print(f" {elapsed:.2f}s")
    return result


def smoothstep(edge0, edge1, x):
    """GLSL smoothstep: 0 when x < edge0, 1 when x > edge1."""
    t = np.clip((x - edge0) / (edge1 - edge0 + 1e-8), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def generate_weather_map(size=SIZE):
    """Generate complete weather map with all channels."""
    t_start = time.perf_counter()
    print(f"Generating weather map ({size}²)...")

    # R channel: coverage — 3 octaves of Perlin noise
    # Large features (~8km), medium (~2km), fine (~500m)
    print("  R channel (coverage)...")
    coverage = generate_perlin_2d_tileable(size, octaves=3, persistence=0.5)

    # Bias coverage: most areas should have some clouds, with occasional clear patches
    # Apply gentle contrast curve
    coverage = smoothstep(0.25, 0.85, coverage)

    # G channel: cloud type — 1-2 octaves, very smooth
    print("  G channel (cloud type)...")
    cloud_type = generate_perlin_2d_tileable(size, octaves=2, persistence=0.5)
    # Bias toward cumulus (0.3-0.7 range), occasional stratus (0.0-0.3) and towering (0.7-1.0)
    cloud_type = smoothstep(0.2, 0.8, cloud_type)

    # B channel: storm darkness — derived from coverage
    print("  B channel (storm darkness)...")
    storm = smoothstep(0.7, 1.0, coverage) * coverage

    # A channel: reserved
    alpha = np.full((size, size), 0.5, dtype=np.float32)

    # Pack channels
    texture = np.zeros((size, size, CHANNELS), dtype=np.float32)
    texture[..., 0] = coverage
    texture[..., 1] = cloud_type
    texture[..., 2] = storm
    texture[..., 3] = alpha

    print(f"\n  Coverage range:    [{coverage.min():.3f}, {coverage.max():.3f}]")
    print(f"  Cloud type range:  [{cloud_type.min():.3f}, {cloud_type.max():.3f}]")
    print(f"  Storm range:       [{storm.min():.3f}, {storm.max():.3f}]")

    elapsed = time.perf_counter() - t_start
    print(f"\n  Total: {elapsed:.2f}s")

    return texture


def save_weather_map(texture, out_dir):
    """Save weather map as raw binary, PNG, and channel visualizations."""
    os.makedirs(out_dir, exist_ok=True)
    size = texture.shape[0]

    # Raw binary (RGBA8)
    data_uint8 = (texture * 255).clip(0, 255).astype(np.uint8)
    raw_path = os.path.join(out_dir, "weather_map.raw")
    with open(raw_path, 'wb') as f:
        f.write(data_uint8.tobytes())
    print(f"  Saved raw: {raw_path} ({os.path.getsize(raw_path)} bytes)")

    # PNG (full RGBA)
    png_path = os.path.join(out_dir, "weather_map.png")
    img = Image.fromarray(data_uint8, mode='RGBA')
    img.save(png_path)
    print(f"  Saved PNG: {png_path}")

    # Individual channel PNGs for inspection
    channels = ['r', 'g', 'b', 'a']
    names = ['coverage', 'cloud_type', 'storm_darkness', 'reserved']
    for i, (ch, name) in enumerate(zip(channels, names)):
        ch_data = (texture[..., i] * 255).clip(0, 255).astype(np.uint8)
        ch_img = Image.fromarray(ch_data, mode='L')
        ch_path = os.path.join(out_dir, f"weather_map_{ch}.png")
        ch_img.save(ch_path)
        print(f"  Saved {ch.upper()} ({name}): {ch_path}")


def main():
    texture = generate_weather_map(SIZE)

    out_dir = "data/textures/weather"
    save_weather_map(texture, out_dir)

    print(f"\nDone! Output in {out_dir}/")
    print("\nShader usage (from Clouds.hs):")
    print("  weatherUV = Vec2 (px * 0.00005) (pz * 0.00005)")
    print("  ~(Vec4 cov type storm _) <- use @(ImageTexel \"weather_map\") NilOps weatherUV")
    print("  combinedCoverage = clamp (cov * globalCoverage) 0.0 1.0")


if __name__ == "__main__":
    main()
