#!/usr/bin/env python3
"""
Depth-map edge / wall comparison.

Tries many preprocessing pipelines on the inpainted (object-free) depth map
and shows the resulting edge / wall candidate for each, so we can pick the
cleanest one to feed into wall detection.

Usage:
  python3 depth_edge_compare.py \
    --depth  <cleaned_depth.png> \
    --edges  <edge_map.png> \
    --output <output_dir>

Output:
  <output_dir>/index.html   (comparison grid, dark theme)
  <output_dir>/<name>.png   (one result per experiment)
"""

import argparse
import base64
import cv2
import numpy as np
import os
from pathlib import Path

from skimage import exposure, img_as_float, img_as_ubyte
from skimage.filters import (
    sobel as sk_sobel,
    threshold_triangle,
    threshold_multiotsu,
    apply_hysteresis_threshold,
)


# ── helpers ───────────────────────────────────────────────────────────────────

def rescale(img):
    """Percentile-based intensity rescale to full 0-255."""
    p2, p98 = float(np.percentile(img, 2)), float(np.percentile(img, 98))
    if p98 <= p2:
        return img.copy()
    return np.clip((img.astype(np.float32) - p2) / (p98 - p2) * 255, 0, 255).astype(np.uint8)

def gamma(img, g=0.4):
    return (np.power(img.astype(np.float32) / 255.0, g) * 255).astype(np.uint8)

def clahe(img, clip=3.0, tile=8):
    return cv2.createCLAHE(clipLimit=clip, tileGridSize=(tile, tile)).apply(img)

def bilateral(img):
    return cv2.bilateralFilter(img, d=9, sigmaColor=75, sigmaSpace=75)

def log_transform(img):
    """Aggressive dark-image boost (steeper than gamma near 0)."""
    f = img.astype(np.float32) + 1.0
    out = np.log(f) / np.log(256.0) * 255
    return np.clip(out, 0, 255).astype(np.uint8)

def sobel_cv(img):
    gx = cv2.Sobel(img, cv2.CV_64F, 1, 0, ksize=3)
    gy = cv2.Sobel(img, cv2.CV_64F, 0, 1, ksize=3)
    grad = np.sqrt(gx**2 + gy**2)
    if grad.max() > 0:
        grad = grad / grad.max() * 255
    return grad.astype(np.uint8)

def sobel_sk(img):
    """skimage Sobel — slightly smoother, same concept."""
    return img_as_ubyte(np.clip(sk_sobel(img.astype(np.float32) / 255.0), 0, 1))

def binarize(grad, thresh):
    _, b = cv2.threshold(grad, thresh, 255, cv2.THRESH_BINARY)
    return b

def morph_close(img, px):
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (px, px))
    return cv2.morphologyEx(img, cv2.MORPH_CLOSE, k)

def morph_open(img, px=3):
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (px, px))
    return cv2.morphologyEx(img, cv2.MORPH_OPEN, k)

def directional_close(img, px):
    h_k = cv2.getStructuringElement(cv2.MORPH_RECT, (px, 1))
    v_k = cv2.getStructuringElement(cv2.MORPH_RECT, (1, px))
    return cv2.bitwise_or(
        cv2.morphologyEx(img, cv2.MORPH_CLOSE, h_k),
        cv2.morphologyEx(img, cv2.MORPH_CLOSE, v_k),
    )

def edges_to_img(e, close_px=20):
    """Turn a binary edge map into a 'fat' visible mask via directional+iso close."""
    d = directional_close(e, close_px)
    return morph_close(d, close_px)

def img_to_b64(path):
    with open(path, 'rb') as f:
        return base64.b64encode(f.read()).decode()


# ── experiments ───────────────────────────────────────────────────────────────

