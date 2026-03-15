#!/usr/bin/env python3
"""
Analyze Gemini color-annotated battlemap to extract a wall/door pixel map.

Gemini is asked to recolor the battlemap using 4 semantic colors:
  Bright green  (#00FF00) → inner room walls
  Bright pink   (#FF00FF) → inner room doors
  Bright blue   (#0000FF) → outer perimeter walls
  Bright red    (#FF0000) → outer perimeter doors

Pipeline:
  1. Load original image + Gemini-recolored image
  2. Shape-aware resize: scale Gemini output back to original dimensions
     then re-quantize each pixel to nearest target color (blending from
     resize smears the pure hues)
  3. Find pixels changed to target colors; keep unchanged pixels dark
  4. Gap detection: scan wall skeletons for gaps of plausible door width
     that Gemini may have left unlabeled, then autofill as door
  5. Connectivity: find floor regions not reachable through any door, then
     punch through the thinnest nearby wall to connect them

Usage:
  python3 gemini_colormap_analyze.py
      --original  <original.png>
      --colormap  <gemini_output.png>
      --output-dir <dir>
      [--has-inner-walls 0|1]   default 1
"""

import argparse
import cv2
import json
import math
import numpy as np
import os
import sys


# ── Target colors (BGR for OpenCV) ───────────────────────────────────────────

COLORS = {
    'inner_wall': np.array([0,   255, 0  ], dtype=np.int32),  # green
    'inner_door': np.array([255, 0,   255], dtype=np.int32),  # magenta/pink
    'outer_wall': np.array([0,   0,   255], dtype=np.int32),  # blue  (BGR: B=0,G=0,R=255)
    'outer_door': np.array([0,   255, 255], dtype=np.int32),  # — wait, fix below
}

# Correct BGR values
_TARGET_BGR = {
    'inner_wall': np.array([  0, 255,   0], dtype=np.int32),  # green:   B=0, G=255, R=0
    'inner_door': np.array([255,   0, 255], dtype=np.int32),  # magenta: B=255,G=0, R=255
    'outer_wall': np.array([255,   0,   0], dtype=np.int32),  # blue:    B=255,G=0, R=0
    'outer_door': np.array([  0,   0, 255], dtype=np.int32),  # red:     B=0, G=0, R=255
}

LABEL_IDX = {name: i + 1 for i, name in enumerate(_TARGET_BGR)}
IDX_LABEL = {v: k for k, v in LABEL_IDX.items()}

# Visualization colors (BGR)
VIZ_BGR = {
    'inner_wall': (0,   200, 0  ),
    'inner_door': (255, 0,   255),
    'outer_wall': (255, 80,  0  ),
    'outer_door': (0,   0,   255),
    'gap_door':   (128, 0,   255),   # purple = autofilled gap door
    'punch':      (0,   255, 255),   # yellow = connectivity punch
}


# ── Shape-aware resize + re-quantize ─────────────────────────────────────────

