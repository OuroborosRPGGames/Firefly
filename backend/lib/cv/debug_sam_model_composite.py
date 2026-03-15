"""Generate SAM model-colored composite: green=SAM2G, yellow=Lang-SAM, cyan=SAM2Grounded.

Usage: python3 debug_sam_model_composite.py <image_path> <model_map_json> <output_path>

model_map_json: JSON dict { type_name: {mask: path, model: "samg"|"lang_sam"|"sam2grounded"}, ... }
"""
import cv2
import numpy as np
import sys
import json

MODEL_COLORS = {
    'samg':         [0, 255, 0],
    'lang_sam':     [0, 255, 255],
    'sam2grounded': [255, 255, 0],
    'none':         [128, 128, 128],
}
LEGEND = [
    ('SAM2G',        [0, 255, 0]),
    ('Lang-SAM',     [0, 255, 255]),
    ('SAM2Grounded', [255, 255, 0]),
]

def main():
    img = cv2.imread(sys.argv[1])
    if img is None:
        sys.exit(0)
    model_map = json.loads(sys.argv[2])
    overlay = np.zeros_like(img)
    for name, info in model_map.items():
        m = cv2.imread(info['mask'], cv2.IMREAD_GRAYSCALE)
        if m is None:
            continue
        if (m.shape[0], m.shape[1]) != (img.shape[0], img.shape[1]):
            m = cv2.resize(m, (img.shape[1], img.shape[0]))
        rgb = MODEL_COLORS.get(info['model'], [128, 128, 128])
        bgr = [rgb[2], rgb[1], rgb[0]]
        colored = np.zeros_like(img)
        colored[m > 128] = bgr
        overlay = cv2.bitwise_or(overlay, colored)
    result = cv2.addWeighted(img, 0.5, overlay, 0.5, 0)
    # Draw legend
    pad, box_w, box_h, font_scale = 8, 18, 14, 0.45
    legend_x = 10
    legend_y = 10
    for label, rgb in LEGEND:
        bgr = [rgb[2], rgb[1], rgb[0]]
        cv2.rectangle(result, (legend_x, legend_y), (legend_x + box_w, legend_y + box_h), bgr, -1)
        cv2.putText(result, label, (legend_x + box_w + 4, legend_y + box_h - 2),
                    cv2.FONT_HERSHEY_SIMPLEX, font_scale, bgr, 1)
        legend_y += box_h + pad
    cv2.imwrite(sys.argv[3], result)

if __name__ == '__main__':
    main()
