"""Draw classified hex overlay on a battlemap image with legend.

Usage: python3 debug_hex_classified.py <image_path> <items_json> <hex_size> <colors_json> <output_path>

items_json: JSON array of {px, py, hex_type, label} objects.
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
    items = json.loads(sys.argv[2])
    hs = float(sys.argv[3])
    cols_rgb = json.loads(sys.argv[4])
    overlay = img.copy()
    for item in items:
        px, py = int(item['px']), int(item['py'])
        rgb = cols_rgb.get(item['hex_type'], [128, 128, 128])
        c = [rgb[2], rgb[1], rgb[0]]  # RGB -> BGR
        border = [max(0, v - 40) for v in c]
        pts = np.array([[int(px + hs * np.cos(np.radians(60 * i))),
                         int(py + hs * np.sin(np.radians(60 * i)))] for i in range(6)], np.int32)
        cv2.fillPoly(overlay, [pts], c)
        cv2.polylines(overlay, [pts], True, border, 1)
    result = cv2.addWeighted(img, 0.4, overlay, 0.6, 0)
    # Draw type labels legend
    legend_items = {}
    for item in items:
        legend_items[item['hex_type']] = cols_rgb.get(item['hex_type'], [128, 128, 128])
    ly = 20
    for htype, rgb in legend_items.items():
        c = [rgb[2], rgb[1], rgb[0]]
        cv2.rectangle(result, (6, ly - 12), (18, ly), c, -1)
        cv2.putText(result, htype, (22, ly), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (255, 255, 255), 1)
        cv2.putText(result, htype, (22, ly), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 0, 0), 1)
        ly += 16
    cv2.imwrite(sys.argv[5], result)

if __name__ == '__main__':
    main()