def classify_image(colormap_bgr, orig_bgr, orig_h, orig_w, change_threshold=30,
                   depth_map=None):
    """
    Classify pixels by how much they moved toward each target color.

    For each pixel we compute:
      movement(target) = dist(orig, target) - dist(new, target)
    A positive value means the pixel moved closer to that target color.

    A pixel is classified as a label when ALL of:
      1. It moved toward that target more than any other target (argmax)
      2. movement > MIN_MOVEMENT — genuinely painted, not just global tone shift
      3. dist(new, target) < MAX_DIST_TO_TARGET — pixel is now close to the target
      4. dist(orig, new) > MIN_SOURCE_CHANGE — pixel actually changed from original

    When a depth map is provided, pixels brighter than the median depth
    (raised structures like walls/doors) get a reduced MIN_MOVEMENT threshold,
    making them easier to classify. This adds depth as an additional signal
    alongside the color-shift detection.

    This replaces the old hue-zone approach, which misclassified pre-existing
    greenish/reddish original pixels and was fooled by global Gemini tone shifts.
    """
    MIN_MOVEMENT       = 34   # looser recolor movement gate to retain faint Gemini paints
    MAX_DIST_TARGET    = 195  # allow slightly less-saturated target pixels
    MIN_SOURCE_CHANGE  = 28   # lower source-change gate for subtle door/wall recolors
    NEAR_TARGET_BYPASS = 95   # if new pixel is very near target, trust it even with low source change
                               # (handles originals already close to target shade)
    MIN_MARGIN         = 10   # smaller winner margin to avoid dropping boundary pixels
                               # ensures clear winner, not just argmax by 1 unit
    DEPTH_WEIGHT       = 35   # stronger depth influence (raised pixels classify easier)

    resized = cv2.resize(colormap_bgr, (orig_w, orig_h), interpolation=cv2.INTER_LANCZOS4)

    orig_f = orig_bgr.astype(np.float32)
    new_f  = resized.astype(np.float32)

    # ── Depth-based movement threshold adjustment ───────────────────────────
    # Floor pixels cluster around the median depth. Walls/doors deviate from it.
    # We measure how close each pixel is to the median vs the maximum possible
    # deviation. Pixels near median (floor-like) get a raised threshold to
    # reject false positives; pixels far from median (wall-like) get a lowered
    # threshold to catch more true walls.
    #
    # nearness = 1.0 at median (pure floor), 0.0 at max deviation (wall/edge)
    # threshold shift = (nearness - 0.5) * 2 * DEPTH_WEIGHT
    #   → floor (nearness~1.0): shift = +DEPTH_WEIGHT (harder to classify)
    #   → wall  (nearness~0.0): shift = -DEPTH_WEIGHT (easier to classify)
    if depth_map is not None:
        depth_gray = depth_map if len(depth_map.shape) == 2 else cv2.cvtColor(depth_map, cv2.COLOR_BGR2GRAY)
        depth_resized = cv2.resize(depth_gray, (orig_w, orig_h), interpolation=cv2.INTER_LINEAR)
        depth_f = depth_resized.astype(np.float32)
        median_depth = float(np.median(depth_f))
        # Max possible deviation from median in either direction
        max_dev = max(abs(255.0 - median_depth), abs(median_depth), 1.0)
        # How close to median: 1.0 = exactly at median, 0.0 = max deviation
        abs_dev = np.abs(depth_f - median_depth)
        nearness = 1.0 - np.clip(abs_dev / max_dev, 0.0, 1.0)
        # Shift: nearness 1.0 (floor) → +DEPTH_WEIGHT, nearness 0.0 (wall) → -DEPTH_WEIGHT
        depth_shift = (nearness - 0.5) * 2.0 * DEPTH_WEIGHT
        effective_min_movement = MIN_MOVEMENT + depth_shift
        # Clamp so threshold never goes below 10 (some signal still required) or above 80
        effective_min_movement = np.clip(effective_min_movement, 10.0, 80.0)
        print(f"  Depth map: median={median_depth:.1f}, max_dev={max_dev:.1f}, "
              f"threshold range {effective_min_movement.min():.0f}..{effective_min_movement.max():.0f} "
              f"(base={MIN_MOVEMENT}, weight=±{DEPTH_WEIGHT})")
    else:
        effective_min_movement = float(MIN_MOVEMENT)

    # Source-change gate — bypassed below when pixel is already very close to target
    src_change = np.sqrt(np.sum((new_f - orig_f) ** 2, axis=2))
    actually_changed = src_change > MIN_SOURCE_CHANGE

    # For each target color compute movement and distance-to-target
    target_names = list(_TARGET_BGR.keys())
    movements   = []
    dist_to_tgt = []
    for name in target_names:
        tgt = _TARGET_BGR[name].astype(np.float32)
        d_orig = np.sqrt(np.sum((orig_f - tgt) ** 2, axis=2))
        d_new  = np.sqrt(np.sum((new_f  - tgt) ** 2, axis=2))
        movements.append(d_orig - d_new)
        dist_to_tgt.append(d_new)

    movement_stack = np.stack(movements,   axis=2)  # h×w×4
    dist_stack     = np.stack(dist_to_tgt, axis=2)  # h×w×4

    best_idx      = np.argmax(movement_stack, axis=2)   # h×w
    best_movement = np.max(movement_stack,    axis=2)   # h×w

    # Second-best movement for margin check: best must clearly beat 2nd place
    sorted_movements    = np.sort(movement_stack, axis=2)  # ascending
    second_best_movement = sorted_movements[:, :, -2]      # second largest per pixel

    label_map = np.zeros((orig_h, orig_w), dtype=np.uint8)
    for i, name in enumerate(target_names):
        is_best    = (best_idx == i)
        moved_ok   = best_movement > effective_min_movement
        margin_ok  = (best_movement - second_best_movement) >= MIN_MARGIN
        close_ok   = dist_stack[:, :, i] < MAX_DIST_TARGET
        # Bypass source-change gate when pixel is already very close to target color.
        # This handles originals that share the target hue — Gemini barely changes them
        # but they're still valid detections.
        near_target = dist_stack[:, :, i] < NEAR_TARGET_BYPASS
        source_ok  = actually_changed | near_target
        mask = is_best & moved_ok & margin_ok & close_ok & source_ok
        label_map[mask] = LABEL_IDX[name]

    # Remove tiny isolated blobs per label. Keep lower threshold for doors so
    # narrow doorway recolors survive, but keep walls stricter to avoid noise.
    min_blob_px_by_label = {
        LABEL_IDX['inner_wall']: 130,
        LABEL_IDX['outer_wall']: 130,
        LABEL_IDX['inner_door']: 60,
        LABEL_IDX['outer_door']: 60
    }
    for idx in LABEL_IDX.values():
        mask = (label_map == idx).astype(np.uint8)
        if mask.sum() == 0:
            continue
        num, comps, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
        min_blob_px = min_blob_px_by_label.get(idx, 100)
        for lbl in range(1, num):
            if stats[lbl, cv2.CC_STAT_AREA] < min_blob_px:
                label_map[comps == lbl] = 0

    classified = int((label_map > 0).sum())
    print(f"  Source-changed pixels: {actually_changed.sum()} / {orig_h*orig_w} "
          f"(min_change={MIN_SOURCE_CHANGE}, near_target_bypass={NEAR_TARGET_BYPASS})")
    print(f"  Classified (post-blob-filter): {classified}")

    return label_map, resized


