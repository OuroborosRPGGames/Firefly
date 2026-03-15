"""Pixel-space contour detection with per-hex overlap computation.

Loads an edge map, finds closed contours via morphological closing,
classifies them (room_outline, wall_like, object_like), and computes
overlap percentages for each hex in a provided coordinate list.

Usage: python3 shape_map_detect.py <edge_map_png> <hex_coords_json> <hex_size> <output_json>

  edge_map_png    - Grayscale PNG where bright pixels (>128) are edges
  hex_coords_json - JSON file: array of [hx, hy, center_x_px, center_y_px]
  hex_size        - Hex size in pixels (float)
  output_json     - Output path for per-hex overlap results
"""
import cv2
import json
import math
import numpy as np
import os
import sys


def print_usage():
    print(f"Usage: {sys.argv[0]} <edge_map_png> <hex_coords_json> <hex_size> <output_json>", file=sys.stderr)


def flat_top_hex_vertices(cx, cy, size):
    """Return 6 vertices for a flat-top hexagon centered at (cx, cy)."""
    pts = []
    for i in range(6):
        angle = math.pi / 3.0 * i
        px = cx + size * math.cos(angle)
        py = cy + size * math.sin(angle)
        pts.append((px, py))
    return pts


def classify_contours(contours, hierarchy, hex_size, solidity_min=0.4):
    """Classify contours into room_outline, wall_like, or object_like.

    Returns list of dicts with keys: id, contour, area, perimeter, solidity, shape_type.
    """
    if hierarchy is None:
        return []

    min_area = hex_size * hex_size
    min_perimeter = hex_size * 2.0
    hierarchy = hierarchy[0]  # hierarchy shape is (1, N, 4)

    classified = []
    largest_area = 0
    largest_idx = -1

    for i, cnt in enumerate(contours):
        area = cv2.contourArea(cnt)
        perimeter = cv2.arcLength(cnt, True)

        if area < min_area or perimeter < min_perimeter:
            continue

        hull = cv2.convexHull(cnt)
        hull_area = cv2.contourArea(hull)
        solidity = area / hull_area if hull_area > 0 else 0
        if solidity < solidity_min:
            continue

        classified.append({
            "id": i,
            "contour": cnt,
            "area": area,
            "perimeter": perimeter,
            "solidity": solidity,
            "shape_type": None,  # assigned below
        })

        if area > largest_area:
            largest_area = area
            largest_idx = len(classified) - 1

    # Classify each contour
    for j, entry in enumerate(classified):
        if j == largest_idx:
            entry["shape_type"] = "room_outline"
        else:
            # perimeter^2 / area — high ratio means elongated/thin (wall-like)
            ratio = (entry["perimeter"] ** 2) / entry["area"] if entry["area"] > 0 else 0
            if ratio > 12:
                entry["shape_type"] = "wall_like"
            else:
                entry["shape_type"] = "object_like"

    return classified


