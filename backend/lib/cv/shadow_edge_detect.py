"""Shadow-aware edge detection for battlemap normalization.

Preprocesses the image to neutralize shadow contrast before running Canny,
producing an edge map that captures real structural boundaries (walls, furniture)
without picking up shadow edges.

Usage: python3 shadow_edge_detect.py <input_path> <output_path>
"""
import cv2
import numpy as np
import sys

if len(sys.argv) != 3:
    print(f"Usage: {sys.argv[0]} <input_path> <output_path>", file=sys.stderr)
    sys.exit(1)

img = cv2.imread(sys.argv[1])
if img is None:
    print(f"Error: could not read image {sys.argv[1]}", file=sys.stderr)
    sys.exit(1)

lab = cv2.cvtColor(img, cv2.COLOR_BGR2LAB)
l, a, b = cv2.split(lab)

# CLAHE on L channel — equalizes local brightness, flattens shadows
clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(16, 16))
l_eq = clahe.apply(l)

# Recombine and convert back
lab_eq = cv2.merge([l_eq, a, b])
bgr_eq = cv2.cvtColor(lab_eq, cv2.COLOR_LAB2BGR)
gray_eq = cv2.cvtColor(bgr_eq, cv2.COLOR_BGR2GRAY)

# Bilateral filter — edge-preserving smooth
gray_smooth = cv2.bilateralFilter(gray_eq, 9, 75, 75)

# Canny on shadow-suppressed luminance
edges_main = cv2.Canny(gray_smooth, 50, 150)

# Chrominance-only Canny (shadows don't change A/B channels)
a_edges = cv2.Canny(a, 30, 100)
b_edges = cv2.Canny(b, 30, 100)
chroma_edges = cv2.bitwise_or(a_edges, b_edges)

# Combine both
combined = cv2.bitwise_or(edges_main, chroma_edges)
cv2.imwrite(sys.argv[2], combined)
