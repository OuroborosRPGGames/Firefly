"""Draw classified hex overlay with object mask contours and labels.

Usage: python3 debug_hex_objects.py <image_path> <masks_json> <items_json> <hex_size> <colors_json> <output_path>

masks_json: JSON dict { type_name: {path: str, color: [r,g,b]}, ... }
items_json: JSON array of {px, py, hex_type} objects.
colors_json: JSON dict mapping hex_type -> [r, g, b].
"""
import cv2
import numpy as np
import sys
import json

def main():
    img = cv2.imread(sys.argv[1])
    if img is None:
        sys.exit(0)
    masks_json = json.loads(sys.argv[2])
    items = json.loads(sys.argv[3])
    hs = float(sys.argv[4])
    cols_rgb = json.loads(sys.argv[5])
    # Draw hex fill (semi-transparent) by type
    overlay = img.copy()
    for item in items:
        px, py = int(item['px']), int(item['py'])
        rgb = cols_rgb.get(item['hex_type'], [100, 200, 100])
        c = [rgb[2], rgb[1], rgb[0]]
        pts = np.array([[int(px + hs * np.cos(np.radians(60 * i))),
                         int(py + hs * np.sin(np.radians(60 * i)))] for i in range(6)], np.int32)
        cv2.fillPoly(overlay, [pts], c)
    result = cv2.addWeighted(img, 0.5, overlay, 0.5, 0)
    # Draw object mask outlines
    for name, info in masks_json.items():
        m = cv2.imread(info['path'], cv2.IMREAD_GRAYSCALE)
        if m is None:
            continue
        if (m.shape[0], m.shape[1]) != (result.shape[0], result.shape[1]):
            m = cv2.resize(m, (result.shape[1], result.shape[0]))
        rgb = info['color']
        bgr = (rgb[2], rgb[1], rgb[0])
        contours, _ = cv2.findContours((m > 128).astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        cv2.drawContours(result, contours, -1, bgr, 2)
        # Label near centroid of mask
        ys, xs = np.where(m > 128)
        if len(xs):
            cx, cy = int(xs.mean()), int(ys.mean())
            cv2.putText(result, name, (cx, cy), cv2.FONT_HERSHEY_SIMPLEX, 0.5, bgr, 1)
    # Draw hex outlines on top
    for item in items:
        px, py = int(item['px']), int(item['py'])
        pts = np.array([[int(px + hs * np.cos(np.radians(60 * i))),
                         int(py + hs * np.sin(np.radians(60 * i)))] for i in range(6)], np.int32)
        cv2.polylines(result, [pts], True, (255, 255, 255), 1)
    cv2.imwrite(sys.argv[6], result)

if __name__ == '__main__':
    main()
