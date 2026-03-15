#!/usr/bin/env python3
"""
Build a pixel-level zone map from depth map + edge map.

Zones:
  0 = off_map (outside room boundary)
  1 = wall (structural boundary band)
  2 = floor (room interior, ground level)
  3 = object (elevated area inside room — furniture, etc.)

Algorithm:
  1. Compute depth gradient (Sobel on depth) → depth edges
  2. Combine depth edges with visual edge map → structural boundaries
  3. Flood fill from image border through non-boundary, non-wall-depth pixels → off_map
  4. Dilate off_map boundary inward → wall zone (the transition band)
  5. Remaining interior: high depth = object, low depth = floor

Usage:
  python3 zone_map.py <depth_map.png> <edge_map.png> <output_zone.png> [--debug <debug_dir>]

Output is a single-channel PNG where pixel values are zone IDs (0-3).
"""

import cv2
import numpy as np
import sys
import os

# If the histogram valley between floor peak and depth=200 stays above this
# fraction of the peak height, the depth signal lacks clear floor/object
# separation and we fall back to edge-only zone detection.
DEPTH_FLOOR_CONFIDENCE = 0.05


def _build_zone_map_edge_only(combined_boundary: np.ndarray, kernel_small: np.ndarray, h: int, w: int, debug_dir: str | None = None) -> np.ndarray:
    """Build zone map using edges only (no depth-based classification).

    Used as fallback when the depth histogram has no clear floor mode,
    e.g. noisy depth maps from stylized/sci-fi scenes.

    Zones produced: 0=off_map, 1=wall, 2=floor (no object zone).
    """
    # Passable = not on a structural boundary edge
    is_boundary = (combined_boundary > 128).astype(np.uint8)
    passable = (1 - is_boundary) * 255
    passable = passable.astype(np.uint8)

    # Find connected components of passable pixels
    num_labels, labels = cv2.connectedComponents(passable)

    # Border mask: pixels on image edges
    border_mask = np.zeros((h, w), np.uint8)
    border_mask[0, :] = 255
    border_mask[-1, :] = 255
    border_mask[:, 0] = 255
    border_mask[:, -1] = 255

    # Mark border-touching components as off_map
    border_labels = set(np.unique(labels[border_mask > 0]))
    border_labels.discard(0)  # 0 = background (boundary pixels)

    off_map = np.zeros((h, w), np.uint8)
    for label in border_labels:
        off_map[labels == label] = 255

    # Wall = dilated boundary band between off_map and interior
    kernel_grow = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7))
    off_map_dilated = cv2.dilate(off_map, kernel_grow, iterations=2)
    wall_band = cv2.subtract(off_map_dilated, off_map)
    # Also include actual boundary pixels near off_map
    boundary_pixels = is_boundary * 255
    boundary_near_offmap = cv2.bitwise_and(
        boundary_pixels,
        cv2.dilate(off_map, kernel_small, iterations=3)
    )
    wall_zone = cv2.bitwise_or(wall_band, boundary_near_offmap)

    # Assemble: everything else = floor (zone 2)
    zone_map = np.full((h, w), 2, dtype=np.uint8)
    zone_map[off_map > 0] = 0
    zone_map[wall_zone > 0] = 1

    # Debug output
    if debug_dir:
        os.makedirs(debug_dir, exist_ok=True)
        cv2.imwrite(os.path.join(debug_dir, 'zone_combined_boundary.png'), combined_boundary)
        cv2.imwrite(os.path.join(debug_dir, 'zone_off_map.png'), off_map)
        cv2.imwrite(os.path.join(debug_dir, 'zone_wall.png'), wall_zone)

        color_map = np.zeros((h, w, 3), dtype=np.uint8)
        color_map[zone_map == 0] = [40, 40, 40]      # off_map = dark gray
        color_map[zone_map == 1] = [0, 0, 200]        # wall = red
        color_map[zone_map == 2] = [200, 200, 150]    # floor = light tan
        cv2.imwrite(os.path.join(debug_dir, 'zone_colorized.png'), color_map)

        total = h * w
        for zone_id, name in [(0, 'off_map'), (1, 'wall'), (2, 'floor'), (3, 'object')]:
            count = np.sum(zone_map == zone_id)
            print(f"  {name}: {count} px ({count/total*100:.1f}%)")

    return zone_map