def label_to_viz(label_map, orig_bgr):
    """Render label map as colored overlay on dark original."""
    h, w = label_map.shape
    vis = (orig_bgr.astype(np.float32) * 0.25).astype(np.uint8)

    color_map_bgr = {
        LABEL_IDX['inner_wall']: VIZ_BGR['inner_wall'],
        LABEL_IDX['inner_door']: VIZ_BGR['inner_door'],
        LABEL_IDX['outer_wall']: VIZ_BGR['outer_wall'],
        LABEL_IDX['outer_door']: VIZ_BGR['outer_door'],
    }
    for idx, bgr in color_map_bgr.items():
        vis[label_map == idx] = bgr
    return vis


# ── Gap detection in wall segments ───────────────────────────────────────────

def find_wall_gaps(label_map, wall_label_idx, door_label_idx,
                   min_gap_px=60, max_gap_px=300):
    """
    Direction-aware gap detection using axis projection.

    Algorithm:
      1. Erode the wall mask to discard pixels within ~4px of a non-wall
         edge, leaving a solid "core" free of paint fuzz.
      2. Project the core onto each axis to discover WHERE the walls are:
           x-projection → dense columns  = vertical wall bands
           y-projection → dense rows     = horizontal wall bands
      3. For each discovered wall band, project the FULL (uneroded) wall+door
         mask onto the wall axis:
           vertical band at x=[xs..xe]  → any(wall_pixel in row) → 1-D over y
           horizontal band at y=[ys..ye] → any(wall_pixel in col) → 1-D over x
      4. Scan the 1-D projection for gaps of min_gap..max_gap px.
         Doors appear as breaks in the projection even across separate segments.

    Returns list of gap dicts: {cx, cy, length, axis}
    """
    wall_mask = (label_map == wall_label_idx).astype(np.uint8)
    door_mask = (label_map == door_label_idx).astype(np.uint8)
    combined  = cv2.bitwise_or(wall_mask, door_mask)
    if combined.sum() < 100:
        return []

    h, w = combined.shape

    # ── Step 1: erode to solid core ───────────────────────────────────────
    erode_k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7))
    core = cv2.erode(combined, erode_k, iterations=1)

    # ── Step 2: project core to find wall band positions ──────────────────
    # x_proj[x] = rows with a core pixel at column x  →  high = vertical wall
    # y_proj[y] = cols with a core pixel at row y     →  high = horizontal wall
    x_proj = np.sum(core > 0, axis=0).astype(float)   # shape (w,)
    y_proj = np.sum(core > 0, axis=1).astype(float)   # shape (h,)

    # Smooth to merge nearby high-density columns/rows into bands
    smooth = np.ones(15) / 15
    x_smooth = np.convolve(x_proj, smooth, mode='same')
    y_smooth = np.convolve(y_proj, smooth, mode='same')

    x_thresh = max(x_smooth.max() * 0.08, 3.0)
    y_thresh = max(y_smooth.max() * 0.08, 3.0)

    def _find_bands(arr, thresh):
        """Return list of (start, end) for contiguous above-threshold regions."""
        bands, in_b, start = [], False, 0
        for i, v in enumerate(arr):
            if v > thresh and not in_b:
                start = i; in_b = True
            elif v <= thresh and in_b:
                bands.append((start, i)); in_b = False
        if in_b:
            bands.append((start, len(arr)))
        return bands

    vert_bands  = _find_bands(x_smooth, x_thresh)   # x-ranges for vertical walls
    horiz_bands = _find_bands(y_smooth, y_thresh)   # y-ranges for horizontal walls

    gaps = []

    MIN_FLANK_PX = 20  # require ≥20px of wall on each side of a gap

    def _scan_projection(has_wall, offset, axis, band_lo, band_hi):
        """Scan a 1-D bool array for unlabeled gaps of plausible door width.

        Requires MIN_FLANK_PX of continuous wall immediately before AND after the
        gap so isolated false-positive blobs don't produce spurious door detections.
        Uses pre-computed left/right run-length arrays for correct flank checking.
        """
        n = len(has_wall)
        # left_run[i] = continuous wall pixels ending at i (going left)
        # right_run[i] = continuous wall pixels starting at i (going right)
        lrun = np.zeros(n, dtype=np.int32)
        rrun = np.zeros(n, dtype=np.int32)
        r = 0
        for i in range(n):
            r = r + 1 if has_wall[i] else 0
            lrun[i] = r
        r = 0
        for i in range(n - 1, -1, -1):
            r = r + 1 if has_wall[i] else 0
            rrun[i] = r

        in_wall  = False
        gap_start = None
        for i, present in enumerate(has_wall):
            if present:
                if gap_start is not None:
                    gap_len = i - gap_start
                    left_flank  = lrun[gap_start - 1] if gap_start > 0 else 0
                    right_flank = rrun[i]
                    if (min_gap_px <= gap_len <= max_gap_px
                            and left_flank >= MIN_FLANK_PX
                            and right_flank >= MIN_FLANK_PX):
                        mid = offset + (gap_start + i) // 2
                        if axis == 1:   # vertical scan → gap_cy varies
                            cx_g, cy_g = (band_lo + band_hi) // 2, mid
                            slc = label_map[offset + gap_start:offset + i,
                                            band_lo:band_hi]
                        else:           # horizontal scan → gap_cx varies
                            cx_g, cy_g = mid, (band_lo + band_hi) // 2
                            slc = label_map[band_lo:band_hi,
                                            offset + gap_start:offset + i]
                        if not np.any(slc == door_label_idx):
                            gaps.append({'cx': cx_g, 'cy': cy_g,
                                         'length': gap_len, 'axis': axis})
                    gap_start = None
                in_wall = True
            else:
                if in_wall:
                    gap_start = i
                in_wall = False

    # ── Step 3a: scan vertical wall bands (project onto y-axis) ──────────
    for xs, xe in vert_bands:
        region = combined[:, xs:xe]
        y_coverage = np.any(region > 0, axis=1)   # (h,) — any wall pixel per row
        ys_present = np.where(y_coverage)[0]
        if len(ys_present) < 50:
            continue
        # Must span mostly vertically (y-extent >> band width)
        if (ys_present[-1] - ys_present[0]) < (xe - xs) * 2:
            continue
        _scan_projection(y_coverage, 0, axis=1, band_lo=xs, band_hi=xe)

    # ── Step 3b: scan horizontal wall bands (project onto x-axis) ────────
    for ys, ye in horiz_bands:
        region = combined[ys:ye, :]
        x_coverage = np.any(region > 0, axis=0)   # (w,) — any wall pixel per col
        xs_present = np.where(x_coverage)[0]
        if len(xs_present) < 50:
            continue
        # Must span mostly horizontally (x-extent >> band height)
        if (xs_present[-1] - xs_present[0]) < (ye - ys) * 2:
            continue
        _scan_projection(x_coverage, 0, axis=0, band_lo=ys, band_hi=ye)

    # ── Deduplicate nearby gaps ───────────────────────────────────────────
    merged = []
    used = set()
    for i, g in enumerate(gaps):
        if i in used:
            continue
        cluster = [g]
        for j, g2 in enumerate(gaps):
            if j <= i or j in used:
                continue
            if abs(g2['cx'] - g['cx']) < 50 and abs(g2['cy'] - g['cy']) < 50:
                cluster.append(g2)
                used.add(j)
        used.add(i)
        cx = int(np.median([c['cx'] for c in cluster]))
        cy = int(np.median([c['cy'] for c in cluster]))
        ln = max(c['length'] for c in cluster)
        ax = cluster[0]['axis']
        merged.append({'cx': cx, 'cy': cy, 'length': ln, 'axis': ax})

    return merged


