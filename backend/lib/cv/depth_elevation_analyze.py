#!/usr/bin/env python3
"""Depth-based elevation analysis for battlemap hex grids.

Clusters depth values at hex centers into discrete elevation bands using
k-means, calibrates using stair/ladder anchor positions, and outputs
per-hex elevation assignments.

Inputs:
  --depth-map    Grayscale depth image (from Depth Anything v2)
  --wall-mask    RGB wall mask (red channel = walls)
  --hex-data     JSON file with hex coords, types, pixel positions, neighbors
  --output-dir   Directory for output files

Outputs:
  elevation_results.json  Per-hex elevation assignments and platform info
  depth_elevation.png     Debug visualization
"""

import argparse
import json
import os
import sys

import cv2
import numpy as np


# ── Constants ────────────────────────────────────────────────────────────────
MIN_WALKABLE_HEXES = 10        # Skip if fewer walkable hexes
MIN_SILHOUETTE = 0.4           # Minimum silhouette score to accept clustering
MIN_DEPTH_RANGE = 30           # Minimum depth range (0-255) to detect platforms
DEFAULT_MAX_SPACING = 8        # Max elevation units between adjacent bands
MIN_ANCHOR_DEPTH_DELTA = 10    # Destination must be clearly higher than stair-side
MIN_PLATFORM_HEXES = 6         # Destination component must be substantive
MIN_WALL_CONSTRAINT_RATIO = 0.20  # Destination should be partly wall-constrained
ELEVATION_MIN = -10            # RoomHex minimum elevation
ELEVATION_MAX = 10             # RoomHex maximum elevation

# Hex types excluded from elevation clustering
EXCLUDED_HEX_TYPES = {'wall', 'off_map', 'window', 'pit'}

# Hex types whose existing elevation_level is an intrinsic object height
# (should be added to platform elevation, not replaced)
OBJECT_HEX_TYPES = {'furniture', 'cover', 'concealed', 'debris'}


def load_depth_map(path, target_h=None, target_w=None):
    """Load depth map as grayscale float32 array, resized to target dims.

    Depth Anything v2 may output at a different resolution than the input
    image. Since hex pixel positions are relative to the original image,
    we must resize the depth map to match.
    """
    img = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    if img is None:
        print(f"ERROR: Could not load depth map: {path}", file=sys.stderr)
        return None
    if target_h and target_w and (img.shape[0] != target_h or img.shape[1] != target_w):
        print(f"  Resizing depth map from {img.shape[1]}x{img.shape[0]} to {target_w}x{target_h}")
        img = cv2.resize(img, (target_w, target_h), interpolation=cv2.INTER_LINEAR)
    return img.astype(np.float32)


def load_wall_mask(path, target_h, target_w):
    """Load wall mask and return binary wall pixel mask.

    Wall mask is RGB: red channel = walls. Returns a boolean array where
    True = wall pixel (excluded from depth clustering).
    """
    if path is None or not os.path.exists(path):
        return None
    img = cv2.imread(path, cv2.IMREAD_COLOR)
    if img is None:
        return None
    if img.shape[0] != target_h or img.shape[1] != target_w:
        img = cv2.resize(img, (target_w, target_h), interpolation=cv2.INTER_NEAREST)
    # Red channel (BGR index 2) > 128 indicates wall
    return img[:, :, 2] > 128