def build_zone_map(depth_path: str, edge_path: str, debug_dir: str | None = None) -> np.ndarray:
    depth = cv2.imread(depth_path, cv2.IMREAD_GRAYSCALE)
    edges = cv2.imread(edge_path, cv2.IMREAD_GRAYSCALE)

    if depth is None:
        raise ValueError(f"Could not read depth map: {depth_path}")
    if edges is None:
        raise ValueError(f"Could not read edge map: {edge_path}")

    h, w = depth.shape

    # Resize edge map to match depth if needed
    if edges.shape != depth.shape:
        edges = cv2.resize(edges, (w, h), interpolation=cv2.INTER_LINEAR)

    # --- Step 1: Depth gradient (structural edges from depth discontinuities) ---
    depth_blur = cv2.GaussianBlur(depth, (5, 5), 0)
    grad_x = cv2.Sobel(depth_blur, cv2.CV_64F, 1, 0, ksize=3)
    grad_y = cv2.Sobel(depth_blur, cv2.CV_64F, 0, 1, ksize=3)
    depth_gradient = np.sqrt(grad_x**2 + grad_y**2)
    depth_gradient = np.clip(depth_gradient / depth_gradient.max() * 255, 0, 255).astype(np.uint8)

    # Threshold depth gradient -> depth edges
    _, depth_edges = cv2.threshold(depth_gradient, 30, 255, cv2.THRESH_BINARY)

    # --- Step 2: Combine depth edges with visual edges -> structural boundaries ---
    kernel_small = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
    depth_edges_dilated = cv2.dilate(depth_edges, kernel_small, iterations=1)
    combined_boundary = cv2.bitwise_or(depth_edges_dilated, edges)

    # Clean up: close small gaps in the boundary
    kernel_close = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    combined_boundary = cv2.morphologyEx(combined_boundary, cv2.MORPH_CLOSE, kernel_close)

    # --- Step 3: Determine floor depth baseline ---
    hist = cv2.calcHist([depth], [0], None, [256], [0, 256]).flatten()
    hist_smooth = np.convolve(hist, np.ones(11)/11, mode='same')
    floor_peak = int(np.argmax(hist_smooth[5:251]) + 5)
    floor_std = 15

    # --- Depth confidence check ---
    search_start = min(floor_peak + floor_std, 200)
    if search_start < 200 and hist_smooth[floor_peak] > 0:
        valley_min = np.min(hist_smooth[search_start:200])
        valley_ratio = valley_min / hist_smooth[floor_peak]
    else:
        valley_ratio = 0.0

    if valley_ratio > DEPTH_FLOOR_CONFIDENCE:
        print(f"WARNING: Weak depth signal (valley_ratio={valley_ratio:.3f} > {DEPTH_FLOOR_CONFIDENCE},"
              f" floor_peak={floor_peak}). Falling back to edge-only zone detection.")
        return _build_zone_map_edge_only(combined_boundary, kernel_small, h, w, debug_dir=debug_dir)

    # Object threshold via Otsu
    interior_mask = depth > 3
    if np.sum(interior_mask) > 100:
        otsu_thresh, _ = cv2.threshold(depth[interior_mask].reshape(-1, 1).astype(np.uint8),
                                        0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
        otsu_thresh = int(otsu_thresh)
    else:
        otsu_thresh = floor_peak + 30

    if otsu_thresh >= floor_peak:
        object_depth_thresh = max(otsu_thresh, floor_peak + 30)
        depth_inverted = False
    else:
        object_depth_thresh = min(otsu_thresh, floor_peak - 30)
        depth_inverted = True

    # --- Step 4: Flood fill from border -> off_map ---
    flood_mask = np.zeros((h + 2, w + 2), np.uint8)

    is_boundary = combined_boundary > 128

    # Passable = not on a structural boundary edge.
    # We do NOT exclude floor-depth pixels here: exterior areas often have depth
    # values similar to the room floor (depth models are relative), which would
    # block the border flood fill from detecting the exterior as off_map at all.
    # Room walls form a strong closed boundary ring that stops the fill.
    passable = (~is_boundary).astype(np.uint8) * 255

    off_map = np.zeros((h, w), np.uint8)
    border_mask = np.zeros((h, w), np.uint8)
    border_mask[0, :] = 255
    border_mask[-1, :] = 255
    border_mask[:, 0] = 255
    border_mask[:, -1] = 255

    num_labels, labels = cv2.connectedComponents(passable)
    border_labels = set(np.unique(labels[border_mask > 0]))
    border_labels.discard(0)

    for label in border_labels:
        off_map[labels == label] = 255

    # Extend into wall-depth border regions
    kernel_grow = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7))
    off_map_grown = cv2.dilate(off_map, kernel_grow, iterations=3)
    if depth_inverted:
        wall_depth_pixels = (depth < object_depth_thresh).astype(np.uint8) * 255
    else:
        wall_depth_pixels = (depth > object_depth_thresh).astype(np.uint8) * 255
    off_map_extension = cv2.bitwise_and(off_map_grown, wall_depth_pixels)
    num_ext, ext_labels = cv2.connectedComponents(off_map_extension)
    existing_off_labels = set(np.unique(ext_labels[off_map > 0]))
    existing_off_labels.discard(0)
    for label in existing_off_labels:
        off_map[ext_labels == label] = 255

    # --- Step 5: Wall zone = band within wall_proximity of off_map ---
    # Use distance transform so coverage scales with wall thickness regardless
    # of pixel dimensions. Walls sit between the off_map exterior and the room
    # interior, and can be 50-150px thick — fixed small dilation (iterations=2)
    # never reached them. wall_proximity = ~5% of the larger image dimension.
    not_offmap = cv2.bitwise_not(off_map)
    dist_from_offmap = cv2.distanceTransform(not_offmap, cv2.DIST_L2, 5)
    wall_proximity_px = max(h, w) // 20  # ~5% of image — covers thick walls
    wall_candidate = ((dist_from_offmap > 0) & (dist_from_offmap < wall_proximity_px)).astype(np.uint8) * 255
    boundary_pixels = (combined_boundary > 128).astype(np.uint8) * 255
    boundary_near_offmap = cv2.bitwise_and(
        boundary_pixels,
        (dist_from_offmap < wall_proximity_px * 2).astype(np.uint8) * 255
    )
    wall_zone = cv2.bitwise_or(wall_candidate, boundary_near_offmap)

    # --- Step 6: Object detection = elevated interior pixels ---
    interior = cv2.bitwise_not(cv2.bitwise_or(off_map, wall_zone))
    if depth_inverted:
        elevated = (depth < object_depth_thresh).astype(np.uint8) * 255
    else:
        elevated = (depth > object_depth_thresh).astype(np.uint8) * 255
    object_zone = cv2.bitwise_and(interior, elevated)

    kernel_obj = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    object_zone = cv2.morphologyEx(object_zone, cv2.MORPH_OPEN, kernel_obj)
    object_zone = cv2.morphologyEx(object_zone, cv2.MORPH_CLOSE, kernel_obj)

    # --- Step 7: Assemble zone map ---
    zone_map = np.full((h, w), 2, dtype=np.uint8)  # default = floor
    zone_map[off_map > 0] = 0       # off_map
    zone_map[wall_zone > 0] = 1     # wall
    zone_map[object_zone > 0] = 3   # object (overrides wall if overlapping)

    # --- Debug output ---
    if debug_dir:
        os.makedirs(debug_dir, exist_ok=True)
        cv2.imwrite(os.path.join(debug_dir, 'zone_depth_gradient.png'), depth_gradient)
        cv2.imwrite(os.path.join(debug_dir, 'zone_depth_edges.png'), depth_edges)
        cv2.imwrite(os.path.join(debug_dir, 'zone_combined_boundary.png'), combined_boundary)
        cv2.imwrite(os.path.join(debug_dir, 'zone_off_map.png'), off_map)
        cv2.imwrite(os.path.join(debug_dir, 'zone_wall.png'), wall_zone)
        cv2.imwrite(os.path.join(debug_dir, 'zone_object.png'), object_zone)

        color_map = np.zeros((h, w, 3), dtype=np.uint8)
        color_map[zone_map == 0] = [40, 40, 40]     # off_map = dark gray
        color_map[zone_map == 1] = [0, 0, 200]       # wall = red
        color_map[zone_map == 2] = [200, 200, 150]   # floor = light tan
        color_map[zone_map == 3] = [0, 180, 0]       # object = green
        cv2.imwrite(os.path.join(debug_dir, 'zone_colorized.png'), color_map)

        print(f"Floor depth peak: {floor_peak}, threshold: +/-{floor_std}")
        print(f"Otsu threshold: {otsu_thresh}, object depth threshold: {object_depth_thresh}")
        total = h * w
        for zone_id, name in [(0, 'off_map'), (1, 'wall'), (2, 'floor'), (3, 'object')]:
            count = np.sum(zone_map == zone_id)
            print(f"  {name}: {count} px ({count/total*100:.1f}%)")

    return zone_map


if __name__ == '__main__':
    if len(sys.argv) < 4:
        print("Usage: zone_map.py <depth.png> <edges.png> <output.png> [--debug <dir>]")
        sys.exit(1)

    depth_path = sys.argv[1]
    edge_path = sys.argv[2]
    output_path = sys.argv[3]

    debug_dir = None
    if '--debug' in sys.argv:
        idx = sys.argv.index('--debug')
        if idx + 1 < len(sys.argv):
            debug_dir = sys.argv[idx + 1]

    zone_map = build_zone_map(depth_path, edge_path, debug_dir=debug_dir)
    cv2.imwrite(output_path, zone_map)
    print(f"Zone map written to {output_path} ({zone_map.shape[1]}x{zone_map.shape[0]})")