def build_depth_shapes(depth_path, hex_size, debug_dir=None):
    """Extract contiguous elevated regions from depth map.
    Returns list of shapes: [{ id, polygon, area_px, centroid, depth_delta }]
    """
    depth = cv2.imread(depth_path, cv2.IMREAD_GRAYSCALE)
    if depth is None:
        return []

    h, w = depth.shape
    min_shape_area = hex_size * hex_size * 2  # minimum 2 hex areas

    # Find floor depth peak (same logic as zone_map.py)
    hist = cv2.calcHist([depth], [0], None, [256], [0, 256]).flatten()
    hist_smooth = np.convolve(hist, np.ones(11)/11, mode='same')
    floor_peak = int(np.argmax(hist_smooth[5:251]) + 5)
    floor_std = 15

    # Check confidence — skip if depth is unreliable
    total_pixels = h * w
    floor_confidence = hist_smooth[floor_peak] / total_pixels
    if floor_confidence < 0.05:
        if debug_dir:
            print(f"Depth shapes: weak signal (confidence={floor_confidence:.3f}), skipping")
        return []

    # Elevated pixels: significantly different from floor
    diff = np.abs(depth.astype(np.int16) - int(floor_peak))
    elevated_mask = (diff > floor_std * 2).astype(np.uint8) * 255

    # Clean up
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    elevated_mask = cv2.morphologyEx(elevated_mask, cv2.MORPH_OPEN, kernel)
    elevated_mask = cv2.morphologyEx(elevated_mask, cv2.MORPH_CLOSE, kernel)

    contours, _ = cv2.findContours(elevated_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

    shapes = []
    for i, cnt in enumerate(contours):
        area = cv2.contourArea(cnt)
        if area < min_shape_area:
            continue

        M = cv2.moments(cnt)
        if M['m00'] == 0:
            continue
        cx = int(M['m10'] / M['m00'])
        cy = int(M['m01'] / M['m00'])

        # Average depth delta within contour
        cnt_mask = np.zeros((h, w), np.uint8)
        cv2.drawContours(cnt_mask, [cnt], 0, 255, -1)
        region_depths = depth[cnt_mask > 0]
        avg_depth = float(np.mean(region_depths))
        depth_delta = avg_depth - floor_peak

        shapes.append({
            'id': i,
            'polygon': cnt.reshape(-1, 2).tolist(),
            'area_px': float(area),
            'centroid': [cx, cy],
            'depth_delta': float(depth_delta),
        })

    if debug_dir:
        os.makedirs(debug_dir, exist_ok=True)
        vis = np.zeros((h, w, 3), np.uint8)
        for s in shapes:
            pts = np.array(s['polygon']).reshape(-1, 1, 2)
            color = (0, 200, 0) if s['depth_delta'] > 0 else (200, 0, 0)
            cv2.drawContours(vis, [pts], 0, color, 2)
            cv2.circle(vis, tuple(s['centroid']), 5, (255, 255, 0), -1)
        cv2.imwrite(os.path.join(debug_dir, 'depth_shapes.png'), vis)
        print(f"Depth shapes: {len(shapes)} found (floor_peak={floor_peak})")

    return shapes


def main():
    if len(sys.argv) == 2 and sys.argv[1] in ("--help", "-h"):
        print(__doc__)
        sys.exit(0)

    if len(sys.argv) != 5:
        print_usage()
        sys.exit(1)

    edge_map_path = sys.argv[1]
    hex_coords_path = sys.argv[2]
    hex_size_str = sys.argv[3]
    output_path = sys.argv[4]

    # Parse hex_size
    try:
        hex_size = float(hex_size_str)
    except ValueError:
        print(f"Error: hex_size must be a number, got '{hex_size_str}'", file=sys.stderr)
        sys.exit(1)

    if hex_size <= 0:
        print(f"Error: hex_size must be positive, got {hex_size}", file=sys.stderr)
        sys.exit(1)

    # Load edge map
    edge_map = cv2.imread(edge_map_path, cv2.IMREAD_GRAYSCALE)
    if edge_map is None:
        print(f"Error: could not read image {edge_map_path}", file=sys.stderr)
        sys.exit(1)

    # Load hex coordinates
    try:
        with open(hex_coords_path, "r") as f:
            hex_coords = json.load(f)
    except FileNotFoundError:
        print(f"Error: could not read hex coords file {hex_coords_path}", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"Error: invalid JSON in {hex_coords_path}: {e}", file=sys.stderr)
        sys.exit(1)

    if not isinstance(hex_coords, list):
        print(f"Error: hex_coords_json must be an array, got {type(hex_coords).__name__}", file=sys.stderr)
        sys.exit(1)

    h, w = edge_map.shape[:2]

    # Step 1: Threshold at 128
    _, binary = cv2.threshold(edge_map, 128, 255, cv2.THRESH_BINARY)

    # Step 2: Morphological close
    kernel_size = int(hex_size * 0.3)
    if kernel_size < 3:
        kernel_size = 3
    if kernel_size % 2 == 0:
        kernel_size += 1
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (kernel_size, kernel_size))
    closed = cv2.morphologyEx(binary, cv2.MORPH_CLOSE, kernel)

    # Step 3: Find contours
    contours, hierarchy = cv2.findContours(closed, cv2.RETR_TREE, cv2.CHAIN_APPROX_SIMPLE)

    # Step 4 & 5: Filter and classify
    classified = classify_contours(contours, hierarchy, hex_size)

    # Pre-render contour masks (filled) for overlap computation
    contour_masks = []
    for entry in classified:
        mask = np.zeros((h, w), dtype=np.uint8)
        cv2.drawContours(mask, [entry["contour"]], -1, 255, thickness=cv2.FILLED)
        contour_masks.append(mask)

    # Step 6: Per-hex overlap computation
    results = {}

    for coord in hex_coords:
        if not isinstance(coord, list) or len(coord) != 4:
            continue

        hx, hy, cx, cy = coord
        key = f"{hx},{hy}"

        # Build hex polygon mask
        vertices = flat_top_hex_vertices(float(cx), float(cy), hex_size)
        hex_pts = np.array(vertices, dtype=np.int32)
        hex_mask = np.zeros((h, w), dtype=np.uint8)
        cv2.fillPoly(hex_mask, [hex_pts], 255)

        hex_area = cv2.countNonZero(hex_mask)
        if hex_area == 0:
            results[key] = {
                "inside_shape": False,
                "shape_ids": [],
                "overlap_pct": 0.0,
                "shape_type": None,
            }
            continue

        shape_ids = []
        total_overlap = 0
        dominant_type = None
        max_overlap = 0

        for j, entry in enumerate(classified):
            # AND hex mask with contour mask
            overlap_mask = cv2.bitwise_and(hex_mask, contour_masks[j])
            overlap_pixels = cv2.countNonZero(overlap_mask)
            overlap_ratio = overlap_pixels / hex_area

            # Step 7: Only count if > 5%
            if overlap_ratio > 0.05:
                shape_ids.append(entry["id"])
                total_overlap += overlap_pixels
                if overlap_pixels > max_overlap:
                    max_overlap = overlap_pixels
                    dominant_type = entry["shape_type"]

        # Cap overlap_pct at 1.0 (overlapping contours can sum > 100%)
        overlap_pct = min(total_overlap / hex_area, 1.0)

        results[key] = {
            "inside_shape": len(shape_ids) > 0,
            "shape_ids": shape_ids,
            "overlap_pct": round(overlap_pct, 4),
            "shape_type": dominant_type,
        }

    # Step 8: Write output
    with open(output_path, "w") as f:
        json.dump(results, f, indent=2)

    print(f"Processed {len(hex_coords)} hexes, {len(classified)} contours found, output written to {output_path}")


if __name__ == "__main__":
    main()
