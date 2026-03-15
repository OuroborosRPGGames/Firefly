#!/usr/bin/env python3
"""Build RGB wall/door/window pixel mask from gemini_colormap_analyze.py output.

Input:
  --input-dir: directory containing mask_outer_wall.png, mask_inner_wall.png,
               mask_outer_door.png, mask_inner_door.png (from gemini_colormap_analyze.py)
  --window-mask: optional path to window binary mask (white=window)
  --output: path to write RGB wall mask PNG

Output:
  RGB PNG where:
    Red   (255,0,0) = wall (blocks movement + LOS)
    Green (0,255,0) = door (runtime open/closed)
    Blue  (0,0,255) = window (blocks movement, transparent to LOS)
    Black (0,0,0)   = floor (passable)

Classification threshold: dominant channel > 128, other channels < 64.
"""

import argparse
import os
import sys

import cv2
import numpy as np


def load_mask(path, h, w):
    """Load a grayscale mask and resize to (h, w). Returns None if missing."""
    if not path or not os.path.exists(path):
        return None
    m = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    if m is None:
        return None
    if m.shape[:2] != (h, w):
        m = cv2.resize(m, (w, h), interpolation=cv2.INTER_NEAREST)
    return m > 127  # boolean


def main():
    parser = argparse.ArgumentParser(description='Build RGB wall/door/window mask')
    parser.add_argument('--input-dir', required=True, help='Directory with per-label masks')
    parser.add_argument('--output', required=True, help='Output RGB PNG path')
    parser.add_argument('--window-mask', default=None, help='Optional window mask path')
    args = parser.parse_args()

    # Determine dimensions from first available mask
    mask_names = ['mask_outer_wall.png', 'mask_inner_wall.png',
                  'mask_outer_door.png', 'mask_inner_door.png']
    h, w = None, None
    for name in mask_names:
        path = os.path.join(args.input_dir, name)
        if os.path.exists(path):
            m = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
            if m is not None:
                h, w = m.shape[:2]
                break

    if h is None or w is None:
        # Try combined_wall_door.png as fallback
        combined_path = os.path.join(args.input_dir, 'combined_wall_door.png')
        if os.path.exists(combined_path):
            m = cv2.imread(combined_path, cv2.IMREAD_GRAYSCALE)
            if m is not None:
                h, w = m.shape[:2]

    if h is None or w is None:
        print('ERROR: No mask files found in input directory', file=sys.stderr)
        sys.exit(1)

    # Load individual masks
    outer_wall = load_mask(os.path.join(args.input_dir, 'mask_outer_wall.png'), h, w)
    inner_wall = load_mask(os.path.join(args.input_dir, 'mask_inner_wall.png'), h, w)
    outer_door = load_mask(os.path.join(args.input_dir, 'mask_outer_door.png'), h, w)
    inner_door = load_mask(os.path.join(args.input_dir, 'mask_inner_door.png'), h, w)
    window = load_mask(args.window_mask, h, w) if args.window_mask else None

    # Combine walls and doors
    is_wall = np.zeros((h, w), dtype=bool)
    if outer_wall is not None:
        is_wall |= outer_wall
    if inner_wall is not None:
        is_wall |= inner_wall

    is_door = np.zeros((h, w), dtype=bool)
    if outer_door is not None:
        is_door |= outer_door
    if inner_door is not None:
        is_door |= inner_door

    is_window = window if window is not None else np.zeros((h, w), dtype=bool)

    # Priority: door > window > wall > floor
    # OpenCV writes BGR, so to get RGB (255,0,0)=wall in file, write BGR (0,0,255)
    mask = np.zeros((h, w, 3), dtype=np.uint8)  # black = floor (BGR)

    # Layer 1: walls → RGB red = BGR (0, 0, 255)
    mask[is_wall] = [0, 0, 255]

    # Layer 2: windows override walls → RGB blue = BGR (255, 0, 0)
    window_only = is_window & ~is_door
    mask[window_only] = [255, 0, 0]

    # Layer 3: doors override everything → RGB green = BGR (0, 255, 0)
    mask[is_door] = [0, 255, 0]

    cv2.imwrite(args.output, mask)

    # Print summary
    wall_px = int(np.sum(is_wall & ~is_door & ~is_window))
    door_px = int(np.sum(is_door))
    win_px = int(np.sum(window_only))
    total = h * w
    print(f'Wall: {wall_px} px ({wall_px*100/total:.1f}%)')
    print(f'Door: {door_px} px ({door_px*100/total:.1f}%)')
    print(f'Window: {win_px} px ({win_px*100/total:.1f}%)')
    print(f'Floor: {total - wall_px - door_px - win_px} px')
    print(f'Output: {args.output} ({w}x{h})')


if __name__ == '__main__':
    main()
