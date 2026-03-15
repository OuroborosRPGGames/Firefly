#!/usr/bin/env python3
"""
Wall & Door Detection from depth maps with object mask subtraction.

Key insight: after subtracting SAM object masks from the depth map, remaining
elevated pixels ≈ walls. This gives solid, thick wall regions (vs gradient-based
thin boundary lines) enabling proper skeleton thickness analysis for door detection.

Off-map detection: start from image corners/borders and expand inward through
similar-depth pixels until we find the complete exterior region.

Door detection uses 4 rules:
  1. Thin section — skeleton thickness local minimum
  2. Door posts   — two compact elevated blobs with a passable gap
  3. Edge pairs   — two facing skeleton endpoints with perpendicular orientation
  4. Interruption — clear break/gap in wall contour

Experiments:
  wall_extract     — Depth-threshold wall detection at varying Otsu margins
  contour_analysis — Separate perimeter from internal walls
  door_thinning    — Find doors via rules 1, 2, 3, 4 combined
  door_gap         — Find doors via contour interruptions (rule 4 focused)
  connectivity     — Verify floor reachability (punch-throughs avoid objects)
  llm_verify       — Cross-reference detections with LLM hints

Usage:
  python3 wall_door_detect.py \\
    --image <original.png> --depth <depth.png> --edges <edges.png> \\
    --object-mask <combined_objects.png> --gemini <gemini.json> \\
    --output-dir <dir> --experiment <name> [--params '<json>']
"""

import argparse
import cv2
import json
import math
import numpy as np
import os
import sys


# ── Off-map detection via corner expansion ────────────────────────────────────

def find_offmap_from_corners(depth: np.ndarray, h: int, w: int, base_tolerance: int = 35) -> tuple[np.ndarray, float, int]:
    """
    Find off-map region by starting at image borders and flooding through
    exterior-depth pixels inward.
    Returns (off_map_mask, off_depth, threshold_used).

    Uses a one-sided depth ≤ threshold candidate rather than the old
    |depth - off_depth| ≤ tol approach, which let the symmetric tolerance
    accidentally include wall-depth pixels when off_depth was estimated wrong.

    Key design decisions:
    - Per-border medians: exterior depth is low; wall/floor is high.  A border
      is exterior-like if its median is below EXTERIOR_CUTOFF (120).  Borders
      above this (wall-depth, found in tightly-trimmed images) are excluded from
      seeding so they don't flood through wall pixels.
    - ext_threshold = max(exterior border medians) + small buffer.  This single
      threshold covers all exterior-facing borders regardless of which direction
      has slightly higher exterior depth, without risking inclusion of floor pixels.
    - Progressive expansion: if the exterior region is tiny after the first pass
      (trimmed image — exterior mostly cropped out) we return immediately rather
      than expanding into floor depth territory.
    """
    EXTERIOR_CUTOFF = 120   # border medians above this are wall/floor, not exterior

    step = max(1, min(h, w) // 20)
    top_med    = int(np.median(depth[0, ::step]))
    bottom_med = int(np.median(depth[-1, ::step]))
    left_med   = int(np.median(depth[::step, 0]))
    right_med  = int(np.median(depth[::step, -1]))

    exterior_meds = [m for m in (top_med, bottom_med, left_med, right_med)
                     if m < EXTERIOR_CUTOFF]

    if not exterior_meds:
        # All borders at wall/floor depth — fully trimmed, no exterior present.
        return np.zeros((h, w), np.uint8), min(top_med, bottom_med, left_med, right_med), base_tolerance

    off_depth = min(exterior_meds)
    # Cover all exterior border depths plus a small noise buffer.
    ext_threshold = max(exterior_meds) + 5

    # Seed from exterior-like borders only.
    seed_mask = np.zeros((h, w), np.uint8)
    if top_med    < EXTERIOR_CUTOFF: seed_mask[0, :]  = 255
    if bottom_med < EXTERIOR_CUTOFF: seed_mask[-1, :] = 255
    if left_med   < EXTERIOR_CUTOFF: seed_mask[:, 0]  = 255
    if right_med  < EXTERIOR_CUTOFF: seed_mask[:, -1] = 255

    first_off_map = None
    for extra in [0, base_tolerance, base_tolerance * 2]:
        candidate = (depth.astype(int) <= ext_threshold + extra).astype(np.uint8) * 255
        num_labels, labels = cv2.connectedComponents(candidate)

        border_labels = set(np.unique(labels[seed_mask > 0]))
        border_labels.discard(0)

        off_map = np.zeros((h, w), np.uint8)
        for label in border_labels:
            off_map[labels == label] = 255

        if first_off_map is None:
            first_off_map = off_map.copy()

        if np.sum(off_map > 0) >= h * w * 0.05:
            return off_map, off_depth, ext_threshold + extra

        if extra > 0:
            # Exterior still tiny after one expansion — trimmed image.
            # Return first result to avoid flooding into floor pixels.
            return first_off_map, off_depth, ext_threshold

    return first_off_map if first_off_map is not None else np.zeros((h, w), np.uint8), off_depth, ext_threshold


# ── Core wall detection ───────────────────────────────────────────────────────

def compute_wall_zone_clahe_sobel(cleaned_depth: np.ndarray, object_mask: np.ndarray, h: int, w: int,
                                   sobel_thresh: int = 25, close_px: int | None = None,
                                   gamma_val: float = 0.4, pre_median_k: int = 0) -> np.ndarray:
    """
    Wall detection via CLAHE+Sobel+contour-ring-fill on cleaned depth map.

    Pipeline from edge_report.md + shape_finding.md:
      1. Rescale intensity to full 0-255 (critical for compressed depth ranges)
      2. Gamma γ=gamma_val to nonlinearly boost faint transitions near dark regions
         (0.3 = stronger boost for showing all walls; 0.4 = balanced default)
      3. CLAHE for local contrast (adaptive — works even when global wall/floor
         depths are similar because it normalises locally per tile)
      4. Bilateral filter: smooth noise while preserving depth discontinuities
      4b. Optional median filter (pre_median_k > 0): salt-and-pepper noise removal
          before Sobel — use k=5 for the G pipeline (cleaner lines, slight gaps)
      5. Sobel gradient → detects depth transitions at wall surfaces
      6. Threshold binary edges
      7. Directional closing (separate H+V kernels) — architectural features are
         predominantly rectilinear; this bridges gaps along walls without merging
         perpendicular features (shape_finding.md recommendation)
      8. Isotropic close to fill remaining diagonal/irregular gaps
      9. findContours(RETR_CCOMP): 2-level hierarchy gives outer + hole contours
         Ring fill: fill outer contour (white) → fill child contour (black)
         = only the wall ring, NOT the room interior
     10. Off-map via corner expansion; wall = ring NOT in off-map, NOT in objects

    Returns (wall_zone, off_map, debug_info, enhanced_depth, sobel_gradient).
    """
    # Step 1: Rescale intensity to full 0-255 range (robust to outliers)
    p2, p98 = float(np.percentile(cleaned_depth, 2)), float(np.percentile(cleaned_depth, 98))
    if p98 > p2:
        stretched = np.clip(
            (cleaned_depth.astype(np.float32) - p2) / (p98 - p2) * 255, 0, 255
        ).astype(np.uint8)
    else:
        stretched = cleaned_depth.copy()

    # Step 2: Gamma — power-law curve has steepest slope near 0, giving
    # greatest stretch exactly where near-zero (dark) depth values cluster
    gamma_img = np.power(stretched.astype(np.float32) / 255.0, gamma_val)
    gamma_img = (gamma_img * 255).astype(np.uint8)

    # Step 3: CLAHE — local contrast, works even with similar global depths
    clahe = cv2.createCLAHE(clipLimit=3.0, tileGridSize=(8, 8))
    enhanced = clahe.apply(gamma_img)

    # Step 4: Bilateral filter — preserves depth discontinuities, smooths noise
    smooth = cv2.bilateralFilter(enhanced, d=9, sigmaColor=75, sigmaSpace=75)

    # Step 4b: Optional median filter — further removes salt-and-pepper noise
    # while preserving sharp edges (used by G pipeline with k=5)
    if pre_median_k > 0:
        k = pre_median_k if pre_median_k % 2 == 1 else pre_median_k + 1
        smooth = cv2.medianBlur(smooth, k)

    # Step 5: Sobel gradient on bilaterally-smoothed enhanced depth
    grad_x = cv2.Sobel(smooth, cv2.CV_64F, 1, 0, ksize=3)
    grad_y = cv2.Sobel(smooth, cv2.CV_64F, 0, 1, ksize=3)
    gradient = np.sqrt(grad_x**2 + grad_y**2)
    if gradient.max() > 0:
        gradient = np.clip(gradient / gradient.max() * 255, 0, 255).astype(np.uint8)
    else:
        gradient = np.zeros((h, w), np.uint8)

    # Step 6: Threshold → binary edge image
    _, edges = cv2.threshold(gradient, sobel_thresh, 255, cv2.THRESH_BINARY)

    # Step 7: Directional closing (shape_finding.md): separate H+V kernels exploit
    # rectilinear geometry — bridges gaps along walls without merging perpendicular edges
    dir_size = max(7, max(h, w) // 80)
    h_kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (dir_size, 1))
    v_kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (1, dir_size))
    h_closed = cv2.morphologyEx(edges, cv2.MORPH_CLOSE, h_kernel)
    v_closed = cv2.morphologyEx(edges, cv2.MORPH_CLOSE, v_kernel)
    directional = cv2.bitwise_or(h_closed, v_closed)

    # Step 8: Isotropic close to fill remaining gaps
    if close_px is None:
        close_px = max(h, w) // 25  # ~4% of image
    close_px = max(close_px, 5)
    kernel_iso = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (close_px, close_px))
    edges_closed = cv2.morphologyEx(directional, cv2.MORPH_CLOSE, kernel_iso)

    # Step 9: RETR_CCOMP ring fill
    # RETR_CCOMP gives 2-level hierarchy: level 0 = outer boundaries,
    # level 1 = holes inside those boundaries. For a wall:
    #   outer contour encloses (room + wall); child contour encloses room interior.
    #   Fill outer white → fill child black = only the wall ring remains.
    contours, hierarchy = cv2.findContours(
        edges_closed, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_SIMPLE
    )
    wall_candidate = np.zeros((h, w), np.uint8)
    if contours and hierarchy is not None:
        hier = hierarchy[0]  # shape (N, 4): [Next, Prev, First_Child, Parent]
        min_area = (max(h, w) * 0.02) ** 2  # skip tiny noise contours

        # Pass 1: fill all top-level contours (parent == -1) white
        for i, (c, hi) in enumerate(zip(contours, hier)):
            if hi[3] == -1 and cv2.contourArea(c) >= min_area:
                cv2.drawContours(wall_candidate, [c], -1, 255, cv2.FILLED)

        # Pass 2: erase children (holes = interior regions) with black
        for i, (c, hi) in enumerate(zip(contours, hier)):
            if hi[3] != -1 and cv2.contourArea(c) >= min_area:
                cv2.drawContours(wall_candidate, [c], -1, 0, cv2.FILLED)

    # Fallback: if contour fill produced nothing, use dilated edges directly
    if np.sum(wall_candidate > 0) < h * w * 0.02:
        fallback_px = max(h, w) // 20
        kf = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (fallback_px, fallback_px))
        wall_candidate = cv2.dilate(edges_closed, kf)

    # Remove tiny noise blobs
    kernel_open = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
    wall_candidate = cv2.morphologyEx(wall_candidate, cv2.MORPH_OPEN, kernel_open)

    # Step 10: Off-map via corner expansion; wall = candidate NOT in exterior/objects
    off_map, off_depth, tol = find_offmap_from_corners(cleaned_depth, h, w)
    wall_zone = cv2.bitwise_and(wall_candidate, cv2.bitwise_not(off_map))
    wall_zone[object_mask > 0] = 0

    debug_info = {
        'method': 'clahe_sobel',
        'sobel_thresh': sobel_thresh,
        'close_px': close_px,
        'dir_close_px': dir_size,
        'gamma_val': gamma_val,
        'pre_median_k': pre_median_k,
        'off_depth': int(off_depth),
        'off_map_tolerance': int(tol),
    }
    return wall_zone, off_map, debug_info, enhanced, gradient


def compute_wall_zone(cleaned_depth: np.ndarray, object_mask: np.ndarray, h: int, w: int, otsu_margin: int = 15) -> np.ndarray:
    """
    Fallback: depth-threshold wall detection (Otsu on interior pixels).
    Use when CLAHE+Sobel doesn't give clean results.
    Returns (wall_zone, off_map, debug_info).
    """
    off_map, off_depth, tol = find_offmap_from_corners(cleaned_depth, h, w)

    interior_pixels = cleaned_depth[off_map == 0]
    if len(interior_pixels) > 100:
        hist = cv2.calcHist(
            [interior_pixels.reshape(-1, 1).astype(np.uint8)],
            [0], None, [256], [0, 256]
        ).flatten()
        hist_smooth = np.convolve(hist, np.ones(11) / 11, mode='same')
        floor_peak = int(np.argmax(hist_smooth[5:251]) + 5)
        flat = interior_pixels.reshape(-1, 1).astype(np.uint8)
        otsu_val, _ = cv2.threshold(flat, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
        otsu_thresh = int(otsu_val)
    else:
        floor_peak = 128
        otsu_thresh = 143

    if otsu_thresh >= floor_peak:
        threshold = max(otsu_thresh, floor_peak + otsu_margin)
        elevated = (cleaned_depth > threshold).astype(np.uint8) * 255
        depth_inverted = False
    else:
        threshold = min(otsu_thresh, floor_peak - otsu_margin)
        elevated = (cleaned_depth < threshold).astype(np.uint8) * 255
        depth_inverted = True

    elevated[object_mask > 0] = 0
    kernel_close = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (9, 9))
    kernel_open = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
    wall_candidate = cv2.morphologyEx(elevated, cv2.MORPH_CLOSE, kernel_close)
    wall_candidate = cv2.morphologyEx(wall_candidate, cv2.MORPH_OPEN, kernel_open)
    wall_zone = cv2.bitwise_and(wall_candidate, cv2.bitwise_not(off_map))

    debug_info = {
        'method': 'otsu',
        'off_depth': int(off_depth),
        'off_map_tolerance': int(tol),
        'floor_peak': int(floor_peak),
        'otsu_thresh': int(otsu_thresh),
        'effective_threshold': int(threshold),
        'depth_inverted': bool(depth_inverted),
    }
    return wall_zone, off_map, debug_info


def fill_mask_holes(mask: np.ndarray) -> np.ndarray:
    """
    Fill interior holes in a binary mask (0/255).

    Holes form when objects sitting ON TOP of a detected object (e.g. items on
    a table) break the SAMG segmentation, leaving transparent voids inside an
    otherwise solid mask.

    Algorithm:
      1. Morphological close (21px) to seal thin channels connecting interior
         holes to the image border — without this, flood-fill leaks through the
         channel and treats the hole as exterior, skipping it.
      2. Flood-fill from the image border on the closed mask → exterior background
      3. Fill any background not reachable from the border (= interior holes)
      4. Apply filled holes back onto the original mask to preserve exact boundaries
      5. Small dilation to catch object edges that barely overhang the parent

    Returns a filled binary mask (same size, dtype uint8, values 0/255).
    """
    h, w = mask.shape[:2]

    # Pass 1: global 15px seal + RETR_CCOMP for small enclosed holes
    kernel_seal = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (15, 15))
    pre_sealed = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel_seal)
    contours, hierarchy = cv2.findContours(pre_sealed, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_SIMPLE)
    filled = mask.copy()
    if hierarchy is not None:
        for i in range(len(contours)):
            if hierarchy[0][i][3] != -1:
                cv2.drawContours(filled, contours, i, 255, -1)
    # Pass 2: per-component proportional close (scales gap tolerance with object size)
    num_labels, labels, stats, _ = cv2.connectedComponentsWithStats(filled)
    for i in range(1, num_labels):
        if stats[i, cv2.CC_STAT_AREA] < 200:
            continue
        bw = stats[i, cv2.CC_STAT_WIDTH]
        bh = stats[i, cv2.CC_STAT_HEIGHT]
        k = max(15, int(min(bw, bh) * 0.15))
        k = k if k % 2 == 1 else k + 1
        x0, y0 = stats[i, cv2.CC_STAT_LEFT], stats[i, cv2.CC_STAT_TOP]
        pad = k
        r0 = max(0, y0 - pad); r1 = min(h, y0 + bh + pad)
        c0 = max(0, x0 - pad); c1 = min(w, x0 + bw + pad)
        comp = (labels[r0:r1, c0:c1] == i).astype(np.uint8) * 255
        kk = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k))
        closed = cv2.morphologyEx(comp, cv2.MORPH_CLOSE, kk, iterations=2)
        filled[r0:r1, c0:c1] = cv2.bitwise_or(filled[r0:r1, c0:c1], closed)

    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    return cv2.dilate(filled, kernel, iterations=1)


def subtract_objects(depth: np.ndarray, object_mask: np.ndarray) -> np.ndarray:
    """
    Fill object pixels using inpainting capped at floor depth.

    Inpainting produces smooth transitions at object edges (better than flat
    floor-fill for dark objects on lighter areas like the bench shadow problem).
    However, objects near walls would inherit wall-like brightness via inpainting.
    Fix: cap every inpainted pixel at min(border_median, floor_depth).

    - border_median: median depth of the 5px ring immediately outside the mask —
      reflects the actual local environment (floor, not wall) for most objects.
    - floor_depth: mode of all non-object interior pixels — global floor estimate.
    - Taking the min of both ensures neither wall-adjacent nor globally-biased
      values can brighten the filled region above what the floor actually reads.
    """
    if np.sum(object_mask > 0) == 0:
        return depth.copy()

    mask_u8 = (object_mask > 0).astype(np.uint8)

    # Floor depth = mode of non-object pixels with depth ≥ 50.
    non_obj = depth[mask_u8 == 0].ravel()
    interior = non_obj[non_obj >= 50]
    if len(interior) > 100:
        hist = np.bincount(interior.astype(np.int32), minlength=256)
        floor_depth = int(np.argmax(hist))
    else:
        floor_depth = int(np.median(non_obj))

    # Dilate mask to cover depth-model halos around object edges.
    dil_kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (9, 9))
    mask_u8 = cv2.dilate(mask_u8, dil_kernel, iterations=1)

    # Ceiling cap: block wall-level values from bleeding in via inpainting.
    # Wall depth ≈ floor_depth + 40-60; cap at floor_depth + 25 to allow
    # natural local floor variation while staying well below wall depth.
    ceiling = floor_depth + 25

    # Inpaint, then clamp to ceiling.
    inpainted = cv2.inpaint(depth, mask_u8, 3, cv2.INPAINT_TELEA)
    result = depth.copy()
    result[mask_u8 > 0] = np.minimum(inpainted[mask_u8 > 0], ceiling)
    return result


