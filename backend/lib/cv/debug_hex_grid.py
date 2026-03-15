"""Draw hex grid overlay on a battlemap image.

Usage: python3 debug_hex_grid.py <image_path> <hex_data_json> <hex_size> <output_path>

hex_data_json: JSON array of {px, py} objects for hex centers.
"""
import cv2
import numpy as np
import sys
import json

def main():
    img = cv2.imread(sys.argv[1])
    if img is None:
        sys.exit(0)
    data = json.loads(sys.argv[2])
    hs = float(sys.argv[3])
    for item in data:
        px, py = int(item['px']), int(item['py'])
        pts = np.array([[int(px + hs * np.cos(np.radians(60 * i))),
                         int(py + hs * np.sin(np.radians(60 * i)))] for i in range(6)], np.int32)
        cv2.polylines(img, [pts], True, (0, 220, 255), 1)
    cv2.imwrite(sys.argv[4], img)

if __name__ == '__main__':
    main()
