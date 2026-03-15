#!/usr/bin/env python3
"""Pixel-level hex classification using zone map and optional depth shapes.

Loads a zone map PNG (single-channel, pixel values 0-3: 0=off_map, 1=wall,
2=floor, 3=object) and hex coordinates, then renders filled hex polygon masks
to compute precise per-hex zone overlap.

For each hex:
  1. Renders a flat-top hexagon mask at the hex's pixel center
  2. Computes pixel overlap with each zone (off_map, wall, floor, object)
  3. Assigns zone based on >50% threshold (off_map > wall > object > floor)
  4. Detects wall passthrough: wall pixels spanning >=50% of hex width/height
  5. Optionally computes overlap with depth shape contours

Usage:
  python3 hex_classify.py <zone_map.png> <hex_coords.json> <hex_size> <output.json> \
    [--depth <depth_map.png>] [--debug <debug_dir>]

  zone_map.png      - Single-channel PNG, pixel values 0-3
  hex_coords.json   - JSON array of [hx, hy, center_x_px, center_y_px]
  hex_size          - Hex size in pixels (float, circumradius)
  output.json       - Output path for per-hex classification results
  --depth           - Optional depth map for shape extraction
  --debug           - Optional directory for debug visualizations

Output JSON: { "hx,hy": { "zone": int, "wall_coverage": float,
  "wall_passthrough": float, "shape_id": int|null, "shape_overlap": float } }
"""
import argparse
import cv2
import glob
import json
import math
import numpy as np
import os
import sys


def flat_top_hex_vertices(cx, cy, size):
    """Return 6 vertices for a flat-top hexagon centered at (cx, cy)."""
    pts = []
    for i in range(6):
        angle = math.pi / 3.0 * i
        px = cx + size * math.cos(angle)
        py = cy + size * math.sin(angle)
        pts.append((px, py))
    return pts