def compute_wall_zone_combined(depth: np.ndarray, object_mask: np.ndarray, h: int, w: int, perim_pct: float = 0.07, otsu_margin: int = 15) -> np.ndarray:
    """
    Combined geometric + depth approach — replaces CLAHE+Sobel for downstream experiments.

    Perimeter wall: pure geometry — distance-transform band from off-map boundary.
      Off-map detection is reliable (corner expansion, proven with off_depth=164).
      This guarantees a clean perimeter ring regardless of depth map noise.

    Internal walls: Otsu threshold on interior depth pixels only.
      Simpler problem than global Otsu: only needs to separate floor from elevated
      blobs within the room interior (furniture already subtracted via object_mask).

    Returns (wall_zone, off_map, debug_info) — same signature as compute_wall_zone.
    """
    off_map, off_depth, tol = find_offmap_from_corners(depth, h, w)

    # ── Perimeter wall: distance-transform band from off-map ──────────────────
    not_offmap = cv2.bitwise_not(off_map)
    dist_from_offmap = cv2.distanceTransform(not_offmap, cv2.DIST_L2, 5)
    perim_px = max(int(max(h, w) * perim_pct), 20)
    perim_wall = ((dist_from_offmap > 0) & (dist_from_offmap < perim_px)).astype(np.uint8) * 255
    perim_wall[object_mask > 0] = 0

    # ── Interior: pixels inside perimeter, not off-map ────────────────────────
    interior_mask = ((off_map == 0) & (perim_wall == 0)).astype(np.uint8) * 255

    # ── Internal walls: Otsu on interior depth pixels ─────────────────────────
    interior_pixels = depth[interior_mask > 0]
    floor_peak = 128
    otsu_thresh = 143
    depth_inverted = False

    if len(interior_pixels) > 100:
        hist = cv2.calcHist(
            [interior_pixels.reshape(-1, 1).astype(np.uint8)],
            [0], None, [256], [0, 256]
        ).flatten()
        hist_smooth = np.convolve(hist, np.ones(11) / 11, mode='same')
        floor_peak = int(np.argmax(hist_smooth[5:251]) + 5)
        flat = interior_pixels.reshape(-1, 1).astype(np.uint8)
        otsu_val, _ = cv2.threshold(flat, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
        otsu_thresh = int(otsu_val)

    if otsu_thresh >= floor_peak:
        threshold = max(otsu_thresh, floor_peak + otsu_margin)
        elevated = (depth > threshold).astype(np.uint8) * 255
        depth_inverted = False
    else:
        threshold = min(otsu_thresh, floor_peak - otsu_margin)
        elevated = (depth < threshold).astype(np.uint8) * 255
        depth_inverted = True

    # Restrict to interior only
    elevated = cv2.bitwise_and(elevated, interior_mask)
    elevated[object_mask > 0] = 0

    # Morphological cleanup: close gaps, remove noise
    kernel_close = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (11, 11))
    kernel_open = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    internal_candidate = cv2.morphologyEx(elevated, cv2.MORPH_CLOSE, kernel_close)
    internal_candidate = cv2.morphologyEx(internal_candidate, cv2.MORPH_OPEN, kernel_open)

    # Filter: keep only blobs large enough to be real walls (not noise)
    min_internal_area = int((max(h, w) * 0.02) ** 2 / 4)
    num_labels, labels = cv2.connectedComponents(internal_candidate)
    internal_walls = np.zeros((h, w), np.uint8)
    for i in range(1, num_labels):
        area = int(np.sum(labels == i))
        if area >= min_internal_area:
            internal_walls[labels == i] = 255

    # ── Combine perimeter + internal ──────────────────────────────────────────
    wall_zone = cv2.bitwise_or(perim_wall, internal_walls)

    debug_info = {
        'method': 'combined',
        'off_depth': int(off_depth),
        'off_map_tolerance': int(tol),
        'perim_px': int(perim_px),
        'floor_peak': int(floor_peak),
        'otsu_thresh': int(otsu_thresh),
        'effective_threshold': int(threshold),
        'depth_inverted': bool(depth_inverted),
    }
    return wall_zone, off_map, debug_info


# ── Direction helpers ─────────────────────────────────────────────────────────

def direction_from_angle(angle_deg: float) -> str:
    a = angle_deg % 360
    if a < 22.5 or a >= 337.5:   return 'e'
    elif a < 67.5:                return 'ne'
    elif a < 112.5:               return 'n'
    elif a < 157.5:               return 'nw'
    elif a < 202.5:               return 'w'
    elif a < 247.5:               return 'sw'
    elif a < 292.5:               return 's'
    else:                         return 'se'


def point_direction(px: int, py: int, cx: int, cy: int) -> str:
    angle = math.degrees(math.atan2(-(py - cy), px - cx))
    return direction_from_angle(angle)


def colorize_zone_map(wall_zone: np.ndarray, off_map: np.ndarray, h: int, w: int, image: np.ndarray | None = None, alpha: float = 0.45) -> np.ndarray:
    """Zone colorization. If image provided, blends colors onto it as a semi-transparent overlay."""
    color = np.zeros((h, w, 3), dtype=np.uint8)
    color[:, :] = [200, 200, 150]         # floor = light tan
    color[off_map > 0] = [40, 40, 40]     # off_map = dark gray
    color[wall_zone > 0] = [0, 0, 200]    # wall = red (BGR)
    if image is not None:
        img3 = image if image.ndim == 3 else cv2.cvtColor(image, cv2.COLOR_GRAY2BGR)
        return cv2.addWeighted(img3, 1 - alpha, color, alpha, 0)
    return color


# ── Skeleton helpers ──────────────────────────────────────────────────────────

def find_skeleton_endpoints(skeleton: np.ndarray) -> list[tuple[int, int]]:
    """Return list of (y, x) endpoint coordinates (pixels with exactly 1 neighbor)."""
    kernel = np.ones((3, 3), dtype=np.uint8)
    kernel[1, 1] = 0
    neighbor_count = cv2.filter2D((skeleton > 0).astype(np.uint8), -1, kernel)
    endpoint_mask = (skeleton > 0) & (neighbor_count == 1)
    points = np.argwhere(endpoint_mask)
    return [(int(p[0]), int(p[1])) for p in points]


# ── Door detection helpers ────────────────────────────────────────────────────

def detect_door_posts(wall_zone, object_mask, h, w, gemini=None,
                      min_gap_px=15, max_gap_px=100):
    """
    Rule 2: Door posts — pairs of compact elevated blobs at appropriate distance.
    Filters out pairs where the gap centroid lands on an object.
    Returns list of door post candidates.
    """
    # Find connected components of wall
    num_labels, labels = cv2.connectedComponents(wall_zone)

    blobs = []
    for i in range(1, num_labels):
        blob_mask = (labels == i).astype(np.uint8)
        area = int(np.sum(blob_mask))
        if area < 30 or area > (h * w * 0.05):
            continue

        pts = cv2.findNonZero(blob_mask * 255)
        if pts is None:
            continue
        rect = cv2.minAreaRect(pts)
        rw, rh = rect[1]
        if rw < 2 or rh < 2:
            continue
        aspect = max(rw, rh) / min(rw, rh)

        M = cv2.moments(blob_mask)
        if M['m00'] == 0:
            continue
        cx = float(M['m10'] / M['m00'])
        cy = float(M['m01'] / M['m00'])

        blobs.append({'id': i, 'cx': cx, 'cy': cy, 'area': area,
                      'aspect': aspect, 'rect': rect})

    llm_doors = set(gemini.get('perimeter_wall_doors', []) if gemini else [])
    img_cx, img_cy = w / 2.0, h / 2.0

    candidates = []
    used = set()
    for i, b1 in enumerate(blobs):
        if i in used:
            continue
        for j, b2 in enumerate(blobs):
            if j <= i or j in used:
                continue
            dist = math.sqrt((b2['cx'] - b1['cx'])**2 + (b2['cy'] - b1['cy'])**2)
            if not (min_gap_px <= dist <= max_gap_px):
                continue
            size_ratio = (min(b1['area'], b2['area']) /
                          max(b1['area'], b2['area']))
            if size_ratio < 0.3:
                continue  # very different sizes — not matching posts
            # Both should be compact (aspect ratio < 3)
            if b1['aspect'] > 3.5 or b2['aspect'] > 3.5:
                continue

            gap_cx = (b1['cx'] + b2['cx']) / 2
            gap_cy = (b1['cy'] + b2['cy']) / 2

            # Don't punch into an object
            gxi, gyi = int(gap_cx), int(gap_cy)
            gxi = max(0, min(w - 1, gxi))
            gyi = max(0, min(h - 1, gyi))
            if object_mask[gyi, gxi] > 0:
                continue

            direction = point_direction(gap_cx, gap_cy, img_cx, img_cy)
            used.add(i)
            used.add(j)
            candidates.append({
                'type': 'door_posts',
                'post1': [round(b1['cx'], 1), round(b1['cy'], 1)],
                'post2': [round(b2['cx'], 1), round(b2['cy'], 1)],
                'gap_px': round(dist, 1),
                'centroid': [round(gap_cx, 1), round(gap_cy, 1)],
                'direction': direction,
                'llm_match': direction in llm_doors,
                'score': round(size_ratio * (1 - dist / max_gap_px), 3),
            })

    return candidates


def detect_edge_pairs(skeleton, wall_zone, object_mask, h, w, gemini=None,
                      min_gap=10, max_gap=80):
    """
    Rule 3: Facing skeleton endpoint pairs (perpendicular wall edges).
    Two skeleton endpoints near each other whose local wall directions are
    roughly opposite → they're the two sides of a door opening.
    Returns list of edge-pair candidates.
    """
    endpoints = find_skeleton_endpoints(skeleton)
    if not endpoints:
        return []

    llm_doors = set(gemini.get('perimeter_wall_doors', []) if gemini else [])
    img_cx, img_cy = w / 2.0, h / 2.0

    # For each endpoint, estimate local wall direction using neighbor skeleton pixels
    def local_wall_dir(ey, ex, radius=8):
        ys = slice(max(0, ey - radius), min(h, ey + radius + 1))
        xs = slice(max(0, ex - radius), min(w, ex + radius + 1))
        region = skeleton[ys, xs]
        pts = np.argwhere(region > 0)
        if len(pts) < 2:
            return None
        pts = pts - np.array([ey - max(0, ey - radius), ex - max(0, ex - radius)])
        # PCA-like: main direction = eigenvector of covariance
        cov = np.cov(pts.T)
        if cov.shape != (2, 2):
            return None
        vals, vecs = np.linalg.eigh(cov)
        main = vecs[:, -1]  # eigenvector of largest eigenvalue
        return main  # (dy, dx) of wall direction at this endpoint

    candidates = []
    used = set()

    for i, (y1, x1) in enumerate(endpoints):
        if i in used:
            continue
        dir1 = local_wall_dir(y1, x1)

        best_j, best_dist = -1, float('inf')
        for j, (y2, x2) in enumerate(endpoints):
            if j <= i or j in used:
                continue
            dist = math.sqrt((x2 - x1)**2 + (y2 - y1)**2)
            if not (min_gap <= dist <= max_gap):
                continue
            if dist < best_dist:
                best_j, best_dist = j, dist

        if best_j < 0:
            continue

        y2, x2 = endpoints[best_j]
        dir2 = local_wall_dir(y2, x2)

        gap_cx = (x1 + x2) / 2.0
        gap_cy = (y1 + y2) / 2.0

        # Check opening is not into an object
        gxi, gyi = int(gap_cx), int(gap_cy)
        gxi = max(0, min(w - 1, gxi))
        gyi = max(0, min(h - 1, gyi))
        if object_mask[gyi, gxi] > 0:
            continue

        # Score: higher if wall directions are anti-parallel (facing each other)
        facing_score = 0.5
        if dir1 is not None and dir2 is not None:
            dot = float(np.dot(dir1, dir2))
            facing_score = (1.0 - dot) / 2.0  # anti-parallel → score ≈ 1

        direction = point_direction(gap_cx, gap_cy, img_cx, img_cy)
        used.add(i)
        used.add(best_j)

        candidates.append({
            'type': 'edge_pair',
            'point1': [x1, y1],
            'point2': [x2, y2],
            'gap_px': round(best_dist, 1),
            'centroid': [round(gap_cx, 1), round(gap_cy, 1)],
            'direction': direction,
            'llm_match': direction in llm_doors,
            'facing_score': round(facing_score, 3),
            'score': round(facing_score * (1 - best_dist / max_gap), 3),
        })

    return candidates


# ── Experiment 1: wall_extract ────────────────────────────────────────────────

def _wall_metrics(wall_zone, off_map, h, w):
    """Compute standard metrics for a wall zone mask."""
    total = h * w
    wall_px = int(np.sum(wall_zone > 0))
    off_px = int(np.sum(off_map > 0))
    floor_px = total - wall_px - off_px
    wall_frac = wall_px / total
    _, wall_labels = cv2.connectedComponents(wall_zone)
    num_wc = int(wall_labels.max())
    sizes = [int(np.sum(wall_labels == i)) for i in range(1, num_wc + 1)]
    largest_frac = (max(sizes) / wall_px) if (wall_px > 0 and sizes) else 0
    return {
        'wall_area_fraction': round(wall_frac, 4),
        'wall_pixels': wall_px,
        'num_components': num_wc,
        'largest_component_frac': round(largest_frac, 4),
        'off_map_fraction': round(off_px / total, 4),
        'floor_fraction': round(floor_px / total, 4),
    }


def run_wall_extract(image, depth, edges, object_mask, gemini, output_dir, params):
    """
    Run BOTH wall detection methods for comparison:
      A) CLAHE+Sobel+ring-fill (primary)
      B) Otsu depth threshold (fallback)
    Parameterised by sobel_thresh (method A) and otsu_margin (method B).
    """
    sobel_thresh = params.get('sobel_thresh', 25)
    close_px = params.get('close_px', None)
    otsu_margin = params.get('otsu_margin', 15)
    h, w = depth.shape

    cleaned_depth = subtract_objects(depth, object_mask)
    cv2.imwrite(os.path.join(output_dir, 'cleaned_depth.png'), cleaned_depth)

    # ── Method A: CLAHE+Sobel+ring-fill ──────────────────────────────────────
    wall_a, off_map_a, dbg_a, enhanced, gradient = compute_wall_zone_clahe_sobel(
        cleaned_depth, object_mask, h, w,
        sobel_thresh=sobel_thresh, close_px=close_px
    )
    metrics_a = _wall_metrics(wall_a, off_map_a, h, w)

    cv2.imwrite(os.path.join(output_dir, 'enhanced_depth.png'), enhanced)
    cv2.imwrite(os.path.join(output_dir, 'sobel_gradient.png'), gradient)
    cv2.imwrite(os.path.join(output_dir, 'wall_mask_clahe.png'), wall_a)
    cv2.imwrite(os.path.join(output_dir, 'zone_colorized_clahe.png'),
                colorize_zone_map(wall_a, off_map_a, h, w, image=image))

    overlay_a = image.copy()
    overlay_a[wall_a > 0] = [0, 0, 200]
    blended_a = cv2.addWeighted(image, 0.6, overlay_a, 0.4, 0)
    cv2.imwrite(os.path.join(output_dir, 'wall_overlay_clahe.png'), blended_a)

    # Default outputs named without suffix for backward compatibility
    cv2.imwrite(os.path.join(output_dir, 'wall_mask.png'), wall_a)
    cv2.imwrite(os.path.join(output_dir, 'zone_colorized.png'),
                colorize_zone_map(wall_a, off_map_a, h, w, image=image))
    cv2.imwrite(os.path.join(output_dir, 'wall_overlay.png'), blended_a)
    cv2.imwrite(os.path.join(output_dir, 'off_map.png'), off_map_a)

    # ── Method B: Otsu depth threshold ───────────────────────────────────────
    wall_b, off_map_b, dbg_b = compute_wall_zone(
        cleaned_depth, object_mask, h, w, otsu_margin=otsu_margin
    )
    metrics_b = _wall_metrics(wall_b, off_map_b, h, w)

    cv2.imwrite(os.path.join(output_dir, 'wall_mask_otsu.png'), wall_b)
    cv2.imwrite(os.path.join(output_dir, 'zone_colorized_otsu.png'),
                colorize_zone_map(wall_b, off_map_b, h, w, image=image))
    overlay_b = image.copy()
    overlay_b[wall_b > 0] = [0, 0, 200]
    blended_b = cv2.addWeighted(image, 0.6, overlay_b, 0.4, 0)
    cv2.imwrite(os.path.join(output_dir, 'wall_overlay_otsu.png'), blended_b)

    results = {
        'sobel_thresh': sobel_thresh,
        'close_px': dbg_a['close_px'],
        **{'clahe_' + k: v for k, v in metrics_a.items()},
        **{'clahe_' + k: v for k, v in dbg_a.items()},
        'otsu_margin': otsu_margin,
        **{'otsu_' + k: v for k, v in metrics_b.items()},
        **{'otsu_' + k: v for k, v in dbg_b.items()},
        # Primary (for downstream experiments)
        'wall_area_fraction': metrics_a['wall_area_fraction'],
        'num_components': metrics_a['num_components'],
        'largest_component_frac': metrics_a['largest_component_frac'],
        'floor_peak': dbg_b.get('floor_peak', 0),
        'otsu_thresh': dbg_b.get('otsu_thresh', 0),
        'effective_threshold': dbg_b.get('effective_threshold', 0),
        'depth_inverted': dbg_b.get('depth_inverted', False),
        'off_depth': dbg_a.get('off_depth', 0),
        'off_map_tolerance': dbg_a.get('off_map_tolerance', 0),
    }

    print(f"  wall_extract (sobel={sobel_thresh}, close={dbg_a['close_px']}px): "
          f"CLAHE wall={metrics_a['wall_area_fraction']*100:.1f}% {metrics_a['num_components']}comp | "
          f"Otsu wall={metrics_b['wall_area_fraction']*100:.1f}% {metrics_b['num_components']}comp")
    return results


# ── Experiment 2: contour_analysis ───────────────────────────────────────────

