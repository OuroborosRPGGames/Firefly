"""Generate SAM composite overlay: masks colored per-object on the battlemap.

Usage: python3 debug_sam_composite.py <image_path> <masks_json> <colors_json> <output_path>

masks_json: JSON dict { type_name: mask_path, ... }
colors_json: JSON array of [r, g, b] color arrays.
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
    colors_rgb = json.loads(sys.argv[3])
    overlay = np.zeros_like(img)
    legend_y = 20
    for i, (name, mpath) in enumerate(masks_json.items()):
        m = cv2.imread(mpath, cv2.IMREAD_GRAYSCALE)
        if m is None:
            continue
        if (m.shape[0], m.shape[1]) != (img.shape[0], img.shape[1]):
            m = cv2.resize(m, (img.shape[1], img.shape[0]))
        rgb = colors_rgb[i % len(colors_rgb)]
        bgr = [rgb[2], rgb[1], rgb[0]]
        colored = np.zeros_like(img)
        colored[m > 128] = bgr
        overlay = cv2.bitwise_or(overlay, colored)
        cv2.putText(overlay, name, (10, legend_y), cv2.FONT_HERSHEY_SIMPLEX, 0.55, bgr, 1)
        legend_y += 20
    result = cv2.addWeighted(img, 0.5, overlay, 0.5, 0)
    cv2.imwrite(sys.argv[4], result)

if __name__ == '__main__':
    main()