def detect_and_correct_polarity(depth, floor_depths):
    """Detect and correct depth polarity using Otsu + floor heuristic.

    Depth Anything v2 polarity is not guaranteed — brighter may mean
    closer OR farther. Uses Otsu thresholding on interior pixels to find
    the object/floor boundary, then checks whether floor peak is above
    or below the Otsu threshold. Matches zone_map.py approach.

    Args:
        depth: Full depth map (float32)
        floor_depths: Array of depth values at floor hex centers

    Returns:
        Corrected depth map (float32), bool indicating if inverted
    """
    if len(floor_depths) == 0:
        return depth, False

    # Otsu on interior pixels (depth > 3 to exclude pure black borders)
    interior = depth[depth > 3].astype(np.uint8)
    if len(interior) > 100:
        otsu_thresh, _ = cv2.threshold(
            interior.reshape(-1, 1), 0, 255,
            cv2.THRESH_BINARY + cv2.THRESH_OTSU)
        otsu_thresh = float(otsu_thresh)
    else:
        otsu_thresh = 128.0

    floor_peak = float(np.median(floor_depths))

    if otsu_thresh >= floor_peak:
        # Floor is below Otsu threshold — normal polarity (dark=low, bright=high)
        print(f"  Depth polarity: normal (floor_peak={floor_peak:.1f}, otsu={otsu_thresh:.1f})")
        return depth, False
    else:
        # Floor is above Otsu threshold — inverted (bright=low)
        print(f"  Depth polarity: inverted (floor_peak={floor_peak:.1f}, otsu={otsu_thresh:.1f})")
        return 255.0 - depth, True


def sample_hex_depths(depth, hex_data, img_h, img_w, wall_mask=None):
    """Sample depth values at each hex center.

    Args:
        depth: Grayscale depth map (float32)
        hex_data: List of hex dicts with px, py, hex_type, label
        img_h, img_w: Image dimensions
        wall_mask: Optional boolean array where True = wall pixel

    Returns:
        walkable_indices: list of indices into hex_data for walkable hexes
        walkable_depths: numpy array of depth values at walkable hex centers
        floor_indices: list of indices for floor-type hexes (for polarity detection)
    """
    walkable_indices = []
    walkable_depths = []
    floor_indices = []

    for i, hx in enumerate(hex_data):
        ht = hx.get('hex_type', 'normal')
        if ht in EXCLUDED_HEX_TYPES:
            continue

        px = hx.get('px', 0)
        py = hx.get('py', 0)

        # Clamp to image bounds
        px = max(0, min(px, img_w - 1))
        py = max(0, min(py, img_h - 1))

        # Skip hex centers that fall on wall pixels
        if wall_mask is not None and wall_mask[py, px]:
            continue

        walkable_indices.append(i)
        walkable_depths.append(float(depth[py, px]))

        if ht == 'normal' and hx.get('label', '') in ('open_floor', 'normal', ''):
            floor_indices.append(len(walkable_indices) - 1)  # index into walkable arrays

    return walkable_indices, np.array(walkable_depths, dtype=np.float32), floor_indices


def cluster_depths(walkable_depths, max_k=5):
    """Cluster depth values into elevation bands using k-means.

    Tries k=2..max_k, selects best k by silhouette score.

    Returns:
        labels: cluster assignment per walkable hex (0-based)
        k: number of clusters chosen
        silhouette: silhouette score
        centers: sorted cluster centers (ascending brightness)
        None if clustering should be skipped
    """
    from sklearn.cluster import KMeans
    from sklearn.metrics import silhouette_score

    n = len(walkable_depths)
    if n < MIN_WALKABLE_HEXES:
        print(f"  Too few walkable hexes ({n} < {MIN_WALKABLE_HEXES}), skipping")
        return None

    depth_range = float(np.max(walkable_depths) - np.min(walkable_depths))
    if depth_range < MIN_DEPTH_RANGE:
        print(f"  Depth range too small ({depth_range:.1f} < {MIN_DEPTH_RANGE}), skipping")
        return None

    X = walkable_depths.reshape(-1, 1)
    best_k = 1
    best_score = -1.0
    best_labels = np.zeros(n, dtype=int)
    best_centers = np.array([np.mean(walkable_depths)])

    for k in range(2, min(max_k + 1, n)):
        km = KMeans(n_clusters=k, n_init=10, random_state=42)
        labels = km.fit_predict(X)
        score = silhouette_score(X, labels)
        print(f"  k={k}: silhouette={score:.3f}")
        if score > best_score:
            best_score = score
            best_k = k
            best_labels = labels
            best_centers = km.cluster_centers_.flatten()

    if best_score < MIN_SILHOUETTE:
        print(f"  Best silhouette {best_score:.3f} < {MIN_SILHOUETTE}, skipping")
        return None

    # Sort clusters by brightness (ascending = lowest elevation first)
    sorted_order = np.argsort(best_centers)
    remap = {old: new for new, old in enumerate(sorted_order)}
    sorted_labels = np.array([remap[l] for l in best_labels])
    sorted_centers = best_centers[sorted_order]

    print(f"  Chose k={best_k} (silhouette={best_score:.3f})")
    print(f"  Band centers: {[f'{c:.1f}' for c in sorted_centers]}")

    return sorted_labels, best_k, best_score, sorted_centers


