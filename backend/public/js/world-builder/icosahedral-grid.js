/**
 * IcosahedralGrid - Generates hex coordinates on an icosahedral projection
 *
 * Creates a sphere tiled with hexagons (plus 12 pentagons at vertices).
 * Based on Goldberg polyhedron / geodesic dome subdivision.
 */
class IcosahedralGrid {
  constructor(subdivisions = 10) {
    this.subdivisions = subdivisions;
    this.vertices = [];
    this.faces = [];
    this.hexCenters = [];

    this.generateIcosahedron();
    this.subdivide();
    this.generateHexCenters();
  }

  // Golden ratio for icosahedron vertices
  static PHI = (1 + Math.sqrt(5)) / 2;

  generateIcosahedron() {
    const t = IcosahedralGrid.PHI;

    // 12 vertices of icosahedron
    this.vertices = [
      [-1,  t,  0], [ 1,  t,  0], [-1, -t,  0], [ 1, -t,  0],
      [ 0, -1,  t], [ 0,  1,  t], [ 0, -1, -t], [ 0,  1, -t],
      [ t,  0, -1], [ t,  0,  1], [-t,  0, -1], [-t,  0,  1]
    ].map(v => this.normalize(v));

    // 20 triangular faces
    this.faces = [
      [0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
      [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
      [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
      [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]
    ];
  }

  normalize(v) {
    const len = Math.sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]);
    return [v[0]/len, v[1]/len, v[2]/len];
  }

  midpoint(v1, v2) {
    return this.normalize([
      (v1[0] + v2[0]) / 2,
      (v1[1] + v2[1]) / 2,
      (v1[2] + v2[2]) / 2
    ]);
  }

  subdivide() {
    for (let i = 0; i < this.subdivisions; i++) {
      const newFaces = [];
      const midpointCache = {};

      const getMidpoint = (i1, i2) => {
        const key = i1 < i2 ? `${i1}-${i2}` : `${i2}-${i1}`;
        if (!midpointCache[key]) {
          const mp = this.midpoint(this.vertices[i1], this.vertices[i2]);
          midpointCache[key] = this.vertices.length;
          this.vertices.push(mp);
        }
        return midpointCache[key];
      };

      for (const face of this.faces) {
        const [a, b, c] = face;
        const ab = getMidpoint(a, b);
        const bc = getMidpoint(b, c);
        const ca = getMidpoint(c, a);

        newFaces.push(
          [a, ab, ca],
          [b, bc, ab],
          [c, ca, bc],
          [ab, bc, ca]
        );
      }

      this.faces = newFaces;
    }
  }

  generateHexCenters() {
    // For hex rendering, we use face centroids
    this.hexCenters = this.faces.map((face, index) => {
      const [a, b, c] = face;
      const v1 = this.vertices[a];
      const v2 = this.vertices[b];
      const v3 = this.vertices[c];

      const center = this.normalize([
        (v1[0] + v2[0] + v3[0]) / 3,
        (v1[1] + v2[1] + v3[1]) / 3,
        (v1[2] + v2[2] + v3[2]) / 3
      ]);

      // Convert to lat/lng
      const [x, y, z] = center;
      const lat = Math.asin(z) * 180 / Math.PI;
      const lng = Math.atan2(y, x) * 180 / Math.PI;

      return {
        id: index,
        lat,
        lng,
        faceIndex: index,
        vertices: [v1, v2, v3]
      };
    });
  }

  // Get hex polygons formatted for Globe.gl
  getGlobeHexPolygons() {
    return this.hexCenters.map(hex => ({
      id: hex.id,
      lat: hex.lat,
      lng: hex.lng,
    }));
  }

  // Get number of hexes at current subdivision level
  getHexCount() {
    // 20 faces * 4^subdivisions
    return 20 * Math.pow(4, this.subdivisions);
  }

  // Find hex containing a lat/lng point
  findHexAt(lat, lng) {
    // Convert to 3D point
    const latRad = lat * Math.PI / 180;
    const lngRad = lng * Math.PI / 180;
    const point = [
      Math.cos(latRad) * Math.cos(lngRad),
      Math.cos(latRad) * Math.sin(lngRad),
      Math.sin(latRad)
    ];

    // Find closest hex center
    let closest = null;
    let closestDist = Infinity;

    for (const hex of this.hexCenters) {
      const center = this.normalize([
        Math.cos(hex.lat * Math.PI / 180) * Math.cos(hex.lng * Math.PI / 180),
        Math.cos(hex.lat * Math.PI / 180) * Math.sin(hex.lng * Math.PI / 180),
        Math.sin(hex.lat * Math.PI / 180)
      ]);

      const dist = Math.sqrt(
        Math.pow(point[0] - center[0], 2) +
        Math.pow(point[1] - center[1], 2) +
        Math.pow(point[2] - center[2], 2)
      );

      if (dist < closestDist) {
        closestDist = dist;
        closest = hex;
      }
    }

    return closest;
  }
}
