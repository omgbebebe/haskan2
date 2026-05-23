#!/usr/bin/env python3
"""Check if cloud noise slices are tilable (seamless)."""

from pathlib import Path
import numpy as np
from PIL import Image
import sys

def check_tilable(image_path, tolerance=5):
    """Check if image edges match for seamless tiling."""
    img = Image.open(image_path).convert('RGBA')
    arr = np.array(img)
    
    h, w = arr.shape[:2]
    
    # Check horizontal tiling: left edge vs right edge
    left_edge = arr[:, 0, :]
    right_edge = arr[:, -1, :]
    h_diff = np.abs(left_edge.astype(float) - right_edge.astype(float))
    h_max_diff = np.max(h_diff)
    h_match = np.mean(h_diff < tolerance) * 100
    
    # Check vertical tiling: top edge vs bottom edge
    top_edge = arr[0, :, :]
    bottom_edge = arr[-1, :, :]
    v_diff = np.abs(top_edge.astype(float) - bottom_edge.astype(float))
    v_max_diff = np.max(v_diff)
    v_match = np.mean(v_diff < tolerance) * 100
    
    return {
        'path': image_path,
        'size': (w, h),
        'horizontal': {
            'max_diff': h_max_diff,
            'match_pct': h_match,
            'tilable': h_max_diff < tolerance
        },
        'vertical': {
            'max_diff': v_max_diff,
            'match_pct': v_match,
            'tilable': v_max_diff < tolerance
        }
    }

def main():
    debug_dir = Path('data/debug/clouds')
    
    if not debug_dir.exists():
        print(f"Directory not found: {debug_dir}")
        print("Run the engine and click 'Save Noise Slices' first.")
        sys.exit(1)
    
    # Find all noise slice files
    slice_files = sorted(debug_dir.glob('*cloud_noise_slice_Z*.png'))
    
    if not slice_files:
        print(f"No noise slice files found in {debug_dir}")
        print("Run the engine and click 'Save Noise Slices' first.")
        sys.exit(1)
    
    print(f"Found {len(slice_files)} noise slice files")
    print("=" * 70)
    
    all_h_tilable = True
    all_v_tilable = True
    
    for f in slice_files:
        result = check_tilable(f)
        h = result['horizontal']
        v = result['vertical']
        
        h_status = "✓" if h['tilable'] else "✗"
        v_status = "✓" if v['tilable'] else "✗"
        
        print(f"\n{result['path'].name} ({result['size'][0]}x{result['size'][1]})")
        print(f"  Horizontal: {h_status} max_diff={h['max_diff']:.1f} match={h['match_pct']:.1f}%")
        print(f"  Vertical:   {v_status} max_diff={v['max_diff']:.1f} match={v['match_pct']:.1f}%")
        
        all_h_tilable = all_h_tilable and h['tilable']
        all_v_tilable = all_v_tilable and v['tilable']
    
    print("\n" + "=" * 70)
    if all_h_tilable and all_v_tilable:
        print("RESULT: All slices are TILABLE (seamless)")
    else:
        print("RESULT: NOT tilable - edges don't match")
        if not all_h_tilable:
            print("  - Horizontal tiling fails")
        if not all_v_tilable:
            print("  - Vertical tiling fails")

if __name__ == '__main__':
    main()
