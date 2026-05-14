#!/usr/bin/env python3
"""Generate 64x64 blue noise texture for cloud dithering.

Blue noise has high-frequency, isotropic spectral distribution — ideal for
stochastic sampling without visible low-frequency patterns.

Output: data/textures/blue_noise_64.raw — single channel R8 (64x64)
"""

import numpy as np
import os

SIZE = 64

def generate_blue_noise(size, num_iterations=1000):
    """Generate blue noise via void-and-cluster algorithm."""
    # Start with random binary pattern
    rng = np.random.default_rng(42)
    pattern = rng.random((size, size))
    threshold = 0.5
    binary = (pattern > threshold).astype(np.float32)
    
    # Void-and-cluster iterations
    for _ in range(num_iterations):
        # Find tightest cluster (white pixel with highest energy)
        energy = convolve_energy(binary)
        white_mask = binary > 0.5
        if np.any(white_mask):
            cluster_idx = np.unravel_index(np.argmax(energy * white_mask), energy.shape)
            binary[cluster_idx] = 0.0
        
        # Find largest void (black pixel with lowest energy)
        energy = convolve_energy(binary)
        black_mask = binary < 0.5
        if np.any(black_mask):
            void_idx = np.unravel_index(np.argmin(energy + 1e6 * (1 - black_mask)), energy.shape)
            binary[void_idx] = 1.0
    
    # Rank pixels by their void-and-cluster ordering
    result = np.zeros((size, size), dtype=np.float32)
    temp = binary.copy()
    for rank in range(size * size):
        energy = convolve_energy(temp)
        void_idx = np.unravel_index(np.argmin(energy), energy.shape)
        result[void_idx] = rank / (size * size - 1)
        temp[void_idx] = 1.0  # Mark as occupied
    
    return result

def convolve_energy(pattern):
    """Gaussian energy convolution for void-and-cluster."""
    from scipy.ndimage import gaussian_filter
    return gaussian_filter(pattern, sigma=1.5, mode='wrap')

def main():
    print(f"Generating {SIZE}x{SIZE} blue noise...")
    
    # Simple approach: use numpy's FFT-based blue noise
    # Generate white noise, filter to keep only high frequencies
    rng = np.random.default_rng(42)
    white = rng.standard_normal((SIZE, SIZE))
    
    # FFT
    freq = np.fft.fft2(white)
    freq_shift = np.fft.fftshift(freq)
    
    # Create high-pass filter (keep high frequencies = blue noise)
    y, x = np.ogrid[-SIZE//2:SIZE//2, -SIZE//2:SIZE//2]
    r = np.sqrt(x*x + y*y)
    r[SIZE//2, SIZE//2] = 1e-10  # Avoid div by zero at DC
    
    # High-pass: attenuate low frequencies
    filter_mask = np.clip(r / (SIZE * 0.15), 0, 1) ** 2
    
    # Apply filter
    filtered = freq_shift * filter_mask
    
    # Inverse FFT
    result = np.real(np.fft.ifft2(np.fft.ifftshift(filtered)))
    
    # Normalize to [0, 1]
    result = (result - result.min()) / (result.max() - result.min())
    
    # Tileable: ensure wrap-around continuity by blending edges
    # (For 64x64 blue noise, tileability is less critical since
    #  we sample with fractional UVs anyway)
    
    # Convert to uint8
    raw_u8 = (result * 255).astype(np.uint8)
    
    # Expand to RGBA8 (replicate R channel)
    raw_rgba = np.zeros((SIZE, SIZE, 4), dtype=np.uint8)
    raw_rgba[:, :, 0] = raw_u8
    raw_rgba[:, :, 1] = raw_u8
    raw_rgba[:, :, 2] = raw_u8
    raw_rgba[:, :, 3] = 255
    
    out_dir = "data/textures/blue_noise"
    os.makedirs(out_dir, exist_ok=True)
    
    # Save raw binary (RGBA8)
    raw_path = f"{out_dir}/blue_noise_{SIZE}.raw"
    with open(raw_path, 'wb') as f:
        f.write(raw_rgba.tobytes())
    
    print(f"Saved {raw_path} ({SIZE*SIZE*4} bytes)")
    
    # Save as PNG for inspection
    try:
        from PIL import Image
        png_path = f"{out_dir}/blue_noise_{SIZE}.png"
        Image.fromarray(raw_rgba, mode='RGBA').save(png_path)
        print(f"Saved {png_path}")
    except ImportError:
        pass

if __name__ == "__main__":
    main()