def build_depth_shapes(depth_path, hex_size, debug_dir=None):
    """Extract object shapes from depth map using gamma-boosted Sobel + Otsu + proximity merge.

    Pipeline:
      1. Sobel gradient on raw depth detects object boundaries
      2. Gamma 0.3 boosts faint gradient values near zero (depth maps have very low contrast)
      3. Gaussian blur (5x5) suppresses noise amplified by gamma
      4. Otsu threshold — automatically picks correct cutoff on the bimodal histogram
      5. Morphological close (13x13, 2 iter) seals gaps in edge fragments
      6. Invert + connected components finds enclosed regions
      7. Filter: remove border-touching, floor-depth, and too-small regions
      8. Proximity merge: union-find merges nearby shapes (r=30px, depth_tol=20) with fill_holes

    Returns list of shapes with keys: id, contour, area_px, centroid,
    depth_delta, and the filled contour mask for overlap computation.
    """
    from scipy import ndimage as ndi

    depth = cv2.imread(depth_path, cv2.IMREAD_GRAYSCALE)
    if depth is None:
        return [], []

    h, w = depth.shape
    hex_area = (3 * math.sqrt(3) / 2) * hex_size * hex_size
    min_shape_area = max(hex_area * 2, 500)  # minimum 2 hex areas, floor at 500px

    # Find floor depth peak (dominant value in histogram)
    hist = cv2.calcHist([depth], [0], None, [256], [0, 256]).flatten()
    hist_smooth = np.convolve(hist, np.ones(11) / 11, mode='same')
    floor_peak = int(np.argmax(hist_smooth[5:251]) + 5)

    # 1. Sobel gradient on raw depth
    sx = cv2.Sobel(depth.astype(np.float32), cv2.CV_32F, 1, 0, ksize=3)
    sy = cv2.Sobel(depth.astype(np.float32), cv2.CV_32F, 0, 1, ksize=3)
    gradient = np.sqrt(sx**2 + sy**2)
    grad_max = gradient.max()
    if grad_max == 0:
        if debug_dir:
            print("Depth shapes: zero gradient (flat depth map), no shapes")
        return [], []
    grad_norm = (gradient / grad_max * 255).astype(np.uint8)

    # 2. Gamma 0.3 — boosts faint values near zero (depth gradients are typically very low)
    grad_f = grad_norm.astype(np.float64) / 255.0
    grad_gamma = (np.power(grad_f, 0.3) * 255).astype(np.uint8)

    # 3. Gaussian blur — suppresses noise amplified by gamma
    blurred = cv2.GaussianBlur(grad_gamma, (5, 5), 0)

    # 4. Otsu threshold — finds natural split in the boosted gradient histogram
    _, binary = cv2.threshold(blurred, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)

    # 5. Morphological close to seal gaps in edge fragments
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (13, 13))
    closed = cv2.morphologyEx(binary, cv2.MORPH_CLOSE, kernel, iterations=2)

    # 6. Invert + connected components with stats (for fast bbox access)
    inverted = cv2.bitwise_not(closed)
    n_labels, labels, stats, centroids = cv2.connectedComponentsWithStats(inverted)

    # 7. Filter regions into candidate shapes
    raw_shapes = []
    for i in range(1, n_labels):
        area = stats[i, cv2.CC_STAT_AREA]
        if area < min_shape_area:
            continue
        if area > h * w * 0.3:
            continue
        x0, y0 = stats[i, cv2.CC_STAT_LEFT], stats[i, cv2.CC_STAT_TOP]
        bw, bh = stats[i, cv2.CC_STAT_WIDTH], stats[i, cv2.CC_STAT_HEIGHT]
        if x0 <= 2 or y0 <= 2 or x0 + bw >= w - 3 or y0 + bh >= h - 3:
            continue
        mask = (labels == i).astype(np.uint8)
        avg_depth = float(np.mean(depth[mask > 0]))
        depth_delta = avg_depth - floor_peak
        if abs(depth_delta) < 5:
            continue
        raw_shapes.append({
            'area': area, 'mean_depth': avg_depth, 'depth_delta': depth_delta,
            'mask': mask, 'bbox': (x0, y0, bw, bh),
            'center': (int(centroids[i][0]), int(centroids[i][1])),
        })

    if not raw_shapes:
        if debug_dir:
            print(f"Depth shapes: 0 found after filtering (floor_peak={floor_peak})")
        return [], []

    # 8. Proximity merge — union-find groups nearby shapes with similar depth
    MERGE_RADIUS = 30
    DEPTH_TOL = 20
    n = len(raw_shapes)
    parent = list(range(n))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[ra] = rb

    expanded = []
    for s in raw_shapes:
        x0, y0, bw, bh = s['bbox']
        expanded.append((
            max(0, x0 - MERGE_RADIUS), max(0, y0 - MERGE_RADIUS),
            min(w, x0 + bw + MERGE_RADIUS), min(h, y0 + bh + MERGE_RADIUS)
        ))

    dk = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (MERGE_RADIUS * 2 + 1, MERGE_RADIUS * 2 + 1))
    for i in range(n):
        for j in range(i + 1, n):
            if abs(raw_shapes[i]['mean_depth'] - raw_shapes[j]['mean_depth']) > DEPTH_TOL:
                continue
            ix0, iy0, ix1, iy1 = expanded[i]
            jx0, jy0, jx1, jy1 = expanded[j]
            if ix1 < jx0 or jx1 < ix0 or iy1 < jy0 or jy1 < iy0:
                continue
            rx0, ry0 = max(ix0, jx0), max(iy0, jy0)
            rx1, ry1 = min(ix1, jx1), min(iy1, jy1)
            if ry1 <= ry0 or rx1 <= rx0:
                continue
            ci = raw_shapes[i]['mask'][ry0:ry1, rx0:rx1]
            cj = raw_shapes[j]['mask'][ry0:ry1, rx0:rx1]
            if ci.size == 0 or cj.size == 0:
                continue
            if np.any(cv2.bitwise_and(cv2.dilate(ci, dk), cv2.dilate(cj, dk)) > 0):
                union(i, j)

    groups = {}
    for i in range(n):
        groups.setdefault(find(i), []).append(i)

    shapes = []
    shape_masks = []
    for indices in groups.values():
        combined = np.zeros((h, w), np.uint8)
        for idx in indices:
            combined = cv2.bitwise_or(combined, raw_shapes[idx]['mask'])
        filled = ndi.binary_fill_holes(combined > 0).astype(np.uint8) * 255
        area = int(np.sum(filled > 0))
        if area < min_shape_area:
            continue
        avg_depth = float(np.mean(depth[filled > 0]))
        depth_delta = avg_depth - floor_peak
        M = cv2.moments(filled)
        if M['m00'] == 0:
            continue
        cx = int(M['m10'] / M['m00'])
        cy = int(M['m01'] / M['m00'])
        contours, _ = cv2.findContours(filled, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        if not contours:
            continue
        cnt = max(contours, key=cv2.contourArea)
        shapes.append({
            'id': len(shapes),
            'contour': cnt,
            'area_px': float(area),
            'centroid': [cx, cy],
            'depth_delta': float(depth_delta),
        })
        shape_masks.append(filled)

    if debug_dir:
        os.makedirs(debug_dir, exist_ok=True)
        cv2.imwrite(os.path.join(debug_dir, 'depth_gradient.png'), grad_norm)
        cv2.imwrite(os.path.join(debug_dir, 'depth_gamma.png'), grad_gamma)
        cv2.imwrite(os.path.join(debug_dir, 'depth_edges_closed.png'), closed)
        vis = np.zeros((h, w, 3), np.uint8)
        for s in shapes:
            color = (0, 200, 0) if s['depth_delta'] > 0 else (200, 0, 0)
            cv2.drawContours(vis, [s['contour']], 0, color, 2)
            cv2.circle(vis, tuple(s['centroid']), 5, (255, 255, 0), -1)
        cv2.imwrite(os.path.join(debug_dir, 'depth_shapes.png'), vis)
        print(f"Depth shapes: {len(shapes)} found (floor_peak={floor_peak}, "
              f"raw={len(raw_shapes)}, merged={len(shapes)})")

    return shapes, shape_masks


def build_image_shapes(image_path, hex_size, debug_dir=None):
    """Extract visual shapes from raw image using bilateral-denoised Sobel edges.

    Pipeline: bilateral d=7 → Sobel → Otsu → close(9x9) → components → filter
    Used for flat hex types (water, fire, etc.) with no depth signal.
    """
    img = cv2.imread(image_path)
    if img is None:
        return [], []
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    h, w = gray.shape
    hex_area = (3 * math.sqrt(3) / 2) * hex_size * hex_size
    min_shape_area = max(hex_area * 2, 500)

    denoised = cv2.bilateralFilter(gray, 7, 75, 75)
    sx = cv2.Sobel(denoised.astype(np.float32), cv2.CV_32F, 1, 0, ksize=3)
    sy = cv2.Sobel(denoised.astype(np.float32), cv2.CV_32F, 0, 1, ksize=3)
    gradient = np.sqrt(sx**2 + sy**2)
    grad_max = gradient.max()
    if grad_max == 0:
        return [], []
    grad_norm = (gradient / grad_max * 255).astype(np.uint8)

    _, binary = cv2.threshold(grad_norm, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (9, 9))
    closed = cv2.morphologyEx(binary, cv2.MORPH_CLOSE, kernel, iterations=2)

    inverted = cv2.bitwise_not(closed)
    n_labels, labels, stats, centroids = cv2.connectedComponentsWithStats(inverted)

    shapes, shape_masks = [], []
    for i in range(1, n_labels):
        area = stats[i, cv2.CC_STAT_AREA]
        if area < min_shape_area or area > h * w * 0.4:
            continue
        x0, y0 = stats[i, cv2.CC_STAT_LEFT], stats[i, cv2.CC_STAT_TOP]
        bw, bh = stats[i, cv2.CC_STAT_WIDTH], stats[i, cv2.CC_STAT_HEIGHT]
        if x0 <= 2 or y0 <= 2 or x0 + bw >= w - 3 or y0 + bh >= h - 3:
            continue
        mask = (labels == i).astype(np.uint8) * 255
        shapes.append({'id': len(shapes), 'area_px': float(area),
                       'centroid': [int(centroids[i][0]), int(centroids[i][1])]})
        shape_masks.append(mask)

    if debug_dir:
        os.makedirs(debug_dir, exist_ok=True)
        cv2.imwrite(os.path.join(debug_dir, 'image_shapes_edges.png'), closed)
        print(f"Image shapes: {len(shapes)} found")

    return shapes, shape_masks


def build_sam2_shapes(masks_dir, hex_size, depth_path=None, debug_dir=None):
    """Load pre-downloaded SAM2 individual mask PNGs and split into raised/flat shapes.

    Raised shapes (depth_delta >= 5 vs floor peak) → replace depth shapes.
    Flat shapes (depth_delta < 5, or no depth available) → replace image shapes.

    Returns four lists: raised_shapes, raised_masks, flat_shapes, flat_masks.
    Each shape dict has keys: id, area_px, centroid (and depth_delta for raised).
    """
    mask_paths = sorted(glob.glob(os.path.join(masks_dir, 'mask_*.png')))
    if not mask_paths:
        if debug_dir:
            print(f"SAM2 shapes: no mask files in {masks_dir}")
        return [], [], [], []

    min_area = 1000  # flat noise floor — keep small objects like barrels and chairs

    # Load raw depth map and compute floor peak from its histogram.
    # Classification uses the 90th percentile of depth within each mask vs floor_peak —
    # P90 catches objects where the top of the surface is clearly raised even when mask
    # boundaries drag the median down. threshold=8 on raw depth (no gamma needed).
    depth = None
    floor_peak = None
    if depth_path and os.path.exists(depth_path):
        depth = cv2.imread(depth_path, cv2.IMREAD_GRAYSCALE)
        if depth is not None:
            hist = cv2.calcHist([depth], [0], None, [256], [0, 256]).flatten()
            hist_smooth = np.convolve(hist, np.ones(11) / 11, mode='same')
            floor_peak = int(np.argmax(hist_smooth[5:251]) + 5)

    raised_shapes, raised_masks = [], []
    flat_shapes, flat_masks = [], []

    for mask_path in mask_paths:
        binary = cv2.imread(mask_path, cv2.IMREAD_GRAYSCALE)
        if binary is None:
            continue
        # Ensure truly binary (SAM2 masks should already be 0/255)
        _, binary = cv2.threshold(binary, 127, 255, cv2.THRESH_BINARY)

        area = int(cv2.countNonZero(binary))
        h, w = binary.shape
        if area < min_area or area > h * w * 0.4:
            continue

        # Compute centroid
        M = cv2.moments(binary)
        if M['m00'] == 0:
            continue
        cx = int(M['m10'] / M['m00'])
        cy = int(M['m01'] / M['m00'])

        # Classify raised vs flat using P90 of depth within the mask.
        # P90 catches objects where the peak surface depth is clearly above floor
        # even when mask boundaries drag the median/mean down.
        depth_delta = 0.0
        is_raised = False
        if depth is not None and floor_peak is not None:
            dh, dw = depth.shape[:2]
            if (dh, dw) != (h, w):
                depth_resized = cv2.resize(depth, (w, h), interpolation=cv2.INTER_LINEAR)
            else:
                depth_resized = depth
            p90 = float(np.percentile(depth_resized[binary > 0], 90))
            depth_delta = p90 - floor_peak
            is_raised = depth_delta >= 8

        if is_raised:
            shape_id = len(raised_shapes)
            contours, _ = cv2.findContours(binary, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
            cnt = max(contours, key=cv2.contourArea) if contours else None
            raised_shapes.append({
                'id': shape_id, 'area_px': float(area), 'centroid': [cx, cy],
                'depth_delta': float(depth_delta), 'contour': cnt,
            })
            raised_masks.append(binary)
        else:
            flat_shapes.append({
                'id': len(flat_shapes), 'area_px': float(area), 'centroid': [cx, cy],
            })
            flat_masks.append(binary)

    if debug_dir:
        os.makedirs(debug_dir, exist_ok=True)
        print(f"SAM2 shapes: {len(raised_shapes)} raised, {len(flat_shapes)} flat "
              f"(floor_peak={floor_peak}, {len(mask_paths)} masks loaded)")

        # Build depth_shapes.png: raised=green filled, flat=blue filled, depth value labeled
        ref_mask = (raised_masks or flat_masks or [None])[0]
        if ref_mask is not None:
            h, w = ref_mask.shape[:2]
            vis = np.zeros((h, w, 3), np.uint8)
            # Draw flat shapes in blue (dim)
            for s, m in zip(flat_shapes, flat_masks):
                m2 = cv2.resize(m, (w, h), interpolation=cv2.INTER_NEAREST) if m.shape[:2] != (h, w) else m
                vis[m2 > 0] = np.maximum(vis[m2 > 0], [60, 30, 0])
                cv2.circle(vis, tuple(s['centroid']), 4, (100, 60, 0), -1)
            # Draw raised shapes in green, intensity = depth_delta magnitude
            max_delta = max((abs(s['depth_delta']) for s in raised_shapes), default=1.0)
            for s, m in zip(raised_shapes, raised_masks):
                m2 = cv2.resize(m, (w, h), interpolation=cv2.INTER_NEAREST) if m.shape[:2] != (h, w) else m
                intensity = int(min(255, 80 + 175 * abs(s['depth_delta']) / max(max_delta, 1)))
                color = (0, intensity, 0)
                vis[m2 > 0] = np.maximum(vis[m2 > 0], color)
            # Label raised shapes with their depth_delta
            for s in raised_shapes:
                cx, cy = s['centroid']
                label = f"{s['depth_delta']:+.0f}"
                cv2.putText(vis, label, (cx - 12, cy + 4),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.35, (255, 255, 100), 1)
            cv2.imwrite(os.path.join(debug_dir, 'depth_shapes.png'), vis)

    return raised_shapes, raised_masks, flat_shapes, flat_masks


def compute_wall_passthrough(hex_mask, wall_mask_in_hex, hex_pts, hex_area):
    """Detect if wall pixels span across the hex even if <50% area.

    Projects wall pixels onto the hex's major axes (horizontal and vertical)
    and checks if wall spans >=50% of the hex extent on either axis.

    Returns the maximum span ratio (0.0 - 1.0).
    """
    if hex_area == 0:
        return 0.0

    # Find bounding box of the hex polygon
    x_coords = hex_pts[:, 0]
    y_coords = hex_pts[:, 1]
    hex_min_x = int(np.min(x_coords))
    hex_max_x = int(np.max(x_coords))
    hex_min_y = int(np.min(y_coords))
    hex_max_y = int(np.max(y_coords))

    hex_width = max(hex_max_x - hex_min_x, 1)
    hex_height = max(hex_max_y - hex_min_y, 1)

    # Compute wall pixels within hex
    wall_in_hex = cv2.bitwise_and(hex_mask, wall_mask_in_hex)
    wall_coords = np.where(wall_in_hex > 0)
    if len(wall_coords[0]) == 0:
        return 0.0

    wall_ys = wall_coords[0]
    wall_xs = wall_coords[1]

    # Horizontal span: range of x coordinates with wall pixels
    x_span = (int(np.max(wall_xs)) - int(np.min(wall_xs))) / hex_width if hex_width > 0 else 0.0
    # Vertical span: range of y coordinates with wall pixels
    y_span = (int(np.max(wall_ys)) - int(np.min(wall_ys))) / hex_height if hex_height > 0 else 0.0

    return max(x_span, y_span)


def classify_hexes(zone_map, hex_coords, hex_size, shapes=None, shape_masks=None,
                   image_shapes=None, image_shape_masks=None):
    """Classify each hex by computing pixel overlap with zone map and depth shapes.

    Args:
        zone_map: Single-channel image, pixel values 0-3
        hex_coords: List of [hx, hy, center_x_px, center_y_px]
        hex_size: Hex circumradius in pixels
        shapes: Optional list of depth shape dicts
        shape_masks: Optional list of filled contour masks for shapes
        image_shapes: Optional list of image shape dicts (flat/depthless types)
        image_shape_masks: Optional list of masks for image shapes

    Returns:
        Dict of "hx,hy" -> classification result
    """
    h, w = zone_map.shape[:2]

    # Pre-build zone masks (binary masks for each zone value)
    zone_masks = {}
    for zone_id in [0, 1, 3]:
        zone_masks[zone_id] = (zone_map == zone_id).astype(np.uint8) * 255

    # Pre-resize all shape masks to zone_map dimensions once (avoid per-hex resize)
    if shape_masks:
        shape_masks = [
            cv2.resize(m, (w, h), interpolation=cv2.INTER_NEAREST) if m.shape[:2] != (h, w) else m
            for m in shape_masks
        ]
    if image_shape_masks:
        image_shape_masks = [
            cv2.resize(m, (w, h), interpolation=cv2.INTER_NEAREST) if m.shape[:2] != (h, w) else m
            for m in image_shape_masks
        ]

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
                "zone": 0,
                "wall_coverage": 0.0,
                "wall_passthrough": 0.0,
                "shape_id": None,
                "shape_overlap": 0.0,
            }
            continue

        # Compute overlap with each zone
        zone_overlaps = {}
        for zone_id in [0, 1, 3]:
            overlap = cv2.bitwise_and(hex_mask, zone_masks[zone_id])
            overlap_pixels = cv2.countNonZero(overlap)
            zone_overlaps[zone_id] = overlap_pixels / hex_area

        # Wall coverage is always recorded
        wall_coverage = zone_overlaps.get(1, 0.0)

        # Wall passthrough detection
        wall_passthrough = 0.0
        if wall_coverage > 0.0:
            wall_passthrough = compute_wall_passthrough(
                hex_mask, zone_masks[1], hex_pts, hex_area
            )

        # Zone assignment: priority off_map(0) > wall(1) > object(3) > floor(2)
        # Use >50% threshold; wall_passthrough can also promote to wall
        assigned_zone = 2  # default = floor
        if zone_overlaps[0] > 0.5:
            assigned_zone = 0
        elif zone_overlaps[1] > 0.5 or wall_passthrough >= 0.5:
            assigned_zone = 1
        elif zone_overlaps[3] > 0.5:
            assigned_zone = 3
        # else: no zone exceeds 50%, default floor (zone 2) stands

        # Depth shape overlap
        best_shape_id = None
        best_shape_overlap = 0.0
        if shapes and shape_masks:
            for s, smask in zip(shapes, shape_masks):
                overlap = cv2.bitwise_and(hex_mask, smask)
                overlap_pixels = cv2.countNonZero(overlap)
                overlap_pct = overlap_pixels / hex_area
                if overlap_pct > best_shape_overlap:
                    best_shape_overlap = overlap_pct
                    best_shape_id = s['id']

        if best_shape_overlap > 0.5:
            if assigned_zone == 2:  # depth shapes promote floor to object
                assigned_zone = 3

        # Image shape overlap (for flat/depthless types)
        best_image_shape_id = None
        best_image_overlap = 0.0
        if image_shapes and image_shape_masks:
            for s, smask in zip(image_shapes, image_shape_masks):
                overlap_pct = cv2.countNonZero(cv2.bitwise_and(hex_mask, smask)) / hex_area
                if overlap_pct > best_image_overlap:
                    best_image_overlap = overlap_pct
                    best_image_shape_id = s['id']

        results[key] = {
            "zone": assigned_zone,
            "wall_coverage": round(wall_coverage, 4),
            "wall_passthrough": round(wall_passthrough, 4),
            "shape_id": best_shape_id if best_shape_overlap > 0.5 else None,
            "shape_overlap": round(best_shape_overlap, 4) if best_shape_overlap > 0.5 else 0.0,
            "image_shape_id": best_image_shape_id if best_image_overlap > 0.2 else None,
        }

    return results


def write_debug_output(zone_map, hex_coords, hex_size, results, debug_dir, shapes=None):
    """Write debug visualizations: hex overlay colored by assigned zone."""
    os.makedirs(debug_dir, exist_ok=True)
    h, w = zone_map.shape[:2]

    # Zone colors (BGR)
    zone_colors = {
        0: (40, 40, 40),       # off_map = dark gray
        1: (0, 0, 200),        # wall = red
        2: (200, 200, 150),    # floor = light tan
        3: (0, 180, 0),        # object = green
    }

    # Start with the zone map colorized as background
    overlay = np.zeros((h, w, 3), dtype=np.uint8)
    for zone_id, color in zone_colors.items():
        overlay[zone_map == zone_id] = color

    # Draw filled hex polygons with transparency
    hex_layer = overlay.copy()
    for coord in hex_coords:
        if not isinstance(coord, list) or len(coord) != 4:
            continue
        hx, hy, cx, cy = coord
        key = f"{hx},{hy}"
        if key not in results:
            continue

        zone = results[key]["zone"]
        vertices = flat_top_hex_vertices(float(cx), float(cy), hex_size)
        hex_pts = np.array(vertices, dtype=np.int32)
        color = zone_colors.get(zone, (128, 128, 128))
        cv2.fillPoly(hex_layer, [hex_pts], color)
        # Draw hex outline
        cv2.polylines(hex_layer, [hex_pts], True, (255, 255, 255), 1)

    # Blend 60% hex layer, 40% background
    blended = cv2.addWeighted(hex_layer, 0.6, overlay, 0.4, 0)
    cv2.imwrite(os.path.join(debug_dir, 'hex_classify_overlay.png'), blended)

    # Print zone distribution stats
    zone_names = {0: 'off_map', 1: 'wall', 2: 'floor', 3: 'object'}
    zone_counts = {0: 0, 1: 0, 2: 0, 3: 0}
    for r in results.values():
        zone_counts[r["zone"]] = zone_counts.get(r["zone"], 0) + 1

    total = len(results)
    print(f"\nHex classification results ({total} hexes):")
    for zone_id in [0, 1, 2, 3]:
        count = zone_counts[zone_id]
        pct = count / total * 100 if total > 0 else 0
        print(f"  {zone_names[zone_id]}: {count} hexes ({pct:.1f}%)")

    # Wall passthrough stats
    passthrough_hexes = sum(1 for r in results.values()
                           if r["wall_passthrough"] >= 0.5 and r["zone"] == 1
                           and r["wall_coverage"] <= 0.5)
    if passthrough_hexes > 0:
        print(f"  wall (via passthrough): {passthrough_hexes} hexes promoted")

    # Shape overlap stats
    if shapes:
        shape_hexes = sum(1 for r in results.values() if r["shape_id"] is not None)
        print(f"  hexes overlapping depth shapes: {shape_hexes}")


def parse_args():
    parser = argparse.ArgumentParser(
        description='Pixel-level hex classification using zone map and optional depth shapes.',
        usage='%(prog)s <zone_map.png> <hex_coords.json> <hex_size> <output.json> '
              '[--depth <depth_map.png>] [--debug <debug_dir>]'
    )
    parser.add_argument('zone_map', help='Single-channel zone map PNG (pixel values 0-3)')
    parser.add_argument('hex_coords', help='JSON file: array of [hx, hy, center_x_px, center_y_px]')
    parser.add_argument('hex_size', type=float, help='Hex circumradius in pixels')
    parser.add_argument('output', help='Output JSON path')
    parser.add_argument('--depth', help='Optional depth map PNG for shape extraction')
    parser.add_argument('--image', help='Raw image path for flat shape detection')
    parser.add_argument('--sam2-masks-dir', dest='sam2_masks_dir',
                        help='Directory of SAM2 individual mask PNGs (replaces --depth and --image shapes)')
    parser.add_argument('--debug', help='Optional directory for debug visualizations')
    return parser.parse_args()


def main():
    args = parse_args()

    if args.hex_size <= 0:
        print(f"Error: hex_size must be positive, got {args.hex_size}", file=sys.stderr)
        sys.exit(1)

    # Load zone map
    zone_map = cv2.imread(args.zone_map, cv2.IMREAD_GRAYSCALE)
    if zone_map is None:
        print(f"Error: could not read zone map {args.zone_map}", file=sys.stderr)
        sys.exit(1)

    # Load hex coordinates
    try:
        with open(args.hex_coords, 'r') as f:
            hex_coords = json.load(f)
    except FileNotFoundError:
        print(f"Error: could not read hex coords file {args.hex_coords}", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"Error: invalid JSON in {args.hex_coords}: {e}", file=sys.stderr)
        sys.exit(1)

    if not isinstance(hex_coords, list):
        print(f"Error: hex_coords must be an array, got {type(hex_coords).__name__}", file=sys.stderr)
        sys.exit(1)

    # SAM2 masks take priority: they replace both depth shapes and image shapes
    shapes = []
    shape_masks = []
    image_shapes, image_shape_masks = [], []

    if args.sam2_masks_dir and os.path.isdir(args.sam2_masks_dir):
        shapes, shape_masks, image_shapes, image_shape_masks = build_sam2_shapes(
            args.sam2_masks_dir, args.hex_size,
            depth_path=args.depth, debug_dir=args.debug
        )
    else:
        # Fallback: depth shapes + bilateral/Sobel image shapes
        if args.depth:
            shapes, shape_masks = build_depth_shapes(
                args.depth, args.hex_size, debug_dir=args.debug
            )
        if args.image and os.path.exists(args.image):
            image_shapes, image_shape_masks = build_image_shapes(
                args.image, args.hex_size, debug_dir=args.debug
            )

    # Classify hexes
    results = classify_hexes(zone_map, hex_coords, args.hex_size, shapes, shape_masks,
                             image_shapes=image_shapes, image_shape_masks=image_shape_masks)

    # Write output
    with open(args.output, 'w') as f:
        json.dump(results, f, indent=2)

    image_shape_ids = [v['image_shape_id'] for v in results.values() if v.get('image_shape_id') is not None]
    print(f"Classified {len(results)} hexes, output written to {args.output}")
    print(f"  depth shapes: {len(shapes)}, image shapes: {len(image_shapes)}, hexes with image_shape_id: {len(image_shape_ids)}")

    # Debug output
    if args.debug:
        write_debug_output(zone_map, hex_coords, args.hex_size, results, args.debug, shapes)


if __name__ == '__main__':
    main()
