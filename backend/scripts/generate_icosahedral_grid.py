#!/usr/bin/env python3
"""Generate vertex-based icosahedral hex grid.

Outputs a binary file with vertex positions and neighbor adjacency.
Uses iterative subdivision with NumPy for memory efficiency.

Usage:
    python3 generate_icosahedral_grid.py SUBDIVISIONS OUTPUT_FILE

Output format (binary):
    Header:  vertex_count(u32), edge_count(u32)
    Vertices (vertex_count entries): face_index(u32), lat(f64), lon(f64)
    Edges (edge_count entries): vertex_id_a(u32), vertex_id_b(u32)
"""

import sys
import struct
import math
import numpy as np

PHI = (1.0 + math.sqrt(5.0)) / 2.0


def icosahedron():
    """Return (vertices, faces) for a unit icosahedron."""
    norm = math.sqrt(1.0 + PHI * PHI)
    verts = np.array([
        [0, 1, PHI], [0, -1, PHI], [0, 1, -PHI], [0, -1, -PHI],
        [1, PHI, 0], [-1, PHI, 0], [1, -PHI, 0], [-1, -PHI, 0],
        [PHI, 0, 1], [-PHI, 0, 1], [PHI, 0, -1], [-PHI, 0, -1]
    ], dtype=np.float64) / norm

    faces = np.array([
        [0,8,1], [0,1,9], [0,9,5], [0,5,4], [0,4,8],
        [1,8,6], [9,1,7], [5,9,11], [4,5,2], [8,4,10],
        [3,6,7], [3,7,11], [3,11,2], [3,2,10], [3,10,6],
        [6,8,10], [7,6,1], [11,7,9], [2,11,5], [10,2,4]
    ], dtype=np.int32)
    return verts, faces


def normalize_rows(arr):
    """Normalize each row of an Nx3 array to unit length."""
    norms = np.sqrt(np.sum(arr * arr, axis=1, keepdims=True))
    return arr / norms