def compute_band_spacing(k):
    """Compute adaptive inter-band elevation spacing.

    Formula: min(DEFAULT_MAX_SPACING, 18 / (k - 1))
    This ensures all bands fit within -10..+10 range.
    """
    if k <= 1:
        return DEFAULT_MAX_SPACING
    return min(DEFAULT_MAX_SPACING, int(18 / (k - 1)))


def calibrate_elevations(labels, hex_data, walkable_indices, walkable_depths, k):
    """Calibrate band elevations using stair/ladder anchors.

    Stairs/ladders bridge two bands. Their neighbors in a different band
    indicate the destination platform. Default spacing is used when no
    anchors are available.

    Returns:
        band_elevations: dict mapping band index -> elevation level
    """
    spacing = compute_band_spacing(k)
    band_elevations = {b: b * spacing for b in range(k)}

    # Build quick lookups for walkable hexes
    hex_band = {}  # (x, y) -> band
    depth_by_coord = {}  # (x, y) -> depth value
    hex_lookup = {}  # (x, y) -> hex dict
    for idx, wi in enumerate(walkable_indices):
        hx = hex_data[wi]
        coord = (hx['x'], hx['y'])
        hex_band[coord] = int(labels[idx])
        depth_by_coord[coord] = float(walkable_depths[idx])
        hex_lookup[coord] = hx

    # Find validated stair/ladder anchors and destination components
    anchors = []
    for idx, wi in enumerate(walkable_indices):
        hx = hex_data[wi]
        if not (hx.get('hex_type') == 'stairs' or hx.get('is_stairs') or hx.get('is_ladder')):
            continue

        stair_band = int(labels[idx])
        stair_coord = (hx['x'], hx['y'])
        neighbors = [tuple(n) for n in hx.get('neighbors', [])]
        neighbor_bands = [hex_band.get(nc) for nc in neighbors]
        neighbor_bands = [nb for nb in neighbor_bands if nb is not None and nb != stair_band]

        if not neighbor_bands:
            continue

        # Destination band = most common different band among neighbors
        from collections import Counter
        dest_band = Counter(neighbor_bands).most_common(1)[0][0]
        dest_neighbors = [nc for nc in neighbors if hex_band.get(nc) == dest_band]
        if not dest_neighbors:
            continue

        # Build connected destination component from neighbor(s) on the destination side
        component = set(dest_neighbors)
        queue = list(dest_neighbors)
        while queue:
            current = queue.pop(0)
            current_hex = hex_lookup.get(current)
            if not current_hex:
                continue
            for nn in [tuple(n) for n in current_hex.get('neighbors', [])]:
                if nn in component:
                    continue
                if hex_band.get(nn) != dest_band:
                    continue
                component.add(nn)
                queue.append(nn)

        if len(component) < MIN_PLATFORM_HEXES:
            continue

        # Destination must be clearly higher than stair-side neighbors.
        # Depth has already been polarity-corrected, so larger = higher.
        dest_depths = [depth_by_coord[c] for c in component if c in depth_by_coord]
        stair_side_depths = [depth_by_coord[nc] for nc in neighbors if hex_band.get(nc) == stair_band and nc in depth_by_coord]
        if not dest_depths:
            continue
        if not stair_side_depths:
            stair_side_depths = [depth_by_coord.get(stair_coord, 0.0)]
        depth_delta = float(np.median(dest_depths) - np.median(stair_side_depths))
        if depth_delta < MIN_ANCHOR_DEPTH_DELTA:
            continue

        # Destination should be at least somewhat wall-constrained.
        boundary_edges = 0
        wall_edges = 0
        for cc in component:
            ch = hex_lookup.get(cc)
            if not ch:
                continue
            for nn in [tuple(n) for n in ch.get('neighbors', [])]:
                if nn in component:
                    continue
                boundary_edges += 1
                nh = hex_lookup.get(nn)
                ntype = nh.get('hex_type') if nh else None
                if nh is None or ntype in ('wall', 'window', 'off_map', 'pit'):
                    wall_edges += 1
        wall_ratio = wall_edges / max(boundary_edges, 1)
        if wall_ratio < MIN_WALL_CONSTRAINT_RATIO:
            continue

        anchors.append({
            'x': hx['x'], 'y': hx['y'],
            'stair_band': stair_band,
            'dest_band': dest_band,
            'depth_delta': round(depth_delta, 2),
            'wall_ratio': round(wall_ratio, 2),
            'component': [list(c) for c in sorted(component)]
        })

    if anchors:
        print(f"  Validated anchors: {len(anchors)}")
        for a in anchors:
            print(f"    staircase at ({a['x']},{a['y']}): "
                  f"band {a['stair_band']} -> band {a['dest_band']} "
                  f"(depth_delta={a['depth_delta']}, wall_ratio={a['wall_ratio']})")
    else:
        print("  No validated stair/ladder anchors found")

    return band_elevations, anchors