def run_contour_analysis(image, depth, edges, object_mask, gemini, output_dir, params):
    """
    Separate perimeter from internal walls.

    Perimeter wall: the large connected wall region touching the off-map boundary.
    Internal walls: elongated elevated blobs inside the perimeter not touching the
    off-map region. Shape (aspect ratio) determines whether a blob is wall-like.
    No 3x3 grid quadrant mapping — uses actual spatial position relative to centroid.
    """
    h, w = depth.shape
    cleaned_depth = subtract_objects(depth, object_mask)

    wall_zone, off_map, dbg = compute_wall_zone_combined(cleaned_depth, object_mask, h, w)

    img_cx, img_cy = w / 2.0, h / 2.0

    # Label wall components
    num_labels, labels = cv2.connectedComponents(wall_zone)

    # Off-map dilated: used to identify perimeter wall (touches exterior)
    kernel_grow = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (11, 11))
    off_dilated = cv2.dilate(off_map, kernel_grow, iterations=2)

    perimeter_blobs = []
    internal_blobs = []

    for i in range(1, num_labels):
        blob = (labels == i).astype(np.uint8) * 255
        area = int(np.sum(blob > 0))
        if area < 50:
            continue

        # Does this blob touch the off_map / exterior?
        touches_exterior = cv2.bitwise_and(blob, off_dilated)
        is_perimeter = np.any(touches_exterior > 0)

        pts = cv2.findNonZero(blob)
        if pts is None:
            continue
        rect = cv2.minAreaRect(pts)
        rw, rh = rect[1]
        if rw < 2 or rh < 2:
            aspect = 1.0
        else:
            aspect = max(rw, rh) / min(rw, rh)

        M = cv2.moments(blob)
        cx = float(M['m10'] / M['m00']) if M['m00'] > 0 else 0
        cy = float(M['m01'] / M['m00']) if M['m00'] > 0 else 0
        direction = point_direction(cx, cy, img_cx, img_cy)

        info = {
            'label': i,
            'area': area,
            'aspect_ratio': round(aspect, 2),
            'centroid': [round(cx, 1), round(cy, 1)],
            'direction': direction,
            'is_elongated': aspect > 2.5,
        }

        if is_perimeter:
            perimeter_blobs.append(info)
        else:
            info['llm_match'] = False
            # Cross-reference with LLM internal walls (by actual quadrant position)
            for llm_w in (gemini.get('internal_walls', []) if gemini else []):
                if llm_w.get('location') == direction:
                    info['llm_match'] = True
                    break
            internal_blobs.append(info)

    # Sort perimeter by area (largest = main wall)
    perimeter_blobs.sort(key=lambda b: -b['area'])
    internal_blobs.sort(key=lambda b: -b['area'])

    # Draw visualization
    vis = image.copy()

    # Perimeter blobs in blue
    for b in perimeter_blobs:
        blob = (labels == b['label']).astype(np.uint8) * 255
        contours, _ = cv2.findContours(blob, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        cv2.drawContours(vis, contours, -1, (255, 100, 0), 2)

    # Internal blobs: yellow=elongated, grey=compact
    for b in internal_blobs:
        blob = (labels == b['label']).astype(np.uint8) * 255
        contours, _ = cv2.findContours(blob, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        color = (0, 255, 255) if b['is_elongated'] else (100, 100, 100)
        cv2.drawContours(vis, contours, -1, color, 2)
        cx, cy = int(b['centroid'][0]), int(b['centroid'][1])
        label = f"{b['direction']} AR={b['aspect_ratio']:.1f}"
        cv2.putText(vis, label, (cx - 40, cy - 8),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.45, color, 1)

    # LLM expected internal wall directions (shown as annotated circles)
    for llm_w in (gemini.get('internal_walls', []) if gemini else []):
        loc = llm_w.get('location', '')
        # Draw a text label near the quadrant center (rough spatial estimate)
        dir_map = {
            'n': (w//2, h//5), 's': (w//2, 4*h//5),
            'e': (4*w//5, h//2), 'w': (w//5, h//2),
            'ne': (4*w//5, h//5), 'nw': (w//5, h//5),
            'se': (4*w//5, 4*h//5), 'sw': (w//5, 4*h//5),
        }
        if loc in dir_map:
            qx, qy = dir_map[loc]
            cv2.circle(vis, (qx, qy), 25, (0, 200, 200), 1)
            cv2.putText(vis, f"LLM:{loc}", (qx - 30, qy + 40),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.4, (0, 200, 200), 1)

    cv2.imwrite(os.path.join(output_dir, 'contour_overlay.png'), vis)
    cv2.imwrite(os.path.join(output_dir, 'wall_mask.png'), wall_zone)

    results = {
        'num_perimeter_blobs': len(perimeter_blobs),
        'num_internal_blobs': len(internal_blobs),
        'perimeter_blobs': perimeter_blobs[:5],
        'internal_blobs': [b for b in internal_blobs if b['area'] > 200][:10],
        'llm_internal_locations': [w.get('location') for w in (gemini.get('internal_walls', []) if gemini else [])],
        **{k: v for k, v in dbg.items()},
    }

    print(f"  contour_analysis: {len(perimeter_blobs)} perimeter blobs, "
          f"{len(internal_blobs)} internal blobs")
    return results


# ── Experiment 3: door_thinning (all 4 rules) ────────────────────────────────

def run_door_thinning(image, depth, edges, object_mask, gemini, output_dir, params):
    """
    Detect doors using 4 rules:
      Rule 1 — Thin section in skeleton (local thickness minimum)
      Rule 2 — Door posts (two compact blobs with passable gap)
      Rule 3 — Facing skeleton endpoint pairs (perpendicular wall edges)
      Rule 4 — Skeleton endpoint cluster (clear interruption, handled in door_gap)
    """
    thin_ratio = params.get('thin_ratio', 0.5)
    min_cluster_gap = params.get('min_cluster_gap', 20)
    h, w = depth.shape

    cleaned_depth = subtract_objects(depth, object_mask)
    wall_zone, off_map, dbg = compute_wall_zone_combined(cleaned_depth, object_mask, h, w)

    wall_binary = (wall_zone > 0).astype(np.uint8) * 255
    dist_inside_wall = cv2.distanceTransform(wall_binary, cv2.DIST_L2, 5)
    skeleton = cv2.ximgproc.thinning(wall_binary)

    # ── Rule 1: thin section ──────────────────────────────────────────────────
    rule1_candidates = []
    skeleton_points = np.argwhere(skeleton > 0)
    if len(skeleton_points) > 0:
        thickness_values = dist_inside_wall[skeleton > 0]
        median_thickness = float(np.median(thickness_values))
        thin_threshold = median_thickness * thin_ratio

        thin_mask = np.zeros((h, w), dtype=np.uint8)
        for pt, val in zip(skeleton_points, thickness_values):
            if 0 < val < thin_threshold:
                thin_mask[pt[0], pt[1]] = 255

        if np.sum(thin_mask > 0) > 0:
            kernel = cv2.getStructuringElement(
                cv2.MORPH_ELLIPSE, (min_cluster_gap, min_cluster_gap))
            clustered = cv2.dilate(thin_mask, kernel, iterations=1)
            num_clusters, cluster_labels = cv2.connectedComponents(clustered)
            img_cx, img_cy = w / 2.0, h / 2.0
            llm_doors = set(gemini.get('perimeter_wall_doors', []) if gemini else [])

            for i in range(1, num_clusters):
                cluster_mask = (cluster_labels == i).astype(np.uint8) * 255
                cluster_thin = cv2.bitwise_and(thin_mask, cluster_mask)
                pts = np.argwhere(cluster_thin > 0)
                if len(pts) == 0:
                    continue
                cy = float(np.mean(pts[:, 0]))
                cx = float(np.mean(pts[:, 1]))
                gxi, gyi = int(cx), int(cy)
                gxi = max(0, min(w - 1, gxi)); gyi = max(0, min(h - 1, gyi))
                if object_mask[gyi, gxi] > 0:
                    continue
                mean_t = float(np.mean(dist_inside_wall[cluster_thin > 0]))
                direction = point_direction(cx, cy, img_cx, img_cy)
                score = 1.0 - (mean_t / median_thickness) if median_thickness > 0 else 0
                if direction in llm_doors:
                    score = min(1.0, score + 0.3)
                rule1_candidates.append({
                    'type': 'thin_section',
                    'centroid': [round(cx, 1), round(cy, 1)],
                    'direction': direction,
                    'mean_thickness': round(mean_t, 1),
                    'num_points': len(pts),
                    'score': round(score, 3),
                    'llm_match': direction in llm_doors,
                })
    else:
        median_thickness = 0.0
        thin_threshold = 0.0
        thin_mask = np.zeros((h, w), dtype=np.uint8)

    # ── Rule 2: door posts ────────────────────────────────────────────────────
    rule2_candidates = detect_door_posts(wall_zone, object_mask, h, w, gemini)

    # ── Rule 3: facing endpoint pairs ─────────────────────────────────────────
    rule3_candidates = detect_edge_pairs(skeleton, wall_zone, object_mask, h, w, gemini)

    # ── Merge + deduplicate by proximity ─────────────────────────────────────
    all_candidates = rule1_candidates + rule2_candidates + rule3_candidates
    all_candidates.sort(key=lambda c: -c['score'])

    # Deduplicate: if two candidates are within 30px, keep higher score
    deduped = []
    used = set()
    for i, c1 in enumerate(all_candidates):
        if i in used:
            continue
        deduped.append(c1)
        c1x, c1y = c1['centroid']
        for j, c2 in enumerate(all_candidates):
            if j <= i or j in used:
                continue
            c2x, c2y = c2['centroid']
            if math.sqrt((c2x - c1x)**2 + (c2y - c1y)**2) < 30:
                used.add(j)

    # ── Visualization ─────────────────────────────────────────────────────────
    vis = image.copy()

    # Show distance transform heatmap on skeleton
    if median_thickness > 0:
        dt_norm = np.clip(dist_inside_wall / (median_thickness * 2) * 255, 0, 255).astype(np.uint8)
        dt_colored = cv2.applyColorMap(dt_norm, cv2.COLORMAP_JET)
        skel_mask = skeleton > 0
        vis[skel_mask] = dt_colored[skel_mask]

    # Thin points in cyan
    vis[thin_mask > 0] = [255, 255, 0]

    # Draw all candidates
    for i, c in enumerate(deduped):
        cx, cy = int(c['centroid'][0]), int(c['centroid'][1])
        color_map = {'thin_section': (0, 255, 0), 'door_posts': (0, 200, 255),
                     'edge_pair': (255, 0, 200)}
        color = color_map.get(c['type'], (200, 200, 200))
        cv2.circle(vis, (cx, cy), 15, color, 2)
        label = f"{c['type'][0]}:{c['direction']} {c['score']:.2f}"
        cv2.putText(vis, label, (cx + 18, cy + 5),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.4, color, 1)

    cv2.imwrite(os.path.join(output_dir, 'door_thinning.png'), vis)
    cv2.imwrite(os.path.join(output_dir, 'skeleton.png'), skeleton)
    cv2.imwrite(os.path.join(output_dir, 'thin_points.png'), thin_mask)
    cv2.imwrite(os.path.join(output_dir, 'wall_mask.png'), wall_zone)

    # Combined overlay: wall zone (semi-transparent blue) + door candidates on room image
    combined = image.copy()
    wall_overlay = combined.copy()
    wall_overlay[wall_zone > 0] = [180, 60, 0]  # blue-ish tint for walls (BGR)
    combined = cv2.addWeighted(combined, 0.65, wall_overlay, 0.35, 0)
    for c in deduped:
        cx, cy = int(c['centroid'][0]), int(c['centroid'][1])
        color_map = {'thin_section': (0, 230, 0), 'door_posts': (0, 200, 255),
                     'edge_pair': (255, 0, 200)}
        col = color_map.get(c['type'], (200, 200, 200))
        cv2.circle(combined, (cx, cy), 18, col, 3)
        cv2.putText(combined, f"{c['direction']} {c['score']:.2f}",
                    (cx + 20, cy + 5), cv2.FONT_HERSHEY_SIMPLEX, 0.45, col, 1)
    cv2.imwrite(os.path.join(output_dir, 'wall_door_overlay.png'), combined)

    results = {
        'thin_ratio': thin_ratio,
        'median_wall_thickness': round(median_thickness, 1),
        'thin_threshold': round(thin_threshold, 1),
        'rule1_thin_section': len(rule1_candidates),
        'rule2_door_posts': len(rule2_candidates),
        'rule3_edge_pairs': len(rule3_candidates),
        'num_candidates': len(deduped),
        'candidates': deduped,
        **{k: v for k, v in dbg.items()},
    }

    print(f"  door_thinning (ratio={thin_ratio}): median={median_thickness:.1f}px, "
          f"r1={len(rule1_candidates)} r2={len(rule2_candidates)} r3={len(rule3_candidates)} "
          f"→ {len(deduped)} merged")
    return results


# ── Experiment 4: door_gap ────────────────────────────────────────────────────

def run_door_gap(image, depth, edges, object_mask, gemini, output_dir, params):
    """Rule 4: Find doors via wall skeleton endpoint gaps / interruptions."""
    max_gap_px = params.get('max_gap_px', 20)
    h, w = depth.shape

    cleaned_depth = subtract_objects(depth, object_mask)
    wall_zone, off_map, dbg = compute_wall_zone_combined(cleaned_depth, object_mask, h, w)

    wall_binary = (wall_zone > 0).astype(np.uint8) * 255
    skeleton = cv2.ximgproc.thinning(wall_binary)

    endpoints = find_skeleton_endpoints(skeleton)
    img_cx, img_cy = w / 2.0, h / 2.0
    llm_doors = set(gemini.get('perimeter_wall_doors', []) if gemini else [])

    # Pair endpoints that are within max_gap
    gaps = []
    used = set()
    for i, (y1, x1) in enumerate(endpoints):
        if i in used:
            continue
        best_j, best_dist = -1, float('inf')
        for j, (y2, x2) in enumerate(endpoints):
            if j <= i or j in used:
                continue
            dist = math.sqrt((x2 - x1)**2 + (y2 - y1)**2)
            if dist < max_gap_px and dist < best_dist:
                best_j, best_dist = j, dist

        if best_j >= 0:
            y2, x2 = endpoints[best_j]
            gap_cx, gap_cy = (x1 + x2) / 2.0, (y1 + y2) / 2.0

            # Don't suggest into object
            gxi, gyi = int(gap_cx), int(gap_cy)
            gxi = max(0, min(w - 1, gxi)); gyi = max(0, min(h - 1, gyi))
            if object_mask[gyi, gxi] > 0:
                used.add(i); used.add(best_j)
                continue

            direction = point_direction(gap_cx, gap_cy, img_cx, img_cy)
            used.add(i); used.add(best_j)
            gaps.append({
                'type': 'gap',
                'point1': [x1, y1],
                'point2': [x2, y2],
                'gap_width': round(best_dist, 1),
                'centroid': [round(gap_cx, 1), round(gap_cy, 1)],
                'direction': direction,
                'llm_match': direction in llm_doors,
            })

    # Isolated endpoints (one-sided break)
    for i, (y1, x1) in enumerate(endpoints):
        if i in used:
            continue
        direction = point_direction(x1, y1, img_cx, img_cy)
        gxi, gyi = max(0, min(w - 1, x1)), max(0, min(h - 1, y1))
        if object_mask[gyi, gxi] > 0:
            continue
        gaps.append({
            'type': 'isolated',
            'point1': [x1, y1],
            'point2': None,
            'gap_width': 0,
            'centroid': [float(x1), float(y1)],
            'direction': direction,
            'llm_match': direction in llm_doors,
        })

    # Visualization
    vis = image.copy()
    vis[skeleton > 0] = [200, 200, 200]
    for y, x in endpoints:
        cv2.circle(vis, (x, y), 4, (0, 0, 255), -1)
    for gap in gaps:
        p1 = (int(gap['point1'][0]), int(gap['point1'][1]))
        color = (0, 255, 0) if gap['llm_match'] else (0, 165, 255)
        cv2.circle(vis, p1, 8, color, 2)
        if gap.get('point2'):
            p2 = (int(gap['point2'][0]), int(gap['point2'][1]))
            cv2.circle(vis, p2, 8, color, 2)
            cv2.line(vis, p1, p2, color, 2)
        cx, cy = int(gap['centroid'][0]), int(gap['centroid'][1])
        cv2.putText(vis, f"{gap['direction']} w={gap['gap_width']:.0f}",
                    (cx + 10, cy - 10), cv2.FONT_HERSHEY_SIMPLEX, 0.4, color, 1)

    cv2.imwrite(os.path.join(output_dir, 'door_gaps.png'), vis)

    paired = [g for g in gaps if g.get('point2')]
    isolated = [g for g in gaps if not g.get('point2')]
    results = {
        'max_gap_px': max_gap_px,
        'num_endpoints': len(endpoints),
        'num_gaps': len(paired),
        'num_isolated': len(isolated),
        'gaps': gaps,
        **{k: v for k, v in dbg.items()},
    }

    print(f"  door_gap (max_gap={max_gap_px}px): {len(endpoints)} endpoints, "
          f"{len(paired)} gaps, {len(isolated)} isolated")
    return results


# ── Experiment 5: connectivity ────────────────────────────────────────────────

def run_connectivity(image, depth, edges, object_mask, gemini, output_dir, params):
    """
    Verify floor reachability. Punch-through suggestions avoid object regions.
    """
    h, w = depth.shape
    cleaned_depth = subtract_objects(depth, object_mask)
    wall_zone, off_map, dbg = compute_wall_zone_combined(cleaned_depth, object_mask, h, w)

    # Floor = not wall and not off_map
    passable = np.zeros((h, w), np.uint8)
    passable[(wall_zone == 0) & (off_map == 0)] = 255

    num_components, comp_labels = cv2.connectedComponents(passable)
    num_floor = num_components - 1

    components = []
    for i in range(1, num_components):
        size = int(np.sum(comp_labels == i))
        pts = np.argwhere(comp_labels == i)
        cy = float(np.mean(pts[:, 0])) if len(pts) > 0 else 0
        cx = float(np.mean(pts[:, 1])) if len(pts) > 0 else 0
        components.append({'id': i, 'size': size,
                           'centroid': [round(cx, 1), round(cy, 1)]})
    components.sort(key=lambda c: -c['size'])

    # Punch-through suggestions: find thinnest wall between disconnected regions
    punch_points = []
    wall_binary = (wall_zone > 0).astype(np.uint8) * 255
    dist_inside_wall = cv2.distanceTransform(wall_binary, cv2.DIST_L2, 5)
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))

    for i in range(1, min(len(components), 4)):
        comp_a = (comp_labels == components[0]['id']).astype(np.uint8) * 255
        comp_b = (comp_labels == components[i]['id']).astype(np.uint8) * 255

        a_dilated = cv2.dilate(comp_a, kernel, iterations=10)
        b_dilated = cv2.dilate(comp_b, kernel, iterations=10)
        between = cv2.bitwise_and(wall_binary, cv2.bitwise_and(a_dilated, b_dilated))

        if np.sum(between > 0) == 0:
            continue

        between_dist = dist_inside_wall.copy()
        between_dist[between == 0] = 9999
        min_loc = np.unravel_index(np.argmin(between_dist), between_dist.shape)
        min_val = float(dist_inside_wall[min_loc])

        px, py = int(min_loc[1]), int(min_loc[0])

        # Safety: don't punch into an object
        # Check a small neighborhood around the punch point
        margin = 5
        neighborhood = object_mask[
            max(0, py - margin):min(h, py + margin + 1),
            max(0, px - margin):min(w, px + margin + 1)
        ]
        if np.any(neighborhood > 0):
            # Try to find an alternative point further from objects
            # Build a score: dist_inside_wall - 9999*(object nearby)
            safe_map = between_dist.copy()
            obj_dist = cv2.distanceTransform(
                cv2.bitwise_not(object_mask), cv2.DIST_L2, 5)
            # Penalize points near objects
            safe_map[obj_dist < 10] = 9999
            alt_loc = np.unravel_index(np.argmin(safe_map), safe_map.shape)
            alt_val = float(dist_inside_wall[alt_loc])
            if safe_map[alt_loc] < 9999:
                px, py = int(alt_loc[1]), int(alt_loc[0])
                min_val = alt_val

        punch_points.append({
            'point': [px, py],
            'wall_half_thickness': round(min_val, 1),
            'wall_thickness': round(min_val * 2, 1),
            'between_components': [components[0]['id'], components[i]['id']],
            'near_object': bool(np.any(object_mask[
                max(0, py - 5):min(h, py + 6),
                max(0, px - 5):min(w, px + 6)
            ] > 0)),
        })

    # Visualization: floor components as colored overlays on the room image
    colors = [(200, 50, 50), (50, 200, 50), (50, 50, 220),
              (200, 200, 50), (200, 50, 200), (50, 200, 200)]
    # Start with the room image as background
    vis = image.copy() if image.ndim == 3 else cv2.cvtColor(image, cv2.COLOR_GRAY2BGR)
    # Semi-transparent component color overlays
    overlay = vis.copy()
    for i, comp in enumerate(components):
        overlay[comp_labels == comp['id']] = colors[i % len(colors)]
    vis = cv2.addWeighted(vis, 0.5, overlay, 0.5, 0)
    # Wall zone: dark gray semi-transparent
    overlay2 = vis.copy()
    overlay2[wall_zone > 0] = [40, 40, 40]
    vis = cv2.addWeighted(vis, 0.7, overlay2, 0.3, 0)
    # Off-map: very dark
    vis[off_map > 0] = [15, 15, 15]
    # Component centroid labels
    for i, comp in enumerate(components):
        cx, cy = int(comp['centroid'][0]), int(comp['centroid'][1])
        cv2.putText(vis, f"#{comp['id']} ({comp['size']//1000}K)",
                    (cx - 30, cy), cv2.FONT_HERSHEY_SIMPLEX, 0.5, colors[i % len(colors)], 1)
    for pp in punch_points:
        px, py = pp['point']
        color = (0, 255, 0) if not pp['near_object'] else (0, 100, 255)
        cv2.circle(vis, (px, py), 14, color, 3)
        cv2.putText(vis, f"punch t={pp['wall_thickness']:.0f}{'!' if pp['near_object'] else ''}",
                    (px + 16, py), cv2.FONT_HERSHEY_SIMPLEX, 0.5, color, 1)

    cv2.imwrite(os.path.join(output_dir, 'connectivity.png'), vis)

    # Also write zone map blended onto image
    cv2.imwrite(os.path.join(output_dir, 'zone_overlay.png'),
                colorize_zone_map(wall_zone, off_map, h, w, image=image))

    results = {
        'num_floor_components': num_floor,
        'is_connected': num_floor <= 1,
        'components': components[:6],
        'punch_points': punch_points,
        **{k: v for k, v in dbg.items()},
    }

    print(f"  connectivity: {num_floor} floor components, connected={num_floor <= 1}, "
          f"{len(punch_points)} punch points")
    return results


# ── Experiment 6: llm_verify ──────────────────────────────────────────────────

def run_llm_verify(image, depth, edges, object_mask, gemini, output_dir, params):
    """Cross-reference all detected doors with LLM expectations."""
    h, w = depth.shape

    if not gemini:
        print("  llm_verify: no gemini data")
        return {'error': 'no gemini data'}

    cleaned_depth = subtract_objects(depth, object_mask)
    wall_zone, off_map, dbg = compute_wall_zone_combined(cleaned_depth, object_mask, h, w)

    # Run thinning at 0.5 and gap at 20px in temp dirs
    thin_dir = os.path.join(output_dir, '_thin_tmp')
    os.makedirs(thin_dir, exist_ok=True)
    thin_r = run_door_thinning(image, depth, edges, object_mask, gemini, thin_dir,
                               {'thin_ratio': 0.5})

    gap_dir = os.path.join(output_dir, '_gap_tmp')
    os.makedirs(gap_dir, exist_ok=True)
    gap_r = run_door_gap(image, depth, edges, object_mask, gemini, gap_dir,
                         {'max_gap_px': 20})

    # Merge candidates
    all_candidates = (
        [dict(c, source='thinning') for c in thin_r.get('candidates', [])] +
        [dict(g, source='gap', score=0.5 if g.get('point2') else 0.2)
         for g in gap_r.get('gaps', []) if g.get('point2')]
    )

    llm_perim = set(gemini.get('perimeter_wall_doors', []))
    llm_internal_doors = set()
    for iw in gemini.get('internal_walls', []):
        if iw.get('has_door') and iw.get('door_side') not in (None, 'none', ''):
            llm_internal_doors.add(iw['door_side'])
    all_expected = llm_perim | llm_internal_doors

    detected_dirs = set(c['direction'] for c in all_candidates)
    matched = detected_dirs & all_expected
    unmatched_llm = all_expected - detected_dirs
    spurious = detected_dirs - all_expected

    # Suggestions for unmatched directions
    wall_binary = (wall_zone > 0).astype(np.uint8) * 255
    skeleton = cv2.ximgproc.thinning(wall_binary)
    dist_inside = cv2.distanceTransform(wall_binary, cv2.DIST_L2, 5)
    img_cx, img_cy = w / 2.0, h / 2.0

    suggestions = []
    for direction in unmatched_llm:
        skel_pts = np.argwhere(skeleton > 0)
        dir_pts = [(py, px) for py, px in skel_pts
                   if point_direction(px, py, img_cx, img_cy) == direction]
        if not dir_pts:
            continue
        min_val, min_pt = float('inf'), None
        for py, px in dir_pts:
            val = dist_inside[py, px]
            # Skip points near objects
            margin = 5
            near_obj = np.any(object_mask[
                max(0, py - margin):min(h, py + margin + 1),
                max(0, px - margin):min(w, px + margin + 1)
            ] > 0)
            if 0 < val < min_val and not near_obj:
                min_val = val
                min_pt = (px, py)
        if min_pt:
            suggestions.append({
                'direction': direction,
                'suggested_point': list(min_pt),
                'wall_thickness': round(min_val * 2, 1),
                'reason': 'LLM expects door but none detected',
            })

    # Visualization
    vis = image.copy()
    vis[skeleton > 0] = (
        cv2.addWeighted(image, 0.6,
                        np.full_like(image, [180, 180, 180]), 0.4, 0)[skeleton > 0]
    )
    for c in all_candidates:
        cx, cy = int(c['centroid'][0]), int(c['centroid'][1])
        color = (0, 255, 0) if c['direction'] in matched else (0, 165, 255)
        cv2.circle(vis, (cx, cy), 12, color, 2)
        label = f"{'OK' if c['direction'] in matched else '?'}:{c['direction']}"
        cv2.putText(vis, label, (cx + 15, cy + 5),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.45, color, 1)
    for s in suggestions:
        px, py = s['suggested_point']
        cv2.circle(vis, (px, py), 15, (0, 0, 255), 3)
        cv2.putText(vis, f"MISS:{s['direction']}",
                    (px + 18, py + 5), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 0, 255), 1)

    cv2.imwrite(os.path.join(output_dir, 'llm_verify.png'), vis)

    results = {
        'llm_perimeter_doors': list(llm_perim),
        'llm_internal_doors': list(llm_internal_doors),
        'detected_directions': list(detected_dirs),
        'matched': list(matched),
        'unmatched_llm': list(unmatched_llm),
        'spurious_detected': list(spurious),
        'suggestions': suggestions,
        'match_score': round(len(matched) / max(len(all_expected), 1), 3),
        **{k: v for k, v in dbg.items()},
    }

    print(f"  llm_verify: matched={list(matched)}, unmatched={list(unmatched_llm)}, "
          f"spurious={list(spurious)}, score={results['match_score']:.2f}")
    return results


# ── Experiment 7: shape_detect ────────────────────────────────────────────────
# Shape-aware wall and door detection using the dual D+G pipeline.
# D pipeline (gamma=0.3, sobel=15) shows all walls with some external noise.
# G pipeline (gamma=0.4, bilateral+median, sobel=20) is clean but has slight gaps.
# Combined = G primary, D fills interior gaps; off-map masks external noise.
# Outer perimeter: largest connected component touching exterior → polygon fit.
# Inner walls: remaining elongated components → HoughLinesP to bridge gaps.
# Doors: gap scan along each wall segment + skeleton thinning on perimeter.

def _merge_hough_lines(raw_lines, angle_tol=12, dist_tol=20):
    """Merge collinear HoughLinesP segments into longer consolidated lines."""
    if raw_lines is None or len(raw_lines) == 0:
        return []

    segments = []
    for line in raw_lines:
        x1, y1, x2, y2 = line[0]
        length = math.sqrt((x2 - x1) ** 2 + (y2 - y1) ** 2)
        if length < 1:
            continue
        angle = math.degrees(math.atan2(y2 - y1, x2 - x1)) % 180
        mx, my = (x1 + x2) / 2.0, (y1 + y2) / 2.0
        # Perpendicular distance from origin (used as rho proxy for grouping)
        rho_a = math.radians(angle + 90)
        rho = mx * math.cos(rho_a) + my * math.sin(rho_a)
        segments.append({'x1': x1, 'y1': y1, 'x2': x2, 'y2': y2,
                         'angle': angle, 'rho': rho, 'length': length})

    merged = []
    used = [False] * len(segments)

    for i, s in enumerate(segments):
        if used[i]:
            continue
        group = [s]
        used[i] = True

        for j, t in enumerate(segments):
            if used[j]:
                continue
            da = abs(s['angle'] - t['angle'])
            da = min(da, 180 - da)
            if da > angle_tol:
                continue
            if abs(s['rho'] - t['rho']) > dist_tol:
                continue
            group.append(t)
            used[j] = True

        ref_angle = float(np.median([g['angle'] for g in group]))
        ref_dx = math.cos(math.radians(ref_angle))
        ref_dy = math.sin(math.radians(ref_angle))
        mx = float(np.mean([(g['x1'] + g['x2']) / 2 for g in group]))
        my = float(np.mean([(g['y1'] + g['y2']) / 2 for g in group]))

        projections = []
        for g in group:
            for px, py in [(g['x1'], g['y1']), (g['x2'], g['y2'])]:
                projections.append((px - mx) * ref_dx + (py - my) * ref_dy)

        t_min, t_max = min(projections), max(projections)
        merged.append([
            int(round(mx + t_min * ref_dx)), int(round(my + t_min * ref_dy)),
            int(round(mx + t_max * ref_dx)), int(round(my + t_max * ref_dy)),
        ])

    return merged


def _cluster_points(pts, gap=35):
    """Cluster (y,x) array into groups where neighbors are within gap pixels."""
    if len(pts) == 0:
        return []
    pts = [tuple(p) for p in pts]
    used = [False] * len(pts)
    clusters = []
    for i in range(len(pts)):
        if used[i]:
            continue
        cluster = [pts[i]]
        used[i] = True
        queue = [i]
        while queue:
            ci = queue.pop()
            cy, cx = pts[ci]
            for j in range(len(pts)):
                if used[j]:
                    continue
                jy, jx = pts[j]
                if math.sqrt((jy - cy) ** 2 + (jx - cx) ** 2) <= gap:
                    used[j] = True
                    cluster.append(pts[j])
                    queue.append(j)
        clusters.append(np.array(cluster))
    return clusters


def _scan_segment_gaps(p1, p2, mask, min_gap=20, max_gap=200, strip_w=10):
    """
    Scan along wall segment p1→p2 for contiguous gaps in the wall mask.
    Returns list of ((cx, cy), gap_len_px).
    strip_w: look ±strip_w perpendicular pixels to detect wall presence.
    """
    p1 = np.array(p1, dtype=float)
    p2 = np.array(p2, dtype=float)
    seg_len = float(np.linalg.norm(p2 - p1))
    if seg_len < 1:
        return []

    direction = (p2 - p1) / seg_len
    perp = np.array([-direction[1], direction[0]])
    h_mask, w_mask = mask.shape
    n_steps = int(seg_len)

    wall_present = []
    positions = []

    for i in range(n_steps + 1):
        t = i / max(n_steps, 1) * seg_len
        cx = p1[0] + direction[0] * t
        cy = p1[1] + direction[1] * t
        has_wall = False
        for s in range(-strip_w, strip_w + 1):
            sx = int(round(cx + perp[0] * s))
            sy = int(round(cy + perp[1] * s))
            if 0 <= sy < h_mask and 0 <= sx < w_mask and mask[sy, sx] > 0:
                has_wall = True
                break
        wall_present.append(has_wall)
        positions.append((cx, cy))

    gaps = []
    in_gap = False
    gap_start = 0

    for i, present in enumerate(wall_present):
        if not present and not in_gap:
            in_gap = True
            gap_start = i
        elif present and in_gap:
            in_gap = False
            gap_len = i - gap_start
            if min_gap <= gap_len <= max_gap:
                mid = (gap_start + i) // 2
                gaps.append((positions[mid], gap_len))

    if in_gap:
        gap_len = len(wall_present) - gap_start
        if min_gap <= gap_len <= max_gap:
            mid = (gap_start + len(wall_present)) // 2
            if mid < len(positions):
                gaps.append((positions[mid], gap_len))

    return gaps


def _wall_thickness_profile(p1, p2, mask, strip_w=8):
    """
    Return the number of wall pixels (thickness proxy) at each step along p1→p2.
    Scans ±strip_w perpendicular pixels at each position.
    Returns ndarray of int counts with length = int(seg_len) + 1.
    """
    p1 = np.array(p1, dtype=float)
    p2 = np.array(p2, dtype=float)
    seg_len = float(np.linalg.norm(p2 - p1))
    if seg_len < 1:
        return np.zeros(1, dtype=np.int32)
    direction = (p2 - p1) / seg_len
    perp = np.array([-direction[1], direction[0]])
    h_mask, w_mask = mask.shape
    n_steps = int(seg_len)
    profile = []
    for i in range(n_steps + 1):
        t = i / max(n_steps, 1) * seg_len
        cx = p1[0] + direction[0] * t
        cy = p1[1] + direction[1] * t
        count = 0
        for s in range(-strip_w, strip_w + 1):
            sx = int(round(cx + perp[0] * s))
            sy = int(round(cy + perp[1] * s))
            if 0 <= sy < h_mask and 0 <= sx < w_mask and mask[sy, sx] > 0:
                count += 1
        profile.append(count)
    return np.array(profile, dtype=np.int32)


def _scan_segment_thinning(p1, p2, mask, strip_w=8, min_thin_px=40, max_thin_px=300,
                            thin_ratio=0.45, context_px=60):
    """
    Detect door-like thinning along p1→p2 by measuring wall thickness.
    A thinning = contiguous region where thickness < thin_ratio × local baseline.
    The baseline is the median of the ±context_px window excluding the thin region.

    Returns list of ((cx, cy), thin_len, thin_score)
    where thin_score ∈ [0, 1]: higher = stronger thinning contrast.
    """
    profile = _wall_thickness_profile(p1, p2, mask, strip_w)
    n = len(profile)
    if n < 10:
        return []

    p1 = np.array(p1, dtype=float)
    p2 = np.array(p2, dtype=float)
    seg_len = float(np.linalg.norm(p2 - p1))
    direction = (p2 - p1) / max(seg_len, 1)

    wall_pixels = profile[profile > 0]
    global_median = float(np.median(wall_pixels)) if len(wall_pixels) > 0 else 0.0
    if global_median < 2:
        return []

    threshold = global_median * thin_ratio
    below = profile < threshold

    thinnings = []
    in_thin = False
    thin_start = 0
    for i, is_below in enumerate(below):
        if is_below and not in_thin:
            in_thin = True
            thin_start = i
        elif not is_below and in_thin:
            in_thin = False
            thin_len = i - thin_start
            if min_thin_px <= thin_len <= max_thin_px:
                mid = (thin_start + i) // 2
                # Local baseline from context windows (excluding the thin region)
                before = profile[max(0, thin_start - context_px):thin_start]
                after  = profile[i:min(n, i + context_px)]
                ctx    = np.concatenate([before, after])
                ctx_ok = ctx[ctx >= threshold] if len(ctx) > 0 else np.array([global_median])
                baseline = float(np.median(ctx_ok)) if len(ctx_ok) > 0 else global_median
                local_min = float(np.min(profile[thin_start:i])) if thin_start < i else global_median
                thin_score = 1.0 - min(local_min / max(baseline, 1.0), 1.0)

                t = mid / max(n - 1, 1) * seg_len
                cx = p1[0] + direction[0] * t
                cy = p1[1] + direction[1] * t
                thinnings.append(((cx, cy), thin_len, thin_score))
    return thinnings


def _gap_post_ratio(gap_t, gap_len, profile, context_px=40):
    """
    Measure wall thickness contrast around a gap.
    Returns ratio = min(before_thick, after_thick) / max(1, global_mean).
    Higher ratio (>1) means wall is thicker on both sides than average → door post signal.
    """
    half = gap_len // 2
    gap_start = max(0, gap_t - half)
    gap_end   = min(len(profile), gap_t + half + 1)
    before    = profile[max(0, gap_start - context_px):gap_start]
    after     = profile[gap_end:min(len(profile), gap_end + context_px)]
    global_mean = float(np.mean(profile)) if len(profile) > 0 else 1.0
    if global_mean < 0.5:
        return 1.0
    before_thick = float(np.mean(before)) if len(before) > 0 else global_mean
    after_thick  = float(np.mean(after))  if len(after)  > 0 else global_mean
    return min(before_thick, after_thick) / global_mean


def _dedup_candidates(candidates, dist_thresh=40):
    """Keep highest-score candidate per spatial cluster (within dist_thresh px)."""
    if not candidates:
        return []
    candidates = sorted(candidates, key=lambda c: -c['score'])
    kept = []
    for c in candidates:
        if all(math.sqrt((c['x'] - k['x']) ** 2 + (c['y'] - k['y']) ** 2) >= dist_thresh
               for k in kept):
            kept.append(c)
    return kept


def _direction_to_perim_point(direction, poly, cx, cy):
    """
    Cast ray from (cx, cy) in the given compass direction, return intersection
    with the nearest perimeter polygon edge.  Returns (x, y) or (None, None).
    """
    dir_angles = {
        'e': 0, 'ne': 45, 'n': 90, 'nw': 135,
        'w': 180, 'sw': 225, 's': 270, 'se': 315,
    }
    if direction not in dir_angles or poly is None:
        return None, None

    angle = math.radians(dir_angles[direction])
    # Image y-axis points DOWN, so negate sin for image-space direction
    ray_dx = math.cos(angle)
    ray_dy = -math.sin(angle)
    pts = poly.reshape(-1, 2).astype(float)
    N = len(pts)
    best_t, best_xy = None, None

    for i in range(N):
        ex, ey = pts[(i + 1) % N] - pts[i]
        # Parametric: cx + t*ray_dx = pts[i,0] + s*ex
        denom = ray_dx * ey - ray_dy * ex
        if abs(denom) < 1e-6:
            continue
        fx, fy = pts[i, 0] - cx, pts[i, 1] - cy
        t = (fx * ey - fy * ex) / denom
        s = (fx * ray_dy - fy * ray_dx) / denom
        if t >= 0 and 0 <= s <= 1:
            if best_t is None or t < best_t:
                best_t = t
                best_xy = (int(round(cx + t * ray_dx)), int(round(cy + t * ray_dy)))

    return best_xy if best_xy else (None, None)


def run_shape_detect(image, depth, edges, object_mask, gemini, output_dir, params):
    """
    Shape-aware wall and door detection — Pipeline A from line_detect.md.

    Pipeline:
      1. Inpaint depth to remove objects.
      2. Two edge pipelines (D: gamma=0.3/sob=15 complete, G: gamma=0.4/med/sob=20 clean).
         Combine: G primary, D fills interior gaps; off-map masks exterior noise.
      3. Directional morphological close → skeletonize → 1px wall lines.
      4. HoughLinesP on skeleton (threshold=15, minLineLength=20, maxLineGap=20).
      5. Merge collinear segments (_merge_hough_lines).
      6. Off-map mask: discard segments mostly in exterior.
      7. shapely.polygonize: assemble closed room polygons from segments.
         - Largest polygon = outer perimeter.
         - Smaller polygon(s) inside = inner room(s).
      8. Door detection: scan each polygon edge against the combined wall mask
         for contiguous gaps (20–200px). No thinning — just clean gap scan.
      9. LLM cross-reference and visualisation.
    """
    import shapely

    h, w = depth.shape
    min_door_px = int(params.get('min_door_px', 50))
    # Perimeter max: 350px — larger than any real door but small enough to reject
    # skeleton voids that span between sparse wall segments on fragmentary walls.
    # Corridor-width open ends are handled by the endpoint-pair fallback, not gap scan.
    max_perim_door_px = int(params.get('max_door_px', 350))
    max_inner_door_px = int(params.get('max_inner_door_px', 350))
    max_line_gap = int(params.get('max_line_gap', 20))
    min_line_len = int(params.get('min_line_len', 20))
    snap_tol = float(params.get('snap_tol', 8.0))
    scan_strip_w = int(params.get('scan_strip_w', 6))
    # border_px: depth map has a white border of this width on each side.
    # object_mask is already placed at (border_px, border_px) by main().
    # Door coordinates are shifted back to original-image space at the end.
    border_px = int(params.get('border_px', 0))

    cleaned = subtract_objects(depth, object_mask)

    # ── Off-map (exterior) ────────────────────────────────────────────────────
    off_map, _, _ = find_offmap_from_corners(cleaned, h, w)
    interior_mask = cv2.bitwise_not(off_map)

    # ── Pipeline D: gamma=0.3, sobel=15 ──────────────────────────────────────
    wall_D, _, _, enh_D, grad_D = compute_wall_zone_clahe_sobel(
        cleaned, object_mask, h, w,
        sobel_thresh=15, close_px=20, gamma_val=0.3)

    # ── Pipeline G: gamma=0.4 + bilateral + median(5), sobel=20 ─────────────
    wall_G, _, _, enh_G, grad_G = compute_wall_zone_clahe_sobel(
        cleaned, object_mask, h, w,
        sobel_thresh=20, close_px=25, gamma_val=0.4, pre_median_k=5)

    # ── Combine wall masks (for door gap scan) ────────────────────────────────
    combined = cv2.bitwise_or(wall_G, cv2.bitwise_and(wall_D, interior_mask))
    combined[object_mask > 0] = 0

    cv2.imwrite(os.path.join(output_dir, 'shape_enh_D.png'), enh_D)
    cv2.imwrite(os.path.join(output_dir, 'shape_enh_G.png'), enh_G)
    cv2.imwrite(os.path.join(output_dir, 'shape_wall_D.png'), wall_D)
    cv2.imwrite(os.path.join(output_dir, 'shape_wall_G.png'), wall_G)
    cv2.imwrite(os.path.join(output_dir, 'shape_wall_combined.png'), combined)

    # ── Build skeleton from D gradient (most complete) ─────────────────────────
    # Start from the raw Sobel gradient (before ring-fill) — thin natural lines.
    # Threshold → directional close → skeletonize → HoughLinesP.
    _, bin_D = cv2.threshold(grad_D, 15, 255, cv2.THRESH_BINARY)
    bin_D = cv2.bitwise_and(bin_D, interior_mask)   # remove exterior noise
    bin_D[object_mask > 0] = 0                        # remove object regions

    # Directional close: bridge gaps along rectilinear wall directions.
    # Re-apply interior_mask after closing — the horizontal kernel (dir_px wide)
    # can bridge from off_map boundary residue pixels into the actual wall, creating
    # a spurious giant connected component that spans the full image width and causes
    # Hough to detect wall segments at the exterior edge instead of the true wall.
    dir_px = max(7, max(h, w) // 100)
    kh = cv2.getStructuringElement(cv2.MORPH_RECT, (dir_px, 1))
    kv = cv2.getStructuringElement(cv2.MORPH_RECT, (1, dir_px))
    dir_closed = cv2.bitwise_or(
        cv2.morphologyEx(bin_D, cv2.MORPH_CLOSE, kh),
        cv2.morphologyEx(bin_D, cv2.MORPH_CLOSE, kv),
    )
    k5 = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    bin_closed = cv2.morphologyEx(dir_closed, cv2.MORPH_CLOSE, k5)
    bin_closed = cv2.bitwise_and(bin_closed, interior_mask)  # strip exterior residue added by closing

    # Remove tiny noise blobs before skeletonising
    num_cc, cc_labels, cc_stats, _ = cv2.connectedComponentsWithStats(bin_closed)
    min_blob = max(100, (h * w) // 5000)
    noise_filter = np.zeros_like(bin_closed)
    for i in range(1, num_cc):
        if cc_stats[i, cv2.CC_STAT_AREA] >= min_blob:
            noise_filter[cc_labels == i] = 255
    skeleton = cv2.ximgproc.thinning(noise_filter)
    cv2.imwrite(os.path.join(output_dir, 'shape_skeleton_raw.png'), skeleton)

    # ── HoughLinesP on skeleton ───────────────────────────────────────────────
    raw_lines = cv2.HoughLinesP(
        skeleton, rho=1, theta=np.pi / 180,
        threshold=15, minLineLength=min_line_len, maxLineGap=max_line_gap)
    segments = _merge_hough_lines(raw_lines, angle_tol=8, dist_tol=15)

    # Discard segments mostly in off-map exterior
    segs_filtered = []
    for seg in segments:
        x1, y1, x2, y2 = seg
        mx, my = (x1 + x2) // 2, (y1 + y2) // 2
        if 0 <= my < h and 0 <= mx < w and off_map[my, mx] == 0:
            segs_filtered.append(seg)
    segments = segs_filtered
    print(f"  shape_detect: HoughLinesP → {len(segments)} segments after merge+filter")

    # ── Build outer rectangle from detected extreme wall segments ─────────────
    # The top wall is often gapped or partial; other 3 walls are cleanly detected.
    # Build an axis-aligned rect from: leftmost/rightmost vertical + topmost/bottommost
    # horizontal long segments. Fall back to off_map boundary for the top wall.
    def _build_outer_rect(segs, h_, w_, off_m):
        horiz, vert = [], []
        for x1, y1, x2, y2 in segs:
            dx, dy = abs(x2 - x1), abs(y2 - y1)
            ln = np.hypot(dx, dy)
            if ln < 30:
                continue
            if dy <= dx * 0.25:
                horiz.append((float(y1 + y2) / 2, min(x1, x2), max(x1, x2)))
            elif dx <= dy * 0.25:
                vert.append((float(x1 + x2) / 2, min(y1, y2), max(y1, y2)))
        mg = max(20, min(h_, w_) // 60)
        west  = [(x, y1, y2) for x, y1, y2 in vert  if y2 - y1 > h_ * 0.25 and x < w_ * 0.40]
        east  = [(x, y1, y2) for x, y1, y2 in vert  if y2 - y1 > h_ * 0.25 and x > w_ * 0.60]
        north = [(y, x1, x2) for y, x1, x2 in horiz if x2 - x1 > w_ * 0.15 and y < h_ * 0.40]
        south = [(y, x1, x2) for y, x1, x2 in horiz if x2 - x1 > w_ * 0.25 and y > h_ * 0.60]
        detected = {
            'west': bool(west), 'east': bool(east),
            'north': bool(north), 'south': bool(south),
        }
        # West/East: prefer long vertical segments; fall back to horizontal wall extents
        # so a corridor with only N+S walls still gets a correct bounding rect.
        if west:
            x_l = int(round(np.median([x for x, _, _ in west])))
        elif horiz:
            x_l = min(x1 for _, x1, _ in horiz)
        else:
            x_l = mg
        if east:
            x_r = int(round(np.median([x for x, _, _ in east])))
        elif horiz:
            x_r = max(x2 for _, _, x2 in horiz)
        else:
            x_r = w_ - mg
        # South: prefer horiz segments; fall back to lowest vertical extent
        if south:
            y_b = int(round(np.median([y for y, _, _ in south])))
        elif vert:
            y_b = max(y2 for _, _, y2 in vert)
        else:
            y_b = h_ - mg
        # North: prefer horiz segments; fall back to topmost vertical extent, then off-map
        if north:
            y_t = int(round(np.median([y for y, _, _ in north])))
        elif vert:
            y_t = min(y1 for _, y1, _ in vert)
        else:
            top_mask = off_m[:h_ // 2, max(0, x_l):min(w_, x_r)]
            rows = np.where(top_mask.any(axis=1))[0]
            y_t = int(rows[-1]) + mg if len(rows) > 0 else mg
        return x_l, y_t, x_r, y_b, detected

    x_left, y_top_r, x_right, y_bottom, detected_sides = _build_outer_rect(segments, h, w, off_map)
    print(f"  shape_detect: outer rect x={x_left}..{x_right}, y={y_top_r}..{y_bottom} "
          f"detected={detected_sides}")

    from shapely.geometry import Polygon
    outer_room = Polygon([(x_left, y_top_r), (x_right, y_top_r),
                          (x_right, y_bottom), (x_left, y_bottom)])
    print(f"  shape_detect: polygonize → outer rect (area={int(outer_room.area)})")

    outer_poly_cv = np.array([
        [x_left, y_top_r], [x_right, y_top_r],
        [x_right, y_bottom], [x_left, y_bottom],
    ], dtype=np.int32).reshape(-1, 1, 2)

    perim_centroid = ((x_left + x_right) // 2, (y_top_r + y_bottom) // 2)
    cx_img, cy_img = perim_centroid

    # ── Inner wall segments (not on the outer boundary) ───────────────────────
    def _on_outer_boundary(seg, xl, yt, xr, yb, tol=20):
        x1, y1, x2, y2 = seg
        mx, my = (x1 + x2) / 2, (y1 + y2) / 2
        dx, dy = abs(x2 - x1), abs(y2 - y1)
        if dx <= dy * 0.25:        # near-vertical → check x proximity
            if abs(mx - xl) < tol: return True
            if abs(mx - xr) < tol: return True
        if dy <= dx * 0.25:        # near-horizontal → check y proximity
            if abs(my - yt) < tol: return True
            if abs(my - yb) < tol: return True
        return False

    inner_segs = [s for s in segments
                  if not _on_outer_boundary(s, x_left, y_top_r, x_right, y_bottom)]
    inner_rooms = []  # shapely Polygon objects built from inner segments below

    # Attempt to close inner segments into polygons using the outer rect as a boundary:
    # add the sections of the outer rect that border the inner area, then polygonize.
    from shapely.geometry import LineString as SLine
    from shapely.ops import polygonize as shp_polygonize, unary_union as shp_union
    if inner_segs:
        # Build line strings from inner segments + relevant outer boundary pieces
        shp_inner = [SLine([(s[0], s[1]), (s[2], s[3])]) for s in inner_segs]
        # Add outer boundary segments so inner polys can "borrow" a wall
        outer_boundary_lines = [
            SLine([(x_left, y_top_r), (x_right, y_top_r)]),
            SLine([(x_right, y_top_r), (x_right, y_bottom)]),
            SLine([(x_right, y_bottom), (x_left, y_bottom)]),
            SLine([(x_left, y_bottom), (x_left, y_top_r)]),
        ]
        all_lines = shp_inner + outer_boundary_lines
        merged_all = shp_union(all_lines)
        snapped_all = [shapely.snap(ln, merged_all, snap_tol * 4) for ln in all_lines]
        noded_all = shapely.node(shapely.geometrycollections(snapped_all))
        polys_all = list(shp_polygonize(noded_all.geoms))
        outer_area = float(outer_room.area)
        # Inner rooms must be inside outer_room and < 70% of its area
        inner_rooms = sorted(
            [p for p in polys_all
             if 0.005 * outer_area < p.area < 0.70 * outer_area
             and outer_room.contains(p.centroid)],
            key=lambda p: p.area, reverse=True
        )
    print(f"  shape_detect: {len(inner_segs)} inner wall segments, {len(inner_rooms)} inner room(s)")

    # ── LLM guidance flags ────────────────────────────────────────────────────
    # Pull these up here so both the scan sections and the visualisation can use them.
    llm_perim_doors    = gemini.get('perimeter_wall_doors', []) if gemini else []
    llm_internal_walls = gemini.get('internal_walls', [])       if gemini else []
    # perimeter_wall: None/missing means unknown → assume present; False → skip scan
    llm_has_perimeter  = gemini.get('perimeter_wall', True) is not False
    # Scan inner walls when LLM reports any internal walls at all (even if none have
    # doors — the LLM may miss a door that the CV finds).  Skip only when the list is
    # completely absent/empty (e.g. a simple corridor with no internal structure).
    llm_has_internal   = bool(llm_internal_walls)

    # ── Door detection: gap scan along 4 outer sides + inner segments ─────────
    # Use skeleton (1px thin wall lines) — gaps in skeleton = real door openings.
    # The combined mask is too thick (closed) to show door gaps; skeleton preserves them.
    door_candidates = []

    north_excl_y = y_top_r + (y_bottom - y_top_r) * 0.12  # gaps above this → near north wall (skip)

    def _scan_and_collect(p1, p2, scan_mask, rule, wall_label, room_cx, room_cy,
                          strip_w, base_score=0.50, max_gap=None):
        max_g = max_gap if max_gap is not None else max_perim_door_px
        gaps = _scan_segment_gaps(p1, p2, scan_mask, min_door_px, max_g, strip_w)
        for (gx, gy), gap_len in gaps:
            gxi, gyi = int(round(gx)), int(round(gy))
            # Skip if gap midpoint is in off-map exterior
            if 0 <= gyi < h and 0 <= gxi < w and off_map[gyi, gxi] > 0:
                continue
            # Skip inner-wall gaps too close to north wall (unreliable region)
            if wall_label == 'inner' and gyi < north_excl_y:
                continue
            dirn = point_direction(gxi, gyi, room_cx, room_cy)
            door_candidates.append({
                'x': gxi, 'y': gyi,
                'direction': dirn,
                'score': min(0.92, base_score + gap_len / (2.0 * max_g)),
                'rule': rule,
                'wall': wall_label,
                'gap_px': float(gap_len),
            })

    def _segs_per_side(segs, xl, yt, xr, yb, off_m, tol=30):
        """Return segments grouped by outer-boundary side.
        Only includes segments that lie on the outer rect (within tol px) and whose
        midpoint is inside the room (not in the off-map exterior).  The off-map check
        discards phantom segments produced by depth-map ceiling/background gradients
        whose midpoints fall in the exterior zone above/below/beside the room."""
        h_m, w_m = off_m.shape
        side = {'west': [], 'east': [], 'north': [], 'south': []}
        for seg in segs:
            x1, y1, x2, y2 = seg
            dx, dy = abs(x2 - x1), abs(y2 - y1)
            if np.hypot(dx, dy) < 30:
                continue
            mx = (x1 + x2) / 2
            my = (y1 + y2) / 2
            # Discard segments whose midpoint is in the off-map exterior
            mxi, myi = int(mx), int(my)
            if 0 <= myi < h_m and 0 <= mxi < w_m and off_m[myi, mxi] > 0:
                continue
            if dx <= dy * 0.25:            # near-vertical
                if abs(mx - xl) <= tol:
                    side['west'].append(seg)
                elif abs(mx - xr) <= tol:
                    side['east'].append(seg)
            elif dy <= dx * 0.25:          # near-horizontal
                if abs(my - yt) <= tol:
                    side['north'].append(seg)
                elif abs(my - yb) <= tol:
                    side['south'].append(seg)
        return side

    # Scan outer perimeter sides. Skip entirely when LLM says no perimeter wall.
    # Scan along actual Hough segments (not synthetic rect edges) so the skeleton
    # is guaranteed to align.  North scanning is now re-enabled: when real north
    # segments exist the alignment problem that forced it off is eliminated.
    if llm_has_perimeter:
        outer_side_segs = _segs_per_side(segments, x_left, y_top_r, x_right, y_bottom, off_map)

        # Scan each outer side along a single representative line derived from its segments.
        # Using one line per side (not per-segment) is essential: real doors are gaps
        # BETWEEN segments; per-segment scanning misses them and creates endpoint artefacts.
        # North is included when real north segments exist (re-enabled vs the old approach
        # that kept north disabled due to synthetic-edge alignment issues).
        # Sides with no segments are skipped; endpoint-pair fallback handles open ends.
        for side_name in ('east', 'south', 'west', 'north'):
            segs = outer_side_segs[side_name]
            if not segs:
                continue
            if side_name in ('east', 'west'):
                # Vertical sides: representative x = median of segment midpoints;
                # scan from the topmost to bottommost y covered by the segments.
                rep_x = int(round(np.median([(s[0] + s[2]) / 2 for s in segs])))
                min_y = min(min(s[1], s[3]) for s in segs)
                max_y = max(max(s[1], s[3]) for s in segs)
                p1 = np.array([rep_x, min_y], float)
                p2 = np.array([rep_x, max_y], float)
            else:
                # Horizontal sides: representative y = median of segment midpoints;
                # scan from the leftmost to rightmost x covered by the segments.
                rep_y = int(round(np.median([(s[1] + s[3]) / 2 for s in segs])))
                min_x = min(min(s[0], s[2]) for s in segs)
                max_x = max(max(s[0], s[2]) for s in segs)
                p1 = np.array([min_x, rep_y], float)
                p2 = np.array([max_x, rep_y], float)
            _scan_and_collect(p1, p2, skeleton, f'gap_{side_name}', 'perimeter',
                              cx_img, cy_img, strip_w=scan_strip_w)

        # ── Endpoint-pair fallback for open corridor ends ──────────────────────
        # Gap scan needs wall present on both sides of the gap (wall→gap→wall).
        # A corridor with open ends has wall that simply terminates — the skeleton
        # has an endpoint there, not a gap flanked by wall.  Detect these by finding
        # pairs of facing skeleton endpoints near each outer-rect boundary that found
        # no gaps: one endpoint from each parallel wall = an open corridor exit.
        sides_with_gaps = {dc['rule'] for dc in door_candidates if dc['wall'] == 'perimeter'}
        ep_yx = find_skeleton_endpoints(skeleton)
        endpoints_xy = [(x, y) for y, x in ep_yx
                        if 0 <= y < h and 0 <= x < w and off_map[y, x] == 0]
        mid_x_r = (x_left + x_right) // 2
        mid_y_r = (y_top_r + y_bottom) // 2

        check_sides = []
        if 'gap_east'  not in sides_with_gaps: check_sides.append(('east',  x_right, None,     'x'))
        if 'gap_west'  not in sides_with_gaps: check_sides.append(('west',  x_left,  None,     'x'))
        if 'gap_south' not in sides_with_gaps: check_sides.append(('south', None,     y_bottom, 'y'))
        # North omitted — unreliable, same reason as the gap scan above.

        for side_name, bx, by, axis in check_sides:
            if axis == 'x':
                near = [(ex, ey) for ex, ey in endpoints_xy
                        if abs(ex - bx) <= 30 and y_top_r <= ey <= y_bottom]
                if len(near) < 2:
                    continue
                top = [p for p in near if p[1] < mid_y_r]
                bot = [p for p in near if p[1] >= mid_y_r]
                if not top or not bot:
                    continue
                tp = min(top, key=lambda p: mid_y_r - p[1])  # nearest to centre from above
                bp = min(bot, key=lambda p: p[1] - mid_y_r)  # nearest to centre from below
                gap = bp[1] - tp[1]
                if gap < min_door_px:
                    continue
                cx_ep, cy_ep = bx, int((tp[1] + bp[1]) / 2)
                safe_x = min(max(cx_ep, 0), w - 1)
                if 0 <= cy_ep < h and off_map[cy_ep, safe_x] == 0:
                    dirn = point_direction(cx_ep, cy_ep, cx_img, cy_img)
                    door_candidates.append({
                        'x': cx_ep, 'y': cy_ep, 'direction': dirn,
                        'score': 0.55, 'rule': f'endpoint_{side_name}',
                        'wall': 'perimeter', 'gap_px': float(gap),
                    })
            else:  # axis == 'y'
                near = [(ex, ey) for ex, ey in endpoints_xy
                        if abs(ey - by) <= 30 and x_left <= ex <= x_right]
                if len(near) < 2:
                    continue
                left  = [p for p in near if p[0] < mid_x_r]
                right = [p for p in near if p[0] >= mid_x_r]
                if not left or not right:
                    continue
                lp = min(left,  key=lambda p: mid_x_r - p[0])
                rp = min(right, key=lambda p: p[0] - mid_x_r)
                gap = rp[0] - lp[0]
                if gap < min_door_px:
                    continue
                cx_ep, cy_ep = int((lp[0] + rp[0]) / 2), by
                if 0 <= cy_ep < h and 0 <= cx_ep < w and off_map[cy_ep, cx_ep] == 0:
                    dirn = point_direction(cx_ep, cy_ep, cx_img, cy_img)
                    door_candidates.append({
                        'x': cx_ep, 'y': cy_ep, 'direction': dirn,
                        'score': 0.55, 'rule': f'endpoint_{side_name}',
                        'wall': 'perimeter', 'gap_px': float(gap),
                    })
    else:
        print("  shape_detect: skipping perimeter scan (LLM: no perimeter wall)")

    # Inner wall scan — skip when LLM says there are no internal walls.
    # This avoids false doors from shelf/counter edges in simple rectangular rooms.
    inner_cx, inner_cy = cx_img, cy_img  # fallback (used in visualisation)
    if llm_has_internal and inner_segs:
        # Estimate inner room centroid from the longest inner vertical and horizontal walls.
        # (The polygonize inner room polygon may be inaccurate; direct estimation is more reliable.)
        min_inner_len_v = h * 0.12   # inner vertical wall must span >12% of height
        min_inner_len_h = w * 0.08   # inner horizontal wall must span >8% of width
        # Strict angle: near-vertical dy/dx > 6 (~10°), near-horizontal dx/dy > 6
        long_verts = sorted(
            [s for s in inner_segs
             if (abs(s[2] - s[0]) == 0 or abs(s[3] - s[1]) / max(1, abs(s[2] - s[0])) > 6)
             and abs(s[3] - s[1]) >= min_inner_len_v
             and (s[0] + s[2]) / 2 < x_right - (x_right - x_left) * 0.10],
            key=lambda s: -abs(s[3] - s[1])
        )
        north_margin = y_top_r + (y_bottom - y_top_r) * 0.10
        long_horizs = sorted(
            [s for s in inner_segs
             if (abs(s[3] - s[1]) == 0 or abs(s[2] - s[0]) / max(1, abs(s[3] - s[1])) > 6)
             and abs(s[2] - s[0]) >= min_inner_len_h
             and north_margin < min(s[1], s[3]) < cy_img
             and (s[0] + s[2]) / 2 > cx_img],
            key=lambda s: -abs(s[2] - s[0])
        )
        if long_verts:
            iv = long_verts[0]
            iv_x = int((iv[0] + iv[2]) / 2)
            inner_cx = (iv_x + x_right) // 2
        if long_horizs:
            ih = long_horizs[0]
            ih_y = int((ih[1] + ih[3]) / 2)
            inner_cy = (y_top_r + ih_y) // 2
        print(f"  shape_detect: inner room center est ({inner_cx},{inner_cy}) "
              f"verts={len(long_verts)} horizs={len(long_horizs)}")

        def _in_room(seg, xl, yt, xr, yb, margin=30):
            mx, my = (seg[0] + seg[2]) / 2, (seg[1] + seg[3]) / 2
            return (xl - margin <= mx <= xr + margin and
                    yt - margin <= my <= yb + margin)

        for seg in inner_segs:
            x1, y1, x2, y2 = seg
            dx, dy = abs(x2 - x1), abs(y2 - y1)
            seg_len = float(np.hypot(dx, dy))
            if seg_len < 60:
                continue
            if not _in_room(seg, x_left, y_top_r, x_right, y_bottom):
                continue
            # Only scan near-vertical inner segments — horizontal inner walls tend to be
            # shelves/counters, producing noisy false door gaps.
            if dy <= dx * 3:
                continue
            p1 = np.array([x1, y1], float)
            p2 = np.array([x2, y2], float)
            _scan_and_collect(p1, p2, skeleton, 'gap_inner', 'inner',
                              inner_cx, inner_cy, strip_w=scan_strip_w, base_score=0.45,
                              max_gap=max_inner_door_px)
    elif not llm_has_internal:
        print("  shape_detect: skipping inner scan (LLM: no internal walls)")

    # ── Deduplicate and LLM cross-reference ───────────────────────────────────
    door_candidates = _dedup_candidates(door_candidates, dist_thresh=100)

    llm_inner_dirs = set()
    for iw in llm_internal_walls:
        if isinstance(iw, str):
            llm_inner_dirs.add(iw)
        elif isinstance(iw, dict):
            llm_inner_dirs.add(iw.get('direction', ''))

    for dc in door_candidates:
        dc['llm_match'] = (dc['direction'] in llm_perim_doors or
                           dc['direction'] in llm_inner_dirs)
        if dc['llm_match']:
            dc['score'] = min(1.0, dc['score'] + 0.10)

    # ── Visualisation ─────────────────────────────────────────────────────────
    def shp_to_cv(poly):
        coords = np.array(poly.exterior.coords[:-1], dtype=np.int32)
        return coords.reshape(-1, 1, 2)

    vis = image.copy()

    # Draw all Hough segments (cyan = outer-boundary, yellow = inner)
    seg_vis = image.copy()
    outer_set = set(tuple(s) for s in segments if _on_outer_boundary(s, x_left, y_top_r, x_right, y_bottom))
    for seg in segments:
        x1, y1, x2, y2 = seg
        col = (0, 200, 255) if tuple(seg) in outer_set else (0, 220, 0)
        cv2.line(seg_vis, (x1, y1), (x2, y2), col, 2)
    cv2.imwrite(os.path.join(output_dir, 'shape_segments.png'), seg_vis)

    # Outer perimeter rectangle (blue)
    cv2.polylines(vis, [outer_poly_cv], True, (255, 80, 0), 3)

    # Inner wall segments (yellow) and inner room polygons (teal)
    for seg in inner_segs:
        x1, y1, x2, y2 = seg
        cv2.line(vis, (x1, y1), (x2, y2), (0, 220, 220), 2)
    for inner in inner_rooms:
        pts = shp_to_cv(inner)
        cv2.polylines(vis, [pts], True, (0, 230, 180), 2)

    # Door candidates
    detected_dirs = set()
    for dc in door_candidates:
        detected_dirs.add(dc['direction'])
        col = (0, 200, 0) if dc['llm_match'] else (0, 140, 255)
        cv2.circle(vis, (dc['x'], dc['y']), 22, col, 3)
        cv2.circle(vis, (dc['x'], dc['y']), 5, col, -1)
        label = f"{dc['direction']} {dc['score']:.2f}"
        cv2.putText(vis, label, (dc['x'] + 26, dc['y'] + 6),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.55, col, 2)

    # LLM expected but not found
    for d in llm_perim_doors:
        if d not in detected_dirs:
            px, py = _direction_to_perim_point(d, outer_poly_cv, cx_img, cy_img)
            if px is not None:
                cv2.circle(vis, (px, py), 26, (0, 0, 200), 2)
                cv2.putText(vis, f'?{d}', (px + 30, py + 6),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 0, 200), 2)

    cv2.imwrite(os.path.join(output_dir, 'shape_doors.png'), vis)

    # Perimeter polygon overlay on colourised zone
    zone_vis = colorize_zone_map(combined, off_map, h, w, image=image)
    cv2.polylines(zone_vis, [outer_poly_cv], True, (255, 255, 0), 2)
    for pt in outer_poly_cv.reshape(-1, 2):
        cv2.circle(zone_vis, tuple(pt), 5, (0, 255, 255), -1)
    for seg in inner_segs:
        x1, y1, x2, y2 = seg
        cv2.line(zone_vis, (x1, y1), (x2, y2), (0, 255, 128), 2)
    for inner in inner_rooms:
        pts = shp_to_cv(inner)
        cv2.polylines(zone_vis, [pts], True, (0, 200, 255), 2)
    cv2.imwrite(os.path.join(output_dir, 'shape_perim_poly.png'), zone_vis)

    poly_pts = outer_poly_cv.reshape(-1, 2).tolist()
    print(f"  shape_detect: outer poly sides={len(poly_pts)}, "
          f"inner rooms={len(inner_rooms)}, doors={len(door_candidates)}")
    print(f"    door directions: {[d['direction'] for d in door_candidates]}")
    print(f"    LLM perim_doors: {llm_perim_doors}")

    # ── Strip border offset from all output coordinates ───────────────────────
    # The depth map was processed with a white border of border_px pixels on each
    # side. All coordinates above are in padded space; subtract border_px to return
    # to original-image coordinates.
    def _unborder_pt(pt):
        return [pt[0] - border_px, pt[1] - border_px]

    if border_px > 0:
        poly_pts = [[p[0] - border_px, p[1] - border_px] for p in poly_pts]
        for dc in door_candidates:
            dc['x'] -= border_px
            dc['y'] -= border_px
        inner_segs = [(s[0]-border_px, s[1]-border_px, s[2]-border_px, s[3]-border_px)
                      for s in inner_segs]
        segments   = [(s[0]-border_px, s[1]-border_px, s[2]-border_px, s[3]-border_px)
                      for s in segments]

    return {
        'outer_perimeter': {
            'poly_pts': poly_pts,
            'sides': len(poly_pts),
            'centroid': list(perim_centroid),
        },
        'inner_rooms': [
            {'area': int(r.area), 'centroid': [int(r.centroid.x) - border_px, int(r.centroid.y) - border_px]}
            for r in inner_rooms
        ],
        'inner_segs': [{'x1': int(s[0]), 'y1': int(s[1]), 'x2': int(s[2]), 'y2': int(s[3])}
                       for s in inner_segs],
        'segments': [{'x1': int(s[0]), 'y1': int(s[1]), 'x2': int(s[2]), 'y2': int(s[3])}
                     for s in segments],
        'doors': door_candidates,
        'llm': {
            'perimeter_wall_doors': llm_perim_doors,
            'internal_walls': llm_internal_walls,
        },
    }


# ── Main ──────────────────────────────────────────────────────────────────────

def run_shape_detect_prebin(image, depth, edges, object_mask, gemini, output_dir, params):
    """
    Shape detection on a pre-computed binary wall/edge image (depth_edge_compare style).
    No depth preprocessing — the binary is used directly as the skeleton source.

    params:
      prebin_path     - path to pre-computed binary PNG (0/255)
      outer_rect_mode - 'segmented' (default, rep-line per side) or
                        'synthetic' (old: scan directly along rect edges)
      border_px       - subtract from output coordinates
    """
    import shapely

    h, w = depth.shape
    min_door_px       = int(params.get('min_door_px', 50))
    max_perim_door_px = int(params.get('max_door_px', 350))
    max_inner_door_px = int(params.get('max_inner_door_px', 350))
    max_line_gap      = int(params.get('max_line_gap', 20))
    min_line_len      = int(params.get('min_line_len', 20))
    snap_tol          = float(params.get('snap_tol', 8.0))
    scan_strip_w      = int(params.get('scan_strip_w', 6))
    border_px         = int(params.get('border_px', 0))
    outer_rect_mode   = params.get('outer_rect_mode', 'segmented')

    prebin = cv2.imread(params['prebin_path'], cv2.IMREAD_GRAYSCALE)
    if prebin is None:
        raise ValueError(f"Cannot load prebin: {params['prebin_path']}")
    if prebin.shape != depth.shape:
        prebin = cv2.resize(prebin, (w, h), cv2.INTER_LINEAR)
    cv2.imwrite(os.path.join(output_dir, 'shape_prebin.png'), prebin)

    # Off_map from depth (for gap filtering only — not applied to the prebin)
    off_map, _, _ = find_offmap_from_corners(depth, h, w)
    interior_mask = cv2.bitwise_not(off_map)

    # Skeletonize the prebin
    _, bin_t = cv2.threshold(prebin, 127, 255, cv2.THRESH_BINARY)
    bin_t = cv2.bitwise_and(bin_t, interior_mask)
    num_cc, cc_labels, cc_stats, _ = cv2.connectedComponentsWithStats(bin_t)
    min_blob = max(100, (h * w) // 5000)
    noise_filter = np.zeros_like(bin_t)
    for i in range(1, num_cc):
        if cc_stats[i, cv2.CC_STAT_AREA] >= min_blob:
            noise_filter[cc_labels == i] = 255
    skeleton = cv2.ximgproc.thinning(noise_filter)
    cv2.imwrite(os.path.join(output_dir, 'shape_skeleton_raw.png'), skeleton)

    # HoughLinesP + merge + off_map filter
    raw_lines = cv2.HoughLinesP(skeleton, rho=1, theta=np.pi / 180,
                                threshold=15, minLineLength=min_line_len, maxLineGap=max_line_gap)
    segments = _merge_hough_lines(raw_lines, angle_tol=8, dist_tol=15)
    segments = [s for s in segments
                if 0 <= (s[1]+s[3])//2 < h and 0 <= (s[0]+s[2])//2 < w
                and off_map[(s[1]+s[3])//2, (s[0]+s[2])//2] == 0]
    print(f"  prebin[{outer_rect_mode}]: {len(segments)} segments after HoughLinesP+filter")

    # ── Outer rectangle ───────────────────────────────────────────────────────
    def _build_outer_rect(segs, h_, w_, off_m):
        horiz, vert = [], []
        for x1, y1, x2, y2 in segs:
            dx, dy = abs(x2-x1), abs(y2-y1)
            if np.hypot(dx, dy) < 30: continue
            if dy <= dx * 0.25: horiz.append((float(y1+y2)/2, min(x1,x2), max(x1,x2)))
            elif dx <= dy * 0.25: vert.append((float(x1+x2)/2, min(y1,y2), max(y1,y2)))
        mg = max(20, min(h_,w_) // 60)
        west  = [(x,y1,y2) for x,y1,y2 in vert  if y2-y1 > h_*0.25 and x < w_*0.40]
        east  = [(x,y1,y2) for x,y1,y2 in vert  if y2-y1 > h_*0.25 and x > w_*0.60]
        north = [(y,x1,x2) for y,x1,x2 in horiz if x2-x1 > w_*0.15 and y < h_*0.40]
        south = [(y,x1,x2) for y,x1,x2 in horiz if x2-x1 > w_*0.25 and y > h_*0.60]
        detected = {'west': bool(west), 'east': bool(east), 'north': bool(north), 'south': bool(south)}
        x_l = int(round(np.median([x for x,_,_ in west]))) if west else (min(x1 for _,x1,_ in horiz) if horiz else mg)
        x_r = int(round(np.median([x for x,_,_ in east]))) if east else (max(x2 for _,_,x2 in horiz) if horiz else w_-mg)
        y_b = int(round(np.median([y for y,_,_ in south]))) if south else (max(y2 for _,_,y2 in vert) if vert else h_-mg)
        if north:
            y_t = int(round(np.median([y for y,_,_ in north])))
        elif vert:
            y_t = min(y1 for _,y1,_ in vert)
        else:
            top_mask = off_m[:h_//2, max(0,x_l):min(w_,x_r)]
            rows = np.where(top_mask.any(axis=1))[0]
            y_t = int(rows[-1]) + mg if len(rows) > 0 else mg
        return x_l, y_t, x_r, y_b, detected

    x_left, y_top_r, x_right, y_bottom, detected_sides = _build_outer_rect(segments, h, w, off_map)
    print(f"  prebin[{outer_rect_mode}]: outer rect x={x_left}..{x_right}, y={y_top_r}..{y_bottom}")

    from shapely.geometry import Polygon
    outer_room = Polygon([(x_left,y_top_r),(x_right,y_top_r),(x_right,y_bottom),(x_left,y_bottom)])
    outer_poly_cv = np.array([[x_left,y_top_r],[x_right,y_top_r],
                               [x_right,y_bottom],[x_left,y_bottom]], dtype=np.int32).reshape(-1,1,2)
    cx_img, cy_img = (x_left+x_right)//2, (y_top_r+y_bottom)//2

    # ── Inner wall segments ────────────────────────────────────────────────────
    def _on_outer_boundary(seg, xl, yt, xr, yb, tol=20):
        x1,y1,x2,y2 = seg; mx,my = (x1+x2)/2,(y1+y2)/2; dx,dy = abs(x2-x1),abs(y2-y1)
        if dx <= dy*0.25:
            if abs(mx-xl) < tol or abs(mx-xr) < tol: return True
        if dy <= dx*0.25:
            if abs(my-yt) < tol or abs(my-yb) < tol: return True
        return False

    inner_segs = [s for s in segments if not _on_outer_boundary(s, x_left, y_top_r, x_right, y_bottom)]
    inner_rooms = []
    from shapely.geometry import LineString as SLine
    from shapely.ops import polygonize as shp_polygonize, unary_union as shp_union
    if inner_segs:
        all_lines = [SLine([(s[0],s[1]),(s[2],s[3])]) for s in inner_segs] + [
            SLine([(x_left,y_top_r),(x_right,y_top_r)]), SLine([(x_right,y_top_r),(x_right,y_bottom)]),
            SLine([(x_right,y_bottom),(x_left,y_bottom)]), SLine([(x_left,y_bottom),(x_left,y_top_r)]),
        ]
        merged = shp_union(all_lines)
        snapped = [shapely.snap(ln, merged, snap_tol*4) for ln in all_lines]
        noded = shapely.node(shapely.geometrycollections(snapped))
        outer_area = float(outer_room.area)
        inner_rooms = sorted(
            [p for p in shp_polygonize(noded.geoms)
             if 0.005*outer_area < p.area < 0.70*outer_area and outer_room.contains(p.centroid)],
            key=lambda p: p.area, reverse=True)
    print(f"  prebin[{outer_rect_mode}]: {len(inner_segs)} inner segs, {len(inner_rooms)} inner rooms")

    # ── Door detection ─────────────────────────────────────────────────────────
    llm_perim_doors    = gemini.get('perimeter_wall_doors', []) if gemini else []
    llm_internal_walls = gemini.get('internal_walls', [])       if gemini else []
    llm_has_perimeter  = gemini.get('perimeter_wall', True) is not False
    llm_has_internal   = bool(llm_internal_walls)
    door_candidates    = []
    north_excl_y       = y_top_r + (y_bottom-y_top_r) * 0.12

    def _scan_and_collect(p1, p2, scan_mask, rule, wall_label, room_cx, room_cy,
                          strip_w, base_score=0.50, max_gap=None):
        """
        Gap detection + thinning detection along p1→p2.
        Scoring uses:
          - thickness contrast around each gap (door posts → higher score)
          - thinning signal (local minimum in binary thickness → high score)
          - edge-of-wall penalty (gaps in outer 10% of wall get reduced score)
        """
        max_g    = max_gap if max_gap is not None else max_perim_door_px
        p1f      = np.array(p1, dtype=float)
        p2f      = np.array(p2, dtype=float)
        seg_len_v = float(np.linalg.norm(p2f - p1f))
        direction = (p2f - p1f) / max(seg_len_v, 1.0)

        # Thickness profile on the binary (wider strip captures true wall thickness)
        thick_profile = _wall_thickness_profile(p1f, p2f, bin_t, strip_w=max(strip_w + 4, 10))
        # Skeleton presence profile for flanking-wall check
        skel_profile  = _wall_thickness_profile(p1f, p2f, scan_mask, strip_w=strip_w)

        # ── Gap detection ────────────────────────────────────────────────────────
        for (gx, gy), gap_len in _scan_segment_gaps(p1, p2, scan_mask, min_door_px, max_g, strip_w):
            gxi, gyi = int(round(gx)), int(round(gy))
            if 0 <= gyi < h and 0 <= gxi < w and off_map[gyi, gxi] > 0: continue
            if wall_label == 'inner' and gyi < north_excl_y: continue

            # Position fraction along wall (0=start, 1=end)
            dp_dist  = float(np.dot(np.array([gx, gy]) - p1f, direction))
            pos_frac = dp_dist / max(seg_len_v, 1.0)
            # Penalty for gaps at the very ends (outer 10%) — unlikely to be doors
            edge_factor = 1.0 if 0.10 <= pos_frac <= 0.90 else 0.55

            # Flanking wall: require substantial continuous wall on both sides of gap.
            # Gaps at the edge of a short wall fragment get a lower score.
            gap_t    = max(0, min(int(round(dp_dist)), len(skel_profile) - 1))
            half_gap = int(gap_len / 2)
            gap_s    = max(0, gap_t - half_gap)
            gap_e    = min(len(skel_profile), gap_t + half_gap + 1)
            # Count consecutive wall pixels immediately before the gap
            flank_pre = 0
            for _j in range(gap_s - 1, -1, -1):
                if skel_profile[_j] > 0: flank_pre += 1
                else: break
            # Count consecutive wall pixels immediately after the gap
            flank_post = 0
            for _j in range(gap_e, len(skel_profile)):
                if skel_profile[_j] > 0: flank_post += 1
                else: break
            min_flank    = min(flank_pre, flank_post)
            # 35px minimum — narrow enough for a single door post to count as flanking
            flank_factor = 1.0 if min_flank >= 35 else max(0.65, min_flank / 35.0)

            # Thickness contrast: door posts → wall thicker on both sides of gap
            post_ratio = _gap_post_ratio(gap_t, gap_len, thick_profile, context_px=40)
            # Bonus if wall is noticeably thicker than average on both sides (post_ratio > 1.1)
            post_bonus = min(0.20, max(0.0, (post_ratio - 1.1) / 0.9) * 0.20)

            score = min(0.92, (base_score + gap_len / (2.0 * max_g) + post_bonus)
                               * edge_factor * flank_factor)
            door_candidates.append({
                'x': gxi, 'y': gyi,
                'direction': point_direction(gxi, gyi, room_cx, room_cy),
                'score': score, 'rule': rule, 'wall': wall_label, 'gap_px': float(gap_len),
            })

        # ── Thinning detection (on binary, not skeleton) ─────────────────────────
        # Only if wall has non-trivial thickness variation (avoids detecting skeleton noise)
        if len(thick_profile) > 20 and np.any(thick_profile > 3):
            for (tx, ty), thin_len, thin_score in _scan_segment_thinning(
                    p1f, p2f, bin_t, strip_w=max(strip_w + 4, 10),
                    min_thin_px=min_door_px, max_thin_px=max_g):
                txi, tyi = int(round(tx)), int(round(ty))
                if 0 <= tyi < h and 0 <= txi < w and off_map[tyi, txi] > 0: continue
                if wall_label == 'inner' and tyi < north_excl_y: continue

                dp_dist  = float(np.dot(np.array([tx, ty]) - p1f, direction))
                pos_frac = dp_dist / max(seg_len_v, 1.0)
                edge_factor = 1.0 if 0.10 <= pos_frac <= 0.90 else 0.55

                score = min(0.85, (base_score * 0.85 + thin_score * 0.40) * edge_factor)
                door_candidates.append({
                    'x': txi, 'y': tyi,
                    'direction': point_direction(txi, tyi, room_cx, room_cy),
                    'score': score, 'rule': f'{rule}_thin', 'wall': wall_label,
                    'gap_px': float(thin_len),
                })

    if llm_has_perimeter:
        if outer_rect_mode == 'segmented':
            side_segs = {'west': [], 'east': [], 'north': [], 'south': []}
            for seg in segments:
                x1,y1,x2,y2 = seg; dx,dy = abs(x2-x1),abs(y2-y1); ln = np.hypot(dx,dy)
                if ln < 30: continue
                mx,my = (x1+x2)/2,(y1+y2)/2
                mxi,myi = int(mx),int(my)
                if 0 <= myi < h and 0 <= mxi < w and off_map[myi,mxi] > 0: continue
                if dx <= dy*0.25:
                    if abs(mx-x_left)  <= 30: side_segs['west'].append(seg)
                    elif abs(mx-x_right) <= 30: side_segs['east'].append(seg)
                elif dy <= dx*0.25:
                    if abs(my-y_top_r)  <= 30: side_segs['north'].append(seg)
                    elif abs(my-y_bottom) <= 30: side_segs['south'].append(seg)
            for side_name in ('east', 'south', 'west', 'north'):
                segs = side_segs[side_name]
                if not segs: continue
                # Skip north: tool-display artefacts near y_top_r cause persistent false gaps.
                if side_name == 'north': continue
                if side_name in ('east', 'west'):
                    rep_x = int(round(np.median([(s[0]+s[2])/2 for s in segs])))
                    p1 = np.array([rep_x, min(min(s[1],s[3]) for s in segs)], float)
                    p2 = np.array([rep_x, max(max(s[1],s[3]) for s in segs)], float)
                else:
                    rep_y = int(round(np.median([(s[1]+s[3])/2 for s in segs])))
                    p1 = np.array([min(min(s[0],s[2]) for s in segs), rep_y], float)
                    p2 = np.array([max(max(s[0],s[2]) for s in segs), rep_y], float)
                _scan_and_collect(p1, p2, skeleton, f'gap_{side_name}', 'perimeter',
                                  cx_img, cy_img, strip_w=scan_strip_w)
        else:  # synthetic — scan directly along rect sides
            for side_name, p1, p2 in [
                ('east',  np.array([x_right, y_top_r], float), np.array([x_right, y_bottom], float)),
                ('south', np.array([x_left,  y_bottom], float), np.array([x_right, y_bottom], float)),
                ('west',  np.array([x_left,  y_top_r], float), np.array([x_left,  y_bottom], float)),
            ]:
                _scan_and_collect(p1, p2, skeleton, f'gap_{side_name}', 'perimeter',
                                  cx_img, cy_img, strip_w=scan_strip_w)

        # Endpoint-pair fallback for open corridor ends
        sides_with_gaps = {dc['rule'] for dc in door_candidates if dc['wall'] == 'perimeter'}
        ep_yx = find_skeleton_endpoints(skeleton)
        endpoints_xy = [(x,y) for y,x in ep_yx if 0 <= y < h and 0 <= x < w and off_map[y,x] == 0]
        mid_x_r, mid_y_r = (x_left+x_right)//2, (y_top_r+y_bottom)//2
        for side_name, bx, by, axis in [
            ('east',  x_right, None,     'x'),
            ('west',  x_left,  None,     'x'),
            ('south', None,    y_bottom, 'y'),
        ]:
            if f'gap_{side_name}' in sides_with_gaps: continue
            if axis == 'x':
                near = [(ex,ey) for ex,ey in endpoints_xy if abs(ex-bx) <= 30 and y_top_r <= ey <= y_bottom]
                if len(near) < 2: continue
                top = [p for p in near if p[1] < mid_y_r]; bot = [p for p in near if p[1] >= mid_y_r]
                if not top or not bot: continue
                tp = min(top, key=lambda p: mid_y_r-p[1]); bp = min(bot, key=lambda p: p[1]-mid_y_r)
                gap = bp[1]-tp[1]
                if gap < min_door_px: continue
                cx_ep, cy_ep = bx, int((tp[1]+bp[1])/2)
                if 0 <= cy_ep < h and off_map[cy_ep, min(max(cx_ep,0),w-1)] == 0:
                    door_candidates.append({'x': cx_ep, 'y': cy_ep,
                        'direction': point_direction(cx_ep,cy_ep,cx_img,cy_img),
                        'score': 0.55, 'rule': f'endpoint_{side_name}', 'wall': 'perimeter', 'gap_px': float(gap)})
            else:
                near = [(ex,ey) for ex,ey in endpoints_xy if abs(ey-by) <= 30 and x_left <= ex <= x_right]
                if len(near) < 2: continue
                left = [p for p in near if p[0] < mid_x_r]; right = [p for p in near if p[0] >= mid_x_r]
                if not left or not right: continue
                lp = min(left, key=lambda p: mid_x_r-p[0]); rp = min(right, key=lambda p: p[0]-mid_x_r)
                gap = rp[0]-lp[0]
                if gap < min_door_px: continue
                cx_ep, cy_ep = int((lp[0]+rp[0])/2), by
                if 0 <= cy_ep < h and 0 <= cx_ep < w and off_map[cy_ep,cx_ep] == 0:
                    door_candidates.append({'x': cx_ep, 'y': cy_ep,
                        'direction': point_direction(cx_ep,cy_ep,cx_img,cy_img),
                        'score': 0.55, 'rule': f'endpoint_{side_name}', 'wall': 'perimeter', 'gap_px': float(gap)})

    # Inner wall scan
    inner_cx, inner_cy = cx_img, cy_img
    if llm_has_internal and inner_segs:
        long_verts = sorted([s for s in inner_segs
            if (abs(s[2]-s[0]) == 0 or abs(s[3]-s[1])/max(1,abs(s[2]-s[0])) > 6)
            and abs(s[3]-s[1]) >= h*0.12 and (s[0]+s[2])/2 < x_right-(x_right-x_left)*0.10],
            key=lambda s: -abs(s[3]-s[1]))
        long_horizs = sorted([s for s in inner_segs
            if (abs(s[3]-s[1]) == 0 or abs(s[2]-s[0])/max(1,abs(s[3]-s[1])) > 6)
            and abs(s[2]-s[0]) >= w*0.08
            and y_top_r+(y_bottom-y_top_r)*0.10 < min(s[1],s[3]) < cy_img
            and (s[0]+s[2])/2 > cx_img],
            key=lambda s: -abs(s[2]-s[0]))
        if long_verts:
            iv = long_verts[0]; inner_cx = (int((iv[0]+iv[2])/2) + x_right) // 2
        if long_horizs:
            ih = long_horizs[0]; inner_cy = (y_top_r + int((ih[1]+ih[3])/2)) // 2
        # Only scan inner vertical segs that are well inside the room (not hugging outer boundaries).
        # Segs within 12% of east or west boundary are likely perimeter-adjacent walls, not true
        # inner dividers, and tend to produce false-positive gaps on fragmented skeletons.
        inner_margin_x = (x_right - x_left) * 0.12
        for seg in inner_segs:
            x1,y1,x2,y2 = seg; dx,dy = abs(x2-x1),abs(y2-y1)
            if np.hypot(dx,dy) < 60: continue
            mx,my = (x1+x2)/2,(y1+y2)/2
            if not (x_left-30 <= mx <= x_right+30 and y_top_r-30 <= my <= y_bottom+30): continue
            if dy <= dx*3: continue
            # Skip segs hugging the outer east/west boundary
            if mx > x_right - inner_margin_x or mx < x_left + inner_margin_x: continue
            _scan_and_collect(np.array([x1,y1],float), np.array([x2,y2],float),
                              skeleton, 'gap_inner', 'inner',
                              inner_cx, inner_cy, strip_w=scan_strip_w, base_score=0.45,
                              max_gap=max_inner_door_px)

    # Dedup + LLM cross-reference
    door_candidates = _dedup_candidates(door_candidates, dist_thresh=100)
    llm_inner_dirs = set()
    for iw in llm_internal_walls:
        if isinstance(iw, str): llm_inner_dirs.add(iw)
        elif isinstance(iw, dict): llm_inner_dirs.add(iw.get('direction', ''))
    for dc in door_candidates:
        dc['llm_match'] = (dc['direction'] in llm_perim_doors or dc['direction'] in llm_inner_dirs)
        if dc['llm_match']: dc['score'] = min(1.0, dc['score'] + 0.10)

    # Visualisation
    def shp_to_cv(poly):
        return np.array(poly.exterior.coords[:-1], dtype=np.int32).reshape(-1,1,2)

    seg_vis = image.copy()
    outer_set = set(tuple(s) for s in segments if _on_outer_boundary(s, x_left, y_top_r, x_right, y_bottom))
    for seg in segments:
        x1,y1,x2,y2 = seg
        cv2.line(seg_vis, (x1,y1),(x2,y2), (0,200,255) if tuple(seg) in outer_set else (0,220,0), 2)
    cv2.imwrite(os.path.join(output_dir, 'shape_segments.png'), seg_vis)

    vis = image.copy()
    cv2.polylines(vis, [outer_poly_cv], True, (255,80,0), 3)
    for seg in inner_segs:
        x1,y1,x2,y2 = seg; cv2.line(vis,(x1,y1),(x2,y2),(0,220,220),2)
    for inner in inner_rooms:
        cv2.polylines(vis, [shp_to_cv(inner)], True, (0,230,180), 2)
    detected_dirs = set()
    for dc in door_candidates:
        detected_dirs.add(dc['direction'])
        col = (0,200,0) if dc['llm_match'] else (0,140,255)
        cv2.circle(vis,(dc['x'],dc['y']),22,col,3); cv2.circle(vis,(dc['x'],dc['y']),5,col,-1)
        cv2.putText(vis,f"{dc['direction']} {dc['score']:.2f}",(dc['x']+26,dc['y']+6),
                    cv2.FONT_HERSHEY_SIMPLEX,0.55,col,2)
    for d in llm_perim_doors:
        if d not in detected_dirs:
            px,py = _direction_to_perim_point(d, outer_poly_cv, cx_img, cy_img)
            if px is not None:
                cv2.circle(vis,(px,py),26,(0,0,200),2)
                cv2.putText(vis,f'?{d}',(px+30,py+6),cv2.FONT_HERSHEY_SIMPLEX,0.55,(0,0,200),2)
    cv2.imwrite(os.path.join(output_dir, 'shape_doors.png'), vis)

    zone_vis = colorize_zone_map(prebin, off_map, h, w, image=image)
    cv2.polylines(zone_vis, [outer_poly_cv], True, (255,255,0), 2)
    for pt in outer_poly_cv.reshape(-1,2): cv2.circle(zone_vis,tuple(pt),5,(0,255,255),-1)
    for seg in inner_segs:
        x1,y1,x2,y2 = seg; cv2.line(zone_vis,(x1,y1),(x2,y2),(0,255,128),2)
    cv2.imwrite(os.path.join(output_dir, 'shape_perim_poly.png'), zone_vis)

    poly_pts = outer_poly_cv.reshape(-1,2).tolist()
    print(f"  prebin[{outer_rect_mode}]: doors={len(door_candidates)} {[d['direction'] for d in door_candidates]}")

    # ── Simple polygon extraction from inner_segs + outer rect ────────────────
    # Steps: extend all segs toward outer boundary → merge collinear fragments →
    # filter by merged length → shapely polygonize with outer boundary lines.
    # We extend before filtering so short fragments contribute to longer merged walls.
    room_poly_data = []
    try:
        import shapely as _shp
        from shapely.geometry import LineString as _SLine, Polygon as _ShPoly
        from shapely.ops import polygonize_full as _poly_full, unary_union as _su

        ext_tol = max(h, w) * 0.15        # extend endpoint if within 15% of room dim from boundary
        merge_tol = 20                    # px offset across axis to consider collinear
        merge_ratio = 1.2                 # allow gap up to 120% of shorter seg (bridges doorways)
        min_wall_frac = 0.07              # merged seg must be ≥7% of room dimension to keep
        snap_tol = 20.0

        outer_area_px = float((x_right - x_left) * (y_bottom - y_top_r))
        ob = [_SLine([(x_left,y_top_r),(x_right,y_top_r)]),
              _SLine([(x_right,y_top_r),(x_right,y_bottom)]),
              _SLine([(x_right,y_bottom),(x_left,y_bottom)]),
              _SLine([(x_left,y_bottom),(x_left,y_top_r)])]

        # Extend all inner_segs endpoints toward outer rect
        def _ext(segs):
            out = []
            for s in segs:
                x1,y1,x2,y2 = map(int, s)
                dx,dy = abs(x2-x1), abs(y2-y1)
                if dy >= dx:  # vertical — sort top-first
                    if y1 > y2: x1,y1,x2,y2 = x2,y2,x1,y1
                    if 0 < y1-y_top_r <= ext_tol:  y1 = y_top_r
                    if 0 < y_bottom-y2 <= ext_tol: y2 = y_bottom
                else:          # horizontal — sort left-first
                    if x1 > x2: x1,y1,x2,y2 = x2,y2,x1,y1
                    if 0 < x1-x_left  <= ext_tol: x1 = x_left
                    if 0 < x_right-x2 <= ext_tol: x2 = x_right
                out.append((x1,y1,x2,y2))
            return out

        # Merge collinear fragments of the same orientation
        def _merge(segs, horiz):
            changed = True; segs = list(segs)
            while changed:
                changed = False; merged = []; used = [False]*len(segs)
                for i, a in enumerate(segs):
                    if used[i]: continue
                    ax1,ay1,ax2,ay2 = a
                    for j, b in enumerate(segs):
                        if j <= i or used[j]: continue
                        bx1,by1,bx2,by2 = b
                        if horiz:
                            if ax1>ax2: ax1,ay1,ax2,ay2=ax2,ay2,ax1,ay1
                            if bx1>bx2: bx1,by1,bx2,by2=bx2,by2,bx1,by1
                            if abs((ay1+ay2)/2-(by1+by2)/2) > merge_tol: continue
                            gap = max(0, max(ax1,bx1)-min(ax2,bx2))
                            shorter = min(ax2-ax1, bx2-bx1)
                            if shorter <= 0 or gap > shorter*merge_ratio: continue
                            ny = int(round((ay1+ay2+by1+by2)/4))
                            a = (min(ax1,bx1), ny, max(ax2,bx2), ny)
                        else:
                            if ay1>ay2: ax1,ay1,ax2,ay2=ax2,ay2,ax1,ay1
                            if by1>by2: bx1,by1,bx2,by2=bx2,by2,bx1,by1
                            if abs((ax1+ax2)/2-(bx1+bx2)/2) > merge_tol: continue
                            gap = max(0, max(ay1,by1)-min(ay2,by2))
                            shorter = min(ay2-ay1, by2-by1)
                            if shorter <= 0 or gap > shorter*merge_ratio: continue
                            nx = int(round((ax1+ax2+bx1+bx2)/4))
                            a = (nx, min(ay1,by1), nx, max(ay2,by2))
                        ax1,ay1,ax2,ay2 = a; used[j] = True; changed = True
                    merged.append(a); used[i] = True
                segs = merged
            return segs

        ext = _ext(inner_segs)
        h_ext = [s for s in ext if abs(s[2]-s[0]) >= abs(s[3]-s[1])]
        v_ext = [s for s in ext if abs(s[3]-s[1]) >  abs(s[2]-s[0])]
        wall_segs = (_merge(h_ext, True) + _merge(v_ext, False))
        min_wall_px = max(h, w) * min_wall_frac
        wall_segs = [s for s in wall_segs if np.hypot(abs(s[2]-s[0]),abs(s[3]-s[1])) >= min_wall_px]

        if wall_segs:
            lines = [_SLine([(s[0],s[1]),(s[2],s[3])]) for s in wall_segs] + ob
            ref = _su(lines)
            snapped = [_shp.snap(ln, ref, snap_tol) for ln in lines]
            noded = _shp.node(_shp.geometrycollections(snapped))
            polys, _, _, _ = _poly_full(noded.geoms)
            outer_shp = _ShPoly([(x_left,y_top_r),(x_right,y_top_r),(x_right,y_bottom),(x_left,y_bottom)])
            room_polys = []
            for p in (polys.geoms if not polys.is_empty else []):
                frac = p.area / outer_area_px
                if frac < 0.04 or frac > 0.97: continue
                if not outer_shp.contains(p.centroid): continue
                sol = p.area / p.convex_hull.area if p.convex_hull.area > 0 else 0
                if sol < 0.55: continue
                room_polys.append(p)
            room_polys.sort(key=lambda p: -p.area)

            # Scan each polygon edge for door gaps
            poly_doors = []
            for ri, p in enumerate(room_polys):
                coords = list(p.exterior.coords[:-1])
                pcx, pcy = int(p.centroid.x), int(p.centroid.y)
                for k in range(len(coords)):
                    ep1 = np.array(coords[k], float)
                    ep2 = np.array(coords[(k+1) % len(coords)], float)
                    for (gx, gy), gap_len in _scan_segment_gaps(
                            ep1, ep2, skeleton, min_door_px, max_perim_door_px, scan_strip_w):
                        gxi, gyi = int(round(gx)), int(round(gy))
                        if not (0 <= gyi < h and 0 <= gxi < w): continue
                        if off_map[gyi, gxi] > 0: continue
                        poly_doors.append({
                            'x': gxi, 'y': gyi, 'room': ri,
                            'direction': point_direction(gxi, gyi, pcx, pcy),
                            'score': min(0.92, 0.50 + gap_len / (2.0 * max_perim_door_px)),
                            'gap_px': float(gap_len),
                        })
            poly_doors = _dedup_candidates(poly_doors, dist_thresh=80)
            for dc in poly_doors:
                dc['llm_match'] = (dc['direction'] in llm_perim_doors)

            # Visualize rooms + doors together
            vis_rooms = image.copy()
            cv2.polylines(vis_rooms, [outer_poly_cv], True, (255,80,0), 3)
            for s in wall_segs:
                cv2.line(vis_rooms, (s[0],s[1]),(s[2],s[3]), (80,80,80), 2)
            for i, p in enumerate(room_polys):
                pts = np.array(p.exterior.coords[:-1], int).reshape(-1,1,2)
                cv2.polylines(vis_rooms, [pts], True, (0,255,128), 3)
                ov = vis_rooms.copy(); cv2.fillPoly(ov, [pts], (0,255,128))
                cv2.addWeighted(ov, 0.15, vis_rooms, 0.85, 0, vis_rooms)
                cx_p, cy_p = int(p.centroid.x), int(p.centroid.y)
                cv2.putText(vis_rooms, f"R{i} {p.area/outer_area_px*100:.0f}%",
                            (cx_p-25,cy_p), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255,255,255), 2)
            for dc in poly_doors:
                col = (0,200,0) if dc['llm_match'] else (0,140,255)
                cv2.circle(vis_rooms, (dc['x'],dc['y']), 22, col, 3)
                cv2.circle(vis_rooms, (dc['x'],dc['y']), 5, col, -1)
                cv2.putText(vis_rooms, f"{dc['direction']} {dc['score']:.2f}",
                            (dc['x']+26, dc['y']+6), cv2.FONT_HERSHEY_SIMPLEX, 0.5, col, 2)
            cv2.imwrite(os.path.join(output_dir, 'shape_rooms.png'), vis_rooms)

            off_px = border_px  # coords still in padded space here
            for dc in poly_doors:
                dc['x'] -= off_px; dc['y'] -= off_px
            room_poly_data = [{'id':i,'area_pct':round(p.area/outer_area_px*100,1),
                               'vertices':len(p.exterior.coords)-1,
                               'doors':[d for d in poly_doors if d['room']==i],
                               'pts':[[int(x)-off_px,int(y)-off_px] for x,y in p.exterior.coords[:-1]]}
                              for i,p in enumerate(room_polys)]
            print(f"  prebin[{outer_rect_mode}]: rooms={len(room_polys)} "
                  f"wall_segs={len(wall_segs)} poly_doors={len(poly_doors)}")
    except Exception as _e:
        print(f"  prebin[{outer_rect_mode}]: polygon extraction failed: {_e}")

    if border_px > 0:
        poly_pts = [[p[0]-border_px,p[1]-border_px] for p in poly_pts]
        for dc in door_candidates: dc['x'] -= border_px; dc['y'] -= border_px
        inner_segs = [(s[0]-border_px,s[1]-border_px,s[2]-border_px,s[3]-border_px) for s in inner_segs]
        segments   = [(s[0]-border_px,s[1]-border_px,s[2]-border_px,s[3]-border_px) for s in segments]

    return {
        'outer_perimeter': {'poly_pts': poly_pts, 'sides': len(poly_pts)},
        'inner_rooms': [{'area': int(r.area)} for r in inner_rooms],
        'inner_segs': [{'x1':int(s[0]),'y1':int(s[1]),'x2':int(s[2]),'y2':int(s[3])} for s in inner_segs],
        'room_polygons': room_poly_data,
        'doors': door_candidates,
        'outer_rect_mode': outer_rect_mode,
        'llm': {'perimeter_wall_doors': llm_perim_doors},
    }


def run_shape_polygonize_prebin(image, depth, edges, object_mask, gemini, output_dir, params):
    """
    Build clean room polygons from a pre-computed binary wall image.

    Pipeline:
      1. Skeleton from prebin → HoughLinesP → merge → off_map filter
      2. Outer rect from segments
      3. Noise filter on inner segments: min length + near-rectilinear only
      4. Dangle removal via polygonize_full: segments that don't close any polygon discarded
      5. Re-run polygonize with contributing segments + outer boundary lines
      6. Filter polygons: area, solidity
      7. Rectangle fitting: approxPolyDP + minAreaRect fill-ratio test
    """
    import shapely

    h, w = depth.shape
    min_seg_len     = int(params.get('min_seg_len', 60))
    snap_tol        = float(params.get('snap_tol', 30.0))   # large: connects near-boundary endpoints
    min_area_frac   = float(params.get('min_area_frac', 0.005))
    fill_ratio_thr  = float(params.get('fill_ratio_thr', 0.75))
    solidity_thr    = float(params.get('solidity_thr', 0.65))
    recti_ratio     = float(params.get('recti_ratio', 0.50))
    max_line_gap    = int(params.get('max_line_gap', 80))    # large: bridges door-sized gaps in walls
    min_line_len    = int(params.get('min_line_len', 20))
    border_px       = int(params.get('border_px', 0))

    prebin = cv2.imread(params['prebin_path'], cv2.IMREAD_GRAYSCALE)
    if prebin is None:
        raise ValueError(f"Cannot load prebin: {params['prebin_path']}")
    if prebin.shape != depth.shape:
        prebin = cv2.resize(prebin, (w, h), cv2.INTER_LINEAR)

    off_map, _, _ = find_offmap_from_corners(depth, h, w)
    interior_mask = cv2.bitwise_not(off_map)

    # Build Hough input: either skeletonize (use_skeleton=True, default False) or run on binary directly.
    # Direct binary produces straighter Hough lines because the thick edge band averages out jaggedness.
    # Skeleton is thinner but introduces pixel-level zigzags that produce less straight segments.
    use_skeleton = bool(params.get('use_skeleton', False))
    _, bin_t = cv2.threshold(prebin, 127, 255, cv2.THRESH_BINARY)
    bin_t = cv2.bitwise_and(bin_t, interior_mask)
    num_cc, cc_labels, cc_stats, _ = cv2.connectedComponentsWithStats(bin_t)
    min_blob = max(100, (h * w) // 5000)
    nf = np.zeros_like(bin_t)
    for i in range(1, num_cc):
        if cc_stats[i, cv2.CC_STAT_AREA] >= min_blob:
            nf[cc_labels == i] = 255
    if use_skeleton:
        hough_src = cv2.ximgproc.thinning(nf)
    else:
        hough_src = nf  # thick binary — HoughLinesP averages over edge width naturally
    cv2.imwrite(os.path.join(output_dir, 'shape_poly_skeleton.png'), hough_src)

    # HoughLinesP + merge + off_map filter
    # Use larger dist_tol when running on thick binary to merge parallel duplicates from edge width
    hough_dist_tol = int(params.get('hough_dist_tol', 25 if not use_skeleton else 15))
    raw_lines = cv2.HoughLinesP(hough_src, rho=1, theta=np.pi / 180,
                                threshold=15, minLineLength=min_line_len, maxLineGap=max_line_gap)
    segments = _merge_hough_lines(raw_lines, angle_tol=8, dist_tol=hough_dist_tol)
    segments = [s for s in segments
                if 0 <= (s[1]+s[3])//2 < h and 0 <= (s[0]+s[2])//2 < w
                and off_map[(s[1]+s[3])//2, (s[0]+s[2])//2] == 0]
    print(f"  polygonize: {len(segments)} segments after HoughLinesP+filter")

    # Outer rectangle
    def _build_outer_rect(segs, h_, w_, off_m):
        horiz, vert = [], []
        for x1, y1, x2, y2 in segs:
            dx, dy = abs(x2-x1), abs(y2-y1)
            if np.hypot(dx, dy) < 30: continue
            if dy <= dx * 0.25: horiz.append((float(y1+y2)/2, min(x1,x2), max(x1,x2)))
            elif dx <= dy * 0.25: vert.append((float(x1+x2)/2, min(y1,y2), max(y1,y2)))
        mg = max(20, min(h_,w_) // 60)
        west  = [(x,y1,y2) for x,y1,y2 in vert  if y2-y1 > h_*0.25 and x < w_*0.40]
        east  = [(x,y1,y2) for x,y1,y2 in vert  if y2-y1 > h_*0.25 and x > w_*0.60]
        north = [(y,x1,x2) for y,x1,x2 in horiz if x2-x1 > w_*0.15 and y < h_*0.40]
        south = [(y,x1,x2) for y,x1,x2 in horiz if x2-x1 > w_*0.25 and y > h_*0.60]
        x_l = int(round(np.median([x for x,_,_ in west]))) if west else (min(x1 for _,x1,_ in horiz) if horiz else mg)
        x_r = int(round(np.median([x for x,_,_ in east]))) if east else (max(x2 for _,_,x2 in horiz) if horiz else w_-mg)
        y_b = int(round(np.median([y for y,_,_ in south]))) if south else (max(y2 for _,_,y2 in vert) if vert else h_-mg)
        if north:
            y_t = int(round(np.median([y for y,_,_ in north])))
        elif vert:
            y_t = min(y1 for _,y1,_ in vert)
        else:
            top = off_m[:h_//2, max(0,x_l):min(w_,x_r)]
            rows = np.where(top.any(axis=1))[0]
            y_t = int(rows[-1]) + mg if len(rows) > 0 else mg
        return x_l, y_t, x_r, y_b

    x_left, y_top, x_right, y_bottom = _build_outer_rect(segments, h, w, off_map)
    print(f"  polygonize: outer rect x={x_left}..{x_right}, y={y_top}..{y_bottom}")

    from shapely.geometry import Polygon as ShPoly, LineString as SLine
    from shapely.ops import polygonize_full, unary_union as shp_union
    outer_room = ShPoly([(x_left,y_top),(x_right,y_top),(x_right,y_bottom),(x_left,y_bottom)])
    outer_area = float(outer_room.area)
    outer_poly_cv = np.array([[x_left,y_top],[x_right,y_top],
                               [x_right,y_bottom],[x_left,y_bottom]], dtype=np.int32).reshape(-1,1,2)
    outer_boundary_lines = [
        SLine([(x_left,y_top),(x_right,y_top)]),
        SLine([(x_right,y_top),(x_right,y_bottom)]),
        SLine([(x_right,y_bottom),(x_left,y_bottom)]),
        SLine([(x_left,y_bottom),(x_left,y_top)]),
    ]

    # Outer boundary tol
    def _on_outer(seg, tol=20):
        x1,y1,x2,y2 = seg; mx,my=(x1+x2)/2,(y1+y2)/2; dx,dy=abs(x2-x1),abs(y2-y1)
        if dx<=dy*0.25: return abs(mx-x_left)<tol or abs(mx-x_right)<tol
        if dy<=dx*0.25: return abs(my-y_top)<tol or abs(my-y_bottom)<tol
        return False

    outer_segs = [s for s in segments if _on_outer(s)]
    inner_segs_all = [s for s in segments if not _on_outer(s)]

    # Noise filter: min length + near-rectilinear + inside outer rect
    inner_segs = []
    for seg in inner_segs_all:
        x1,y1,x2,y2 = seg
        dx,dy = abs(x2-x1),abs(y2-y1)
        length = float(np.hypot(dx, dy))
        if length < min_seg_len: continue
        # Near-rectilinear: dy < dx*recti_ratio OR dx < dy*recti_ratio
        if not (dy < dx * recti_ratio or dx < dy * recti_ratio): continue
        mx,my = (x1+x2)/2,(y1+y2)/2
        if not (x_left-40 <= mx <= x_right+40 and y_top-40 <= my <= y_bottom+40): continue
        inner_segs.append(seg)
    print(f"  polygonize: {len(inner_segs)} inner segs after noise filter (was {len(inner_segs_all)})")

    # Identify dangles for visualization only — do NOT gate segment inclusion on dangle status.
    # Door gaps in inner walls cause every wall segment to appear as a dangle even when the wall
    # is real.  We use all inner_segs for the actual polygonize step.
    dangle_segs_set = set()
    if inner_segs:
        inner_lines_vis = [SLine([(s[0],s[1]),(s[2],s[3])]) for s in inner_segs]
        all_vis = inner_lines_vis + outer_boundary_lines
        ref_vis = shp_union(all_vis)
        snapped_vis = [shapely.snap(ln, ref_vis, snap_tol) for ln in all_vis]
        noded_vis = shapely.node(shapely.geometrycollections(snapped_vis))
        _, dangles_vis, cut_vis, _ = polygonize_full(noded_vis.geoms)
        waste_parts_vis = [g for g in [dangles_vis, cut_vis] if not g.is_empty]
        if waste_parts_vis:
            waste_vis = shp_union([g for coll in waste_parts_vis for g in coll.geoms])
            for seg, ln in zip(inner_segs, inner_lines_vis):
                if ln.difference(waste_vis).length <= 5.0:
                    dangle_segs_set.add(tuple(seg))
    contributing_segs = [s for s in inner_segs if tuple(s) not in dangle_segs_set]
    print(f"  polygonize: {len(contributing_segs)} non-dangle segs "
          f"({len(dangle_segs_set)} identified as dangles, still using all for polygonize)")

    # Raw visualization: draw on the binary so segments can be verified against source edges
    vis_raw = cv2.cvtColor(hough_src, cv2.COLOR_GRAY2BGR)
    cv2.polylines(vis_raw, [outer_poly_cv], True, (255,80,0), 3)
    for seg in inner_segs:
        col = (0,100,255) if tuple(seg) in dangle_segs_set else (150,150,150)
        cv2.line(vis_raw, (seg[0],seg[1]),(seg[2],seg[3]), col, 2)
    cv2.imwrite(os.path.join(output_dir, 'shape_polygons_raw.png'), vis_raw)

    # Extend inner segment endpoints toward the outer boundary so they form closed polygons.
    # A near-vertical segment whose top is above y_top+extend_tol gets extended to y_top.
    # A near-horizontal segment whose left end is left of x_left+extend_tol gets extended.
    extend_tol = int(params.get('extend_tol', 120))
    extended_segs = []
    for seg in inner_segs:
        x1, y1, x2, y2 = map(int, seg)
        dx, dy = abs(x2-x1), abs(y2-y1)
        # Ensure top point first for vertical; left point first for horizontal
        if dy >= dx:  # near-vertical
            # sort so y1 <= y2
            if y1 > y2:
                x1, y1, x2, y2 = x2, y2, x1, y1
            # Extend top endpoint toward outer north wall
            if y1 - y_top <= extend_tol and y1 > y_top:
                y1 = y_top
            # Extend bottom endpoint toward outer south wall
            if y_bottom - y2 <= extend_tol and y2 < y_bottom:
                y2 = y_bottom
        else:  # near-horizontal
            # sort so x1 <= x2
            if x1 > x2:
                x1, y1, x2, y2 = x2, y2, x1, y1
            # Extend left endpoint toward outer west wall
            if x1 - x_left <= extend_tol and x1 > x_left:
                x1 = x_left
            # Extend right endpoint toward outer east wall
            if x_right - x2 <= extend_tol and x2 < x_right:
                x2 = x_right
        extended_segs.append((x1, y1, x2, y2))

    # Merge near-collinear extended segments (same orientation, aligned, overlapping/close).
    # This joins fragments of the same wall that have doorway-sized gaps between them.
    merge_gap_ratio = float(params.get('merge_gap_ratio', 0.6))  # gap < this fraction of shorter seg
    merge_align = int(params.get('merge_align', 20))  # max offset across axis

    def merge_collinear(segs, orient_fn):
        """Merge segments of the same orientation that are aligned and close."""
        import itertools
        changed = True
        segs = list(segs)
        while changed:
            changed = False
            merged = []
            used = [False] * len(segs)
            for i, a in enumerate(segs):
                if used[i]: continue
                ax1,ay1,ax2,ay2 = a
                for j, b in enumerate(segs):
                    if j <= i or used[j]: continue
                    bx1,by1,bx2,by2 = b
                    combined = orient_fn(ax1,ay1,ax2,ay2,bx1,by1,bx2,by2)
                    if combined is not None:
                        a = combined
                        ax1,ay1,ax2,ay2 = a
                        used[j] = True
                        changed = True
                merged.append(a)
                used[i] = True
            segs = merged
        return segs

    def try_merge_horiz(ax1,ay1,ax2,ay2,bx1,by1,bx2,by2,align,gap_ratio):
        # Both horizontal, sort left-right
        if ax1>ax2: ax1,ay1,ax2,ay2=ax2,ay2,ax1,ay1
        if bx1>bx2: bx1,by1,bx2,by2=bx2,by2,bx1,by1
        dy_avg=abs((ay1+ay2)/2-(by1+by2)/2)
        if dy_avg > align: return None
        gap_x = max(0, max(ax1,bx1) - min(ax2,bx2))
        shorter = min(ax2-ax1, bx2-bx1)
        if shorter <= 0 or gap_x > shorter * gap_ratio: return None
        nx1=min(ax1,bx1); nx2=max(ax2,bx2)
        ny=int(round((ay1+ay2+by1+by2)/4))
        return (nx1,ny,nx2,ny)

    def try_merge_vert(ax1,ay1,ax2,ay2,bx1,by1,bx2,by2,align,gap_ratio):
        # Both vertical, sort top-bottom
        if ay1>ay2: ax1,ay1,ax2,ay2=ax2,ay2,ax1,ay1
        if by1>by2: bx1,by1,bx2,by2=bx2,by2,bx1,by1
        dx_avg=abs((ax1+ax2)/2-(bx1+bx2)/2)
        if dx_avg > align: return None
        gap_y = max(0, max(ay1,by1) - min(ay2,by2))
        shorter = min(ay2-ay1, by2-by1)
        if shorter <= 0 or gap_y > shorter * gap_ratio: return None
        ny1=min(ay1,by1); ny2=max(ay2,by2)
        nx=int(round((ax1+ax2+bx1+bx2)/4))
        return (nx,ny1,nx,ny2)

    h_segs_ext = [s for s in extended_segs if abs(s[2]-s[0]) >= abs(s[3]-s[1])]
    v_segs_ext = [s for s in extended_segs if abs(s[3]-s[1]) > abs(s[2]-s[0])]
    def _mh(*args): return try_merge_horiz(*args[:8], merge_align, merge_gap_ratio)
    def _mv(*args): return try_merge_vert(*args[:8], merge_align, merge_gap_ratio)
    merged_h = merge_collinear(h_segs_ext, _mh)
    merged_v = merge_collinear(v_segs_ext, _mv)
    merged_segs = merged_h + merged_v
    if len(merged_segs) != len(extended_segs):
        print(f"  polygonize: merged {len(extended_segs)} → {len(merged_segs)} segs")

    # Polygonize using merged segs + outer boundary.
    # Relying on area/solidity filter to discard noise polygons.
    candidate_polys = []
    if merged_segs:
        all_lines = [SLine([(s[0],s[1]),(s[2],s[3])]) for s in merged_segs]
        all_input = all_lines + outer_boundary_lines
        ref2 = shp_union(all_input)
        snapped2 = [shapely.snap(ln, ref2, snap_tol) for ln in all_input]
        noded2 = shapely.node(shapely.geometrycollections(snapped2))
        polys_result, _, _, _ = polygonize_full(noded2.geoms)
        candidate_polys = list(polys_result.geoms) if not polys_result.is_empty else []
        print(f"  polygonize: {len(merged_segs)} merged segs → {len(candidate_polys)} raw polys")

    # Filter: area, solidity, must be inside outer room (exclude the outer room itself)
    min_poly_area = min_area_frac * outer_area
    inner_rooms_filtered = []
    for pi, p in enumerate(candidate_polys):
        solidity = p.area / p.convex_hull.area if p.convex_hull.area > 0 else 0
        area_pct = p.area / outer_area * 100
        centroid_in = outer_room.contains(p.centroid)
        reason = None
        if p.area < min_poly_area: reason = f'too_small({area_pct:.2f}%<{min_area_frac*100:.2f}%)'
        elif p.area > 0.95 * outer_area: reason = f'too_large({area_pct:.1f}%)'
        elif not centroid_in: reason = 'centroid_outside'
        elif solidity < solidity_thr: reason = f'low_solidity({solidity:.2f}<{solidity_thr})'
        if reason:
            continue
        inner_rooms_filtered.append((p, solidity))
    inner_rooms_filtered.sort(key=lambda t: t[0].area, reverse=True)
    print(f"  polygonize: {len(candidate_polys)} raw polys → {len(inner_rooms_filtered)} after filter")

    # Rectangle fitting
    fitted_polys = []
    for poly, solidity in inner_rooms_filtered:
        coords = np.array(poly.exterior.coords[:-1], dtype=np.float32).reshape(-1,1,2)
        perimeter = cv2.arcLength(coords, closed=True)
        approx = cv2.approxPolyDP(coords, 0.03 * perimeter, closed=True)
        n_verts = len(approx)
        minar = cv2.minAreaRect(coords)
        rw, rh = minar[1]
        rect_area = rw * rh
        fill = poly.area / rect_area if rect_area > 0 else 0.0
        is_rect = fill >= fill_ratio_thr and 3 <= n_verts <= 6
        if is_rect:
            corners = np.round(cv2.boxPoints(minar)).astype(int)
            fitted = ShPoly(corners.tolist()).buffer(0)
        else:
            fitted = poly
        fitted_polys.append((fitted, is_rect, poly, solidity, fill))
    n_rect = sum(1 for _,r,_,_,_ in fitted_polys if r)
    print(f"  polygonize: {len(fitted_polys)} final polys ({n_rect} rect-snapped)")

    # Final visualization: draw on the binary so polygon positions can be checked against source edges
    vis = cv2.cvtColor(hough_src, cv2.COLOR_GRAY2BGR)
    cv2.polylines(vis, [outer_poly_cv], True, (255,80,0), 3)
    for seg in merged_segs:
        cv2.line(vis, (seg[0],seg[1]),(seg[2],seg[3]), (100,100,100), 1)
    for (fitted, is_rect, _, _, _) in fitted_polys:
        pts = np.array(fitted.exterior.coords[:-1], int).reshape(-1,1,2)
        col = (0,255,128) if is_rect else (0,200,180)
        cv2.polylines(vis, [pts], True, col, 3)
        overlay = vis.copy()
        cv2.fillPoly(overlay, [pts], col)
        cv2.addWeighted(overlay, 0.15, vis, 0.85, 0, vis)
        cx_p, cy_p = int(fitted.centroid.x), int(fitted.centroid.y)
        area_pct = fitted.area / outer_area * 100
        label = f"{'R' if is_rect else 'P'} {area_pct:.1f}%"
        cv2.putText(vis, label, (cx_p-25,cy_p), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255,255,255), 2)
        cv2.putText(vis, label, (cx_p-25,cy_p), cv2.FONT_HERSHEY_SIMPLEX, 0.5, col, 1)
    cv2.imwrite(os.path.join(output_dir, 'shape_polygons.png'), vis)

    poly_data = []
    for i, (fitted, is_rect, orig_poly, solidity, fill) in enumerate(fitted_polys):
        pts_out = [[int(x)-border_px, int(y)-border_px] for x,y in fitted.exterior.coords[:-1]]
        poly_data.append({
            'id': i, 'pts': pts_out,
            'area': int(fitted.area),
            'area_pct': round(fitted.area / outer_area * 100, 2),
            'is_rect': is_rect,
            'vertices': len(pts_out),
            'solidity': round(solidity, 3),
            'fill_ratio': round(fill, 3),
        })

    return {
        'outer_rect': {k: v-border_px for k,v in
                       [('x_left',x_left),('y_top',y_top),('x_right',x_right),('y_bottom',y_bottom)]},
        # Flat keys for HTML display
        'total_segs': len(segments),
        'filtered_segs': len(inner_segs),
        'contributing_segs': len(contributing_segs),
        'total_polys': len(candidate_polys),
        'kept_polys': len(inner_rooms_filtered),
        'rect_polys': n_rect,
        'freeform_polys': len(fitted_polys) - n_rect,
        'params': params,
        'polygons': poly_data,
    }


EXPERIMENTS = {
    'wall_extract': run_wall_extract,
    'contour_analysis': run_contour_analysis,
    'door_thinning': run_door_thinning,
    'door_gap': run_door_gap,
    'connectivity': run_connectivity,
    'llm_verify': run_llm_verify,
    'shape_detect': run_shape_detect,
    'shape_detect_prebin': run_shape_detect_prebin,
    'shape_polygonize_prebin': run_shape_polygonize_prebin,
}


def main():
    parser = argparse.ArgumentParser(description='Wall & Door Detection')
    parser.add_argument('--image', required=True)
    parser.add_argument('--depth', required=True)
    parser.add_argument('--edges', required=True)
    parser.add_argument('--object-mask', required=True)
    parser.add_argument('--gemini', required=True)
    parser.add_argument('--output-dir', required=True)
    parser.add_argument('--experiment', required=True, choices=list(EXPERIMENTS.keys()))
    parser.add_argument('--params', default='{}')
    args = parser.parse_args()

    image = cv2.imread(args.image)
    depth = cv2.imread(args.depth, cv2.IMREAD_GRAYSCALE)
    edges = cv2.imread(args.edges, cv2.IMREAD_GRAYSCALE)
    obj_mask = cv2.imread(args.object_mask, cv2.IMREAD_GRAYSCALE)

    for name, val in [('image', image), ('depth', depth),
                      ('edges', edges), ('object mask', obj_mask)]:
        if val is None:
            print(f"ERROR: Could not read {name}", file=sys.stderr)
            sys.exit(1)

    h, w = depth.shape
    params = json.loads(args.params)
    border_px = int(params.get('border_px', 0))

    if edges.shape != depth.shape:
        edges = cv2.resize(edges, (w, h), interpolation=cv2.INTER_LINEAR)
    if image.shape[:2] != depth.shape:
        image = cv2.resize(image, (w, h), interpolation=cv2.INTER_LINEAR)

    # Object mask is original-image size when border_px > 0.
    # Place it at (border_px, border_px) in the padded depth canvas rather than
    # resizing (which would stretch the mask to fill the padded dimensions).
    if border_px > 0 and obj_mask.shape[:2] != (h, w):
        mh, mw = obj_mask.shape[:2]
        padded_mask = np.zeros((h, w), dtype=obj_mask.dtype)
        padded_mask[border_px:border_px+mh, border_px:border_px+mw] = obj_mask
        obj_mask = padded_mask
    elif obj_mask.shape[:2] != (h, w):
        obj_mask = cv2.resize(obj_mask, (w, h), interpolation=cv2.INTER_NEAREST)

    _, obj_mask = cv2.threshold(obj_mask, 128, 255, cv2.THRESH_BINARY)
    obj_mask = fill_mask_holes(obj_mask)

    with open(args.gemini, 'r') as f:
        gemini = json.load(f)

    os.makedirs(args.output_dir, exist_ok=True)

    print(f"Running experiment: {args.experiment} (params={params})")
    results = EXPERIMENTS[args.experiment](image, depth, edges, obj_mask, gemini,
                                           args.output_dir, params)

    results_path = os.path.join(args.output_dir, 'results.json')
    with open(results_path, 'w') as f:
        json.dump(results, f, indent=2)
    print(f"Results written to {results_path}")


if __name__ == '__main__':
    main()
