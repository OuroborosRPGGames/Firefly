"""Visualize wall gap detections on the wall mask or battlemap image.

Usage: python3 debug_wall_gaps.py <background_image> <gaps_json> <output_path>

gaps_json: JSON array of {cx, cy, length, axis, kind} objects.
"""
import cv2
import numpy as np
import sys
import json

def main():
    img = cv2.imread(sys.argv[1])
    if img is None:
        sys.exit(0)
    # Convert grayscale mask to BGR for colored annotations
    if len(img.shape) == 2 or img.shape[2] == 1:
        img = cv2.cvtColor(img, cv2.COLOR_GRAY2BGR)
    gaps = json.loads(sys.argv[2])
    for gap in gaps:
        cx, cy = int(gap.get('cx', 0)), int(gap.get('cy', 0))
        length = int(gap.get('length', 20))
        axis = gap.get('axis', 1)  # 0=horizontal, 1=vertical
        kind = gap.get('kind', 'outer')
        color = (0, 200, 255) if kind == 'outer' else (0, 128, 255)  # cyan vs blue
        half = length // 2
        if axis == 1:  # vertical gap (east/west wall)
            cv2.line(img, (cx, cy - half), (cx, cy + half), color, 4)
        else:           # horizontal gap (north/south wall)
            cv2.line(img, (cx - half, cy), (cx + half, cy), color, 4)
        cv2.circle(img, (cx, cy), 8, color, -1)
        label = f"{kind} ({length}px)"
        cv2.putText(img, label, (cx + 10, cy), cv2.FONT_HERSHEY_SIMPLEX, 0.5, color, 1)
    # Legend
    cv2.rectangle(img, (4, 4), (200, 50), (0, 0, 0), -1)
    cv2.putText(img, f"Outer gaps: {sum(1 for g in gaps if g.get('kind') == 'outer')}", (8, 22),
                cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 200, 255), 1)
    cv2.putText(img, f"Inner gaps: {sum(1 for g in gaps if g.get('kind') == 'inner')}", (8, 42),
                cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 128, 255), 1)
    cv2.imwrite(sys.argv[3], img)

if __name__ == '__main__':
    main()
