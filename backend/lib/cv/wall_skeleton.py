"""Wall skeletonization for hex classification.

Thins a wall mask to its skeleton, then checks which hexes the skeleton
crosses through for a significant distance relative to hex diameter.

Usage: python3 wall_skeleton.py <wall_mask_png> <hex_coords_json> <hex_size> <output_json>

Input hex_coords_json format: [[hx, hy, center_x_px, center_y_px], ...]
Output: {"hx,hy": true, ...}  (only hexes where wall skeleton crosses)
"""
import cv2
import json
import math
import numpy as np
import sys


def flat_top_hex_vertices(cx, cy, size):
    """Return 6 vertices for a flat-top hexagon."""
    return [(cx + size * math.cos(math.pi / 3.0 * i),
             cy + size * math.sin(math.pi / 3.0 * i)) for i in range(6)]


def main():
    if len(sys.argv) == 2 and sys.argv[1] in ("--help", "-h"):
        print(__doc__)
        sys.exit(0)

    if len(sys.argv) != 5:
        print(f"Usage: {sys.argv[0]} <wall_mask_png> <hex_coords_json> <hex_size> <output_json>",
              file=sys.stderr)
        sys.exit(1)

    mask_path = sys.argv[1]
    coords_path = sys.argv[2]
    hex_size = float(sys.argv[3])
    output_path = sys.argv[4]

    mask = cv2.imread(mask_path, cv2.IMREAD_GRAYSCALE)
    if mask is None:
        print(f"Error: could not read mask {mask_path}", file=sys.stderr)
        sys.exit(1)

    with open(coords_path, "r") as f:
        hex_coords = json.load(f)

    # Threshold and skeletonize
    _, binary = cv2.threshold(mask, 128, 255, cv2.THRESH_BINARY)
    skeleton = cv2.ximgproc.thinning(binary)

    h, w = mask.shape[:2]
    hex_diameter = hex_size * 2
    min_crossing = hex_diameter * 0.3

    result = {}
    for coord in hex_coords:
        if not isinstance(coord, list) or len(coord) != 4:
            continue

        hx, hy, cx, cy = coord
        key = f"{hx},{hy}"

        # Draw hex mask
        vertices = flat_top_hex_vertices(float(cx), float(cy), hex_size)
        hex_pts = np.array(vertices, dtype=np.int32)
        hex_mask = np.zeros((h, w), dtype=np.uint8)
        cv2.fillPoly(hex_mask, [hex_pts], 255)

        # Count skeleton pixels inside this hex
        overlap = cv2.bitwise_and(hex_mask, skeleton)
        skeleton_pixels = cv2.countNonZero(overlap)

        # Each skeleton pixel is ~1px wide, so pixel count ≈ length in pixels
        if skeleton_pixels >= min_crossing:
            result[key] = True

    with open(output_path, "w") as f:
        json.dump(result, f)

    print(f"Found {len(result)} wall hexes from skeleton analysis")


if __name__ == "__main__":
    main()