# ── Connectivity analysis ─────────────────────────────────────────────────────

def analyze_connectivity(label_map, h, w, object_mask=None):
    """
    Find disconnected floor regions and suggest punch-through points.

    Floor = pixels not labeled as any wall type.
    Doors are passable (they count as floor for connectivity).

    object_mask: optional uint8 array (same shape), non-zero = object present.
      Candidates near objects are penalized — wall_thickness score is increased
      by object_proximity_penalty (default 200) so clearer paths are preferred.
      This is a soft penalty, not a hard filter, so if all paths pass near
      objects the least-obstructed one is still returned.
    """
    OBJECT_PROXIMITY_PX      = 40   # radius to check for nearby objects
    OBJECT_PROXIMITY_PENALTY = 200  # added to thickness score if objects nearby

    # Build passable mask: floor + doors
    wall_mask  = np.zeros((h, w), dtype=np.uint8)
    for name in ('inner_wall', 'outer_wall'):
        wall_mask |= (label_map == LABEL_IDX[name]).astype(np.uint8)

    passable = (wall_mask == 0).astype(np.uint8)

    # Erode slightly to avoid single-pixel connections
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
    passable_tight = cv2.erode(passable, k, iterations=1)

    num_labels, comp_map, stats, centroids = cv2.connectedComponentsWithStats(
        passable_tight, connectivity=8)

    # Filter to non-trivial components (> 500px)
    components = []
    for lbl in range(1, num_labels):
        area = stats[lbl, cv2.CC_STAT_AREA]
        if area > 500:
            components.append({
                'id': int(lbl),
                'area': int(area),
                'centroid': [float(centroids[lbl][0]), float(centroids[lbl][1])],
            })

    is_connected = len(components) <= 1

    # Build separate masks for inner vs outer walls so punch points can be typed
    inner_wall_mask = (label_map == LABEL_IDX['inner_wall']).astype(np.uint8)

    def _object_penalty(px, py):
        """Return OBJECT_PROXIMITY_PENALTY if any object pixel within radius."""
        if object_mask is None:
            return 0
        r = OBJECT_PROXIMITY_PX
        x0, x1 = max(0, px - r), min(w, px + r)
        y0, y1 = max(0, py - r), min(h, py + r)
        return OBJECT_PROXIMITY_PENALTY if object_mask[y0:y1, x0:x1].any() else 0

    all_punch = []
    if not is_connected and len(components) >= 2:
        for i in range(len(components)):
            for j in range(i + 1, len(components)):
                c1 = components[i]
                c2 = components[j]
                cx1, cy1 = int(c1['centroid'][0]), int(c1['centroid'][1])
                cx2, cy2 = int(c2['centroid'][0]), int(c2['centroid'][1])

                steps = max(abs(cx2 - cx1), abs(cy2 - cy1))
                if steps == 0:
                    continue
                best_pt       = None
                best_score    = 9999
                best_thickness = 9999
                best_wall_type = 'outer'
                for t in np.linspace(0, 1, steps + 1):
                    px = int(round(cx1 + (cx2 - cx1) * t))
                    py = int(round(cy1 + (cy2 - cy1) * t))
                    if not (0 <= px < w and 0 <= py < h):
                        continue
                    if wall_mask[py, px] == 0:
                        continue
                    r = 15
                    x1r, x2r = max(0, px - r), min(w, px + r)
                    y1r, y2r = max(0, py - r), min(h, py + r)
                    thickness = int(wall_mask[y1r:y2r, x1r:x2r].sum())
                    score = thickness + _object_penalty(px, py)
                    wt = 'inner' if inner_wall_mask[py, px] else 'outer'
                    if score < best_score:
                        best_score     = score
                        best_thickness = thickness
                        best_pt        = (px, py)
                        best_wall_type = wt

                if best_pt:
                    near_obj = _object_penalty(*best_pt) > 0
                    all_punch.append({
                        'point':             list(best_pt),
                        'wall_thickness':    best_thickness,
                        'wall_type':         best_wall_type,
                        'near_object':       near_obj,
                        'between_components': [c1['id'], c2['id']],
                    })

    # Keep only the best (lowest score = thinnest + object-clear) per wall type
    punch_points = []
    for wt in ('outer', 'inner'):
        candidates = [p for p in all_punch if p['wall_type'] == wt]
        if candidates:
            punch_points.append(min(candidates,
                key=lambda p: p['wall_thickness'] + (OBJECT_PROXIMITY_PENALTY if p['near_object'] else 0)))

    return {
        'is_connected':   is_connected,
        'num_components': len(components),
        'components':     components,
        'punch_points':   punch_points,
    }


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--original',     required=True)
    ap.add_argument('--colormap',     required=True)
    ap.add_argument('--output-dir',   required=True)
    ap.add_argument('--has-inner-walls', type=int, default=1)
    ap.add_argument('--depth-map',    default=None,
                    help='Path to depth map PNG (brighter=closer/raised). '
                         'Used as additional signal for wall/door classification.')
    ap.add_argument('--object-mask',  default=None,
                    help='Path to combined object mask PNG (white=object). '
                         'Used to steer punch-throughs away from objects.')
    args = ap.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    orig_bgr = cv2.imread(args.original)
    if orig_bgr is None:
        print(f"ERROR: cannot read {args.original}", file=sys.stderr)
        sys.exit(1)
    cmap_bgr = cv2.imread(args.colormap)
    if cmap_bgr is None:
        print(f"ERROR: cannot read {args.colormap}", file=sys.stderr)
        sys.exit(1)

    h, w = orig_bgr.shape[:2]
    print(f"Original: {w}×{h}  Colormap: {cmap_bgr.shape[1]}×{cmap_bgr.shape[0]}")

    # Load optional depth map (resized to match original dims)
    depth_map = None
    if args.depth_map:
        dm = cv2.imread(args.depth_map, cv2.IMREAD_GRAYSCALE)
        if dm is not None:
            if dm.shape[:2] != (h, w):
                dm = cv2.resize(dm, (w, h), interpolation=cv2.INTER_LINEAR)
            depth_map = dm
            print(f"  Depth map: {dm.shape[1]}×{dm.shape[0]}, "
                  f"median={int(np.median(dm))}, min={int(dm.min())}, max={int(dm.max())}")
        else:
            print(f"  WARNING: could not read depth map {args.depth_map}")

    # Load optional object mask (resized to match original dims)
    object_mask = None
    if args.object_mask:
        om = cv2.imread(args.object_mask, cv2.IMREAD_GRAYSCALE)
        if om is not None:
            if om.shape[:2] != (h, w):
                om = cv2.resize(om, (w, h), interpolation=cv2.INTER_NEAREST)
            object_mask = om
            print(f"  Object mask: {om.shape[1]}×{om.shape[0]}, "
                  f"{int((om > 0).sum())} non-zero px")

    # ── Classify ──────────────────────────────────────────────────────────────
    label_map, resized_cmap = classify_image(cmap_bgr, orig_bgr, h, w,
                                             depth_map=depth_map)

    # Save resized colormap (for debugging)
    cv2.imwrite(os.path.join(args.output_dir, 'colormap_resized.png'), resized_cmap)

    # Coverage stats
    label_counts = {
        name: int(np.sum(label_map == idx))
        for name, idx in LABEL_IDX.items()
    }
    unchanged_count = int(np.sum(label_map == 0))
    total_px = h * w
    print("Label coverage:")
    for name, cnt in label_counts.items():
        print(f"  {name}: {cnt} px ({100*cnt/total_px:.1f}%)")
    print(f"  unchanged: {unchanged_count} px ({100*unchanged_count/total_px:.1f}%)")

    # ── Visualization: raw classify ───────────────────────────────────────────
    viz_raw = label_to_viz(label_map, orig_bgr)
    cv2.imwrite(os.path.join(args.output_dir, 'colormap_classify.png'), viz_raw)

    # ── Erase wall/door labels that overlap SAM object masks ──────────────────
    # Gemini sometimes misclassifies objects as walls. Any wall/door pixel that
    # overlaps a confirmed SAM object mask is cleared to floor (0) so gap
    # detection doesn't treat object boundaries as door openings.
    object_erase_stats = {
        'raw_object_px': 0,
        'core_object_px': 0,
        'erode_px': 0,
        'labels_cleared': {}
    }
    if object_mask is not None:
        OBJECT_ERASE_ERODE_PX = 2
        wall_door_labels = {LABEL_IDX[k] for k in ('outer_wall', 'outer_door', 'inner_wall', 'inner_door')}
        raw_obj = (object_mask > 0).astype(np.uint8)
        object_erase_stats['raw_object_px'] = int(raw_obj.sum())

        obj_core = raw_obj
        if OBJECT_ERASE_ERODE_PX > 0:
            k = cv2.getStructuringElement(
                cv2.MORPH_ELLIPSE,
                (OBJECT_ERASE_ERODE_PX * 2 + 1, OBJECT_ERASE_ERODE_PX * 2 + 1)
            )
            eroded = cv2.erode(raw_obj, k, iterations=1)
            # Keep a fallback so we never disable overlap cleanup entirely.
            if int(eroded.sum()) > 0:
                obj_core = eroded
                object_erase_stats['erode_px'] = OBJECT_ERASE_ERODE_PX

        object_erase_stats['core_object_px'] = int(obj_core.sum())
        obj_px = obj_core > 0
        print(f"  Object overlap cleanup: raw={object_erase_stats['raw_object_px']} px, "
              f"core={object_erase_stats['core_object_px']} px "
              f"(erode_px={object_erase_stats['erode_px']})")

        for lbl in wall_door_labels:
            cleared = int(np.sum((label_map == lbl) & obj_px))
            if cleared:
                label_map[(label_map == lbl) & obj_px] = 0
                object_erase_stats['labels_cleared'][IDX_LABEL[lbl]] = cleared
                print(f"  Object mask erased {cleared} px of label '{IDX_LABEL[lbl]}'")

    # ── Gap detection: outer wall ─────────────────────────────────────────────
    outer_gaps = find_wall_gaps(label_map,
                                wall_label_idx=LABEL_IDX['outer_wall'],
                                door_label_idx=LABEL_IDX['outer_door'],
                                min_gap_px=60, max_gap_px=200)

    # ── Gap detection: inner wall ─────────────────────────────────────────────
    inner_gaps = []
    if args.has_inner_walls:
        inner_gaps = find_wall_gaps(label_map,
                                    wall_label_idx=LABEL_IDX['inner_wall'],
                                    door_label_idx=LABEL_IDX['inner_door'],
                                    min_gap_px=60, max_gap_px=190)

    # ── Autofill gap doors into label_map ────────────────────────────────────
    # Paint a door-width stroke at each gap centre into the label map so that
    # combined_wall_door.png and connectivity both see the door as passable.
    # We use a brush radius proportional to the gap length.
    def _fill_gap(lmap, gx, gy, gap_len, door_idx, wall_idx, wrong_idxs=(), axis=None):
        """
        Paint door_idx over a rectangle aligned with the gap direction.

        axis=1 → gap runs vertically   (vertical wall):  tall, narrow rect
        axis=0 → gap runs horizontally (horizontal wall): wide, short rect

        Full gap_len // 2 along the wall axis ensures the whole opening is
        covered, not just the centre third.  20px perpendicular covers the
        wall thickness without bleeding too far into adjacent rooms.
        """
        r_para = gap_len // 2          # along the gap (full half-extent)
        r_perp = 20                    # across the gap (wall thickness)
        if axis == 1:                  # vertical wall → tall rectangle
            rx, ry = r_perp, r_para
        elif axis == 0:                # horizontal wall → wide rectangle
            rx, ry = r_para, r_perp
        else:                          # unknown — square fallback
            rx = ry = max(10, gap_len // 2)

        overwrite = {wall_idx} | set(wrong_idxs)
        for dy in range(-ry, ry + 1):
            for dx in range(-rx, rx + 1):
                ny, nx = gy + dy, gx + dx
                if 0 <= ny < lmap.shape[0] and 0 <= nx < lmap.shape[1]:
                    if lmap[ny, nx] in overwrite:
                        lmap[ny, nx] = door_idx

    for g in outer_gaps:
        _fill_gap(label_map, g['cx'], g['cy'], g['length'],
                  LABEL_IDX['outer_door'], LABEL_IDX['outer_wall'],
                  wrong_idxs=(LABEL_IDX['inner_door'], LABEL_IDX['inner_wall']),
                  axis=g['axis'])
    for g in inner_gaps:
        _fill_gap(label_map, g['cx'], g['cy'], g['length'],
                  LABEL_IDX['inner_door'], LABEL_IDX['inner_wall'],
                  wrong_idxs=(LABEL_IDX['outer_door'], LABEL_IDX['outer_wall']),
                  axis=g['axis'])

    print(f"  Gap autofill: {len(outer_gaps)} outer + {len(inner_gaps)} inner gaps filled")

    # ── Connectivity ──────────────────────────────────────────────────────────
    conn = analyze_connectivity(label_map, h, w, object_mask=object_mask)

    # ── Visualization: annotated ──────────────────────────────────────────────
    viz_ann = label_to_viz(label_map, orig_bgr)

    # Gap fills are already in label_map (painted purple in viz via gap_door color);
    # mark centre with a ring so they're easy to spot
    for g in outer_gaps + inner_gaps:
        cv2.circle(viz_ann, (g['cx'], g['cy']), 14, VIZ_BGR['gap_door'], 2)
    for p in conn['punch_points']:
        px, py = p['point']
        cv2.drawMarker(viz_ann, (px, py), VIZ_BGR['punch'],
                       cv2.MARKER_CROSS, 20, 3)

    cv2.imwrite(os.path.join(args.output_dir, 'colormap_annotated.png'), viz_ann)

    # ── Punch-through dedicated image ─────────────────────────────────────────
    # Brighter view so markers are easy to read: lighten the base image
    punch_vis = (orig_bgr.astype(np.float32) * 0.6).astype(np.uint8)
    # Draw wall+door overlay lightly
    for name, bgr in [('outer_wall', (180, 60, 0)), ('inner_wall', (0, 160, 0)),
                      ('outer_door', (0, 0, 200)),  ('inner_door', (200, 0, 200))]:
        punch_vis[label_map == LABEL_IDX[name]] = bgr
    # Draw object mask as faint orange overlay if available
    if object_mask is not None:
        obj_layer = np.zeros_like(punch_vis)
        obj_layer[object_mask > 0] = (0, 100, 200)   # orange-ish in BGR
        punch_vis = cv2.addWeighted(punch_vis, 1.0, obj_layer, 0.35, 0)
    # Draw each punch point with a large labelled marker
    PUNCH_COLORS = {'outer': (0, 220, 255), 'inner': (255, 220, 0)}  # yellow/cyan
    for p in conn['punch_points']:
        px, py   = p['point']
        wt       = p['wall_type']
        col      = PUNCH_COLORS.get(wt, (255, 255, 255))
        near_obj = p.get('near_object', False)
        # Filled circle
        cv2.circle(punch_vis, (px, py), 18, col, -1)
        cv2.circle(punch_vis, (px, py), 18, (0, 0, 0), 2)
        # Warning ring if near object
        if near_obj:
            cv2.circle(punch_vis, (px, py), 26, (0, 0, 255), 3)
        # Label: wall type + thickness
        label = f"{wt[0].upper()} t={p['wall_thickness']}"
        cv2.putText(punch_vis, label, (px + 22, py + 6),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 0, 0), 3, cv2.LINE_AA)
        cv2.putText(punch_vis, label, (px + 22, py + 6),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.55, col,     1, cv2.LINE_AA)
    cv2.imwrite(os.path.join(args.output_dir, 'punch_annotated.png'), punch_vis)

    # ── Binary wall/door output maps ──────────────────────────────────────────
    # Each mask is 0/255 single channel for easy downstream use
    masks_out = {}
    for name, idx in LABEL_IDX.items():
        m = ((label_map == idx).astype(np.uint8) * 255)
        fname = f'mask_{name}.png'
        cv2.imwrite(os.path.join(args.output_dir, fname), m)
        masks_out[name] = fname

    # Combined: walls in white, doors in grey (128)
    combined = np.zeros((h, w), dtype=np.uint8)
    for name in ('outer_wall', 'inner_wall'):
        combined[label_map == LABEL_IDX[name]] = 255
    for name in ('outer_door', 'inner_door'):
        combined[label_map == LABEL_IDX[name]] = 128
    cv2.imwrite(os.path.join(args.output_dir, 'combined_wall_door.png'), combined)

    # ── Colorized side-by-side comparison ─────────────────────────────────────
    # Scale colormap to same height as original for side-by-side
    cmap_disp = cv2.resize(cmap_bgr, (w, h), interpolation=cv2.INTER_LANCZOS4)
    side_by_side = np.hstack([orig_bgr, cmap_disp, viz_ann])
    cv2.imwrite(os.path.join(args.output_dir, 'side_by_side.png'), side_by_side)

    # ── Results JSON ──────────────────────────────────────────────────────────
    label_counts_final = {
        name: int(np.sum(label_map == idx))
        for name, idx in LABEL_IDX.items()
    }
    result = {
        'label_counts': label_counts,
        'label_counts_post_cleanup': label_counts_final,
        'unchanged_px': unchanged_count,
        'total_px': total_px,
        'outer_gaps': outer_gaps,
        'inner_gaps': inner_gaps,
        'connectivity': conn,
        'object_erase': object_erase_stats,
        'masks': masks_out,
    }
    with open(os.path.join(args.output_dir, 'results.json'), 'w') as f:
        json.dump(result, f, indent=2)

    print(f"Outer wall gaps: {len(outer_gaps)}")
    print(f"Inner wall gaps: {len(inner_gaps)}")
    conn_str = 'OK' if conn['is_connected'] else f"{conn['num_components']} disconnected regions"
    print(f"Connectivity: {conn_str}")
    if conn['punch_points']:
        print(f"Punch-through points: {len(conn['punch_points'])}")


if __name__ == '__main__':
    main()