def subdivide_iteratively(ico_verts, ico_faces, subdivisions):
    """Iteratively subdivide the icosahedron, tracking face ownership.

    Returns:
        vertices: Nx3 float64 array of vertex positions on unit sphere
        edges: set of (a, b) tuples with a < b
        face_of_vertex: array of face_index per vertex
    """
    # Start with icosahedron vertices and faces
    # vertices[i] = [x, y, z], faces[i] = [v0, v1, v2]
    vertices = ico_verts.copy()
    faces = ico_faces.copy()

    # Track which icosahedral face each vertex first appeared on
    face_of_vertex = np.full(len(vertices), -1, dtype=np.int32)

    # Original icosahedron face indices (0..19) for each triangle
    # Initially faces[i] belongs to ico face i
    tri_face_idx = np.arange(20, dtype=np.int32)

    # Edge midpoint cache: maps (min_idx, max_idx) -> new_vertex_idx
    # Reused across subdivisions
    for level in range(subdivisions):
        num_tris = len(faces)
        new_faces = np.empty((num_tris * 4, 3), dtype=np.int32)
        new_tri_face_idx = np.empty(num_tris * 4, dtype=np.int32)
        edge_cache = {}

        def get_midpoint(a, b, face_idx):
            key = (min(a, b), max(a, b))
            if key in edge_cache:
                return edge_cache[key]
            mid = (vertices[a] + vertices[b]) * 0.5
            mid /= np.linalg.norm(mid)
            idx = len(vertices)
            vertices = np.vstack([vertices, mid.reshape(1, 3)])  # noqa
            if face_of_vertex is not None:
                face_of_vertex_list.append(face_idx)
            edge_cache[key] = idx
            return idx

        # Can't use np.vstack in a loop efficiently — collect midpoints in a list
        new_verts_list = list(vertices)
        face_of_vertex_list = list(face_of_vertex)

        for i in range(num_tris):
            v0, v1, v2 = faces[i]
            fi = tri_face_idx[i]

            # Get or create midpoints
            mids = []
            for a, b in [(v0, v1), (v1, v2), (v2, v0)]:
                key = (min(a, b), max(a, b))
                if key in edge_cache:
                    mids.append(edge_cache[key])
                else:
                    mid = (new_verts_list[a][0] + new_verts_list[b][0],
                           new_verts_list[a][1] + new_verts_list[b][1],
                           new_verts_list[a][2] + new_verts_list[b][2])
                    norm = math.sqrt(mid[0]**2 + mid[1]**2 + mid[2]**2)
                    inv = 1.0 / norm
                    mid = np.array([mid[0]*inv, mid[1]*inv, mid[2]*inv])
                    idx = len(new_verts_list)
                    new_verts_list.append(mid)
                    face_of_vertex_list.append(fi)
                    edge_cache[key] = idx
                    mids.append(idx)

            m01, m12, m20 = mids

            base = i * 4
            new_faces[base]     = [v0, m01, m20]
            new_faces[base + 1] = [m01, v1, m12]
            new_faces[base + 2] = [m20, m12, v2]
            new_faces[base + 3] = [m01, m12, m20]
            new_tri_face_idx[base:base+4] = fi

            if i % 1000000 == 0 and i > 0:
                print(f"  Level {level}: {i:,}/{num_tris:,} triangles", file=sys.stderr)

        vertices = np.array(new_verts_list)
        face_of_vertex = np.array(face_of_vertex_list, dtype=np.int32)
        faces = new_faces
        tri_face_idx = new_tri_face_idx

        print(f"  Level {level+1}/{subdivisions}: {len(vertices):,} vertices, "
              f"{len(faces):,} triangles", file=sys.stderr)

    # Build edge set from final triangles
    print("Building edge set...", file=sys.stderr)
    edges = set()
    for i in range(len(faces)):
        v0, v1, v2 = faces[i]
        for a, b in [(v0, v1), (v1, v2), (v2, v0)]:
            edges.add((min(a, b), max(a, b)))
        if i % 5000000 == 0 and i > 0:
            print(f"  Edges: {i:,}/{len(faces):,} triangles processed", file=sys.stderr)

    return vertices, edges, face_of_vertex


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} SUBDIVISIONS OUTPUT_FILE", file=sys.stderr)
        sys.exit(1)

    subdivisions = int(sys.argv[1])
    output_file = sys.argv[2]

    expected_vertices = 10 * (4 ** subdivisions) + 2
    print(f"Generating grid: subdivisions={subdivisions}, "
          f"expected_vertices={expected_vertices:,}", file=sys.stderr)

    ico_verts, ico_faces = icosahedron()
    vertices, edges, face_of_vertex = subdivide_iteratively(ico_verts, ico_faces, subdivisions)

    vertex_count = len(vertices)
    edge_count = len(edges)
    print(f"Grid complete: {vertex_count:,} vertices, {edge_count:,} edges", file=sys.stderr)

    # Write binary output
    print(f"Writing to {output_file}...", file=sys.stderr)
    with open(output_file, 'wb') as f:
        f.write(struct.pack('<II', vertex_count, edge_count))

        # Vertices
        for i in range(vertex_count):
            x, y, z = vertices[i]
            lat = math.asin(max(-1.0, min(1.0, float(z))))
            lon = math.atan2(float(y), float(x))
            fi = int(face_of_vertex[i]) if face_of_vertex[i] >= 0 else 0
            f.write(struct.pack('<Idd', fi, lat, lon))

            if i % 5000000 == 0 and i > 0:
                print(f"  Written {i:,}/{vertex_count:,} vertices", file=sys.stderr)

        # Edges
        edge_buf = bytearray(edge_count * 8)
        for idx, (a, b) in enumerate(edges):
            struct.pack_into('<II', edge_buf, idx * 8, a, b)
        f.write(edge_buf)

    file_size_mb = __import__('os').path.getsize(output_file) / (1024 * 1024)
    print(f"Done! File size: {file_size_mb:.1f} MB", file=sys.stderr)


if __name__ == '__main__':
    main()