def run_experiments(depth, edge_map, out_dir, h, w):
    """
    Returns list of dicts:
      { name, label, description, enhanced_png, result_png }
    where *_png are file paths relative to out_dir.
    """
    os.makedirs(out_dir, exist_ok=True)
    results = []
    tracked = {}  # name → result array for DEG average

    def save(name, enhanced, result, label, description):
        ep = os.path.join(out_dir, f'{name}_enh.png')
        rp = os.path.join(out_dir, f'{name}_res.png')
        cv2.imwrite(ep, enhanced)
        cv2.imwrite(rp, result)
        results.append(dict(
            name=name, label=label, description=description,
            enhanced_png=f'{name}_enh.png', result_png=f'{name}_res.png',
        ))

    CLOSE = max(20, min(h, w) // 30)  # ~3% of image — reasonable for these images

    # ── GROUP A: Baseline — raw → edge ────────────────────────────────────────
    name = 'A1_raw_sobel'
    g = sobel_cv(depth)
    save(name, depth, edges_to_img(binarize(g, 15), CLOSE),
         'A1 Raw → Sobel 15',
         'Baseline: no preprocessing at all. Shows why enhancement is essential.')

    # ── GROUP B: Rescale only ─────────────────────────────────────────────────
    r = rescale(depth)
    name = 'B1_rescale_sobel'
    g = sobel_cv(r)
    save(name, r, edges_to_img(binarize(g, 15), CLOSE),
         'B1 Rescale → Sobel 15',
         'Percentile stretch only (p2–p98 → 0-255). Already a big improvement.')

    name = 'B2_rescale_sobel25'
    save(name, r, edges_to_img(binarize(g, 25), CLOSE),
         'B2 Rescale → Sobel 25',
         'Higher Sobel threshold — keeps only strong edges.')

    # ── GROUP C: Rescale → Gamma → Sobel ─────────────────────────────────────
    rg3 = gamma(r, 0.3)
    rg4 = gamma(r, 0.4)
    rg5 = gamma(r, 0.5)

    for gv, gi in [(0.3, rg3), (0.4, rg4), (0.5, rg5)]:
        name = f'C{int(gv*10)}_gamma{gv}_sobel'
        g = sobel_cv(gi)
        save(name, gi, edges_to_img(binarize(g, 20), CLOSE),
             f'C Rescale→Gamma({gv})→Sobel 20',
             f'Gamma {gv} boosts dark-region transitions before Sobel.')

    # ── GROUP D: Rescale → Gamma → CLAHE → Sobel (current pipeline) ──────────
    for gv, gi in [(0.3, rg3), (0.4, rg4)]:
        cl = clahe(gi)
        for st in [15, 25]:
            name = f'D_g{int(gv*10)}_clahe_sob{st}'
            g = sobel_cv(cl)
            res = edges_to_img(binarize(g, st), CLOSE)
            if name == 'D_g3_clahe_sob15':
                tracked['D'] = res.copy()
            save(name, cl, res,
                 f'D Rescale→Gamma({gv})→CLAHE→Sobel {st}',
                 'Current pipeline variant. CLAHE adds local contrast on top of gamma.')

    # ── GROUP E: + Bilateral filter ───────────────────────────────────────────
    rg5 = gamma(r, 0.5)
    for gv, gi in [(0.3, rg3), (0.4, rg4), (0.5, rg5)]:
        cl = clahe(gi)
        bil = bilateral(cl)
        for st in [10, 15, 25]:
            if gv == 0.3 and st == 10:
                continue  # skip — gamma 0.3 + sob10 is too noisy
            name = f'E_g{int(gv*10)}_clahe_bil_sob{st}'
            g = sobel_cv(bil)
            res = edges_to_img(binarize(g, st), CLOSE)
            if name == 'E_g4_clahe_bil_sob15':
                tracked['E'] = res.copy()
            save(name, bil, res,
                 f'E Rescale→Gamma({gv})→CLAHE→Bilateral→Sobel {st}',
                 'Bilateral preserves edges while smoothing noise before Sobel.')

    # ── GROUP F: Log transform ────────────────────────────────────────────────
    lg = log_transform(r)
    cl = clahe(lg)
    bil = bilateral(cl)
    name = 'F1_log_clahe_bil_sobel'
    g = sobel_cv(bil)
    save(name, cl, edges_to_img(binarize(g, 20), CLOSE),
         'F1 Rescale→Log→CLAHE→Bilateral→Sobel 20',
         'Log transform: steeper boost than gamma near 0, great for very dark maps.')

    # ── GROUP G: Median filter (user noted "Median k=5" worked) ──────────────
    for gv, gi in [(0.3, rg3), (0.4, rg4)]:
        cl = clahe(gi)
        bil = bilateral(cl)
        med = cv2.medianBlur(bil, 5)
        name = f'G_g{int(gv*10)}_clahe_bil_med5_sobel'
        g = sobel_cv(med)
        res = edges_to_img(binarize(g, 20), CLOSE)
        if name == 'G_g4_clahe_bil_med5_sobel':
            tracked['G'] = res.copy()
        save(name, med, res,
             f'G Rescale→Gamma({gv})→CLAHE→Bilateral→Median(5)→Sobel 20',
             'Median k=5 removes salt-and-pepper noise; user noted this worked well.')

    # ── GROUP H: Hysteresis thresholding ─────────────────────────────────────
    cl4 = clahe(rg4)
    bil4 = bilateral(cl4)
    sk_g = sk_sobel(bil4.astype(np.float32) / 255.0)
    for lo, hi in [(0.03, 0.15), (0.05, 0.20), (0.07, 0.25)]:
        name = f'H_hyst_{int(lo*100)}_{int(hi*100)}'
        hyst = apply_hysteresis_threshold(sk_g, lo, hi).astype(np.uint8) * 255
        save(name, bil4, edges_to_img(hyst, CLOSE),
             f'H Hysteresis lo={lo} hi={hi}',
             'Hysteresis accepts weak edges only if connected to strong edges — cleaner contours.')

    # ── GROUP I: Triangle threshold on enhanced depth ─────────────────────────
    # Triangle is purpose-built for skewed single-peak histograms (like depth maps)
    cl4 = clahe(rg4)
    t = threshold_triangle(cl4)
    wall_raw = (cl4 > t).astype(np.uint8) * 255
    name = 'I1_triangle_thresh'
    save(name, cl4, morph_close(morph_open(wall_raw, 3), CLOSE),
         f'I1 Triangle threshold (t={int(t)}) on Gamma(0.4)+CLAHE',
         'Triangle threshold maximises distance from histogram peak — good for unimodal depth histograms.')

    # Also try inverted (walls might be darker)
    wall_inv = (cl4 < t).astype(np.uint8) * 255
    name = 'I2_triangle_thresh_inv'
    save(name, cl4, morph_close(morph_open(wall_inv, 3), CLOSE),
         f'I2 Triangle threshold inverted (t={int(t)})',
         'Same as I1 but keep pixels BELOW the threshold (walls darker than floor).')

    # ── GROUP J: Multi-Otsu (3 classes) ──────────────────────────────────────
    cl4 = clahe(rg4)
    try:
        thresholds = threshold_multiotsu(cl4, classes=3)
        # Class 2 (above upper threshold) = elevated objects/walls
        wall_hi  = (cl4 >= thresholds[1]).astype(np.uint8) * 255
        wall_mid = ((cl4 >= thresholds[0]) & (cl4 < thresholds[1])).astype(np.uint8) * 255
        name = 'J1_multiotsu_hi'
        save(name, cl4, morph_close(morph_open(wall_hi, 3), CLOSE),
             f'J1 Multi-Otsu class 3 (t≥{int(thresholds[1])})',
             '3-class Otsu: only keep the highest-elevation class (likely walls).')
        name = 'J2_multiotsu_mid_hi'
        save(name, cl4, morph_close(morph_open(cv2.bitwise_or(wall_hi, wall_mid), 3), CLOSE),
             f'J2 Multi-Otsu classes 2+3 (t≥{int(thresholds[0])})',
             'Keep both mid + high elevation classes.')
    except Exception as e:
        print(f'[warn] Multi-Otsu failed: {e}')

    # ── GROUP K: Edge map fusion (depth_gradient × shadow_edges) ─────────────
    # Multiply depth gradient by shadow edge map — mutual confirmation
    cl4 = clahe(rg4)
    bil4 = bilateral(cl4)
    g_depth = sobel_cv(bil4).astype(np.float32) / 255.0
    g_edges = edge_map.astype(np.float32) / 255.0

    fused_mult = (g_depth * g_edges * 255).astype(np.uint8)
    fused_max  = np.maximum(fused_mult, (g_depth * 255).astype(np.uint8))

    name = 'K1_fused_mult'
    save(name, fused_mult, edges_to_img(binarize(fused_mult, 15), CLOSE),
         'K1 Depth_grad × Shadow_edges (multiply)',
         'Mutual confirmation: only boundaries present in BOTH depth gradient and shadow edge map survive.')

    name = 'K2_fused_max'
    save(name, fused_max, edges_to_img(binarize(fused_max, 15), CLOSE),
         'K2 max(Depth_grad, Fused)',
         'Max of pure depth gradient and the fused product — less strict than pure multiply.')

    name = 'K3_shadow_only'
    save(name, edge_map, edges_to_img(binarize(edge_map, 30), CLOSE),
         'K3 Shadow edges only (reference)',
         'The raw shadow edge map for reference — how much comes from it alone.')

    # ── GROUP L: Guided filter ────────────────────────────────────────────────
    cl4 = clahe(rg4)
    bil4 = bilateral(cl4)
    try:
        guided = cv2.ximgproc.guidedFilter(
            guide=bil4, src=edge_map, radius=8, eps=1000
        )
        name = 'L1_guided_filter'
        save(name, guided, edges_to_img(binarize(guided, 25), CLOSE),
             'L1 Guided filter (shadow→depth guide)',
             'Shadow edges smoothed/aligned using depth as guide — preserves edges that agree with depth structure.')
    except Exception as e:
        print(f'[warn] Guided filter failed: {e}')

    # ── GROUP M: Otsu + Gamma 0.3 + Blur (user noted "worked well") ──────────
    # Rescale → Gamma(0.3) → Blur → Otsu threshold → merge
    rg3_bl = cv2.GaussianBlur(rg3, (7, 7), 0)
    otsu_t, wall_otsu = cv2.threshold(rg3_bl, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    wall_otsu_inv = cv2.bitwise_not(wall_otsu)
    name = 'M1_otsu_gamma03_blur'
    save(name, rg3_bl, morph_close(morph_open(wall_otsu, 3), CLOSE),
         f'M1 Rescale→Gamma(0.3)→Blur→Otsu(t={int(otsu_t)})',
         '"Otsu+Gamma0.3+Blur+Merge" — user noted this worked well in prior experiments.')
    name = 'M2_otsu_gamma03_blur_inv'
    save(name, rg3_bl, morph_close(morph_open(wall_otsu_inv, 3), CLOSE),
         f'M2 Same but inverted (t={int(otsu_t)})',
         'Inverted Otsu — try this if walls are darker in enhanced image.')

    # ── GROUP Z: Average of D(g0.3,sob15) + E(g0.4,sob15) + G(g0.4,sob20) ────
    if len(tracked) == 3:
        avg = (tracked['D'].astype(np.float32) +
               tracked['E'].astype(np.float32) +
               tracked['G'].astype(np.float32)) / 3.0
        avg_img = np.clip(avg, 0, 255).astype(np.uint8)
        save('Z_avg_DEG', avg_img, avg_img,
             'Z Average D(Gamma0.3,Sob15) + E(Gamma0.4,Sob15) + G(Gamma0.4,Sob20)',
             'Pixel-wise average of the three result images. Three 255s → 255, three 0s → 0, mixed → proportional.')

    return results


# ── HTML generation ───────────────────────────────────────────────────────────

STYLE = """
* { box-sizing: border-box; margin: 0; padding: 0; }
body { background: #1a1a2e; color: #e0e0e0; font-family: 'Segoe UI', system-ui, sans-serif; padding: 20px; }
h1 { color: #e94560; margin-bottom: 6px; }
h2 { color: #4ecca3; margin: 24px 0 10px; font-size: 1.1em; border-bottom: 1px solid #333; padding-bottom: 6px; }
.meta { color: #888; font-size: 13px; margin-bottom: 20px; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(400px, 1fr)); gap: 16px; }
.card { background: #16213e; border-radius: 10px; padding: 12px; }
.card-title { font-size: 13px; font-weight: bold; color: #e94560; margin-bottom: 6px; }
.card-desc { font-size: 12px; color: #888; margin-bottom: 8px; }
.img-row { display: flex; gap: 6px; }
.img-row img { flex: 1; min-width: 0; border-radius: 4px; cursor: pointer; object-fit: cover; height: 180px; }
.img-label { font-size: 11px; color: #4ecca3; text-align: center; margin-top: 3px; }
.group { margin-bottom: 30px; }
.lightbox { display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.92); z-index: 1000; justify-content: center; align-items: center; }
.lightbox.active { display: flex; }
.lightbox img { max-width: 95vw; max-height: 95vh; object-fit: contain; }
.caption { position: fixed; bottom: 20px; left: 0; right: 0; text-align: center; color: #e0e0e0; font-size: 14px; }
"""

SCRIPT = """
document.querySelectorAll('.img-row img').forEach(img => {
  img.addEventListener('click', () => {
    document.getElementById('lb-img').src = img.src;
    document.getElementById('lb-cap').textContent = img.title || '';
    document.getElementById('lb').classList.add('active');
  });
});
function close_lb() { document.getElementById('lb').classList.remove('active'); }
document.addEventListener('keydown', e => { if (e.key === 'Escape') close_lb(); });
"""

GROUPS = [
    ('A', 'A: Baseline — raw'),
    ('B', 'B: Rescale only'),
    ('C', 'C: Rescale → Gamma'),
    ('D', 'D: Rescale → Gamma → CLAHE (current)'),
    ('E', 'E: + Bilateral filter'),
    ('F', 'F: Log transform'),
    ('G', 'G: + Median filter'),
    ('H', 'H: Hysteresis thresholding'),
    ('I', 'I: Triangle threshold'),
    ('J', 'J: Multi-Otsu'),
    ('K', 'K: Edge fusion (depth × shadow)'),
    ('L', 'L: Guided filter'),
    ('M', 'M: Otsu + Gamma 0.3 + Blur'),
    ('Z', 'Z: DEG Average (D Gamma0.3 + E Gamma0.4 + G Gamma0.4)'),
]


def build_html(results, depth_b64, edge_b64, out_dir, room_id):
    # Group results by prefix letter
    grouped = {}
    for r in results:
        prefix = r['name'].split('_')[0]
        grouped.setdefault(prefix, []).append(r)

    cards_html = ''
    for prefix, group_label in GROUPS:
        items = grouped.get(prefix, [])
        if not items:
            continue
        cards_html += f'<div class="group"><h2>{group_label}</h2><div class="grid">\n'
        for r in items:
            enh_b64 = img_to_b64(os.path.join(out_dir, r['enhanced_png']))
            res_b64 = img_to_b64(os.path.join(out_dir, r['result_png']))
            cards_html += f"""
<div class="card">
  <div class="card-title">{r['label']}</div>
  <div class="card-desc">{r['description']}</div>
  <div class="img-row">
    <div>
      <img src="data:image/png;base64,{enh_b64}" title="Enhanced: {r['label']}" loading="lazy">
      <div class="img-label">enhanced depth</div>
    </div>
    <div>
      <img src="data:image/png;base64,{res_b64}" title="Result: {r['label']}" loading="lazy">
      <div class="img-label">wall candidate</div>
    </div>
  </div>
</div>"""
        cards_html += '</div></div>\n'

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Depth Edge Compare — Room {room_id}</title>
  <style>{STYLE}</style>
</head>
<body>
  <h1>Depth Edge Compare — Room {room_id}</h1>
  <p class="meta">{len(results)} experiments &nbsp;|&nbsp; Left = enhanced depth &nbsp;|&nbsp; Right = wall candidate &nbsp;|&nbsp; Click to zoom</p>
  <h2>Input images</h2>
  <div class="grid" style="margin-bottom:24px">
    <div class="card">
      <div class="card-title">Cleaned depth (inpainted)</div>
      <img src="data:image/png;base64,{depth_b64}" style="width:100%;border-radius:6px;cursor:pointer" title="Cleaned depth" onclick="document.getElementById('lb-img').src=this.src;document.getElementById('lb').classList.add('active')">
    </div>
    <div class="card">
      <div class="card-title">Shadow edge map</div>
      <img src="data:image/png;base64,{edge_b64}" style="width:100%;border-radius:6px;cursor:pointer" title="Shadow edges" onclick="document.getElementById('lb-img').src=this.src;document.getElementById('lb').classList.add('active')">
    </div>
  </div>
  {cards_html}
  <div class="lightbox" id="lb" onclick="close_lb()">
    <img id="lb-img" src="">
    <div class="caption" id="lb-cap"></div>
  </div>
  <script>{SCRIPT}</script>
</body>
</html>"""

    return html


# ── main ──────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--depth',  required=True, help='Cleaned depth PNG')
    ap.add_argument('--edges',  required=True, help='Shadow edge map PNG')
    ap.add_argument('--output', required=True, help='Output directory')
    ap.add_argument('--room',   default='155',  help='Room ID (for title)')
    args = ap.parse_args()

    depth_img = cv2.imread(args.depth, cv2.IMREAD_GRAYSCALE)
    if depth_img is None:
        print(f'ERROR: cannot load depth from {args.depth}')
        sys.exit(1)

    edge_img = cv2.imread(args.edges, cv2.IMREAD_GRAYSCALE)
    if edge_img is None:
        print(f'ERROR: cannot load edges from {args.edges}')
        sys.exit(1)

    h, w = depth_img.shape
    # Resize edge map to match depth if needed
    if edge_img.shape != depth_img.shape:
        edge_img = cv2.resize(edge_img, (w, h), interpolation=cv2.INTER_LINEAR)

    out_dir = args.output
    os.makedirs(out_dir, exist_ok=True)

    print(f'Depth: {w}x{h}px  |  Running experiments...')
    results = run_experiments(depth_img, edge_img, out_dir, h, w)
    print(f'Ran {len(results)} experiments.')

    depth_b64 = base64.b64encode(open(args.depth, 'rb').read()).decode()
    edge_b64  = base64.b64encode(open(args.edges, 'rb').read()).decode()

    html = build_html(results, depth_b64, edge_b64, out_dir, args.room)
    html_path = os.path.join(out_dir, 'index.html')
    with open(html_path, 'w') as f:
        f.write(html)

    print(f'HTML written to {html_path}')


if __name__ == '__main__':
    main()