def assign_elevations(hex_data, walkable_indices, labels, band_elevations, anchors):
    """Assign elevation levels to all hexes based on band membership.

    - Floor/normal hexes: elevation = band elevation
    - Object hexes: elevation = band elevation + existing object elevation (additive)
    - Stair/ladder hexes: elevation = destination platform elevation // 2
    - Pit hexes: keep static -6
    - All clamped to ELEVATION_MIN..ELEVATION_MAX
    """
    # Build lookups
    hex_band = {}
    hex_lookup = {}
    for idx, wi in enumerate(walkable_indices):
        hx = hex_data[wi]
        coord = (hx['x'], hx['y'])
        hex_band[coord] = int(labels[idx])
        hex_lookup[coord] = hx

    # Build anchored platform map: only elevate validated destination components.
    platform_base = {}  # (x,y) -> base platform elevation
    stair_dest = {}     # (x,y) -> destination elevation
    for a in anchors:
        dest_elev = band_elevations.get(a['dest_band'], 0)
        for coord_list in a.get('component', []):
            coord = tuple(coord_list)
            prev = platform_base.get(coord, ELEVATION_MIN)
            if dest_elev > prev:
                platform_base[coord] = dest_elev
        stair_dest[(a['x'], a['y'])] = dest_elev

    hex_elevations = {}
    platforms = {}  # elevation -> count

    # Apply elevations to anchored components.
    for coord, base_elev in platform_base.items():
        hx = hex_lookup.get(coord)
        if not hx:
            continue
        band = hex_band.get(coord, 0)
        ht = hx.get('hex_type', 'normal')
        key = f"{hx['x']},{hx['y']}"

        if ht in OBJECT_HEX_TYPES:
            obj_elev = hx.get('elevation_level', 0) or 0
            total = base_elev + obj_elev
            hex_elevations[key] = {
                'elevation_level': max(ELEVATION_MIN, min(ELEVATION_MAX, total)),
                'band': band,
                'object_boost': True
            }
        else:
            hex_elevations[key] = {
                'elevation_level': max(ELEVATION_MIN, min(ELEVATION_MAX, base_elev)),
                'band': band
            }
        platforms[base_elev] = platforms.get(base_elev, 0) + 1

    # Stair hexes get half of destination platform elevation.
    for (sx, sy), dest_elev in stair_dest.items():
        key = f"{sx},{sy}"
        stair_elev = max(ELEVATION_MIN, min(ELEVATION_MAX, dest_elev // 2))
        prev = hex_elevations.get(key, {}).get('elevation_level', ELEVATION_MIN)
        if stair_elev > prev:
            hex_elevations[key] = {
                'elevation_level': stair_elev,
                'band': hex_band.get((sx, sy), 0),
                'stair_anchor': True
            }

    # Build platform summary
    platform_list = []
    for elev in sorted(platforms.keys()):
        label = 'floor' if elev == 0 else f'platform_{elev}'
        platform_list.append({
            'band': None,
            'elevation': elev,
            'hex_count': platforms[elev],
            'label': label
        })

    return hex_elevations, platform_list


def generate_debug_visualization(depth, hex_data, walkable_indices, labels,
                                  band_elevations, hex_elevations, output_dir):
    """Generate depth_elevation.png debug image.

    Shows depth map with hex centers color-coded by band and elevation
    values annotated.
    """
    # Normalize depth to 0-255 for display
    depth_norm = cv2.normalize(depth, None, 0, 255, cv2.NORM_MINMAX).astype(np.uint8)
    vis = cv2.cvtColor(depth_norm, cv2.COLOR_GRAY2BGR)

    # Band colors (distinct, high contrast)
    band_colors = [
        (255, 100, 100),   # band 0: blue-ish (BGR)
        (100, 255, 100),   # band 1: green
        (100, 100, 255),   # band 2: red
        (255, 255, 100),   # band 3: cyan
        (255, 100, 255),   # band 4: magenta
    ]

    # Draw hex centers
    hex_band = {}
    for idx, wi in enumerate(walkable_indices):
        hx = hex_data[wi]
        hex_band[(hx['x'], hx['y'])] = int(labels[idx])

    for idx, wi in enumerate(walkable_indices):
        hx = hex_data[wi]
        px, py = hx.get('px', 0), hx.get('py', 0)
        band = int(labels[idx])
        color = band_colors[band % len(band_colors)]
        cv2.circle(vis, (px, py), 6, color, -1)
        cv2.circle(vis, (px, py), 6, (0, 0, 0), 1)

        # Annotate elevation
        key = f"{hx['x']},{hx['y']}"
        elev = hex_elevations.get(key, {}).get('elevation_level', 0)
        cv2.putText(vis, str(elev), (px + 8, py + 4),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.35, (255, 255, 255), 1)

    # Legend
    y_off = 20
    for band, elev in sorted(band_elevations.items()):
        color = band_colors[band % len(band_colors)]
        cv2.rectangle(vis, (10, y_off - 12), (24, y_off), color, -1)
        cv2.putText(vis, f"Band {band}: elev={elev}", (30, y_off),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.4, (255, 255, 255), 1)
        y_off += 18

    out_path = os.path.join(output_dir, 'depth_elevation.png')
    cv2.imwrite(out_path, vis)
    print(f"  Debug visualization: {out_path}")
    return out_path


def main():
    ap = argparse.ArgumentParser(description='Depth-based elevation analysis')
    ap.add_argument('--depth-map', required=True,
                    help='Path to grayscale depth map PNG')
    ap.add_argument('--wall-mask', default=None,
                    help='Path to RGB wall mask PNG (red channel = walls)')
    ap.add_argument('--hex-data', required=True,
                    help='Path to JSON file with hex coordinates and types')
    ap.add_argument('--output-dir', required=True,
                    help='Directory for output files')
    ap.add_argument('--image-width', type=int, default=0,
                    help='Original image width (for depth map resizing)')
    ap.add_argument('--image-height', type=int, default=0,
                    help='Original image height (for depth map resizing)')
    args = ap.parse_args()

    print("=== Depth Elevation Analysis ===")

    # Load hex data
    with open(args.hex_data, 'r') as f:
        hex_data = json.load(f)
    print(f"  Hex data: {len(hex_data)} hexes")

    # Load depth map, resizing to original image dimensions if provided
    target_h = args.image_height if args.image_height > 0 else None
    target_w = args.image_width if args.image_width > 0 else None
    depth = load_depth_map(args.depth_map, target_h=target_h, target_w=target_w)
    if depth is None:
        sys.exit(1)
    img_h, img_w = depth.shape[:2]
    print(f"  Depth map: {img_w}x{img_h}")

    # Load wall mask (optional — excludes wall pixels from clustering)
    wall_mask = load_wall_mask(args.wall_mask, img_h, img_w)
    if wall_mask is not None:
        print(f"  Wall mask loaded: {np.sum(wall_mask)} wall pixels masked")

    # Sample depths at hex centers
    walkable_indices, walkable_depths, floor_indices = \
        sample_hex_depths(depth, hex_data, img_h, img_w, wall_mask=wall_mask)
    print(f"  Walkable hexes: {len(walkable_indices)}, floor hexes: {len(floor_indices)}")

    if len(walkable_indices) < MIN_WALKABLE_HEXES:
        print(f"  Too few walkable hexes, writing skip result")
        results = {'skipped': True, 'reason': 'too_few_walkable_hexes'}
        with open(os.path.join(args.output_dir, 'elevation_results.json'), 'w') as f:
            json.dump(results, f, indent=2)
        return

    # Detect and correct polarity using Otsu + floor heuristic
    # floor_indices are already indices into walkable_depths (not hex_data)
    floor_depths = walkable_depths[floor_indices] if floor_indices else walkable_depths
    depth, inverted = detect_and_correct_polarity(depth, floor_depths)

    # Re-sample after polarity correction
    walkable_indices, walkable_depths, floor_indices = \
        sample_hex_depths(depth, hex_data, img_h, img_w, wall_mask=wall_mask)

    # Cluster into bands
    cluster_result = cluster_depths(walkable_depths)
    if cluster_result is None:
        print("  Skipping elevation adjustment (flat map or insufficient data)")
        results = {'skipped': True, 'reason': 'clustering_failed'}
        with open(os.path.join(args.output_dir, 'elevation_results.json'), 'w') as f:
            json.dump(results, f, indent=2)
        return

    labels, k, silhouette, centers = cluster_result

    # Calibrate elevations from anchors
    band_elevations, anchors = calibrate_elevations(
        labels, hex_data, walkable_indices, walkable_depths, k)

    if not anchors:
        print("  Skipping elevation adjustment (no validated stair/ladder anchors)")
        results = {'skipped': True, 'reason': 'no_valid_stair_or_ladder_anchors'}
        with open(os.path.join(args.output_dir, 'elevation_results.json'), 'w') as f:
            json.dump(results, f, indent=2)
        return

    # Assign per-hex elevations
    hex_elevations, platforms = assign_elevations(
        hex_data, walkable_indices, labels, band_elevations, anchors)

    # Generate debug visualization
    generate_debug_visualization(
        depth, hex_data, walkable_indices, labels,
        band_elevations, hex_elevations, args.output_dir)

    # Write results
    results = {
        'platforms': platforms,
        'hex_elevations': hex_elevations,
        'anchors_used': [
            f"staircase at ({a['x']},{a['y']}) bridging band {a['stair_band']} -> band {a['dest_band']}"
            for a in anchors
        ],
        'k_chosen': k,
        'silhouette_score': round(silhouette, 3),
        'depth_inverted': inverted
    }
    out_path = os.path.join(args.output_dir, 'elevation_results.json')
    with open(out_path, 'w') as f:
        json.dump(results, f, indent=2)
    print(f"  Results written: {out_path}")
    print(f"  Platforms: {len(platforms)}, hexes with elevation: {len(hex_elevations)}")


if __name__ == '__main__':
    main()
