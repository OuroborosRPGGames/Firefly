/**
 * HexEditor - Scrollable 2D SVG-based hex grid editor
 *
 * Displays a scrollable region of the world map for detailed hex editing.
 * Supports: terrain painting, feature drawing, city placement, zone creation.
 *
 * Key concepts:
 * - World coordinates: absolute hex positions in the world (worldX, worldY)
 * - Viewport: which world coordinates are currently visible
 * - Screen coordinates: pixel positions for rendering
 */
class HexEditor {
  constructor(containerId, options = {}) {
    this.containerId = containerId;
    this.container = document.getElementById(containerId);
    this.svg = null;

    // Hex sizing - smaller for more visible hexes
    this.hexRadius = options.hexRadius || 30;

    // World viewport (which world coordinates are visible)
    this.viewportX = options.startX || 0;
    this.viewportY = options.startY || 0;

    // Native mode viewport center (geographic coordinates)
    this.nativeCenterLat = 0;
    this.nativeCenterLng = 0;
    this.nativeLayoutMode = 'unwrap';
    this.localPatchCenterHexId = null;
    this.localPatchBounds = null;
    this.localPatchFocusBounds = null;
    this.localPatchComponentBounds = null;
    this.localPatchFullComponent = false;
    this.localPatchRings = 18;
    this.pendingPatchCenterHexId = null;
    this.nativeProjectionCenterLat = 0;
    this.nativeProjectionCenterLng = 0;
    this.nativeViewX = 0;
    this.nativeViewY = 0;
    this.nativeScale = 1;
    this.nativeSpacing = 0.045;
    this.nativeHexMetric = 0.02;
    this.nativeSpatialIndex = null;
    this.nativeVoronoiBounds = null;

    // Gnomonic projection scale: pixels per radian on the tangent plane.
    // Computed dynamically from actual hex data by calibrateScale().
    // Default assumes NN distance ~0.00060 rad (varies by latitude).
    this.gnomonicScale = this.hexRadius * Math.sqrt(3) / 0.00060;

    // Cell size for globe worlds (degrees per grid cell)
    this.cellSize = 1.0;

    // World ID for API calls
    this.worldId = options.worldId || window.WORLD_ID;

    // Cached hex data: "x,y" -> {terrain, features, traversable, ...}
    this.hexCache = new Map();

    // Dirty hexes that need saving
    this.dirtyHexes = new Set();

    // Tool state
    this.selectedTool = 'select';
    this.selectedTerrain = 'plain';
    this.selectedFeature = 'road';

    // Zone drawing state
    this.zonePoints = [];
    this.isDrawingZone = false;

    // Feature drawing state
    this.featurePoints = [];
    this.features = []; // Array of {type, points: [{x, y}, ...]}
    this.directionalFeatures = []; // Array of {hex_id, lat, lng, direction, type}
    this.namedFeatures = []; // Array of {id, name, feature_type} from API
    this.isDrawingFeature = false;

    // Feature colors for rendering
    this.featureColors = {
      road: '#7f8c8d',
      highway: '#2c3e50',
      street: '#bdc3c7',
      trail: '#a04000',
      river: '#3498db',
      canal: '#2e86c1',
      railway: '#1c2833'
    };

    // Feature line widths
    this.featureWidths = {
      road: 3,
      highway: 5,
      street: 2,
      trail: 2,
      river: 4,
      canal: 3,
      railway: 3
    };

    // Cities data (loaded from API)
    this.cities = [];

    // Zones data (loaded from API)
    this.zones = [];

    // Callbacks
    this.onSave = options.onSave || (() => {});
    this.onClose = options.onClose || (() => {});
    this.onViewportChange = options.onViewportChange || (() => {});
    this.onLoadingStateChange = options.onLoadingStateChange || (() => {});

    // Terrain colors - includes both simple and detailed terrain types
    this.terrainColors = {
      // Water - natural blues
      ocean: '#2d5f8a',
      lake: '#4a8ab5',
      // Coastal - warm naturals
      coast: '#8a9a8d',
      rocky_coast: '#8a8a7d',
      sandy_coast: '#d4c9a8',
      // Plains - muted sage
      plain: '#a8b878',
      grassy_plains: '#a8b878',
      rocky_plains: '#b0a88a',
      // Fields
      field: '#c4ba8a',
      // Forests - natural greens
      forest: '#3a6632',
      light_forest: '#6d9a52',
      dense_forest: '#3a6632',
      jungle: '#2d5a2d',
      // Wetlands
      swamp: '#5a6b48',
      // Hills - warm earth tones
      hill: '#96a07a',
      grassy_hills: '#96a07a',
      rocky_hills: '#9a8d78',
      // Mountains
      mountain: '#8a7d6b',
      // Cold
      ice: '#d8e0e4',
      tundra: '#c8d5d8',
      // Arid - muted sand
      desert: '#c8b48a',
      // Volcanic
      volcanic: '#4a2828',
      // Urban - lighter grays
      urban: '#7a7a7a',
      light_urban: '#9a9a9a',
      // Fallback
      unknown: '#4a4a4a'
    };

    // Pan/drag state
    this.isPanning = false;
    this.panStart = { x: 0, y: 0 };
    this.panAccumulated = { x: 0, y: 0 };
    this.spacePressed = false;
    this.dragThreshold = 5; // pixels before drag is recognized

    // Loading state
    this.isLoading = false;

    // Minimap reference (set externally)
    this.minimap = null;

    this.init();
  }

  // Calculate hex dimensions
  get hexWidth() {
    return this.hexRadius * 2;
  }

  get hexHeight() {
    return Math.sqrt(3) * this.hexRadius;
  }

  get horizSpacing() {
    return this.hexWidth * 0.75;
  }

  get vertSpacing() {
    return this.hexHeight;
  }

  // How many hexes fit in the viewport
  get visibleCols() {
    if (!this.container) return 10;
    return Math.ceil(this.container.clientWidth / this.horizSpacing) + 2;
  }

  get visibleRows() {
    if (!this.container) return 10;
    return Math.ceil(this.container.clientHeight / this.vertSpacing) + 2;
  }

  // Gnomonic forward projection: (lat, lng) -> screen (x, y)
  // Returns null if point is on far side of globe
  gnomonicForward(lat, lng) {
    const DEG2RAD = Math.PI / 180;
    const latRad = lat * DEG2RAD;
    const lat0Rad = this.nativeCenterLat * DEG2RAD;
    const dLng = (lng - this.nativeCenterLng) * DEG2RAD;

    const cosC = Math.sin(lat0Rad) * Math.sin(latRad) +
                 Math.cos(lat0Rad) * Math.cos(latRad) * Math.cos(dLng);
    if (cosC <= 0) return null;

    const w = this.container.clientWidth;
    const h = this.container.clientHeight;
    const s = this.gnomonicScale;

    return {
      x: w / 2 + s * Math.cos(latRad) * Math.sin(dLng) / cosC,
      y: h / 2 - s * (Math.cos(lat0Rad) * Math.sin(latRad) -
                       Math.sin(lat0Rad) * Math.cos(latRad) * Math.cos(dLng)) / cosC
    };
  }

  // Gnomonic inverse projection: screen (x, y) -> (lat, lng)
  gnomonicInverse(screenX, screenY) {
    const w = this.container.clientWidth;
    const h = this.container.clientHeight;
    const s = this.gnomonicScale;

    const dx = (screenX - w / 2) / s;
    const dy = -(screenY - h / 2) / s;
    const rho = Math.sqrt(dx * dx + dy * dy);

    const DEG2RAD = Math.PI / 180;
    const lat0Rad = this.nativeCenterLat * DEG2RAD;

    if (rho === 0) {
      return { lat: this.nativeCenterLat, lng: this.nativeCenterLng };
    }

    const c = Math.atan(rho);
    const cosC = Math.cos(c);
    const sinC = Math.sin(c);

    const lat = Math.asin(cosC * Math.sin(lat0Rad) +
                dy * sinC * Math.cos(lat0Rad) / rho) / DEG2RAD;
    const lng = this.nativeCenterLng +
                Math.atan2(dx * sinC,
                  rho * Math.cos(lat0Rad) * cosC -
                  dy * Math.sin(lat0Rad) * sinC) / DEG2RAD;

    return { lat, lng };
  }

  // Calibrate gnomonic scale from hex density so hexes fill the viewport.
  // Computes the geographic area of the viewport, counts loaded hexes in it,
  // and sizes hexRadius so hex polygons cover the area with minimal gaps.
  calibrateScale() {
    // Count ghid hexes and find their lat/lng extent
    let count = 0;
    let minLat = Infinity, maxLat = -Infinity;
    let minLng = Infinity, maxLng = -Infinity;
    for (const [key, hex] of this.hexCache) {
      if (!key.startsWith('ghid:')) continue;
      count++;
      if (hex.lat < minLat) minLat = hex.lat;
      if (hex.lat > maxLat) maxLat = hex.lat;
      if (hex.lng < minLng) minLng = hex.lng;
      if (hex.lng > maxLng) maxLng = hex.lng;
    }
    if (count < 10) return;

    // Geographic area of loaded hexes (in radians²)
    const DEG2RAD = Math.PI / 180;
    const latSpan = (maxLat - minLat) * DEG2RAD;
    const lngSpan = (maxLng - minLng) * DEG2RAD;
    const midLat = (minLat + maxLat) / 2 * DEG2RAD;
    const geoArea = latSpan * lngSpan * Math.cos(midLat);  // solid angle approximation

    if (geoArea <= 0) return;

    // Hex polygon area in screen pixels: (3√3/2) * hexRadius²
    const hexArea = (3 * Math.sqrt(3) / 2) * this.hexRadius * this.hexRadius;

    // The total hex coverage in screen pixels should equal the screen area
    // of the geographic region. screen_area = geoArea * scale²
    // count * hexArea = geoArea * scale²
    // scale = sqrt(count * hexArea / geoArea)
    const newScale = Math.sqrt(count * hexArea / geoArea);

    if (newScale > 0 && isFinite(newScale)) {
      this.gnomonicScale = newScale;
    }
  }

  // Compute lat/lng bounding box of current viewport via gnomonic inverse
  nativeViewportBounds() {
    const w = this.container.clientWidth;
    const h = this.container.clientHeight;
    const corners = [
      this.gnomonicInverse(0, 0),
      this.gnomonicInverse(w, 0),
      this.gnomonicInverse(0, h),
      this.gnomonicInverse(w, h)
    ];
    const lats = corners.map(c => c.lat);
    const lngs = corners.map(c => c.lng);
    const pad = 0.1;
    const latSpan = Math.max(...lats) - Math.min(...lats);
    const lngSpan = Math.max(...lngs) - Math.min(...lngs);
    return {
      minLat: Math.min(...lats) - latSpan * pad,
      maxLat: Math.max(...lats) + latSpan * pad,
      minLng: Math.min(...lngs) - lngSpan * pad,
      maxLng: Math.max(...lngs) + lngSpan * pad
    };
  }

  localProjectionForward(lat, lng, centerLat = this.nativeProjectionCenterLat, centerLng = this.nativeProjectionCenterLng) {
    const wrappedLng = ((((lng - centerLng) + 540) % 360) - 180);
    const cosLat = Math.cos(centerLat * Math.PI / 180);
    return {
      x: wrappedLng * cosLat,
      y: centerLat - lat
    };
  }

  projectedNativeScreenPos(projectedX, projectedY) {
    const width = this.container.clientWidth;
    const height = this.container.clientHeight;
    return {
      x: width / 2 + (projectedX - this.nativeViewX) * this.nativeScale,
      y: height / 2 + (projectedY - this.nativeViewY) * this.nativeScale
    };
  }

  screenToProjectedNative(screenX, screenY) {
    const width = this.container.clientWidth;
    const height = this.container.clientHeight;
    return {
      x: this.nativeViewX + ((screenX - width / 2) / this.nativeScale),
      y: this.nativeViewY + ((screenY - height / 2) / this.nativeScale)
    };
  }

  applyNativeScale(scale) {
    const clamped = Math.max(20, Math.min(20000, scale));
    this.nativeScale = clamped;
    this.hexRadius = Math.max(2, this.nativeHexMetric * clamped);
  }

  projectedBoundsFromHexes(hexes) {
    if (!hexes || hexes.length === 0) {
      return { minX: 0, maxX: 0, minY: 0, maxY: 0 };
    }

    const xs = hexes.map((hex) => hex.projectedX);
    const ys = hexes.map((hex) => hex.projectedY);
    return {
      minX: Math.min(...xs),
      maxX: Math.max(...xs),
      minY: Math.min(...ys),
      maxY: Math.max(...ys)
    };
  }

  estimateProjectedNativeSpacing(hexes) {
    if (!hexes || hexes.length < 2) return 0.045;

    const sampleCount = Math.min(hexes.length, 160);
    const step = Math.max(1, Math.floor(hexes.length / sampleCount));
    const distances = [];

    for (let i = 0; i < hexes.length; i += step) {
      const hex = hexes[i];
      let first = Infinity;
      let second = Infinity;
      let third = Infinity;

      for (let j = 0; j < hexes.length; j++) {
        if (i === j) continue;
        const other = hexes[j];
        const dx = other.projectedX - hex.projectedX;
        const dy = other.projectedY - hex.projectedY;
        const distSq = (dx * dx) + (dy * dy);
        if (distSq < first) {
          third = second;
          second = first;
          first = distSq;
        } else if (distSq < second) {
          third = second;
          second = distSq;
        } else if (distSq < third) {
          third = distSq;
        }
      }

      if (Number.isFinite(third)) {
        distances.push(Math.sqrt(third));
      }
    }

    if (distances.length === 0) return 0.045;
    distances.sort((a, b) => a - b);
    return distances[Math.floor(distances.length / 2)] || 0.045;
  }

  buildProjectedSpatialIndex(hexes, bucketSize) {
    const bounds = this.projectedBoundsFromHexes(hexes);
    const buckets = new Map();

    hexes.forEach((hex) => {
      const bx = Math.floor((hex.projectedX - bounds.minX) / bucketSize);
      const by = Math.floor((hex.projectedY - bounds.minY) / bucketSize);
      const key = `${bx},${by}`;
      if (!buckets.has(key)) buckets.set(key, []);
      buckets.get(key).push(hex);
    });

    return {
      bucketSize,
      minX: bounds.minX,
      minY: bounds.minY,
      buckets
    };
  }

  collectProjectedNativeCandidates(pointX, pointY, desired = 18) {
    const hexes = this.localPatchHexes();
    if (!this.nativeSpatialIndex || hexes.length <= desired) {
      return hexes;
    }

    const { bucketSize, minX, minY, buckets } = this.nativeSpatialIndex;
    const baseX = Math.floor((pointX - minX) / bucketSize);
    const baseY = Math.floor((pointY - minY) / bucketSize);
    const seen = new Set();
    const candidates = [];

    for (let radius = 0; radius <= 4 && candidates.length < desired * 2; radius++) {
      for (let dx = -radius; dx <= radius; dx++) {
        for (let dy = -radius; dy <= radius; dy++) {
          if (radius > 0 && Math.abs(dx) !== radius && Math.abs(dy) !== radius) continue;

          const bucket = buckets.get(`${baseX + dx},${baseY + dy}`);
          if (!bucket) continue;

          bucket.forEach((hex) => {
            if (seen.has(hex.globe_hex_id)) return;
            seen.add(hex.globe_hex_id);
            candidates.push(hex);
          });
        }
      }
    }

    return candidates.length >= desired ? candidates : hexes;
  }

  clipPolygonToHalfPlane(polygon, currentX, currentY, otherX, otherY) {
    if (!polygon || polygon.length === 0) return [];

    const nx = otherX - currentX;
    const ny = otherY - currentY;
    const c = ((otherX * otherX) + (otherY * otherY) - (currentX * currentX) - (currentY * currentY)) / 2;
    const epsilon = 1e-9;
    const output = [];

    const inside = (point) => ((nx * point.x) + (ny * point.y)) <= (c + epsilon);
    const intersect = (from, to) => {
      const denom = (nx * (to.x - from.x)) + (ny * (to.y - from.y));
      if (Math.abs(denom) < epsilon) return { x: to.x, y: to.y };

      const t = (c - (nx * from.x) - (ny * from.y)) / denom;
      return {
        x: from.x + ((to.x - from.x) * t),
        y: from.y + ((to.y - from.y) * t)
      };
    };

    let previous = polygon[polygon.length - 1];
    let previousInside = inside(previous);

    polygon.forEach((point) => {
      const pointInside = inside(point);
      if (pointInside !== previousInside) {
        output.push(intersect(previous, point));
      }
      if (pointInside) {
        output.push(point);
      }
      previous = point;
      previousInside = pointInside;
    });

    return output;
  }

  computeProjectedNativePolygon(hex) {
    if (!this.nativeVoronoiBounds) return null;

    const bounds = this.nativeVoronoiBounds;
    let polygon = [
      { x: bounds.minX, y: bounds.minY },
      { x: bounds.maxX, y: bounds.minY },
      { x: bounds.maxX, y: bounds.maxY },
      { x: bounds.minX, y: bounds.maxY }
    ];

    const neighbors = this.collectProjectedNativeCandidates(hex.projectedX, hex.projectedY, 18)
      .filter((candidate) => candidate.globe_hex_id !== hex.globe_hex_id)
      .map((candidate) => ({
        hex: candidate,
        distSq: ((candidate.projectedX - hex.projectedX) ** 2) + ((candidate.projectedY - hex.projectedY) ** 2)
      }))
      .sort((a, b) => a.distSq - b.distSq)
      .slice(0, 18);

    neighbors.forEach(({ hex: other }) => {
      polygon = this.clipPolygonToHalfPlane(
        polygon,
        hex.projectedX,
        hex.projectedY,
        other.projectedX,
        other.projectedY
      );
    });

    return polygon.length >= 3 ? polygon : null;
  }

  computePolygonBounds(polygon) {
    if (!polygon || polygon.length === 0) return null;

    const xs = polygon.map((point) => point.x);
    const ys = polygon.map((point) => point.y);
    return {
      minX: Math.min(...xs),
      maxX: Math.max(...xs),
      minY: Math.min(...ys),
      maxY: Math.max(...ys)
    };
  }

  pointInPolygon(point, polygon) {
    if (!polygon || polygon.length < 3) return false;

    let inside = false;
    for (let i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      const xi = polygon[i].x;
      const yi = polygon[i].y;
      const xj = polygon[j].x;
      const yj = polygon[j].y;

      const intersects = ((yi > point.y) !== (yj > point.y)) &&
        (point.x < (((xj - xi) * (point.y - yi)) / ((yj - yi) || 1e-9)) + xi);
      if (intersects) inside = !inside;
    }

    return inside;
  }

  findNearestProjectedNativeHexToPoint(projectedX, projectedY) {
    let nearest = null;
    let nearestDistSq = Infinity;

    this.collectProjectedNativeCandidates(projectedX, projectedY, 18).forEach((hex) => {
      const dx = hex.projectedX - projectedX;
      const dy = hex.projectedY - projectedY;
      const distSq = (dx * dx) + (dy * dy);
      if (distSq < nearestDistSq) {
        nearestDistSq = distSq;
        nearest = hex;
      }
    });

    return nearest;
  }

  findProjectedNativeHexAt(screenX, screenY, maxDistance = this.hexRadius * 1.5) {
    const projectedPoint = this.screenToProjectedNative(screenX, screenY);
    const candidates = this.collectProjectedNativeCandidates(projectedPoint.x, projectedPoint.y, 18);

    for (const hex of candidates) {
      if (!this.ensureProjectedNativePolygon(hex)) continue;
      if (projectedPoint.x < hex.projectedBBox.minX || projectedPoint.x > hex.projectedBBox.maxX ||
          projectedPoint.y < hex.projectedBBox.minY || projectedPoint.y > hex.projectedBBox.maxY) {
        continue;
      }
      if (this.pointInPolygon(projectedPoint, hex.projectedPath)) {
        return hex;
      }
    }

    const nearest = this.findNearestProjectedNativeHexToPoint(projectedPoint.x, projectedPoint.y);
    if (!nearest) return null;

    const limit = Number.isFinite(maxDistance) ? (maxDistance / this.nativeScale) ** 2 : Infinity;
    const dx = nearest.projectedX - projectedPoint.x;
    const dy = nearest.projectedY - projectedPoint.y;
    return ((dx * dx) + (dy * dy)) <= limit ? nearest : null;
  }

  nativeProjectedViewBounds() {
    const halfWidth = this.container.clientWidth / (2 * this.nativeScale);
    const halfHeight = this.container.clientHeight / (2 * this.nativeScale);
    return {
      minX: this.nativeViewX - halfWidth,
      maxX: this.nativeViewX + halfWidth,
      minY: this.nativeViewY - halfHeight,
      maxY: this.nativeViewY + halfHeight
    };
  }

  clampProjectedNativeView(paddingMultiplier = 2) {
    if (!this.localPatchBounds || !this.container || !Number.isFinite(this.nativeScale) || this.nativeScale <= 0) {
      return false;
    }

    const bounds = this.localPatchBounds;
    const padding = this.nativeSpacing * paddingMultiplier;
    const halfWidth = this.container.clientWidth / (2 * this.nativeScale);
    const halfHeight = this.container.clientHeight / (2 * this.nativeScale);
    let changed = false;

    const minCenterX = bounds.minX - padding + halfWidth;
    const maxCenterX = bounds.maxX + padding - halfWidth;
    if (maxCenterX < minCenterX) {
      const centeredX = (bounds.minX + bounds.maxX) / 2;
      if (this.nativeViewX !== centeredX) {
        this.nativeViewX = centeredX;
        changed = true;
      }
    } else {
      const clampedX = Math.min(Math.max(this.nativeViewX, minCenterX), maxCenterX);
      if (clampedX !== this.nativeViewX) {
        this.nativeViewX = clampedX;
        changed = true;
      }
    }

    const minCenterY = bounds.minY - padding + halfHeight;
    const maxCenterY = bounds.maxY + padding - halfHeight;
    if (maxCenterY < minCenterY) {
      const centeredY = (bounds.minY + bounds.maxY) / 2;
      if (this.nativeViewY !== centeredY) {
        this.nativeViewY = centeredY;
        changed = true;
      }
    } else {
      const clampedY = Math.min(Math.max(this.nativeViewY, minCenterY), maxCenterY);
      if (clampedY !== this.nativeViewY) {
        this.nativeViewY = clampedY;
        changed = true;
      }
    }

    return changed;
  }

  fitProjectedNativeBounds(bounds, paddingMultiplier = 2.5) {
    if (!bounds || !this.container) return;

    const spanX = Math.max(bounds.maxX - bounds.minX, this.nativeSpacing);
    const spanY = Math.max(bounds.maxY - bounds.minY, this.nativeSpacing);
    const padding = this.nativeSpacing * paddingMultiplier;
    const targetScale = Math.min(
      this.container.clientWidth / Math.max(spanX + (padding * 2), this.nativeSpacing),
      this.container.clientHeight / Math.max(spanY + (padding * 2), this.nativeSpacing)
    );

    if (Number.isFinite(targetScale) && targetScale > 0) {
      this.applyNativeScale(targetScale);
    }

    this.nativeViewX = (bounds.minX + bounds.maxX) / 2;
    this.nativeViewY = (bounds.minY + bounds.maxY) / 2;
    this.clampProjectedNativeView();
  }

  buildProjectedNativeGeometry() {
    const hexes = this.localPatchHexes();
    if (hexes.length === 0) return;

    this.nativeSpacing = this.estimateProjectedNativeSpacing(hexes);
    this.nativeHexMetric = Math.max(this.nativeSpacing * 0.52, 0.0025);
    this.hexRadius = Math.max(2, this.nativeHexMetric * this.nativeScale);

    const bounds = this.localPatchBounds || this.projectedBoundsFromHexes(hexes);
    const padding = this.nativeSpacing * 2.5;
    this.nativeVoronoiBounds = {
      minX: bounds.minX - padding,
      maxX: bounds.maxX + padding,
      minY: bounds.minY - padding,
      maxY: bounds.maxY + padding
    };
    this.nativeSpatialIndex = this.buildProjectedSpatialIndex(
      hexes,
      Math.max(this.nativeSpacing * 1.5, 0.0001)
    );

    const eagerGeometry = hexes.length <= 2500;
    hexes.forEach((hex) => {
      if (eagerGeometry) {
        hex.projectedPath = this.computeProjectedNativePolygon(hex);
        hex.projectedBBox = this.computePolygonBounds(hex.projectedPath);
      } else {
        hex.projectedPath = null;
        hex.projectedBBox = null;
      }
      this.updateCachedHex(hex);
    });
  }

  ensureProjectedNativePolygon(hex) {
    if (!hex) return false;
    if (hex.projectedPath && hex.projectedBBox) return true;

    hex.projectedPath = this.computeProjectedNativePolygon(hex);
    hex.projectedBBox = this.computePolygonBounds(hex.projectedPath);
    this.updateCachedHex(hex);
    return !!(hex.projectedPath && hex.projectedBBox);
  }

  localPatchScreenPos(worldX, worldY) {
    const startCol = Math.floor(this.viewportX);
    const startRow = Math.floor(this.viewportY);
    const offsetX = (this.viewportX - startCol) * this.horizSpacing;
    const offsetY = (this.viewportY - startRow) * this.vertSpacing;
    const relCol = worldX - startCol;
    const relRow = worldY - startRow;
    const pos = this.hexToPixel(relCol, relRow);
    return { x: pos.x - offsetX, y: pos.y - offsetY };
  }

  findNearestLocalPatchHexByGridCoords(worldX, worldY) {
    let nearest = null;
    let nearestDistSq = Infinity;

    this.localPatchHexes().forEach((hexInfo) => {
      if (hexInfo.worldX == null || hexInfo.worldY == null) return;

      const dx = hexInfo.worldX - worldX;
      const dy = hexInfo.worldY - worldY;
      const distSq = (dx * dx) + (dy * dy);
      if (distSq < nearestDistSq) {
        nearestDistSq = distSq;
        nearest = hexInfo;
      }
    });

    return nearest;
  }

  getLocalPatchHexScreenPos(worldX, worldY) {
    if (this.isUnwrappedNativeMode) {
      const hexInfo = this.getCachedHex(worldX, worldY)
        || this.findNearestLocalPatchHexByGridCoords(worldX, worldY);
      if (!hexInfo) return null;
      return this.projectedNativeScreenPos(hexInfo.projectedX, hexInfo.projectedY);
    }

    return this.localPatchScreenPos(worldX, worldY);
  }

  projectedDirectionVector(direction) {
    const vectors = {
      n: { x: 0, y: -1 },
      ne: { x: Math.sqrt(3) / 2, y: -0.5 },
      se: { x: Math.sqrt(3) / 2, y: 0.5 },
      s: { x: 0, y: 1 },
      sw: { x: -Math.sqrt(3) / 2, y: 0.5 },
      nw: { x: -Math.sqrt(3) / 2, y: -0.5 }
    };

    return vectors[direction] || { x: 0, y: 0 };
  }

  getProjectedNativeEdgePos(hexInfo, direction) {
    if (!hexInfo) return null;

    const center = {
      x: hexInfo.projectedX ?? 0,
      y: hexInfo.projectedY ?? 0
    };

    if (!hexInfo.projectedPath || hexInfo.projectedPath.length < 2) {
      const vector = this.projectedDirectionVector(direction);
      const fallbackDistance = Math.max(this.nativeHexMetric || 0, this.nativeSpacing || 0.01);
      return this.projectedNativeScreenPos(
        center.x + (vector.x * fallbackDistance),
        center.y + (vector.y * fallbackDistance)
      );
    }

    const vector = this.projectedDirectionVector(direction);
    let bestPoint = null;
    let bestScore = -Infinity;

    for (let i = 0; i < hexInfo.projectedPath.length; i++) {
      const from = hexInfo.projectedPath[i];
      const to = hexInfo.projectedPath[(i + 1) % hexInfo.projectedPath.length];
      const midpoint = {
        x: (from.x + to.x) / 2,
        y: (from.y + to.y) / 2
      };
      const score = ((midpoint.x - center.x) * vector.x) + ((midpoint.y - center.y) * vector.y);
      if (score > bestScore) {
        bestScore = score;
        bestPoint = midpoint;
      }
    }

    const target = bestPoint || center;
    return this.projectedNativeScreenPos(target.x, target.y);
  }

  zoomProjectedNativeAt(scaleFactor, screenX = this.container.clientWidth / 2,
    screenY = this.container.clientHeight / 2) {
    if (!this.isUnwrappedNativeMode || !this.container) return false;

    const pointBefore = this.screenToProjectedNative(screenX, screenY);
    const previousScale = this.nativeScale;
    this.applyNativeScale(this.nativeScale * scaleFactor);
    if (this.nativeScale === previousScale) return false;

    const pointAfter = this.screenToProjectedNative(screenX, screenY);
    this.nativeViewX += pointBefore.x - pointAfter.x;
    this.nativeViewY += pointBefore.y - pointAfter.y;
    this.clampProjectedNativeView();
    this.syncNativeCenterFromViewport();
    this.render();
    this.maybeRecenterNativePatch();
    return true;
  }

  zoomNativeAt(scaleFactor, screenX = this.container.clientWidth / 2,
    screenY = this.container.clientHeight / 2) {
    if (!this.isNativeMode || this.isUnwrappedNativeMode || !this.container) return false;

    const cursorGeo = this.gnomonicInverse(screenX, screenY);
    const scalePerRadius = this.gnomonicScale / Math.max(this.hexRadius, 0.0001);
    const newRadius = Math.max(2, Math.min(80, this.hexRadius * scaleFactor));
    if (newRadius === this.hexRadius) return false;

    this.hexRadius = newRadius;
    this.gnomonicScale = this.hexRadius * scalePerRadius;

    const width = this.container.clientWidth;
    const height = this.container.clientHeight;
    const offsetX = screenX - width / 2;
    const offsetY = screenY - height / 2;
    this.nativeCenterLat = cursorGeo.lat;
    this.nativeCenterLng = cursorGeo.lng;
    const shiftedCenter = this.gnomonicInverse(width / 2 - offsetX, height / 2 - offsetY);
    this.nativeCenterLat = shiftedCenter.lat;
    this.nativeCenterLng = shiftedCenter.lng;

    this.render();
    this.loadVisibleHexes();
    return true;
  }

  zoomGridAt(scaleFactor, screenX = this.container.clientWidth / 2,
    screenY = this.container.clientHeight / 2) {
    if (this.isNativeMode || !this.container) return false;

    const newRadius = this.hexRadius * scaleFactor;
    if (newRadius < 2 || newRadius > 80) return false;

    const worldPosBeforeZoom = this.pixelToHex(screenX, screenY);
    this.hexRadius = newRadius;
    const worldPosAfterZoom = this.pixelToHex(screenX, screenY);
    this.viewportX += worldPosBeforeZoom.col - worldPosAfterZoom.col;
    this.viewportY += worldPosBeforeZoom.row - worldPosAfterZoom.row;

    this.render();
    this.loadVisibleHexes();
    return true;
  }

  zoomViewport(scaleFactor, screenX = this.container?.clientWidth / 2,
    screenY = this.container?.clientHeight / 2) {
    if (this.isUnwrappedNativeMode && !this.hasLoadedProjectedNativePatch) {
      return false;
    }
    if (this.isUnwrappedNativeMode) {
      return this.zoomProjectedNativeAt(scaleFactor, screenX, screenY);
    }
    if (this.isNativeMode) {
      return this.zoomNativeAt(scaleFactor, screenX, screenY);
    }
    return this.zoomGridAt(scaleFactor, screenX, screenY);
  }

  zoomViewportIn() {
    return this.zoomViewport(1.15);
  }

  zoomViewportOut() {
    return this.zoomViewport(1 / 1.15);
  }

  getCachedHex(worldX, worldY) {
    return this.hexCache.get(`${worldX},${worldY}`) || null;
  }

  clearLocalPatchCache() {
    this.hexCache.clear();
    this.localPatchBounds = null;
    this.localPatchFocusBounds = null;
    this.localPatchComponentBounds = null;
    this.localPatchFullComponent = false;
    this.nativeSpatialIndex = null;
    this.nativeVoronoiBounds = null;
  }

  cacheLocalPatchHex(hexInfo) {
    const key = `${hexInfo.worldX},${hexInfo.worldY}`;
    this.hexCache.set(key, hexInfo);
    if (hexInfo.globe_hex_id != null) {
      this.hexCache.set(`ghid:${hexInfo.globe_hex_id}`, hexInfo);
    }
  }

  updateCachedHex(hexInfo) {
    if (!hexInfo) return;
    if (hexInfo.worldX != null && hexInfo.worldY != null) {
      this.hexCache.set(`${hexInfo.worldX},${hexInfo.worldY}`, hexInfo);
    }
    if (hexInfo.globe_hex_id != null) {
      this.hexCache.set(`ghid:${hexInfo.globe_hex_id}`, hexInfo);
    }
  }

  localPatchHexes() {
    const hexes = [];
    for (const [key, hexInfo] of this.hexCache) {
      if (this.isUnwrappedNativeMode) {
        if (!key.startsWith('ghid:')) continue;
      } else if (key.startsWith('ghid:')) {
        continue;
      }
      hexes.push(hexInfo);
    }
    return hexes;
  }

  localPatchGeoBounds(visibleOnly = false) {
    if (this.isUnwrappedNativeMode) {
      const visibleBounds = visibleOnly ? this.nativeProjectedViewBounds() : null;
      const padding = this.nativeSpacing * 1.5;
      let minLat = Infinity;
      let maxLat = -Infinity;
      let minLng = Infinity;
      let maxLng = -Infinity;
      let found = false;

      this.localPatchHexes().forEach((hexInfo) => {
        if (visibleBounds && hexInfo.projectedBBox) {
          if (hexInfo.projectedBBox.maxX < visibleBounds.minX - padding ||
              hexInfo.projectedBBox.minX > visibleBounds.maxX + padding ||
              hexInfo.projectedBBox.maxY < visibleBounds.minY - padding ||
              hexInfo.projectedBBox.minY > visibleBounds.maxY + padding) {
            return;
          }
        }

        if (hexInfo.lat == null || hexInfo.lng == null) return;

        found = true;
        minLat = Math.min(minLat, hexInfo.lat);
        maxLat = Math.max(maxLat, hexInfo.lat);
        minLng = Math.min(minLng, hexInfo.lng);
        maxLng = Math.max(maxLng, hexInfo.lng);
      });

      return found ? { minLat, maxLat, minLng, maxLng } : null;
    }

    const startCol = Math.floor(this.viewportX) - 1;
    const endCol = startCol + this.visibleCols + 2;
    const startRow = Math.floor(this.viewportY) - 1;
    const endRow = startRow + this.visibleRows + 2;

    let minLat = Infinity;
    let maxLat = -Infinity;
    let minLng = Infinity;
    let maxLng = -Infinity;
    let found = false;

    this.localPatchHexes().forEach((hexInfo) => {
      if (visibleOnly) {
        if (hexInfo.worldX < startCol || hexInfo.worldX > endCol ||
            hexInfo.worldY < startRow || hexInfo.worldY > endRow) {
          return;
        }
      }

      if (hexInfo.lat == null || hexInfo.lng == null) return;

      found = true;
      minLat = Math.min(minLat, hexInfo.lat);
      maxLat = Math.max(maxLat, hexInfo.lat);
      minLng = Math.min(minLng, hexInfo.lng);
      maxLng = Math.max(maxLng, hexInfo.lng);
    });

    if (!found) return null;

    return { minLat, maxLat, minLng, maxLng };
  }

  findNearestLocalPatchHexByWorld(worldX, worldY) {
    if (this.isUnwrappedNativeMode) {
      return this.findNearestProjectedNativeHexToPoint(worldX, worldY);
    }

    let nearest = null;
    let nearestDistSq = Infinity;

    this.localPatchHexes().forEach((hexInfo) => {
      const dx = hexInfo.worldX - worldX;
      const dy = hexInfo.worldY - worldY;
      const distSq = (dx * dx) + (dy * dy);
      if (distSq < nearestDistSq) {
        nearestDistSq = distSq;
        nearest = hexInfo;
      }
    });

    return nearest;
  }

  getLocalPatchBoundsCenterHex() {
    if (!this.localPatchBounds) return null;

    if (this.isUnwrappedNativeMode) {
      const focusBounds = this.localPatchFocusBounds || this.localPatchBounds;
      return this.findNearestProjectedNativeHexToPoint(
        (focusBounds.minX + focusBounds.maxX) / 2,
        (focusBounds.minY + focusBounds.maxY) / 2
      );
    }

    return this.findNearestLocalPatchHexByWorld(
      (this.localPatchBounds.minX + this.localPatchBounds.maxX) / 2,
      (this.localPatchBounds.minY + this.localPatchBounds.maxY) / 2
    );
  }

  centerViewportOnLocalHex(hexInfo) {
    if (!hexInfo) return false;

    if (this.isUnwrappedNativeMode) {
      this.nativeViewX = hexInfo.projectedX ?? this.nativeViewX;
      this.nativeViewY = hexInfo.projectedY ?? this.nativeViewY;
      return this.clampProjectedNativeView();
    }

    this.viewportX = hexInfo.worldX - this.visibleCols / 2;
    this.viewportY = hexInfo.worldY - this.visibleRows / 2;
    return this.clampViewportToLocalPatchBounds();
  }

  clampViewportToLocalPatchBounds(padding = 1) {
    if (this.isUnwrappedNativeMode) {
      return this.clampProjectedNativeView(Math.max(1, padding));
    }

    if (!this.localPatchBounds) return false;

    const bounds = this.localPatchBounds;
    let changed = false;

    const minViewportX = bounds.minX - padding;
    const maxViewportX = bounds.maxX + padding - this.visibleCols + 1;
    if (maxViewportX < minViewportX) {
      const centeredX = ((bounds.minX + bounds.maxX) / 2) - (this.visibleCols / 2);
      if (this.viewportX !== centeredX) {
        this.viewportX = centeredX;
        changed = true;
      }
    } else {
      const clampedX = Math.min(Math.max(this.viewportX, minViewportX), maxViewportX);
      if (clampedX !== this.viewportX) {
        this.viewportX = clampedX;
        changed = true;
      }
    }

    const minViewportY = bounds.minY - padding;
    const maxViewportY = bounds.maxY + padding - this.visibleRows + 1;
    if (maxViewportY < minViewportY) {
      const centeredY = ((bounds.minY + bounds.maxY) / 2) - (this.visibleRows / 2);
      if (this.viewportY !== centeredY) {
        this.viewportY = centeredY;
        changed = true;
      }
    } else {
      const clampedY = Math.min(Math.max(this.viewportY, minViewportY), maxViewportY);
      if (clampedY !== this.viewportY) {
        this.viewportY = clampedY;
        changed = true;
      }
    }

    return changed;
  }

  fitLocalPatchToViewport(padding = 2) {
    if (this.isUnwrappedNativeMode) {
      return this.fitProjectedNativeBounds(this.localPatchFocusBounds || this.localPatchBounds, padding);
    }

    if (!this.localPatchBounds || !this.container) return;

    const bounds = this.localPatchBounds;
    const cols = Math.max(1, (bounds.maxX - bounds.minX + 1) + (padding * 2));
    const rows = Math.max(1, (bounds.maxY - bounds.minY + 1) + (padding * 2));

    const radiusByWidth = this.container.clientWidth / Math.max(1, (cols * 1.5) + 0.5);
    const radiusByHeight = this.container.clientHeight / Math.max(1, (rows * Math.sqrt(3)) + 1);
    const targetRadius = Math.max(2, Math.min(80, Math.min(radiusByWidth, radiusByHeight)));

    if (Number.isFinite(targetRadius)) {
      this.hexRadius = targetRadius;
    }
  }

  syncNativeCenterFromViewport() {
    if (!this.isUnwrappedNativeMode) return;

    const centerHex = this.getCurrentPatchCenterHex()
      || this.findNearestLocalPatchHex(
        this.container.clientWidth / 2,
        this.container.clientHeight / 2,
        Infinity
      )
      || (this.localPatchCenterHexId != null ? this.hexCache.get(`ghid:${this.localPatchCenterHexId}`) : null);

    if (!centerHex) return;

    this.nativeCenterLat = centerHex.lat ?? this.nativeCenterLat;
    this.nativeCenterLng = centerHex.lng ?? this.nativeCenterLng;
  }

  findLocalPatchHexByLatLng(lat, lng) {
    let nearest = null;
    let nearestDist = Infinity;

    this.localPatchHexes().forEach((hexInfo) => {
      if (hexInfo.lat == null || hexInfo.lng == null) return;
      const dist = ((hexInfo.lat - lat) ** 2) + ((hexInfo.lng - lng) ** 2);
      if (dist < nearestDist) {
        nearestDist = dist;
        nearest = hexInfo;
      }
    });

    return nearest;
  }

  resolvePatchPoint(point) {
    if (!point) return null;

    if (typeof point.x === 'number' && typeof point.y === 'number' && this.hexCache.has(`${point.x},${point.y}`)) {
      return { x: point.x, y: point.y };
    }

    if (point.globe_hex_id != null) {
      const hexInfo = this.hexCache.get(`ghid:${point.globe_hex_id}`);
      if (hexInfo) {
        return { x: hexInfo.worldX, y: hexInfo.worldY };
      }
    }

    const lat = typeof point.lat === 'number'
      ? point.lat
      : (typeof point.y === 'number' && point.y >= -90 && point.y <= 90 ? point.y : null);
    const lng = typeof point.lng === 'number'
      ? point.lng
      : (typeof point.x === 'number' && point.x >= -180 && point.x <= 180 ? point.x : null);

    if (lat == null || lng == null) return null;

    const nearest = this.findLocalPatchHexByLatLng(lat, lng);
    if (!nearest) return null;

    return { x: nearest.worldX, y: nearest.worldY };
  }

  findNearestLocalPatchHex(screenX, screenY, maxDistance = this.hexRadius * 1.2) {
    if (this.isUnwrappedNativeMode) {
      return this.findProjectedNativeHexAt(screenX, screenY, maxDistance);
    }

    let nearest = null;
    let nearestDistSq = Number.isFinite(maxDistance) ? maxDistance * maxDistance : Infinity;

    this.localPatchHexes().forEach((hexInfo) => {
      const pos = this.localPatchScreenPos(hexInfo.worldX, hexInfo.worldY);
      const dx = pos.x - screenX;
      const dy = pos.y - screenY;
      const distSq = (dx * dx) + (dy * dy);
      if (distSq < nearestDistSq) {
        nearestDistSq = distSq;
        nearest = hexInfo;
      }
    });

    return nearest;
  }

  calculateNativePatchRings() {
    const visible = Math.max(this.visibleCols, this.visibleRows);
    return Math.max(12, Math.min(32, Math.ceil(visible * 0.9)));
  }

  getCurrentPatchCenterHex() {
    if (this.isUnwrappedNativeMode) {
      return this.findProjectedNativeHexAt(
        this.container.clientWidth / 2,
        this.container.clientHeight / 2,
        Infinity
      );
    }

    const centerWorld = this.pixelToHex(
      this.container.clientWidth / 2,
      this.container.clientHeight / 2
    );
    const key = `${centerWorld.col},${centerWorld.row}`;
    return this.hexCache.get(key) || null;
  }

  getNearestPatchHexToViewportCenter() {
    return this.findNearestLocalPatchHex(
      this.container.clientWidth / 2,
      this.container.clientHeight / 2,
      Infinity
    );
  }

  async recenterNativePatch(centerHex = null) {
    if (!this.isUnwrappedNativeMode || this.isLoading || !this.hasLoadedProjectedNativePatch) return;

    if (this.localPatchFullComponent && this.localPatchBounds) {
      const targetHex = centerHex
        || this.getLocalPatchBoundsCenterHex()
        || this.getCurrentPatchCenterHex()
        || this.getNearestPatchHexToViewportCenter()
        || (this.localPatchCenterHexId != null ? this.hexCache.get(`ghid:${this.localPatchCenterHexId}`) : null);

      if (!targetHex) return;

      if (centerHex) {
        this.centerViewportOnLocalHex(targetHex);
      } else {
        this.fitLocalPatchToViewport();
      }
      this.localPatchCenterHexId = targetHex.globe_hex_id ?? this.localPatchCenterHexId;
      this.syncNativeCenterFromViewport();
      this.render();
      return;
    }

    const targetHex = centerHex
      || this.getCurrentPatchCenterHex()
      || this.getNearestPatchHexToViewportCenter()
      || (this.localPatchCenterHexId != null ? this.hexCache.get(`ghid:${this.localPatchCenterHexId}`) : null);
    if (!targetHex || targetHex.globe_hex_id == null) return;

    this.pendingPatchCenterHexId = targetHex.globe_hex_id;
    this.localPatchCenterHexId = targetHex.globe_hex_id;
    this.viewportX = -this.visibleCols / 2;
    this.viewportY = -this.visibleRows / 2;
    await this.loadVisibleHexes();
  }

  maybeRecenterNativePatch() {
    if (!this.isUnwrappedNativeMode || !this.localPatchBounds) return;
    if (this.isLoading || this.needsReload) return;
    if (this.isDrawingZone || this.isDrawingFeature) return;

    if (this.localPatchFullComponent) {
      return;
    }

    const viewBounds = this.nativeProjectedViewBounds();
    const buffer = this.nativeSpacing * 6;
    const needsRecenter =
      viewBounds.minX <= this.localPatchBounds.minX + buffer ||
      viewBounds.maxX >= this.localPatchBounds.maxX - buffer ||
      viewBounds.minY <= this.localPatchBounds.minY + buffer ||
      viewBounds.maxY >= this.localPatchBounds.maxY - buffer;

    if (!needsRecenter) return;

    const centerHex = this.getCurrentPatchCenterHex();
    if (!centerHex || centerHex.globe_hex_id == null) return;
    if (centerHex.globe_hex_id === this.localPatchCenterHexId) return;

    this.recenterNativePatch(centerHex);
  }

  init() {
    // Clear container and create fresh Canvas + SVG overlay
    this.container.innerHTML = '';
    this.canvas = this.createCanvas();
    this.ctx = this.canvas.getContext('2d');
    this.svg = this.createSvg();
    this.bindEvents();
    console.log('HexEditor initialized');
  }

  createCanvas() {
    const canvas = document.createElement('canvas');
    canvas.id = 'hex-editor-canvas';
    canvas.style.width = '100%';
    canvas.style.height = '100%';
    canvas.style.position = 'absolute';
    canvas.style.top = '0';
    canvas.style.left = '0';
    canvas.style.background = '#111';
    this.container.appendChild(canvas);
    return canvas;
  }

  createSvg() {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.id = 'hex-editor-svg';
    svg.style.width = '100%';
    svg.style.height = '100%';
    svg.style.position = 'absolute';
    svg.style.top = '0';
    svg.style.left = '0';
    svg.style.cursor = 'crosshair';
    svg.style.display = 'block';
    this.container.appendChild(svg);
    return svg;
  }

  bindEvents() {
    // Pointer events for pan/click
    this.svg.addEventListener('pointerdown', (e) => this.handlePointerDown(e));
    this.svg.addEventListener('pointermove', (e) => this.handlePointerMove(e));
    this.svg.addEventListener('pointerup', (e) => this.handlePointerUp(e));
    this.svg.addEventListener('pointerleave', (e) => this.handlePointerUp(e));

    // Double-click for finishing zone polygon
    this.svg.addEventListener('dblclick', (e) => this.handleDoubleClick(e));

    // Wheel for zoom
    this.svg.addEventListener('wheel', (e) => this.handleWheel(e), { passive: false });

    // Context menu for right-click actions
    this.svg.addEventListener('contextmenu', (e) => this.handleContextMenu(e));

    // Keyboard shortcuts
    document.addEventListener('keydown', (e) => this.handleKeyDown(e));
    document.addEventListener('keyup', (e) => this.handleKeyUp(e));

    // Resize handling
    window.addEventListener('resize', () => this.handleResize());
  }

  handleDoubleClick(e) {
    // Double-click to finish zone polygon
    if (this.isDrawingZone && this.zonePoints.length >= 3) {
      e.preventDefault();
      this.finishZonePolygon();
    }
    // Double-click to finish feature line
    else if (this.isDrawingFeature && this.featurePoints.length >= 2) {
      e.preventDefault();
      this.finishFeatureLine();
    }
    // Double-click with any other state to open sub-hex editor
    else {
      const worldPos = this._pointerToWorld(e);
      if (worldPos.col == null || worldPos.row == null) return;
      e.preventDefault();
      this.openSubHexEditor(worldPos.col, worldPos.row);
    }
  }

  // Get the 6 hex neighbors for a given grid position (offset coordinates)
  getHexNeighbors(col, row) {
    const isOddCol = Math.abs(col % 2) === 1;
    if (isOddCol) {
      return [
        { x: col - 1, y: row },
        { x: col - 1, y: row + 1 },
        { x: col + 1, y: row },
        { x: col + 1, y: row + 1 },
        { x: col, y: row - 1 },
        { x: col, y: row + 1 }
      ];
    } else {
      return [
        { x: col - 1, y: row - 1 },
        { x: col - 1, y: row },
        { x: col + 1, y: row - 1 },
        { x: col + 1, y: row },
        { x: col, y: row - 1 },
        { x: col, y: row + 1 }
      ];
    }
  }

  // Trace a line of adjacent hexes from (fromX, fromY) to (toX, toY).
  // Uses greedy neighbor-stepping: at each hex, pick the neighbor closest to the target.
  // Returns array of {x, y} including both endpoints.
  traceHexLine(fromX, fromY, toX, toY) {
    const path = [{ x: fromX, y: fromY }];
    let cx = fromX, cy = fromY;
    const visited = new Set([`${cx},${cy}`]);

    for (let step = 0; step < 500; step++) {
      if (cx === toX && cy === toY) break;

      // Get pixel position of target for distance calculation
      const targetPos = this.hexToPixel(toX, toY);
      const neighbors = this.getHexNeighbors(cx, cy);

      // Pick unvisited neighbor closest to target
      let best = null, bestDist = Infinity;
      for (const n of neighbors) {
        const key = `${n.x},${n.y}`;
        if (visited.has(key)) continue;

        const nPos = this.hexToPixel(n.x, n.y);
        const dist = (nPos.x - targetPos.x) ** 2 + (nPos.y - targetPos.y) ** 2;
        if (dist < bestDist) {
          bestDist = dist;
          best = n;
        }
      }

      if (!best) break;
      visited.add(`${best.x},${best.y}`);
      path.push(best);
      cx = best.x;
      cy = best.y;
    }

    return path;
  }

  // Open the sub-hex editor for detailed editing within a hex
  openSubHexEditor(worldX, worldY) {
    // Look up identity fields from cache
    const key = `${worldX},${worldY}`;
    const hexInfo = this.hexCache.get(key) || {};
    const globe_hex_id = hexInfo.globe_hex_id;
    const lat = hexInfo.lat;
    const lng = hexInfo.lng;
    const terrain = hexInfo.terrain || 'unknown';

    // Collect neighbor terrain data from cache
    const neighborCoords = this.getHexNeighbors(worldX, worldY);
    const neighbors = neighborCoords.map(n => {
      const nKey = `${n.x},${n.y}`;
      const nInfo = this.hexCache.get(nKey) || {};
      return { x: n.x, y: n.y, terrain: nInfo.terrain || 'ocean' };
    });

    console.log('Opening sub-hex editor for hex:', worldX, worldY, 'terrain:', terrain, 'globe_hex_id:', globe_hex_id);

    // Create sub-hex container if it doesn't exist
    let subHexContainer = document.getElementById('sub-hex-container');
    if (!subHexContainer) {
      subHexContainer = document.createElement('div');
      subHexContainer.id = 'sub-hex-container';
      subHexContainer.style.cssText = 'display: none; position: absolute; top: 0; left: 0; width: 100%; height: 100%; z-index: 100;';
      this.container.parentElement.appendChild(subHexContainer);
    }

    // Hide main hex editor
    this.container.style.display = 'none';

    // Show and initialize sub-hex editor
    subHexContainer.style.display = 'block';

    if (window.SubHexEditor) {
      window.subHexEditor = new SubHexEditor('sub-hex-container', {
        hexCoords: { globe_hex_id, lat, lng, x: worldX, y: worldY },
        worldId: this.worldId,
        terrain: terrain,
        neighbors: neighbors,
        terrainColors: this.terrainColors,
        onClose: () => {
          subHexContainer.style.display = 'none';
          this.container.style.display = 'block';
          this.render();
        }
      });
      window.subHexEditor.show();
    } else {
      console.warn('SubHexEditor not loaded');
      subHexContainer.style.display = 'none';
      this.container.style.display = 'block';
    }
  }

  openSubHexEditorForHex(hexInfo) {
    if (!hexInfo) return;

    let neighbors = [];

    // When using Voronoi renderer, look up neighbors from cached hex data
    if (this.nativeHexRenderer && this.nativeHexRenderer.isActive()) {
      const cached = this.nativeHexRenderer.hexCache[hexInfo.globe_hex_id];
      const nbrIds = cached?.data?.neighbor_ids;
      if (nbrIds && nbrIds.length > 0) {
        neighbors = nbrIds.map((nid, index) => {
          const nCached = this.nativeHexRenderer.hexCache[nid];
          return {
            x: index,
            y: 0,
            terrain: nCached?.data?.terrain_type || 'ocean'
          };
        });
      }
    } else {
      neighbors = this.localPatchHexes()
        .filter((candidate) => candidate.globe_hex_id !== hexInfo.globe_hex_id)
        .map((candidate) => ({
          hex: candidate,
          distSq: ((candidate.projectedX - hexInfo.projectedX) ** 2) + ((candidate.projectedY - hexInfo.projectedY) ** 2)
        }))
        .sort((a, b) => a.distSq - b.distSq)
        .slice(0, 6)
        .map(({ hex }, index) => ({
          x: hex.worldX ?? index,
          y: hex.worldY ?? index,
          terrain: hex.terrain || 'ocean'
        }));
    }

    let subHexContainer = document.getElementById('sub-hex-container');
    if (!subHexContainer) {
      subHexContainer = document.createElement('div');
      subHexContainer.id = 'sub-hex-container';
      subHexContainer.style.cssText = 'display: none; position: absolute; top: 0; left: 0; width: 100%; height: 100%; z-index: 100;';
      this.container.parentElement.appendChild(subHexContainer);
    }

    this.container.style.display = 'none';
    subHexContainer.style.display = 'block';

    if (window.SubHexEditor) {
      window.subHexEditor = new SubHexEditor('sub-hex-container', {
        hexCoords: {
          globe_hex_id: hexInfo.globe_hex_id,
          lat: hexInfo.lat,
          lng: hexInfo.lng,
          x: hexInfo.worldX ?? null,
          y: hexInfo.worldY ?? null
        },
        worldId: this.worldId,
        terrain: hexInfo.terrain || 'unknown',
        neighbors,
        terrainColors: this.terrainColors,
        onClose: () => {
          subHexContainer.style.display = 'none';
          this.container.style.display = 'block';
          this.render();
        }
      });
      window.subHexEditor.show();
    } else {
      console.warn('SubHexEditor not loaded');
      subHexContainer.style.display = 'none';
      this.container.style.display = 'block';
    }
  }

  loadProjectedNativePatch(data, options = {}) {
    const patchBounds = data.projected_bounds ? {
      minX: data.projected_bounds.min_x ?? 0,
      maxX: data.projected_bounds.max_x ?? 0,
      minY: data.projected_bounds.min_y ?? 0,
      maxY: data.projected_bounds.max_y ?? 0
    } : null;
    const focusBounds = data.focus_bounds ? {
      minX: data.focus_bounds.min_x ?? 0,
      maxX: data.focus_bounds.max_x ?? 0,
      minY: data.focus_bounds.min_y ?? 0,
      maxY: data.focus_bounds.max_y ?? 0
    } : patchBounds;

    this.clearLocalPatchCache();
    this.localPatchCenterHexId = data.center_globe_hex_id || options.centerGlobeHexId || null;
    this.localPatchBounds = patchBounds;
    this.localPatchFocusBounds = focusBounds;
    this.localPatchComponentBounds = data.component_bounds ? {
      minX: data.component_bounds.min_x ?? 0,
      maxX: data.component_bounds.max_x ?? 0,
      minY: data.component_bounds.min_y ?? 0,
      maxY: data.component_bounds.max_y ?? 0
    } : patchBounds;
    this.localPatchFullComponent = data.full_component === true || options.fullComponent === true;
    this.localPatchRings = data.rings || options.patchRings || this.localPatchRings;
    this.nativeProjectionCenterLat = data.center_lat ?? this.nativeCenterLat;
    this.nativeProjectionCenterLng = data.center_lng ?? this.nativeCenterLng;
    this.nativeCenterLat = this.nativeProjectionCenterLat;
    this.nativeCenterLng = this.nativeProjectionCenterLng;

    (data.hexes || []).forEach((hex) => {
      this.updateCachedHex({
        ...hex,
        worldX: hex.x,
        worldY: hex.y,
        projectedX: hex.projected_x ?? 0,
        projectedY: hex.projected_y ?? 0
      });
    });

    this.buildProjectedNativeGeometry();

    const targetHex = this.localPatchCenterHexId != null
      ? this.hexCache.get(`ghid:${this.localPatchCenterHexId}`)
      : this.getLocalPatchBoundsCenterHex();

    if (options.recenterViewport !== false) {
      if (this.localPatchFullComponent) {
        this.fitLocalPatchToViewport();
      } else if (targetHex) {
        this.nativeViewX = targetHex.projectedX ?? this.nativeViewX;
        this.nativeViewY = targetHex.projectedY ?? this.nativeViewY;
      }
    } else if (!Number.isFinite(this.nativeViewX) || !Number.isFinite(this.nativeViewY)) {
      this.nativeViewX = targetHex?.projectedX ?? 0;
      this.nativeViewY = targetHex?.projectedY ?? 0;
    }

    this.clampProjectedNativeView();
    this.syncNativeCenterFromViewport();

    console.log('HexEditor: Projected native patch loaded', this.localPatchHexes().length, 'hexes');
    this.render();
  }

  // Load region data for the current origin
  loadRegion(origin, hexData, options = {}) {
    // Store origin for backwards compatibility
    this.regionOrigin = {
      face: origin?.face || 0,
      x: origin?.x || 0,
      y: origin?.y || 0
    };

    // Check if this is a globe world (from options or auto-detect)
    this.isGlobeWorld = options.isGlobeWorld || false;

    if (this.isUnwrappedNativeMode && Array.isArray(hexData) && hexData.every(hex => hex.x != null && hex.y != null)) {
      this.clearLocalPatchCache();
      this.localPatchCenterHexId = options.centerGlobeHexId || this.localPatchCenterHexId;
      this.localPatchBounds = options.patchBounds || null;
      this.localPatchComponentBounds = options.componentBounds || this.localPatchBounds;
      this.localPatchFullComponent = options.fullComponent === true;
      this.localPatchRings = options.patchRings || this.localPatchRings;

      // Native mode uses a local unwrap patch keyed by local grid coordinates.
      hexData.forEach(hex => {
        this.cacheLocalPatchHex({
          ...hex,
          worldX: hex.x,
          worldY: hex.y
        });
      });

      if (options.recenterViewport !== false) {
        if (this.localPatchFullComponent) {
          this.fitLocalPatchToViewport();
          const targetHex = this.getLocalPatchBoundsCenterHex()
            || (this.localPatchCenterHexId != null ? this.hexCache.get(`ghid:${this.localPatchCenterHexId}`) : null);
          if (targetHex) {
            this.centerViewportOnLocalHex(targetHex);
          } else {
            this.viewportX = -this.visibleCols / 2;
            this.viewportY = -this.visibleRows / 2;
          }
        } else {
          this.viewportX = -this.visibleCols / 2;
          this.viewportY = -this.visibleRows / 2;
        }
      }

      const centerHex = this.localPatchCenterHexId != null
        ? this.hexCache.get(`ghid:${this.localPatchCenterHexId}`)
        : null;
      if (centerHex) {
        this.nativeCenterLat = centerHex.lat ?? this.nativeCenterLat;
        this.nativeCenterLng = centerHex.lng ?? this.nativeCenterLng;
      }
      this.clampViewportToLocalPatchBounds();
      this.syncNativeCenterFromViewport();

      console.log('HexEditor: Native unwrap loaded', hexData.length, 'hexes');
      this.render();
      return;
    }

    // Set viewport to region origin, or to a sensible default for globe worlds
    if (this.isGlobeWorld && origin?.x === 0 && origin?.y === 0) {
      // Default to Atlantic/Europe view for globe worlds
      // x=150 is around lng=-30 (Atlantic), y=45 is around lat=45 (Europe)
      this.viewportX = 150;
      this.viewportY = 45;
    } else {
      this.viewportX = this.regionOrigin.x;
      this.viewportY = this.regionOrigin.y;
    }

    // Cache the hex data
    if (Array.isArray(hexData)) {
      hexData.forEach((hex, i) => {
        const col = hex.x !== undefined ? hex.x : (i % 6);
        const row = hex.y !== undefined ? hex.y : Math.floor(i / 6);
        const worldX = this.regionOrigin.x + col;
        const worldY = this.regionOrigin.y + row;
        this.hexCache.set(`${worldX},${worldY}`, {
          ...hex,
          worldX,
          worldY,
          globe_hex_id: hex.globe_hex_id,
          lat: hex.lat,
          lng: hex.lng
        });
      });
    }

    console.log('HexEditor: Loaded region', this.regionOrigin, 'with', this.hexCache.size, 'cached hexes');
    this.render();
  }

  // Load visible hexes from API.
  // Uses a "reload-when-done" pattern: if a request is in-flight and the
  // viewport moves, we mark needsReload so the final position always loads.
  async loadVisibleHexes() {
    if (this.isLoading) {
      this.needsReload = true;
      return;
    }
    this.isLoading = true;
    this.needsReload = false;
    this.notifyLoadingState();

    const minX = Math.floor(this.viewportX);
    const minY = Math.floor(this.viewportY);

    try {
      const apiBase = window.API_BASE || `/admin/world_builder/${this.worldId}/api`;

      if (this.isUnwrappedNativeMode) {
        const rings = this.calculateNativePatchRings();
        this.localPatchRings = rings;

        const params = new URLSearchParams({ rings: rings.toString(), full_component: '1' });
        if (this.pendingPatchCenterHexId || this.localPatchCenterHexId) {
          params.set('center_globe_hex_id', String(this.pendingPatchCenterHexId || this.localPatchCenterHexId));
        } else {
          params.set('lat', String(this.nativeCenterLat));
          params.set('lng', String(this.nativeCenterLng));
        }

        const resp = await fetch(`${apiBase}/local_hex_patch?${params}`);
        if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
        const data = await resp.json();

        if (data.hexes) {
          const recenterViewport = this.pendingPatchCenterHexId != null || this.localPatchBounds == null;
          this.pendingPatchCenterHexId = null;
          this.loadProjectedNativePatch(data, {
            centerGlobeHexId: data.center_globe_hex_id,
            patchRings: data.rings,
            fullComponent: data.full_component === true,
            recenterViewport
          });
        }
      } else {
        const requestSize = Math.max(this.visibleCols, this.visibleRows);
        const params = new URLSearchParams({
          face: this.regionOrigin?.face || 0,
          x: minX,
          y: minY,
          size: requestSize,
          cell_size: this.cellSize  // 'native' or a number
        });

        const resp = await fetch(`${apiBase}/globe_region?${params}`);
        if (!resp.ok) throw new Error(`HTTP ${resp.status}`);

        const data = await resp.json();

        // Track if this is a globe world for coordinate handling
        if (data.is_globe_world !== undefined) {
          this.isGlobeWorld = data.is_globe_world;
        }

        if (data.hexes) {
          data.hexes.forEach(hex => {
            // For globe worlds, compute absolute grid position from relative x,y
            const absX = minX + (hex.x || 0);
            const absY = minY + (hex.y || 0);
            const key = `${absX},${absY}`;
            if (!this.hexCache.has(key) || !this.dirtyHexes.has(key)) {
              this.hexCache.set(key, {
                ...hex,
                worldX: absX,
                worldY: absY,
                globe_hex_id: hex.globe_hex_id,
                lat: hex.lat,
                lng: hex.lng
              });
            }
          });
        }
      }
    } catch (error) {
      console.error('Failed to load hexes:', error);
    } finally {
      this.isLoading = false;
      this.notifyLoadingState();
      this.render();
      // If viewport moved while loading, load the new position
      if (this.needsReload) {
        this.needsReload = false;
        this.loadVisibleHexes();
      }
    }
  }

  renderProjectedNativeScene(width, height) {
    this.clampProjectedNativeView();

    const ctx = this.ctx;
    ctx.fillStyle = this.terrainColors.ocean || '#2d5f8a';
    ctx.fillRect(0, 0, width, height);

    const showLabels = this.hexRadius >= 12;
    const viewBounds = this.nativeProjectedViewBounds();
    const margin = this.nativeSpacing * 2;
    const hexes = this.localPatchHexes();

    hexes.forEach((hexInfo) => {
      if (hexInfo.projectedX < viewBounds.minX - margin ||
          hexInfo.projectedX > viewBounds.maxX + margin ||
          hexInfo.projectedY < viewBounds.minY - margin ||
          hexInfo.projectedY > viewBounds.maxY + margin) {
        return;
      }

      if (!this.ensureProjectedNativePolygon(hexInfo)) return;
      if (hexInfo.projectedBBox.maxX < viewBounds.minX - margin ||
          hexInfo.projectedBBox.minX > viewBounds.maxX + margin ||
          hexInfo.projectedBBox.maxY < viewBounds.minY - margin ||
          hexInfo.projectedBBox.minY > viewBounds.maxY + margin) {
        return;
      }

      const screenPoints = hexInfo.projectedPath.map((point) =>
        this.projectedNativeScreenPos(point.x, point.y)
      );
      if (screenPoints.length < 3) return;

      const center = this.projectedNativeScreenPos(hexInfo.projectedX, hexInfo.projectedY);
      const cacheKey = hexInfo.worldX != null && hexInfo.worldY != null
        ? `${hexInfo.worldX},${hexInfo.worldY}`
        : `ghid:${hexInfo.globe_hex_id}`;
      const isDirty = this.dirtyHexes.has(cacheKey);
      const isNonTraversable = hexInfo.traversable === false;
      const isWaterTerrain = hexInfo.terrain === 'ocean' || hexInfo.terrain === 'lake';
      const highlightNonTraversable = isNonTraversable && (!isWaterTerrain || this.hexRadius >= 5);

      ctx.beginPath();
      ctx.moveTo(screenPoints[0].x, screenPoints[0].y);
      for (let i = 1; i < screenPoints.length; i++) {
        ctx.lineTo(screenPoints[i].x, screenPoints[i].y);
      }
      ctx.closePath();
      ctx.fillStyle = this.terrainColors[hexInfo.terrain] || this.terrainColors.unknown;
      ctx.fill();

      if (isDirty) {
        ctx.strokeStyle = '#ff0';
        ctx.lineWidth = 2;
      } else if (highlightNonTraversable) {
        ctx.strokeStyle = '#dc3545';
        ctx.lineWidth = 2;
      } else {
        ctx.strokeStyle = 'rgba(255,255,255,0.16)';
        ctx.lineWidth = 0.6;
      }
      ctx.stroke();

      if (highlightNonTraversable) {
        ctx.save();
        ctx.beginPath();
        ctx.moveTo(screenPoints[0].x, screenPoints[0].y);
        for (let i = 1; i < screenPoints.length; i++) {
          ctx.lineTo(screenPoints[i].x, screenPoints[i].y);
        }
        ctx.closePath();
        ctx.clip();
        ctx.strokeStyle = 'rgba(220, 53, 69, 0.3)';
        ctx.lineWidth = 2;
        for (let stripe = -this.hexRadius * 2; stripe < this.hexRadius * 2; stripe += 6) {
          ctx.beginPath();
          ctx.moveTo(center.x + stripe, center.y - this.hexRadius);
          ctx.lineTo(center.x + stripe + (this.hexRadius * 2), center.y + this.hexRadius);
          ctx.stroke();
        }
        ctx.restore();
      }

      if (showLabels && hexInfo.lat != null && hexInfo.lng != null) {
        ctx.fillStyle = 'rgba(255,255,255,0.45)';
        ctx.font = '8px sans-serif';
        ctx.textAlign = 'center';
        ctx.fillText(`${parseFloat(hexInfo.lat).toFixed(2)}°`, center.x, center.y - 1);
        ctx.fillText(`${parseFloat(hexInfo.lng).toFixed(2)}°`, center.x, center.y + 9);
      }
    });

    const defs = document.createElementNS('http://www.w3.org/2000/svg', 'defs');
    const pattern = document.createElementNS('http://www.w3.org/2000/svg', 'pattern');
    pattern.setAttribute('id', 'non-traversable-pattern');
    pattern.setAttribute('patternUnits', 'userSpaceOnUse');
    pattern.setAttribute('width', '8');
    pattern.setAttribute('height', '8');
    pattern.setAttribute('patternTransform', 'rotate(45)');
    const patternLine = document.createElementNS('http://www.w3.org/2000/svg', 'line');
    patternLine.setAttribute('x1', '0');
    patternLine.setAttribute('y1', '0');
    patternLine.setAttribute('x2', '0');
    patternLine.setAttribute('y2', '8');
    patternLine.setAttribute('stroke', 'rgba(220, 53, 69, 0.3)');
    patternLine.setAttribute('stroke-width', '4');
    pattern.appendChild(patternLine);
    defs.appendChild(pattern);
    this.svg.appendChild(defs);

    this.renderFeatures();
    this.renderZones();
    this.renderCities();
    this.renderZonePreview();

    if (this.minimap) {
      const mmBounds = this.localPatchGeoBounds(true) || this.localPatchGeoBounds();
      if (mmBounds) {
        this.minimap.setViewport(
          mmBounds.minLng + 180,
          90 - mmBounds.maxLat,
          mmBounds.maxLng - mmBounds.minLng,
          mmBounds.maxLat - mmBounds.minLat
        );
      }
    }

    this.onViewportChange({
      x: this.nativeCenterLng,
      y: this.nativeCenterLat,
      cols: 0,
      rows: 0
    });
  }

  render() {
    if (!this.canvas || !this.svg) return;

    if (this.isUnwrappedNativeMode) {
      this.clampViewportToLocalPatchBounds();
    }

    const width = this.container.clientWidth;
    const height = this.container.clientHeight;

    // Size canvas to match container (at device pixel ratio for sharpness)
    const dpr = window.devicePixelRatio || 1;
    this.canvas.width = width * dpr;
    this.canvas.height = height * dpr;
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

    // Clear canvas
    this.ctx.fillStyle = '#111';
    this.ctx.fillRect(0, 0, width, height);

    // Set SVG viewBox for overlay layers
    this.svg.setAttribute('viewBox', `0 0 ${width} ${height}`);
    this.svg.innerHTML = '';

    if (this.isUnwrappedNativeMode) {
      // Use Three.js hex renderer if available (replaces broken gnomonic projection)
      if (this.nativeHexRenderer && this.nativeHexRenderer.isActive()) {
        // Three.js handles its own rendering — hide canvas
        this.canvas.style.display = 'none';
        this.svg.style.display = 'none';
        return;
      }
      this.renderProjectedNativeScene(width, height);
      return;
    }
    // Ensure canvas is visible when not in native 3D mode
    this.canvas.style.display = '';
    this.svg.style.display = '';

    // Calculate which hexes to render
    const startCol = Math.floor(this.viewportX);
    const startRow = Math.floor(this.viewportY);
    const endCol = startCol + this.visibleCols;
    const endRow = startRow + this.visibleRows;

    // Fractional offset for smooth scrolling
    const offsetX = (this.viewportX - startCol) * this.horizSpacing;
    const offsetY = (this.viewportY - startRow) * this.vertSpacing;

    const r = this.hexRadius;
    const showLabels = r >= 12;

    // Precompute hex point offsets (flat-top hexagon)
    const hexOffsets = [];
    for (let i = 0; i < 6; i++) {
      const angle = Math.PI / 180 * (60 * i);
      hexOffsets.push({ dx: r * Math.cos(angle), dy: r * Math.sin(angle) });
    }

    // === Native mode: render hexes at actual lat/lng positions ===
    if (this.isNativeMode && !this.isUnwrappedNativeMode) {
      const showLabels = r >= 12;

      for (const [key, hexInfo] of this.hexCache) {
        if (!key.startsWith('ghid:')) continue;

        // Gnomonic projection to screen pixels
        const pos = this.gnomonicForward(hexInfo.lat, hexInfo.lng);
        if (!pos) continue;
        const x = pos.x;
        const y = pos.y;

        // Cull off-screen hexes
        if (x < -this.hexWidth || x > width + this.hexWidth ||
            y < -this.hexHeight || y > height + this.hexHeight) continue;

        // Draw filled hex
        const ctx = this.ctx;
        ctx.beginPath();
        ctx.moveTo(x + hexOffsets[0].dx, y + hexOffsets[0].dy);
        for (let i = 1; i < 6; i++) {
          ctx.lineTo(x + hexOffsets[i].dx, y + hexOffsets[i].dy);
        }
        ctx.closePath();
        ctx.fillStyle = this.terrainColors[hexInfo.terrain] || this.terrainColors.unknown;
        ctx.fill();

        // Border
        const isDirty = this.dirtyHexes.has(key);
        const isNonTraversable = hexInfo.traversable === false;
        if (isDirty) {
          ctx.strokeStyle = '#ff0';
          ctx.lineWidth = 2;
        } else if (isNonTraversable) {
          ctx.strokeStyle = '#dc3545';
          ctx.lineWidth = 2;
        } else {
          ctx.strokeStyle = 'rgba(255,255,255,0.12)';
          ctx.lineWidth = 0.5;
        }
        ctx.stroke();

        // Non-traversable diagonal stripes (must re-create path for clipping)
        if (isNonTraversable) {
          ctx.save();
          ctx.beginPath();
          ctx.moveTo(x + hexOffsets[0].dx, y + hexOffsets[0].dy);
          for (let i = 1; i < 6; i++) {
            ctx.lineTo(x + hexOffsets[i].dx, y + hexOffsets[i].dy);
          }
          ctx.closePath();
          ctx.clip();
          ctx.strokeStyle = 'rgba(220, 53, 69, 0.3)';
          ctx.lineWidth = 2;
          for (let s = -r * 2; s < r * 2; s += 6) {
            ctx.beginPath();
            ctx.moveTo(x + s, y - r);
            ctx.lineTo(x + s + r * 2, y + r);
            ctx.stroke();
          }
          ctx.restore();
        }

        // Labels
        if (showLabels && hexInfo.lat != null && hexInfo.lng != null) {
          ctx.fillStyle = 'rgba(255,255,255,0.4)';
          ctx.font = '8px sans-serif';
          ctx.textAlign = 'center';
          ctx.fillText(`${parseFloat(hexInfo.lat).toFixed(2)}°`, x, y - 1);
          ctx.fillText(`${parseFloat(hexInfo.lng).toFixed(2)}°`, x, y + 9);
        }
      }
    } else {
      // === Grid mode render loop (existing code) ===
      for (let row = startRow; row < endRow; row++) {
        for (let col = startCol; col < endCol; col++) {
          const key = `${col},${row}`;
          let hexInfo = this.hexCache.get(key);

          if (!hexInfo) {
            if (this.isUnwrappedNativeMode) continue;
            hexInfo = { terrain: 'unknown' };
          }

          const relCol = col - startCol;
          const relRow = row - startRow;
          const screenPos = this.hexToPixel(relCol, relRow);
          const x = screenPos.x - offsetX;
          const y = screenPos.y - offsetY;

          if (x < -this.hexWidth || x > width + this.hexWidth ||
              y < -this.hexHeight || y > height + this.hexHeight) {
            continue;
          }

          // Draw filled hex
          const ctx = this.ctx;
          ctx.beginPath();
          ctx.moveTo(x + hexOffsets[0].dx, y + hexOffsets[0].dy);
          for (let i = 1; i < 6; i++) {
            ctx.lineTo(x + hexOffsets[i].dx, y + hexOffsets[i].dy);
          }
          ctx.closePath();
          ctx.fillStyle = this.terrainColors[hexInfo.terrain] || this.terrainColors.unknown;
          ctx.fill();

          // Thin border
          const isDirty = this.dirtyHexes.has(key);
          const isNonTraversable = hexInfo.traversable === false;
          if (isDirty) {
            ctx.strokeStyle = '#ff0';
            ctx.lineWidth = 2;
          } else if (isNonTraversable) {
            ctx.strokeStyle = '#dc3545';
            ctx.lineWidth = 2;
          } else {
            ctx.strokeStyle = 'rgba(255,255,255,0.12)';
            ctx.lineWidth = 0.5;
          }
          ctx.stroke();

          if (isNonTraversable) {
            ctx.save();
            ctx.beginPath();
            ctx.moveTo(x + hexOffsets[0].dx, y + hexOffsets[0].dy);
            for (let i = 1; i < 6; i++) {
              ctx.lineTo(x + hexOffsets[i].dx, y + hexOffsets[i].dy);
            }
            ctx.closePath();
            ctx.clip();
            ctx.strokeStyle = 'rgba(220, 53, 69, 0.3)';
            ctx.lineWidth = 2;
            for (let s = -r * 2; s < r * 2; s += 6) {
              ctx.beginPath();
              ctx.moveTo(x + s, y - r);
              ctx.lineTo(x + s + r * 2, y + r);
              ctx.stroke();
            }
            ctx.restore();
          }

          // Labels (only when hexes are large enough)
          if (showLabels) {
            ctx.fillStyle = 'rgba(255,255,255,0.4)';
            ctx.font = '8px sans-serif';
            ctx.textAlign = 'center';
            if (this.isGlobeWorld && hexInfo.lat != null && hexInfo.lng != null) {
              const lat = parseFloat(hexInfo.lat).toFixed(2);
              const lng = parseFloat(hexInfo.lng).toFixed(2);
              ctx.fillText(`${lat}°`, x, y - 1);
              ctx.fillText(`${lng}°`, x, y + 9);
            } else {
              ctx.fillText(`${col},${row}`, x, y + 4);
            }
          }
        }
      }
    }

    // SVG overlay for interactive elements (features, zones, cities)
    // Add defs for patterns
    const defs = document.createElementNS('http://www.w3.org/2000/svg', 'defs');
    const pattern = document.createElementNS('http://www.w3.org/2000/svg', 'pattern');
    pattern.setAttribute('id', 'non-traversable-pattern');
    pattern.setAttribute('patternUnits', 'userSpaceOnUse');
    pattern.setAttribute('width', '8');
    pattern.setAttribute('height', '8');
    pattern.setAttribute('patternTransform', 'rotate(45)');
    const patternLine = document.createElementNS('http://www.w3.org/2000/svg', 'line');
    patternLine.setAttribute('x1', '0');
    patternLine.setAttribute('y1', '0');
    patternLine.setAttribute('x2', '0');
    patternLine.setAttribute('y2', '8');
    patternLine.setAttribute('stroke', 'rgba(220, 53, 69, 0.3)');
    patternLine.setAttribute('stroke-width', '4');
    pattern.appendChild(patternLine);
    defs.appendChild(pattern);
    this.svg.appendChild(defs);

    // Features layer (roads, rivers, etc.)
    this.renderFeatures();

    // Zones layer (colored overlays)
    this.renderZones();

    // Cities layer
    this.renderCities();

    // Zone preview layer (when drawing a zone)
    this.renderZonePreview();

    // Update minimap viewport — convert grid coords back to 1° units for the minimap
    if (this.minimap) {
      if (this.isUnwrappedNativeMode) {
        const mmBounds = this.localPatchGeoBounds(true) || this.localPatchGeoBounds();
        if (mmBounds) {
          this.minimap.setViewport(
            mmBounds.minLng + 180,
            90 - mmBounds.maxLat,
            mmBounds.maxLng - mmBounds.minLng,
            mmBounds.maxLat - mmBounds.minLat
          );
        }
      } else if (this.isNativeMode) {
        const mmBounds = this.nativeViewportBounds();
        this.minimap.setViewport(
          mmBounds.minLng + 180,
          90 - mmBounds.maxLat,
          mmBounds.maxLng - mmBounds.minLng,
          mmBounds.maxLat - mmBounds.minLat
        );
      } else {
        const cs = this.effectiveCellSize;
        this.minimap.setViewport(
          this.viewportX * cs,
          this.viewportY * cs,
          this.visibleCols * cs,
          this.visibleRows * cs
        );
      }
    }

    // Notify viewport change
    this.onViewportChange({
      x: this.viewportX,
      y: this.viewportY,
      cols: this.visibleCols,
      rows: this.visibleRows
    });
  }

  hexToPixel(col, row) {
    const startX = this.hexRadius;
    const startY = this.hexHeight / 2;

    // Use world column parity for hex offset, not relative column.
    // This keeps hexes stable when viewport shifts by odd columns (zoom/pan).
    const worldCol = col + Math.floor(this.viewportX);

    const x = startX + col * this.horizSpacing;
    const y = startY + row * this.vertSpacing + ((worldCol & 1) ? this.hexHeight / 2 : 0);

    return { x, y };
  }

  pixelToHex(screenX, screenY) {
    // Convert screen pixel to world hex coordinates
    const offsetX = (this.viewportX - Math.floor(this.viewportX)) * this.horizSpacing;
    const offsetY = (this.viewportY - Math.floor(this.viewportY)) * this.vertSpacing;

    const adjustedX = screenX + offsetX - this.hexRadius;
    const adjustedY = screenY + offsetY - this.hexHeight / 2;

    // Approximate column
    let col = Math.round(adjustedX / this.horizSpacing);
    col += Math.floor(this.viewportX);

    // Adjust Y for column offset
    let yOffset = (col % 2 === 1) ? this.hexHeight / 2 : 0;
    let row = Math.round((adjustedY - yOffset) / this.vertSpacing);
    row += Math.floor(this.viewportY);

    return { col, row };
  }

  getEdgePosFromCenter(cx, cy, direction) {
    const r = this.hexRadius;
    const h = this.hexHeight / 2;
    const offsets = {
      n:  { x: 0, y: -h },
      s:  { x: 0, y: h },
      ne: { x: r * 0.75, y: -h * 0.25 },
      nw: { x: -r * 0.75, y: -h * 0.25 },
      se: { x: r * 0.75, y: h * 0.25 },
      sw: { x: -r * 0.75, y: h * 0.25 }
    };
    const o = offsets[direction] || { x: 0, y: 0 };
    return { x: cx + o.x, y: cy + o.y };
  }

  createHexElement(cx, cy, hexInfo, worldCol, worldRow) {
    const group = document.createElementNS('http://www.w3.org/2000/svg', 'g');
    group.setAttribute('data-world-x', worldCol);
    group.setAttribute('data-world-y', worldRow);
    if (hexInfo.globe_hex_id != null) group.setAttribute('data-globe-hex-id', hexInfo.globe_hex_id);
    if (hexInfo.lat != null) group.setAttribute('data-lat', hexInfo.lat);
    if (hexInfo.lng != null) group.setAttribute('data-lng', hexInfo.lng);
    group.classList.add('editor-hex');

    // Check if this hex is dirty
    const isDirty = this.dirtyHexes.has(`${worldCol},${worldRow}`);
    const isNonTraversable = hexInfo.traversable === false;

    // Hex polygon - flat-top orientation (no angle offset)
    const points = this.hexPoints(cx, cy, this.hexRadius);
    const polygon = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
    polygon.setAttribute('points', points.map(p => `${p.x},${p.y}`).join(' '));
    polygon.setAttribute('fill', this.terrainColors[hexInfo.terrain] || this.terrainColors.unknown);

    // Stroke color: yellow for dirty, red for non-traversable, default otherwise
    let strokeColor = 'rgba(255,255,255,0.15)';
    let strokeWidth = '1';
    if (isDirty) {
      strokeColor = '#ff0';
      strokeWidth = '2';
    } else if (isNonTraversable) {
      strokeColor = '#dc3545';
      strokeWidth = '2';
    }
    polygon.setAttribute('stroke', strokeColor);
    polygon.setAttribute('stroke-width', strokeWidth);
    group.appendChild(polygon);

    // Add diagonal stripes overlay for non-traversable hexes
    if (isNonTraversable) {
      const stripes = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
      stripes.setAttribute('points', points.map(p => `${p.x},${p.y}`).join(' '));
      stripes.setAttribute('fill', 'url(#non-traversable-pattern)');
      stripes.setAttribute('pointer-events', 'none');
      group.appendChild(stripes);
    }

    // Coordinate label — hide when hexes are too small to read
    if (this.hexRadius < 12) return group;

    const label = document.createElementNS('http://www.w3.org/2000/svg', 'text');
    label.setAttribute('x', cx);
    label.setAttribute('text-anchor', 'middle');
    label.setAttribute('fill', 'rgba(255,255,255,0.4)');
    label.setAttribute('font-size', '8');
    label.setAttribute('pointer-events', 'none');
    if (this.isGlobeWorld && hexInfo.lat != null && hexInfo.lng != null) {
      const lat = parseFloat(hexInfo.lat);
      const lng = parseFloat(hexInfo.lng);
      label.setAttribute('y', cy);
      const line1 = document.createElementNS('http://www.w3.org/2000/svg', 'tspan');
      line1.setAttribute('x', cx);
      line1.setAttribute('dy', '0');
      line1.textContent = `${lat.toFixed(2)}°`;
      const line2 = document.createElementNS('http://www.w3.org/2000/svg', 'tspan');
      line2.setAttribute('x', cx);
      line2.setAttribute('dy', '10');
      line2.textContent = `${lng.toFixed(2)}°`;
      label.appendChild(line1);
      label.appendChild(line2);
    } else {
      label.setAttribute('y', cy + 4);
      label.textContent = `${worldCol},${worldRow}`;
    }
    group.appendChild(label);

    // Lock icon for non-traversable hexes
    if (isNonTraversable) {
      const lockIcon = document.createElementNS('http://www.w3.org/2000/svg', 'text');
      lockIcon.setAttribute('x', cx);
      lockIcon.setAttribute('y', cy - 10);
      lockIcon.setAttribute('text-anchor', 'middle');
      lockIcon.setAttribute('fill', '#dc3545');
      lockIcon.setAttribute('font-size', '12');
      lockIcon.setAttribute('pointer-events', 'none');
      lockIcon.textContent = '🔒';
      group.appendChild(lockIcon);
    }

    // Terrain icon/indicator for cities
    if (hexInfo.terrain === 'urban' || hexInfo.has_city) {
      const cityIcon = document.createElementNS('http://www.w3.org/2000/svg', 'text');
      cityIcon.setAttribute('x', cx);
      cityIcon.setAttribute('y', isNonTraversable ? cy + 12 : cy - 8);
      cityIcon.setAttribute('text-anchor', 'middle');
      cityIcon.setAttribute('fill', '#fff');
      cityIcon.setAttribute('font-size', '12');
      cityIcon.setAttribute('pointer-events', 'none');
      cityIcon.textContent = '🏙️';
      group.appendChild(cityIcon);
    }

    return group;
  }

  hexPoints(cx, cy, size) {
    const points = [];
    for (let i = 0; i < 6; i++) {
      // No angle offset = flat-top hex (matches hexToPixel spacing)
      const angle = (Math.PI / 3) * i;
      points.push({
        x: cx + size * Math.cos(angle),
        y: cy + size * Math.sin(angle)
      });
    }
    return points;
  }

  renderFeatures() {
    const group = document.createElementNS('http://www.w3.org/2000/svg', 'g');
    group.id = 'features-group';
    const projectedMode = this.isUnwrappedNativeMode;

    // Calculate viewport offset for converting world coords to screen
    const startCol = projectedMode ? 0 : Math.floor(this.viewportX);
    const startRow = projectedMode ? 0 : Math.floor(this.viewportY);
    const offsetX = projectedMode ? 0 : (this.viewportX - startCol) * this.horizSpacing;
    const offsetY = projectedMode ? 0 : (this.viewportY - startRow) * this.vertSpacing;

    // Helper to get screen position for a world coordinate
    const getScreenPos = (worldX, worldY) => {
      if (projectedMode) {
        return this.getLocalPatchHexScreenPos(worldX, worldY);
      }
      const relCol = worldX - startCol;
      const relRow = worldY - startRow;
      const pos = this.hexToPixel(relCol, relRow);
      return { x: pos.x - offsetX, y: pos.y - offsetY };
    };

    // Helper to get edge position (midpoint between hex center and edge)
    const getEdgePos = (hexX, hexY, direction) => {
      if (projectedMode) {
        const hexInfo = this.getCachedHex(hexX, hexY) || this.findNearestLocalPatchHexByGridCoords(hexX, hexY);
        return this.getProjectedNativeEdgePos(hexInfo, direction);
      }
      const center = getScreenPos(hexX, hexY);

      // Calculate edge offset based on direction
      // For flat-top hex, edges are at specific angles
      const edgeOffsets = {
        'n':  { x: 0, y: -this.hexHeight * 0.5 },
        's':  { x: 0, y: this.hexHeight * 0.5 },
        'ne': { x: this.hexRadius * 0.75, y: -this.hexHeight * 0.25 },
        'nw': { x: -this.hexRadius * 0.75, y: -this.hexHeight * 0.25 },
        'se': { x: this.hexRadius * 0.75, y: this.hexHeight * 0.25 },
        'sw': { x: -this.hexRadius * 0.75, y: this.hexHeight * 0.25 }
      };

      const offset = edgeOffsets[direction] || { x: 0, y: 0 };
      return {
        x: center.x + offset.x,
        y: center.y + offset.y
      };
    };

    // Render saved features using edge-to-center-to-edge path
    this.features.forEach(feature => {
      if (feature.points.length < 2) return;

      const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
      let d = '';

      // Build path that goes through hex edges
      for (let i = 0; i < feature.points.length; i++) {
        const point = feature.points[i];
        const center = getScreenPos(point.x, point.y);

        if (i === 0) {
          // First point: start at center or incoming edge
          if (feature.points.length > 1) {
            const nextPoint = feature.points[1];
            const direction = this.getHexDirection(point.x, point.y, nextPoint.x, nextPoint.y);
            const edgePos = getEdgePos(point.x, point.y, direction);
            d = `M ${center.x} ${center.y} L ${edgePos.x} ${edgePos.y}`;
          } else {
            d = `M ${center.x} ${center.y}`;
          }
        } else {
          // Middle/end points: enter from edge, go through center, exit to next edge
          const prevPoint = feature.points[i - 1];
          const inDirection = this.getOppositeDirection(this.getHexDirection(prevPoint.x, prevPoint.y, point.x, point.y));
          const inEdge = getEdgePos(point.x, point.y, inDirection);

          // Add line from previous exit to this entry
          d += ` L ${inEdge.x} ${inEdge.y}`;
          // Go through center
          d += ` L ${center.x} ${center.y}`;

          // If there's a next point, exit to that edge
          if (i < feature.points.length - 1) {
            const nextPoint = feature.points[i + 1];
            const outDirection = this.getHexDirection(point.x, point.y, nextPoint.x, nextPoint.y);
            const outEdge = getEdgePos(point.x, point.y, outDirection);
            d += ` L ${outEdge.x} ${outEdge.y}`;
          }
        }
      }

      path.setAttribute('d', d);
      path.setAttribute('stroke', this.featureColors[feature.type] || '#888');
      path.setAttribute('stroke-width', this.featureWidths[feature.type] || 3);
      path.setAttribute('fill', 'none');
      path.setAttribute('stroke-linecap', 'round');
      path.setAttribute('stroke-linejoin', 'round');

      // Add dashed pattern for trails/railways
      if (feature.type === 'trail') {
        path.setAttribute('stroke-dasharray', '5,5');
      } else if (feature.type === 'railway') {
        path.setAttribute('stroke-dasharray', '10,5');
      }

      group.appendChild(path);
    });

    // Render directional features from cached hex data (loaded from API)
    this.renderDirectionalFeaturesFromHexes(group, getScreenPos, getEdgePos);

    // Render in-progress feature line (preview) — trace through intermediate hexes
    if (this.featurePoints.length > 0) {
      // Build full traced preview path
      const previewHexes = [];
      for (let i = 0; i < this.featurePoints.length; i++) {
        if (i === 0) {
          previewHexes.push(this.featurePoints[i]);
        } else {
          const from = this.featurePoints[i - 1];
          const to = this.featurePoints[i];
          const segment = this.traceHexLine(from.x, from.y, to.x, to.y);
          segment.forEach((pt, idx) => {
            if (idx === 0 && previewHexes.length > 0 &&
                previewHexes[previewHexes.length - 1].x === pt.x &&
                previewHexes[previewHexes.length - 1].y === pt.y) return;
            previewHexes.push(pt);
          });
        }
      }

      const previewPath = document.createElementNS('http://www.w3.org/2000/svg', 'path');
      let d = '';

      for (let i = 0; i < previewHexes.length; i++) {
        const point = previewHexes[i];
        const center = getScreenPos(point.x, point.y);

        if (i === 0) {
          d = `M ${center.x} ${center.y}`;
        } else {
          const prevPoint = previewHexes[i - 1];
          const direction = this.getHexDirection(prevPoint.x, prevPoint.y, point.x, point.y);
          const oppositeDir = this.getOppositeDirection(direction);

          if (direction && oppositeDir) {
            const exitEdge = getEdgePos(prevPoint.x, prevPoint.y, direction);
            const entryEdge = getEdgePos(point.x, point.y, oppositeDir);
            d += ` L ${exitEdge.x} ${exitEdge.y} L ${entryEdge.x} ${entryEdge.y} L ${center.x} ${center.y}`;
          } else {
            d += ` L ${center.x} ${center.y}`;
          }
        }
      }

      previewPath.setAttribute('d', d);
      previewPath.setAttribute('stroke', this.featureColors[this.selectedFeature] || '#888');
      previewPath.setAttribute('stroke-width', this.featureWidths[this.selectedFeature] || 3);
      previewPath.setAttribute('fill', 'none');
      previewPath.setAttribute('stroke-linecap', 'round');
      previewPath.setAttribute('stroke-linejoin', 'round');
      previewPath.setAttribute('opacity', '0.7');
      previewPath.setAttribute('stroke-dasharray', '4,4');

      group.appendChild(previewPath);

      // Draw markers at each point
      this.featurePoints.forEach((point, i) => {
        const center = getScreenPos(point.x, point.y);

        const marker = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
        marker.setAttribute('cx', center.x);
        marker.setAttribute('cy', center.y);
        marker.setAttribute('r', i === 0 ? 7 : 5);
        marker.setAttribute('fill', i === 0 ? this.featureColors[this.selectedFeature] : '#fff');
        marker.setAttribute('stroke', i === 0 ? '#fff' : this.featureColors[this.selectedFeature] || '#888');
        marker.setAttribute('stroke-width', 2);
        group.appendChild(marker);
      });
    }

    this.svg.appendChild(group);
  }

  // Render directional features from hex cache (features stored on individual hexes)
  renderDirectionalFeaturesFromHexes(group, getScreenPos, getEdgePos) {
    if (this.isUnwrappedNativeMode) {
      const renderedEdges = new Set();
      const namedFeaturePositions = new Map();
      const viewBounds = this.nativeProjectedViewBounds();
      const margin = this.nativeSpacing * 2;

      this.localPatchHexes().forEach((hexInfo) => {
        if (!hexInfo.features || Object.keys(hexInfo.features).length === 0) return;
        if (hexInfo.projectedBBox) {
          if (hexInfo.projectedBBox.maxX < viewBounds.minX - margin ||
              hexInfo.projectedBBox.minX > viewBounds.maxX + margin ||
              hexInfo.projectedBBox.maxY < viewBounds.minY - margin ||
              hexInfo.projectedBBox.minY > viewBounds.maxY + margin) {
            return;
          }
        }

        Object.entries(hexInfo.features).forEach(([direction, featureType]) => {
          if (!featureType) return;

          const edgeKey = `${hexInfo.worldX},${hexInfo.worldY}-${direction}-${featureType}`;
          const reverseKey = this.getOppositeEdgeKey(hexInfo.worldX, hexInfo.worldY, direction, featureType);
          if (renderedEdges.has(edgeKey) || renderedEdges.has(reverseKey)) return;
          renderedEdges.add(edgeKey);

          const center = getScreenPos(hexInfo.worldX, hexInfo.worldY);
          const edge = getEdgePos(hexInfo.worldX, hexInfo.worldY, direction);
          if (!center || !edge) return;

          const line = document.createElementNS('http://www.w3.org/2000/svg', 'line');
          line.setAttribute('x1', center.x);
          line.setAttribute('y1', center.y);
          line.setAttribute('x2', edge.x);
          line.setAttribute('y2', edge.y);
          line.setAttribute('stroke', this.featureColors[featureType] || '#888');
          line.setAttribute('stroke-width', this.featureWidths[featureType] || 3);
          line.setAttribute('stroke-linecap', 'round');

          if (featureType === 'trail') {
            line.setAttribute('stroke-dasharray', '5,5');
          } else if (featureType === 'railway') {
            line.setAttribute('stroke-dasharray', '10,5');
          }

          group.appendChild(line);

          const featureId = hexInfo.featureIds && hexInfo.featureIds[direction];
          const featureName = hexInfo.featureNames && hexInfo.featureNames[direction];
          if (featureId && featureName) {
            if (!namedFeaturePositions.has(featureId)) {
              namedFeaturePositions.set(featureId, {
                name: featureName,
                color: this.featureColors[featureType] || '#888',
                positions: []
              });
            }
            namedFeaturePositions.get(featureId).positions.push(center);
          }
        });
      });

      namedFeaturePositions.forEach(({ name, color, positions }) => {
        if (positions.length === 0) return;
        const mid = positions[Math.floor(positions.length / 2)];

        const text = document.createElementNS('http://www.w3.org/2000/svg', 'text');
        text.setAttribute('x', mid.x);
        text.setAttribute('y', mid.y - 8);
        text.setAttribute('text-anchor', 'middle');
        text.setAttribute('font-size', '11');
        text.setAttribute('font-family', 'sans-serif');
        text.setAttribute('font-style', 'italic');
        text.setAttribute('fill', color);
        text.setAttribute('stroke', '#000');
        text.setAttribute('stroke-width', '0.3');
        text.setAttribute('pointer-events', 'none');
        text.textContent = name;
        group.appendChild(text);
      });
      return;
    }

    if (this.isNativeMode && !this.isUnwrappedNativeMode) {
      for (const [key, hexInfo] of this.hexCache) {
        if (!key.startsWith('ghid:')) continue;
        if (!hexInfo.features || Object.keys(hexInfo.features).length === 0) continue;

        const pos = this.gnomonicForward(hexInfo.lat, hexInfo.lng);
        if (!pos) continue;
        const cx = pos.x;
        const cy = pos.y;

        for (const [dir, featureType] of Object.entries(hexInfo.features)) {
          const color = this.featureColors[featureType] || this.featureColors.road;
          const lineWidth = this.featureWidths[featureType] || 3;
          const edge = this.getEdgePosFromCenter(cx, cy, dir);

          const line = document.createElementNS('http://www.w3.org/2000/svg', 'line');
          line.setAttribute('x1', cx);
          line.setAttribute('y1', cy);
          line.setAttribute('x2', edge.x);
          line.setAttribute('y2', edge.y);
          line.setAttribute('stroke', color);
          line.setAttribute('stroke-width', lineWidth);
          line.setAttribute('stroke-linecap', 'round');
          group.appendChild(line);
        }
      }
      return;
    }

    // Build a set of rendered edges to avoid duplicates
    const renderedEdges = new Set();
    // Track named features to render labels (feature_id -> {positions, name, color})
    const namedFeaturePositions = new Map();

    // Scan visible hexes for directional features
    const startCol = Math.floor(this.viewportX);
    const endCol = startCol + this.visibleCols;
    const startRow = Math.floor(this.viewportY);
    const endRow = startRow + this.visibleRows;

    for (let row = startRow; row < endRow; row++) {
      for (let col = startCol; col < endCol; col++) {
        const key = `${col},${row}`;
        const hexInfo = this.hexCache.get(key);

        if (hexInfo && hexInfo.features) {
          Object.entries(hexInfo.features).forEach(([direction, featureType]) => {
            if (!featureType) return;

            // Create unique edge key to avoid drawing same edge twice
            const edgeKey = `${col},${row}-${direction}-${featureType}`;
            const reverseKey = this.getOppositeEdgeKey(col, row, direction, featureType);

            if (renderedEdges.has(edgeKey) || renderedEdges.has(reverseKey)) return;
            renderedEdges.add(edgeKey);

            // Draw feature from center to edge
            const center = getScreenPos(col, row);
            const edge = getEdgePos(col, row, direction);

            const line = document.createElementNS('http://www.w3.org/2000/svg', 'line');
            line.setAttribute('x1', center.x);
            line.setAttribute('y1', center.y);
            line.setAttribute('x2', edge.x);
            line.setAttribute('y2', edge.y);
            line.setAttribute('stroke', this.featureColors[featureType] || '#888');
            line.setAttribute('stroke-width', this.featureWidths[featureType] || 3);
            line.setAttribute('stroke-linecap', 'round');

            if (featureType === 'trail') {
              line.setAttribute('stroke-dasharray', '5,5');
            } else if (featureType === 'railway') {
              line.setAttribute('stroke-dasharray', '10,5');
            }

            group.appendChild(line);

            // Collect positions for named features
            const featureId = hexInfo.featureIds && hexInfo.featureIds[direction];
            const featureName = hexInfo.featureNames && hexInfo.featureNames[direction];
            if (featureId && featureName) {
              if (!namedFeaturePositions.has(featureId)) {
                namedFeaturePositions.set(featureId, {
                  name: featureName,
                  color: this.featureColors[featureType] || '#888',
                  positions: []
                });
              }
              namedFeaturePositions.get(featureId).positions.push(center);
            }
          });
        }
      }
    }

    // Render one label per named feature at its midpoint
    namedFeaturePositions.forEach(({ name, color, positions }) => {
      if (positions.length === 0) return;
      const mid = positions[Math.floor(positions.length / 2)];

      const text = document.createElementNS('http://www.w3.org/2000/svg', 'text');
      text.setAttribute('x', mid.x);
      text.setAttribute('y', mid.y - 8);
      text.setAttribute('text-anchor', 'middle');
      text.setAttribute('font-size', '11');
      text.setAttribute('font-family', 'sans-serif');
      text.setAttribute('font-style', 'italic');
      text.setAttribute('fill', color);
      text.setAttribute('stroke', '#000');
      text.setAttribute('stroke-width', '0.3');
      text.setAttribute('pointer-events', 'none');
      text.textContent = name;
      group.appendChild(text);
    });
  }

  // Helper to get reverse edge key for deduplication
  getOppositeEdgeKey(x, y, direction, featureType) {
    const opposites = {
      'n': 's', 's': 'n',
      'ne': 'sw', 'sw': 'ne',
      'se': 'nw', 'nw': 'se'
    };
    const oppositeDir = opposites[direction];
    if (!oppositeDir) return null;

    // Calculate neighbor position based on direction
    const neighborOffsets = {
      'n': [0, -1], 's': [0, 1],
      'ne': [1, 0], 'sw': [-1, 0],
      'se': [1, 1], 'nw': [-1, -1]
    };
    const offset = neighborOffsets[direction] || [0, 0];
    const neighborX = x + offset[0];
    const neighborY = y + offset[1];

    return `${neighborX},${neighborY}-${oppositeDir}-${featureType}`;
  }

  renderCities() {
    if (this.isUnwrappedNativeMode) {
      const group = document.createElementNS('http://www.w3.org/2000/svg', 'g');
      group.id = 'cities-group';
      const viewBounds = this.nativeProjectedViewBounds();
      const margin = this.nativeSpacing * 3;

      this.cities.forEach((city) => {
        let cityHex = null;
        if (city.globe_hex_id != null) {
          cityHex = this.hexCache.get(`ghid:${city.globe_hex_id}`) || null;
        }
        if (!cityHex && city.lat != null && city.lng != null) {
          cityHex = this.findLocalPatchHexByLatLng(city.lat, city.lng);
        }
        if (!cityHex) return;

        if (cityHex.projectedX < viewBounds.minX - margin || cityHex.projectedX > viewBounds.maxX + margin ||
            cityHex.projectedY < viewBounds.minY - margin || cityHex.projectedY > viewBounds.maxY + margin) {
          return;
        }

        const screenPos = this.projectedNativeScreenPos(cityHex.projectedX, cityHex.projectedY);
        const x = screenPos.x;
        const y = screenPos.y;

        const markerGroup = document.createElementNS('http://www.w3.org/2000/svg', 'g');
        markerGroup.classList.add('city-marker');
        markerGroup.setAttribute('data-city-id', city.id);
        markerGroup.style.cursor = 'pointer';

        markerGroup.addEventListener('click', (e) => {
          if (this.selectedTool === 'select') {
            e.stopPropagation();
            if (city.location_id) {
              window.location.href = `/admin/city_builder/${city.location_id}`;
            } else {
              alert(`City: ${city.name}\nZone ID: ${city.id}\n\nNo city grid has been built yet. Double-click the hex to open the sub-hex editor and create the city.`);
            }
          }
        });

        const glow = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
        glow.setAttribute('cx', x);
        glow.setAttribute('cy', y);
        glow.setAttribute('r', 15);
        glow.setAttribute('fill', 'rgba(255, 193, 7, 0.3)');
        markerGroup.appendChild(glow);

        const circle = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
        circle.setAttribute('cx', x);
        circle.setAttribute('cy', y);
        circle.setAttribute('r', 10);
        circle.setAttribute('fill', '#ffc107');
        circle.setAttribute('stroke', '#fff');
        circle.setAttribute('stroke-width', 2);
        markerGroup.appendChild(circle);

        const icon = document.createElementNS('http://www.w3.org/2000/svg', 'text');
        icon.setAttribute('x', x);
        icon.setAttribute('y', y + 4);
        icon.setAttribute('text-anchor', 'middle');
        icon.setAttribute('font-size', '10');
        icon.setAttribute('fill', '#000');
        icon.setAttribute('pointer-events', 'none');
        icon.textContent = '🏙️';
        markerGroup.appendChild(icon);

        if (city.name) {
          const label = document.createElementNS('http://www.w3.org/2000/svg', 'text');
          label.setAttribute('x', x);
          label.setAttribute('y', y + 22);
          label.setAttribute('text-anchor', 'middle');
          label.setAttribute('font-size', '10');
          label.setAttribute('fill', '#fff');
          label.setAttribute('stroke', '#000');
          label.setAttribute('stroke-width', '2');
          label.setAttribute('paint-order', 'stroke');
          label.setAttribute('pointer-events', 'none');
          label.textContent = city.name;
          markerGroup.appendChild(label);
        }

        group.appendChild(markerGroup);
      });

      this.svg.appendChild(group);
      return;
    }

    if (this.isNativeMode && !this.isUnwrappedNativeMode) {
      for (const city of this.cities) {
        if (city.lat == null || city.lng == null) continue;
        const pos = this.gnomonicForward(city.lat, city.lng);
        if (!pos) continue;
        const x = pos.x;
        const y = pos.y;

        // Create city marker group
        const g = document.createElementNS('http://www.w3.org/2000/svg', 'g');
        g.setAttribute('transform', `translate(${x},${y})`);
        g.style.cursor = 'pointer';

        // City dot
        const circle = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
        circle.setAttribute('r', 6);
        circle.setAttribute('fill', '#ff6b6b');
        circle.setAttribute('stroke', '#fff');
        circle.setAttribute('stroke-width', 2);
        g.appendChild(circle);

        // City name label
        if (city.name) {
          const text = document.createElementNS('http://www.w3.org/2000/svg', 'text');
          text.setAttribute('y', -10);
          text.setAttribute('text-anchor', 'middle');
          text.setAttribute('fill', '#fff');
          text.setAttribute('font-size', '10');
          text.setAttribute('font-family', 'sans-serif');
          text.textContent = city.name;
          g.appendChild(text);
        }

        this.svg.appendChild(g);
      }
      return;
    }

    const group = document.createElementNS('http://www.w3.org/2000/svg', 'g');
    group.id = 'cities-group';

    // Calculate viewport offset for converting world coords to screen
    const startCol = Math.floor(this.viewportX);
    const startRow = Math.floor(this.viewportY);
    const offsetX = (this.viewportX - startCol) * this.horizSpacing;
    const offsetY = (this.viewportY - startRow) * this.vertSpacing;

    // Build globe_hex_id → grid position lookup from hexCache
    const hexIdToGrid = new Map();
    for (const [key, hex] of this.hexCache) {
      if (hex.globe_hex_id != null) {
        hexIdToGrid.set(hex.globe_hex_id, { x: hex.worldX, y: hex.worldY });
      }
    }

    // Render city markers
    this.cities.forEach(city => {
      // Look up grid position from globe_hex_id
      let cityCol, cityRow;
      if (city.globe_hex_id && hexIdToGrid.has(city.globe_hex_id)) {
        const pos = hexIdToGrid.get(city.globe_hex_id);
        cityCol = pos.x;
        cityRow = pos.y;
      } else if (this.isUnwrappedNativeMode && city.lat != null && city.lng != null) {
        const nearestHex = this.findLocalPatchHexByLatLng(city.lat, city.lng);
        if (!nearestHex) return;
        cityCol = nearestHex.worldX;
        cityRow = nearestHex.worldY;
      } else {
        // Fallback to x/y (for non-globe worlds)
        cityCol = city.x;
        cityRow = city.y;
      }

      const relCol = cityCol - startCol;
      const relRow = cityRow - startRow;

      if (relCol < -2 || relCol > this.visibleCols + 2 ||
          relRow < -2 || relRow > this.visibleRows + 2) {
        return; // City not visible
      }

      const screenPos = this.hexToPixel(relCol, relRow);
      const x = screenPos.x - offsetX;
      const y = screenPos.y - offsetY;

      // City marker (circle with icon)
      const markerGroup = document.createElementNS('http://www.w3.org/2000/svg', 'g');
      markerGroup.classList.add('city-marker');
      markerGroup.setAttribute('data-city-id', city.id);
      markerGroup.style.cursor = 'pointer';

      // Click handler to navigate to city builder
      markerGroup.addEventListener('click', (e) => {
        if (this.selectedTool === 'select') {
          e.stopPropagation();
          // Navigate to city builder if there's a location_id, otherwise to zone details
          if (city.location_id) {
            window.location.href = `/admin/city_builder/${city.location_id}`;
          } else {
            // Just a zone without a location - show info or open sub-hex editor
            console.log('City zone clicked:', city);
            alert(`City: ${city.name}\nZone ID: ${city.id}\n\nNo city grid has been built yet. Double-click the hex to open the sub-hex editor and create the city.`);
          }
        }
      });

      // Outer glow
      const glow = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
      glow.setAttribute('cx', x);
      glow.setAttribute('cy', y);
      glow.setAttribute('r', 15);
      glow.setAttribute('fill', 'rgba(255, 193, 7, 0.3)');
      markerGroup.appendChild(glow);

      // Inner circle
      const circle = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
      circle.setAttribute('cx', x);
      circle.setAttribute('cy', y);
      circle.setAttribute('r', 10);
      circle.setAttribute('fill', '#ffc107');
      circle.setAttribute('stroke', '#fff');
      circle.setAttribute('stroke-width', 2);
      markerGroup.appendChild(circle);

      // City icon (building emoji or similar)
      const icon = document.createElementNS('http://www.w3.org/2000/svg', 'text');
      icon.setAttribute('x', x);
      icon.setAttribute('y', y + 4);
      icon.setAttribute('text-anchor', 'middle');
      icon.setAttribute('font-size', '10');
      icon.setAttribute('fill', '#000');
      icon.setAttribute('pointer-events', 'none');
      icon.textContent = '🏙️';
      markerGroup.appendChild(icon);

      // City name label (below marker)
      if (city.name) {
        const label = document.createElementNS('http://www.w3.org/2000/svg', 'text');
        label.setAttribute('x', x);
        label.setAttribute('y', y + 22);
        label.setAttribute('text-anchor', 'middle');
        label.setAttribute('font-size', '10');
        label.setAttribute('fill', '#fff');
        label.setAttribute('stroke', '#000');
        label.setAttribute('stroke-width', '2');
        label.setAttribute('paint-order', 'stroke');
        label.setAttribute('pointer-events', 'none');
        label.textContent = city.name;
        markerGroup.appendChild(label);
      }

      group.appendChild(markerGroup);
    });

    this.svg.appendChild(group);
  }

  // Render zone polygon preview when drawing
  renderZonePreview() {
    if (!this.isDrawingZone || this.zonePoints.length === 0) return;

    const group = document.createElementNS('http://www.w3.org/2000/svg', 'g');
    group.id = 'zone-preview-group';

    // Calculate viewport offset
    const startCol = Math.floor(this.viewportX);
    const startRow = Math.floor(this.viewportY);
    const offsetX = (this.viewportX - startCol) * this.horizSpacing;
    const offsetY = (this.viewportY - startRow) * this.vertSpacing;
    const previewPoints = this.zonePoints.map(point => {
      if (this.isUnwrappedNativeMode) {
        return this.resolvePatchPoint(point);
      }
      return { x: point.x, y: point.y };
    }).filter(Boolean);

    if (previewPoints.length === 0) {
      this.svg.appendChild(group);
      return;
    }

    const screenPoints = previewPoints.map((point) => {
      if (this.isUnwrappedNativeMode) {
        return this.getLocalPatchHexScreenPos(point.x, point.y);
      }

      const relCol = point.x - startCol;
      const relRow = point.y - startRow;
      const screenPos = this.hexToPixel(relCol, relRow);
      return {
        x: screenPos.x - offsetX,
        y: screenPos.y - offsetY
      };
    }).filter(Boolean);

    if (screenPoints.length === 0) {
      this.svg.appendChild(group);
      return;
    }

    // Draw polygon if we have 3+ points
    if (screenPoints.length >= 3) {
      const polygon = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
      const points = screenPoints.map(point => `${point.x},${point.y}`).join(' ');

      polygon.setAttribute('points', points);
      polygon.setAttribute('fill', 'rgba(23, 162, 184, 0.3)');
      polygon.setAttribute('stroke', '#17a2b8');
      polygon.setAttribute('stroke-width', 2);
      polygon.setAttribute('stroke-dasharray', '5,5');
      group.appendChild(polygon);
    }

    // Draw lines connecting points
    if (screenPoints.length >= 2) {
      const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
      let d = '';

      screenPoints.forEach((point, i) => {
        if (i === 0) {
          d = `M ${point.x} ${point.y}`;
        } else {
          d += ` L ${point.x} ${point.y}`;
        }
      });

      path.setAttribute('d', d);
      path.setAttribute('stroke', '#17a2b8');
      path.setAttribute('stroke-width', 2);
      path.setAttribute('fill', 'none');
      group.appendChild(path);
    }

    // Draw point markers
    screenPoints.forEach((point, i) => {
      const marker = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
      marker.setAttribute('cx', point.x);
      marker.setAttribute('cy', point.y);
      marker.setAttribute('r', i === 0 ? 8 : 5);
      marker.setAttribute('fill', i === 0 ? '#17a2b8' : '#fff');
      marker.setAttribute('stroke', i === 0 ? '#fff' : '#17a2b8');
      marker.setAttribute('stroke-width', 2);
      group.appendChild(marker);

      // Number label
      const label = document.createElementNS('http://www.w3.org/2000/svg', 'text');
      label.setAttribute('x', point.x);
      label.setAttribute('y', point.y + 3);
      label.setAttribute('text-anchor', 'middle');
      label.setAttribute('font-size', '9');
      label.setAttribute('fill', i === 0 ? '#fff' : '#17a2b8');
      label.setAttribute('pointer-events', 'none');
      label.textContent = (i + 1).toString();
      group.appendChild(label);
    });

    this.svg.appendChild(group);
  }

  // Load cities from API
  async loadCities() {
    try {
      const apiBase = window.API_BASE || `/admin/world_builder/${this.worldId}/api`;
      const resp = await fetch(`${apiBase}/cities`);
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      const data = await resp.json();
      this.cities = data.cities || [];
      this.render();
    } catch (error) {
      console.error('Failed to load cities:', error);
    }
  }

  // Load features from API
  async loadFeatures() {
    try {
      const apiBase = window.API_BASE || `/admin/world_builder/${this.worldId}/api`;
      // Pass viewport bounds to scope the query and avoid scanning all hexes
      let centerLng;
      let centerLat;
      let radius;

      if (this.isUnwrappedNativeMode) {
        const geoBounds = this.localPatchGeoBounds();
        if (geoBounds) {
          centerLng = (geoBounds.minLng + geoBounds.maxLng) / 2;
          centerLat = (geoBounds.minLat + geoBounds.maxLat) / 2;
          radius = Math.max(
            geoBounds.maxLng - geoBounds.minLng,
            geoBounds.maxLat - geoBounds.minLat
          ) / 2 + 0.5;
        } else {
          centerLng = this.nativeCenterLng;
          centerLat = this.nativeCenterLat;
          radius = Math.max(1, this.localPatchRings * 0.05);
        }
      } else {
        const cs = this.effectiveCellSize;
        centerLng = (this.viewportX + this.visibleCols / 2) * cs - 180;
        centerLat = 90 - (this.viewportY + this.visibleRows / 2) * cs;
        radius = Math.max(this.visibleCols, this.visibleRows) * cs / 2 + 1;
      }

      const params = new URLSearchParams({
        lat: String(centerLat),
        lng: String(centerLng),
        radius: String(radius)
      });
      const resp = await fetch(`${apiBase}/features?${params}`);
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      const data = await resp.json();

      // Load legacy features (polyline format)
      this.features = data.features || [];

      // Load named features list
      this.namedFeatures = data.named_features || [];

      // Load directional features and merge into hex cache
      if (data.directional_features) {
        this.directionalFeatures = data.directional_features;

        // Group directional features by hex for the cache
        const featuresByHex = {};
        data.directional_features.forEach(f => {
          // Use globe_hex_id as key, or lat/lng
          const hexKey = f.globe_hex_id || `${f.lat},${f.lng}`;
          if (!featuresByHex[hexKey]) {
            featuresByHex[hexKey] = { ...f, features: {}, featureIds: {}, featureNames: {} };
          }
          featuresByHex[hexKey].features[f.direction] = f.type;
          if (f.feature_id) featuresByHex[hexKey].featureIds[f.direction] = f.feature_id;
          if (f.name) featuresByHex[hexKey].featureNames[f.direction] = f.name;
        });

        // Update hex cache with feature data
        this.hexCache.forEach((hexInfo, key) => {
          const hexKey = hexInfo.globe_hex_id || `${hexInfo.lat},${hexInfo.lng}`;
          if (featuresByHex[hexKey]) {
            hexInfo.features = {
              ...(hexInfo.features || {}),
              ...featuresByHex[hexKey].features
            };
            hexInfo.featureIds = {
              ...(hexInfo.featureIds || {}),
              ...featuresByHex[hexKey].featureIds
            };
            hexInfo.featureNames = {
              ...(hexInfo.featureNames || {}),
              ...featuresByHex[hexKey].featureNames
            };
            this.hexCache.set(key, hexInfo);
          }
        });
      }

      this.render();
    } catch (error) {
      console.error('Failed to load features:', error);
    }
  }

  // Load zones from API
  async loadZones() {
    try {
      const apiBase = window.API_BASE || `/admin/world_builder/${this.worldId}/api`;
      const resp = await fetch(`${apiBase}/zones`);
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      const data = await resp.json();
      this.zones = data.zones || [];
      this.render();
    } catch (error) {
      console.error('Failed to load zones:', error);
    }
  }

  // Render saved zones as colored polygon overlays
  renderZones() {
    if (!this.zones || this.zones.length === 0) return;

    if (this.isNativeMode && !this.isUnwrappedNativeMode) {
      for (const zone of this.zones) {
        if (!zone.points || zone.points.length < 3) continue;
        const screenPoints = [];
        for (const p of zone.points) {
          const pos = this.gnomonicForward(
            p.lat != null ? p.lat : p.y,
            p.lng != null ? p.lng : p.x
          );
          if (pos) screenPoints.push(`${pos.x},${pos.y}`);
        }
        if (screenPoints.length < 3) continue;

        const polygon = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
        polygon.setAttribute('points', screenPoints.join(' '));
        polygon.setAttribute('fill', zone.color || 'rgba(255,100,100,0.2)');
        polygon.setAttribute('stroke', zone.color || 'rgba(255,100,100,0.6)');
        polygon.setAttribute('stroke-width', '2');
        this.svg.appendChild(polygon);

        // Zone name label at centroid
        if (zone.name) {
          const cx = screenPoints.reduce((sum, p) => sum + parseFloat(p.split(',')[0]), 0) / screenPoints.length;
          const cy = screenPoints.reduce((sum, p) => sum + parseFloat(p.split(',')[1]), 0) / screenPoints.length;
          const text = document.createElementNS('http://www.w3.org/2000/svg', 'text');
          text.setAttribute('x', cx);
          text.setAttribute('y', cy);
          text.setAttribute('text-anchor', 'middle');
          text.setAttribute('fill', '#fff');
          text.setAttribute('font-size', '12');
          text.setAttribute('font-family', 'sans-serif');
          text.textContent = zone.name;
          this.svg.appendChild(text);
        }
      }
      return;
    }

    const group = document.createElementNS('http://www.w3.org/2000/svg', 'g');
    group.id = 'zones-group';

    // Zone colors by type (semi-transparent)
    const zoneColors = {
      political: 'rgba(128, 0, 128, 0.25)',
      area: 'rgba(34, 139, 34, 0.25)',
      location: 'rgba(41, 128, 185, 0.25)',
      city: 'rgba(255, 193, 7, 0.25)'
    };
    const zoneBorders = {
      political: 'rgba(128, 0, 128, 0.7)',
      area: 'rgba(34, 139, 34, 0.7)',
      location: 'rgba(41, 128, 185, 0.7)',
      city: 'rgba(255, 193, 7, 0.7)'
    };

    const startCol = Math.floor(this.viewportX);
    const startRow = Math.floor(this.viewportY);
    const offsetX = (this.viewportX - startCol) * this.horizSpacing;
    const offsetY = (this.viewportY - startRow) * this.vertSpacing;

    this.zones.forEach(zone => {
      if (!zone.polygon_points || zone.polygon_points.length < 3) return;

      // Convert polygon points (world hex coords) to screen coordinates
      const screenPoints = zone.polygon_points.map(point => {
        const resolvedPoint = this.isUnwrappedNativeMode
          ? this.resolvePatchPoint(point)
          : { x: point.x, y: point.y };
        if (!resolvedPoint) return null;

        if (this.isUnwrappedNativeMode) {
          return this.getLocalPatchHexScreenPos(resolvedPoint.x, resolvedPoint.y);
        }

        const relCol = resolvedPoint.x - startCol;
        const relRow = resolvedPoint.y - startRow;
        const screenPos = this.hexToPixel(relCol, relRow);
        return {
          x: screenPos.x - offsetX,
          y: screenPos.y - offsetY
        };
      }).filter(Boolean);

      if (screenPoints.length < 3) return;

      // Draw polygon fill
      const polygon = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
      polygon.setAttribute('points', screenPoints.map(p => `${p.x},${p.y}`).join(' '));
      polygon.setAttribute('fill', zoneColors[zone.zone_type] || 'rgba(128, 128, 128, 0.25)');
      polygon.setAttribute('stroke', zoneBorders[zone.zone_type] || 'rgba(128, 128, 128, 0.7)');
      polygon.setAttribute('stroke-width', 2);
      polygon.setAttribute('pointer-events', 'none');
      group.appendChild(polygon);

      // Add zone name label at centroid
      const centroid = screenPoints.reduce(
        (acc, p) => ({ x: acc.x + p.x / screenPoints.length, y: acc.y + p.y / screenPoints.length }),
        { x: 0, y: 0 }
      );

      const label = document.createElementNS('http://www.w3.org/2000/svg', 'text');
      label.setAttribute('x', centroid.x);
      label.setAttribute('y', centroid.y);
      label.setAttribute('text-anchor', 'middle');
      label.setAttribute('font-size', '12');
      label.setAttribute('font-weight', 'bold');
      label.setAttribute('fill', '#fff');
      label.setAttribute('stroke', '#000');
      label.setAttribute('stroke-width', '2');
      label.setAttribute('paint-order', 'stroke');
      label.setAttribute('pointer-events', 'none');
      label.textContent = zone.name;
      group.appendChild(label);
    });

    this.svg.appendChild(group);
  }

  // Convert a pointer event to world hex coordinates
  _pointerToWorld(e) {
    if (this.isUnwrappedNativeMode) {
      const rect = this.svg.getBoundingClientRect();
      const hexInfo = this.findNearestLocalPatchHex(
        e.clientX - rect.left,
        e.clientY - rect.top
      );
      if (!hexInfo) return { col: null, row: null };
      return {
        col: hexInfo.worldX,
        row: hexInfo.worldY,
        lat: hexInfo.lat,
        lng: hexInfo.lng,
        globe_hex_id: hexInfo.globe_hex_id
      };
    }

    if (this.isNativeMode) {
      const rect = this.canvas.getBoundingClientRect();
      const mouseX = e.clientX - rect.left;
      const mouseY = e.clientY - rect.top;
      const clickGeo = this.gnomonicInverse(mouseX, mouseY);
      const clickLng = clickGeo.lng;
      const clickLat = clickGeo.lat;
      return { col: null, row: null, lng: clickLng, lat: clickLat, native: true };
    }
    const rect = this.svg.getBoundingClientRect();
    return this.pixelToHex(e.clientX - rect.left, e.clientY - rect.top);
  }

  // Event handlers
  handlePointerDown(e) {
    const worldPos = this._pointerToWorld(e);

    // Middle mouse button (1) or right-click (2) or spacebar held = always pan
    const shouldPan = e.button === 1 || e.button === 2 || this.spacePressed ||
                      (e.button === 0 && this.selectedTool === 'select');

    if (shouldPan) {
      // Start potential pan
      this.isPanning = true;
      this.panStart = { x: e.clientX, y: e.clientY };
      this.panAccumulated = { x: 0, y: 0 };
      this.panWorldPos = worldPos; // Remember where we clicked
      this.hasDragged = false;
      this.svg.style.cursor = 'grabbing';
      this.svg.setPointerCapture(e.pointerId);
      e.preventDefault();
    } else if (e.button === 0) {
      // Left-click on hex with a tool active (not select)
      if (this.isUnwrappedNativeMode) {
        if (worldPos.col != null && worldPos.row != null) {
          this.handleHexClick(worldPos.col, worldPos.row);
        }
      } else if (this.isNativeMode) {
        const rect = this.canvas.getBoundingClientRect();
        const mouseX = e.clientX - rect.left;
        const mouseY = e.clientY - rect.top;
        const clickGeo = this.gnomonicInverse(mouseX, mouseY);
        const clickLng = clickGeo.lng;
        const clickLat = clickGeo.lat;

        let nearest = null;
        let nearestKey = null;
        let nearestDist = Infinity;
        for (const [key, hex] of this.hexCache) {
          if (!key.startsWith('ghid:')) continue;
          const d = (hex.lng - clickLng) ** 2 + (hex.lat - clickLat) ** 2;
          if (d < nearestDist) {
            nearestDist = d;
            nearest = hex;
            nearestKey = key;
          }
        }

        if (nearest) {
          this.handleNativeHexClick(nearestKey, nearest);
        }
      } else {
        this.handleHexClick(worldPos.col, worldPos.row);
      }
    }
  }

  handlePointerMove(e) {
    if (!this.isPanning) return;

    const dx = e.clientX - this.panStart.x;
    const dy = e.clientY - this.panStart.y;
    const distance = Math.sqrt(dx * dx + dy * dy);

    // Check if we've dragged far enough to be considered a pan (not a click)
    if (!this.hasDragged && distance > this.dragThreshold) {
      this.hasDragged = true;
    }

    // Only pan if we've exceeded the drag threshold
    if (this.hasDragged) {
      // Update viewport (inverted - dragging right moves viewport left)
      if (this.isUnwrappedNativeMode) {
        this.nativeViewX -= (dx - this.panAccumulated.x) / this.nativeScale;
        this.nativeViewY -= (dy - this.panAccumulated.y) / this.nativeScale;
        this.clampProjectedNativeView();
        this.syncNativeCenterFromViewport();
      } else if (this.isNativeMode && !this.isUnwrappedNativeMode) {
        const w = this.container.clientWidth;
        const h = this.container.clientHeight;
        const newCenter = this.gnomonicInverse(
          w / 2 - (dx - this.panAccumulated.x),
          h / 2 - (dy - this.panAccumulated.y)
        );
        this.nativeCenterLat = newCenter.lat;
        this.nativeCenterLng = newCenter.lng;
      } else {
        this.viewportX = this.viewportX - (dx - this.panAccumulated.x) / this.horizSpacing;
        this.viewportY = this.viewportY - (dy - this.panAccumulated.y) / this.vertSpacing;
      }

      this.panAccumulated = { x: dx, y: dy };
      this.render();

      // Load more hexes if needed
      if (this.isUnwrappedNativeMode) {
        this.maybeRecenterNativePatch();
      } else {
        this.loadVisibleHexes();
      }
    }
  }

  handlePointerUp(e) {
    if (this.isPanning) {
      this.svg.releasePointerCapture(e.pointerId);

      // If we didn't drag and clicked on a hex with select tool, treat as a click
      if (!this.hasDragged && this.panWorldPos && this.selectedTool === 'select') {
        if (this.isUnwrappedNativeMode) {
          if (this.panWorldPos.col != null && this.panWorldPos.row != null) {
            this.handleHexClick(this.panWorldPos.col, this.panWorldPos.row);
          }
        } else if (this.isNativeMode) {
          const rect = this.canvas.getBoundingClientRect();
          const mouseX = e.clientX - rect.left;
          const mouseY = e.clientY - rect.top;
          const clickGeo = this.gnomonicInverse(mouseX, mouseY);
          const clickLng = clickGeo.lng;
          const clickLat = clickGeo.lat;

          let nearest = null;
          let nearestKey = null;
          let nearestDist = Infinity;
          for (const [key, hex] of this.hexCache) {
            if (!key.startsWith('ghid:')) continue;
            const d = (hex.lng - clickLng) ** 2 + (hex.lat - clickLat) ** 2;
            if (d < nearestDist) {
              nearestDist = d;
              nearest = hex;
              nearestKey = key;
            }
          }

          if (nearest) {
            this.handleNativeHexClick(nearestKey, nearest);
          }
        } else {
          this.handleHexClick(this.panWorldPos.col, this.panWorldPos.row);
        }
      }

      this.isPanning = false;
      this.hasDragged = false;
      this.panWorldPos = null;
      this.svg.style.cursor = this.spacePressed ? 'grab' : (this.selectedTool === 'select' ? 'grab' : 'crosshair');
    }
  }

  handleWheel(e) {
    e.preventDefault();
    const rect = this.svg.getBoundingClientRect();
    const mouseX = e.clientX - rect.left;
    const mouseY = e.clientY - rect.top;
    const zoomFactor = e.deltaY > 0 ? (1 / 1.15) : 1.15;
    this.zoomViewport(zoomFactor, mouseX, mouseY);
  }

  handleKeyDown(e) {
    // Skip keyboard shortcuts when user is in a form field or modal
    const tag = e.target.tagName;
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return;
    if (e.target.isContentEditable) return;
    if (document.querySelector('.modal.show')) return;

    // Spacebar for pan mode
    if (e.key === ' ' && !this.spacePressed) {
      this.spacePressed = true;
      if (this.svg) this.svg.style.cursor = 'grab';
      e.preventDefault();
      return;
    }

    // Arrow keys to scroll
    const scrollAmount = e.shiftKey ? 5 : 1;
    const nativeScrollAmount = Math.max(this.nativeSpacing || 0.045, 0.01) * (e.shiftKey ? 6 : 2.5);

    switch (e.key) {
      case 'ArrowLeft':
        if (this.isUnwrappedNativeMode) {
          this.nativeViewX -= nativeScrollAmount;
          this.clampProjectedNativeView();
          this.syncNativeCenterFromViewport();
        } else {
          this.viewportX -= scrollAmount;
        }
        this.render();
        if (this.isUnwrappedNativeMode) {
          this.maybeRecenterNativePatch();
        } else {
          this.loadVisibleHexes();
        }
        e.preventDefault();
        break;
      case 'ArrowRight':
        if (this.isUnwrappedNativeMode) {
          this.nativeViewX += nativeScrollAmount;
          this.clampProjectedNativeView();
          this.syncNativeCenterFromViewport();
        } else {
          this.viewportX += scrollAmount;
        }
        this.render();
        if (this.isUnwrappedNativeMode) {
          this.maybeRecenterNativePatch();
        } else {
          this.loadVisibleHexes();
        }
        e.preventDefault();
        break;
      case 'ArrowUp':
        if (this.isUnwrappedNativeMode) {
          this.nativeViewY -= nativeScrollAmount;
          this.clampProjectedNativeView();
          this.syncNativeCenterFromViewport();
        } else {
          this.viewportY -= scrollAmount;
        }
        this.render();
        if (this.isUnwrappedNativeMode) {
          this.maybeRecenterNativePatch();
        } else {
          this.loadVisibleHexes();
        }
        e.preventDefault();
        break;
      case 'ArrowDown':
        if (this.isUnwrappedNativeMode) {
          this.nativeViewY += nativeScrollAmount;
          this.clampProjectedNativeView();
          this.syncNativeCenterFromViewport();
        } else {
          this.viewportY += scrollAmount;
        }
        this.render();
        if (this.isUnwrappedNativeMode) {
          this.maybeRecenterNativePatch();
        } else {
          this.loadVisibleHexes();
        }
        e.preventDefault();
        break;
      case 's':
        if (e.ctrlKey || e.metaKey) {
          e.preventDefault();
          this.save();
        }
        break;
      case 'Enter':
        // Finish zone polygon or feature line
        if (this.selectedTool === 'zone' && this.zonePoints.length >= 3) {
          this.finishZonePolygon();
          e.preventDefault();
        } else if (this.selectedTool === 'feature' && this.featurePoints.length >= 2) {
          this.finishFeatureLine();
          e.preventDefault();
        }
        break;
      case 'Escape':
        // Cancel current drawing operation
        if (this.isDrawingZone) {
          this.cancelZoneDrawing();
          e.preventDefault();
        } else if (this.isDrawingFeature) {
          this.cancelFeatureDrawing();
          e.preventDefault();
        }
        break;
    }
  }

  handleKeyUp(e) {
    if (e.key === ' ') {
      this.spacePressed = false;
      if (this.svg && !this.isPanning) {
        this.svg.style.cursor = this.selectedTool === 'select' ? 'grab' : 'crosshair';
      }
    }
  }

  handleResize() {
    this.render();
  }

  handleHexClick(worldX, worldY) {
    const key = `${worldX},${worldY}`;

    if (this.selectedTool === 'terrain') {
      this.paintTerrain(worldX, worldY);
    } else if (this.selectedTool === 'select') {
      // Single click with select tool opens sub-hex editor
      this.openSubHexEditor(worldX, worldY);
    } else if (this.selectedTool === 'city') {
      this.placeCityMarker(worldX, worldY);
    } else if (this.selectedTool === 'zone') {
      this.addZonePoint(worldX, worldY);
    } else if (this.selectedTool === 'feature') {
      this.drawFeature(worldX, worldY);
    } else if (this.selectedTool === 'traversable') {
      this.toggleTraversable(worldX, worldY);
    }
  }

  handleNativeHexClick(key, hex) {
    if (this.isUnwrappedNativeMode && hex.worldX != null && hex.worldY != null) {
      this.handleHexClick(hex.worldX, hex.worldY);
      return;
    }

    switch (this.selectedTool) {
      case 'terrain':
        this.paintNativeTerrain(key, hex);
        break;
      case 'traversable':
        this.toggleNativeTraversable(key, hex);
        break;
      case 'select':
        console.log('Selected hex:', hex.globe_hex_id, hex.terrain);
        break;
      case 'city':
        this.placeCityMarker(hex.lng, hex.lat);
        break;
      case 'zone':
        this.addZonePoint(hex.lng, hex.lat);
        break;
      case 'feature':
        // Feature drawing in native mode - store hex for feature path
        this.featurePoints.push({ worldX: hex.lng, worldY: hex.lat, globe_hex_id: hex.globe_hex_id });
        this.isDrawingFeature = true;
        this.render();
        break;
    }
  }

  paintNativeTerrain(key, hex) {
    const updated = { ...hex, terrain: this.selectedTerrain };
    this.updateCachedHex(updated);
    this.render();
    this.saveHexChange(updated);
  }

  toggleNativeTraversable(key, hex) {
    const updated = { ...hex, traversable: !hex.traversable };
    this.updateCachedHex(updated);
    this.render();
    this.saveHexChange(updated);
  }

  // Context menu handler for right-click
  handleContextMenu(e) {
    e.preventDefault();

    // Remove any existing context menu
    this.closeContextMenu();

    // Get the clicked hex via coordinate conversion
    const worldPos = this._pointerToWorld(e);
    let worldX = worldPos.col, worldY = worldPos.row;

    // Build menu options based on current state
    const menuItems = [];

    // Add tool-specific options
    if (this.selectedTool === 'feature' && this.featurePoints.length > 0) {
      if (this.featurePoints.length >= 2) {
        menuItems.push({ label: 'Finish Feature', icon: '✓', action: () => this.finishFeatureLine() });
      }
      menuItems.push({ label: 'Undo Last Point', icon: '↩', action: () => this.undoLastFeaturePoint() });
      menuItems.push({ label: 'Cancel Feature', icon: '✕', action: () => this.cancelFeatureDrawing() });
      menuItems.push({ divider: true });
    }

    if (this.selectedTool === 'zone' && this.isDrawingZone) {
      if (this.zonePoints.length >= 3) {
        menuItems.push({ label: 'Finish Zone', icon: '✓', action: () => this.finishZonePolygon() });
      }
      menuItems.push({ label: 'Undo Last Point', icon: '↩', action: () => this.undoLastZonePoint() });
      menuItems.push({ label: 'Cancel Zone', icon: '✕', action: () => this.cancelZoneDrawing() });
      menuItems.push({ divider: true });
    }

    // Always show hex info option if clicking on a hex
    if (worldX !== null) {
      menuItems.push({ label: 'Edit Hex', icon: '🔍', action: () => this.openSubHexEditor(worldX, worldY) });
      const hexInfo = this.hexCache.get(`${worldX},${worldY}`) || { terrain: 'ocean' };
      menuItems.push({ label: `Info: (${worldX}, ${worldY}) - ${hexInfo.terrain}`, icon: 'ℹ', disabled: true });
    }

    // Tool selection submenu
    menuItems.push({ divider: true });
    menuItems.push({ label: 'Tools:', icon: '🛠', disabled: true });
    menuItems.push({ label: 'Select', icon: this.selectedTool === 'select' ? '●' : '○', action: () => { this.setTool('select'); this.updateToolbarSelection('select'); } });
    menuItems.push({ label: 'Paint Terrain', icon: this.selectedTool === 'terrain' ? '●' : '○', action: () => { this.setTool('terrain'); this.updateToolbarSelection('terrain'); } });
    menuItems.push({ label: 'Draw Feature', icon: this.selectedTool === 'feature' ? '●' : '○', action: () => { this.setTool('feature'); this.updateToolbarSelection('feature'); } });
    menuItems.push({ label: 'Draw Zone', icon: this.selectedTool === 'zone' ? '●' : '○', action: () => { this.setTool('zone'); this.updateToolbarSelection('zone'); } });
    menuItems.push({ label: 'Place City', icon: this.selectedTool === 'city' ? '●' : '○', action: () => { this.setTool('city'); this.updateToolbarSelection('city'); } });

    // Create and show menu
    this.showContextMenu(e.clientX, e.clientY, menuItems);
  }

  showContextMenu(x, y, items) {
    const menu = document.createElement('div');
    menu.className = 'hex-context-menu';
    menu.style.cssText = `
      position: fixed;
      left: ${x}px;
      top: ${y}px;
      background: #2a2a2a;
      border: 1px solid #444;
      border-radius: 4px;
      padding: 4px 0;
      z-index: 1000;
      min-width: 180px;
      box-shadow: 0 4px 12px rgba(0,0,0,0.5);
      font-size: 13px;
    `;

    items.forEach(item => {
      if (item.divider) {
        const divider = document.createElement('div');
        divider.style.cssText = 'height: 1px; background: #444; margin: 4px 8px;';
        menu.appendChild(divider);
      } else {
        const menuItem = document.createElement('div');
        menuItem.style.cssText = `
          padding: 6px 12px;
          cursor: ${item.disabled ? 'default' : 'pointer'};
          color: ${item.disabled ? '#888' : '#fff'};
          display: flex;
          align-items: center;
          gap: 8px;
        `;
        if (!item.disabled) {
          menuItem.addEventListener('mouseenter', () => menuItem.style.background = '#3a3a3a');
          menuItem.addEventListener('mouseleave', () => menuItem.style.background = 'transparent');
          menuItem.addEventListener('click', () => {
            this.closeContextMenu();
            item.action();
          });
        }
        menuItem.innerHTML = `<span style="width: 16px; text-align: center;">${item.icon || ''}</span><span>${item.label}</span>`;
        menu.appendChild(menuItem);
      }
    });

    document.body.appendChild(menu);
    this.contextMenu = menu;

    // Close on outside click
    const closeHandler = (e) => {
      if (!menu.contains(e.target)) {
        this.closeContextMenu();
        document.removeEventListener('click', closeHandler);
      }
    };
    setTimeout(() => document.addEventListener('click', closeHandler), 0);

    // Keep menu in viewport
    const rect = menu.getBoundingClientRect();
    if (rect.right > window.innerWidth) menu.style.left = `${x - rect.width}px`;
    if (rect.bottom > window.innerHeight) menu.style.top = `${y - rect.height}px`;
  }

  closeContextMenu() {
    if (this.contextMenu) {
      this.contextMenu.remove();
      this.contextMenu = null;
    }
  }

  updateToolbarSelection(tool) {
    // Update toolbar UI if it exists
    document.querySelectorAll('.tool-btn').forEach(btn => {
      btn.classList.toggle('active', btn.dataset.tool === tool);
    });
  }

  paintTerrain(worldX, worldY) {
    const key = `${worldX},${worldY}`;
    let hexInfo = this.hexCache.get(key) || { terrain: 'ocean' };

    hexInfo = {
      ...hexInfo,
      terrain: this.selectedTerrain,
      worldX,
      worldY
    };

    this.updateCachedHex(hexInfo);
    this.render();

    // Auto-save terrain change immediately
    this.saveHexChange(hexInfo);
  }

  // Save a single hex change to the API
  // Trace a path of adjacent hexes from startId to endId using BFS through neighbor topology
  _traceNativeHexLine(startId, endId) {
    if (!this.nativeHexRenderer) return [];
    var cache = this.nativeHexRenderer.hexCache;
    var start = cache[startId];
    var end = cache[endId];
    if (!start || !end) return [end?.data || { globe_hex_id: endId }];

    var targetLat = end.data.latitude;
    var targetLon = end.data.longitude;
    var visited = new Set([startId]);
    var path = [start.data];
    var currentId = startId;

    for (var step = 0; step < 200; step++) {
      if (currentId === endId) break;

      var current = cache[currentId];
      var neighbors = current?.data?.neighbor_ids || [];
      var bestId = null;
      var bestDist = Infinity;

      for (var i = 0; i < neighbors.length; i++) {
        var nid = neighbors[i];
        if (visited.has(nid)) continue;
        var ncached = cache[nid];
        if (!ncached) continue;
        var dlat = ncached.data.latitude - targetLat;
        var dlon = (ncached.data.longitude - targetLon) * Math.cos(targetLat * Math.PI / 180);
        var dist = dlat * dlat + dlon * dlon;
        if (dist < bestDist) { bestDist = dist; bestId = nid; }
      }

      if (bestId === null) break;
      visited.add(bestId);
      path.push(cache[bestId].data);
      currentId = bestId;
    }

    return path;
  }

  // Get direction (n/ne/se/s/sw/nw) from one hex to another using lat/lon angle
  // Accepts objects with either .latitude/.longitude or .lat/.lng
  _getNativeHexDirection(fromData, toData) {
    var fromLat = fromData.latitude ?? fromData.lat;
    var fromLon = fromData.longitude ?? fromData.lng;
    var toLat = toData.latitude ?? toData.lat;
    var toLon = toData.longitude ?? toData.lng;
    if (fromLat == null || toLat == null) return null;
    var dlat = toLat - fromLat;
    var dlon = (toLon - fromLon) * Math.cos(fromLat * Math.PI / 180);
    var angle = Math.atan2(dlon, dlat) * 180 / Math.PI; // degrees from north, CW positive

    // Map to 6 hex directions (60° sectors)
    if (angle < 0) angle += 360;
    if (angle >= 330 || angle < 30) return 'n';
    if (angle >= 30 && angle < 90) return 'ne';
    if (angle >= 90 && angle < 150) return 'se';
    if (angle >= 150 && angle < 210) return 's';
    if (angle >= 210 && angle < 270) return 'sw';
    if (angle >= 270 && angle < 330) return 'nw';
    return null;
  }

  // Finish feature drawing in native Voronoi mode
  _finishNativeFeatureLine() {
    if (this.featurePoints.length < 2) {
      console.log('Feature: Need at least 2 points');
      return;
    }

    var directionalFeatures = [];
    var opposites = { n: 's', s: 'n', ne: 'sw', sw: 'ne', se: 'nw', nw: 'se' };

    for (var i = 0; i < this.featurePoints.length - 1; i++) {
      var from = this.featurePoints[i];
      var to = this.featurePoints[i + 1];
      var dir = this._getNativeHexDirection(from, to);
      if (!dir) continue;

      directionalFeatures.push({
        globe_hex_id: from.globe_hex_id,
        lat: from.lat, lng: from.lng,
        direction: dir, type: this.selectedFeature
      });
      directionalFeatures.push({
        globe_hex_id: to.globe_hex_id,
        lat: to.lat, lng: to.lng,
        direction: opposites[dir], type: this.selectedFeature
      });
    }

    console.log('Feature: Completed ' + this.selectedFeature + ' through ' + this.featurePoints.length + ' hexes, ' + directionalFeatures.length + ' directional entries');

    // Ask for optional name
    var featureName = prompt('Name this ' + this.selectedFeature + ' (leave blank for unnamed):', '');
    if (featureName && featureName.trim()) {
      directionalFeatures.forEach(function(f) { f.feature_name = featureName.trim(); });
    }

    this.saveDirectionalFeatures(directionalFeatures);

    // Clear drawing state
    this.featurePoints = [];
    this.isDrawingFeature = false;
    this.updateDrawingStatus();

    // Refresh hex data to show new features after a short delay
    setTimeout(() => {
      if (this.nativeHexRenderer) {
        this.nativeHexRenderer._clearChunks();
        this.nativeHexRenderer.hexCache = {};
        this.nativeHexRenderer._tiltAngle = null;
        this.nativeHexRenderer._lastViewport = null;
        this.nativeHexRenderer._pendingFetch = false;
        this.nativeHexRenderer._lastFetchedLat = undefined;
        this.nativeHexRenderer._lastFetchedLon = undefined;
      }
    }, 1000);
  }

  async _saveNativeDirtyHexes() {
    if (!this._nativeDirtyHexes || this._nativeDirtyHexes.size === 0) return;
    const hexes = [];
    this._nativeDirtyHexes.forEach((data, hid) => {
      hexes.push({
        globe_hex_id: hid,
        terrain: data.terrain_type,
        traversable: data.traversable
      });
    });
    this._nativeDirtyHexes.clear();

    try {
      const apiBase = window.API_BASE || `/admin/world_builder/${this.worldId}/api`;
      const csrfToken = window.CSRF_TOKEN || document.querySelector('meta[name="csrf-token"]')?.content;
      await fetch(`${apiBase}/globe_region`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken },
        body: JSON.stringify({ hexes })
      });
    } catch (error) {
      console.error('Failed to save native hex changes:', error);
    }
  }

  async saveHexChange(hexInfo) {
    try {
      const apiBase = window.API_BASE || `/admin/world_builder/${this.worldId}/api`;
      const csrfToken = window.CSRF_TOKEN || document.querySelector('meta[name="csrf-token"]')?.content;

      const response = await fetch(`${apiBase}/globe_region`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': csrfToken
        },
        body: JSON.stringify({
          face: this.regionOrigin?.face || 0,
          origin_x: this.regionOrigin?.x || 0,
          origin_y: this.regionOrigin?.y || 0,
          hexes: [{
            globe_hex_id: hexInfo.globe_hex_id,
            lat: hexInfo.lat,
            lng: hexInfo.lng,
            terrain: hexInfo.terrain,
            traversable: hexInfo.traversable
          }]
        })
      });

      if (!response.ok) {
        console.error('Failed to save hex:', response.status);
      }
    } catch (error) {
      console.error('Failed to save hex change:', error);
    }
  }

  placeCityMarker(worldX, worldY) {
    // Look up identity fields from cache
    const key = `${worldX},${worldY}`;
    const hexInfo = this.hexCache.get(key) || {};

    // Open city creation modal (DaisyUI dialog)
    document.getElementById('city-hex-x').value = hexInfo.lng ?? worldX;
    document.getElementById('city-hex-y').value = hexInfo.lat ?? worldY;
    const globeHexIdField = document.getElementById('city-globe-hex-id');
    if (globeHexIdField) globeHexIdField.value = hexInfo.globe_hex_id ?? '';

    const lat = hexInfo.lat != null ? hexInfo.lat.toFixed(2) : '?';
    const lng = hexInfo.lng != null ? hexInfo.lng.toFixed(2) : '?';
    const hexIdStr = hexInfo.globe_hex_id != null ? `#${hexInfo.globe_hex_id}` : `(${worldX}, ${worldY})`;
    document.getElementById('city-coords-display').textContent = `Hex ${hexIdStr} (${lat}, ${lng})`;

    const modal = document.getElementById('cityModal');
    if (modal && modal.showModal) {
      modal.showModal();
    }
  }

  // Zone Tool: Add a point to the zone polygon
  addZonePoint(worldX, worldY) {
    this.isDrawingZone = true;
    const point = { x: worldX, y: worldY };
    if (this.isUnwrappedNativeMode) {
      const hexInfo = this.getCachedHex(worldX, worldY) || {};
      point.lat = hexInfo.lat;
      point.lng = hexInfo.lng;
      point.globe_hex_id = hexInfo.globe_hex_id;
    }
    this.zonePoints.push(point);

    // Update status indicator
    this.updateDrawingStatus();

    // Visual feedback: render the zone polygon preview
    this.render();

    // If we have at least 3 points, show instruction to double-click to finish
    if (this.zonePoints.length >= 3) {
      console.log('Zone: Press Enter, double-click, or right-click to finish polygon');
    }
  }

  // Finish zone polygon and open modal
  finishZonePolygon() {
    if (this.zonePoints.length < 3) {
      console.log('Zone: Need at least 3 points to create a zone');
      return;
    }

    // Store points in hidden field
    const pointsJson = JSON.stringify(this.zonePoints);
    const pointsField = document.getElementById('zone-polygon-points');
    const pointsDisplay = document.getElementById('zone-points-display');

    if (pointsField) pointsField.value = pointsJson;
    if (pointsDisplay) pointsDisplay.textContent = `Polygon: ${this.zonePoints.length} points`;

    // Open zone modal
    const modal = document.getElementById('zoneModal');
    if (modal && modal.showModal) {
      // Store points temporarily - reset after modal closes
      const savedPoints = [...this.zonePoints];

      modal.showModal();

      // Listen for modal close to reset state
      const closeHandler = () => {
        this.zonePoints = [];
        this.isDrawingZone = false;
        this.updateDrawingStatus();
        this.render();
        modal.removeEventListener('close', closeHandler);
      };
      modal.addEventListener('close', closeHandler);
    } else {
      // No modal, just reset
      this.zonePoints = [];
      this.isDrawingZone = false;
      this.updateDrawingStatus();
      this.render();
    }
  }

  // Cancel zone drawing
  cancelZoneDrawing() {
    this.zonePoints = [];
    this.isDrawingZone = false;
    this.updateDrawingStatus();
    this.render();
  }

  // Undo last zone point
  undoLastZonePoint() {
    if (this.zonePoints.length > 0) {
      this.zonePoints.pop();
      if (this.zonePoints.length === 0) {
        this.isDrawingZone = false;
      }
      this.updateDrawingStatus();
      this.render();
    }
  }

  // Update the drawing status indicator in the UI
  updateDrawingStatus() {
    // Find or create status element
    let statusEl = document.getElementById('drawing-status');
    if (!statusEl) {
      statusEl = document.createElement('div');
      statusEl.id = 'drawing-status';
      statusEl.style.cssText = `
        position: absolute;
        top: 10px;
        left: 50%;
        transform: translateX(-50%);
        background: rgba(0, 0, 0, 0.8);
        color: white;
        padding: 8px 16px;
        border-radius: 4px;
        font-size: 13px;
        z-index: 100;
        display: flex;
        align-items: center;
        gap: 12px;
      `;
      this.container.parentElement.appendChild(statusEl);
    }

    // Update content based on current drawing state
    if (this.isDrawingFeature && this.featurePoints.length > 0) {
      const canFinish = this.featurePoints.length >= 2;
      statusEl.innerHTML = `
        <span>Drawing ${this.selectedFeature}: ${this.featurePoints.length} point(s)</span>
        <button onclick="window.hexEditor?.finishFeatureLine()" style="background: #4caf50; border: none; padding: 4px 8px; border-radius: 3px; cursor: pointer; color: white;" ${!canFinish ? 'disabled' : ''}>Finish</button>
        <button onclick="window.hexEditor?.undoLastFeaturePoint()" style="background: #ff9800; border: none; padding: 4px 8px; border-radius: 3px; cursor: pointer; color: white;">Undo</button>
        <button onclick="window.hexEditor?.cancelFeatureDrawing()" style="background: #f44336; border: none; padding: 4px 8px; border-radius: 3px; cursor: pointer; color: white;">Cancel</button>
      `;
      statusEl.style.display = 'flex';
    } else if (this.isDrawingZone && this.zonePoints.length > 0) {
      const canFinish = this.zonePoints.length >= 3;
      statusEl.innerHTML = `
        <span>Drawing zone: ${this.zonePoints.length} point(s) ${!canFinish ? '(need 3+)' : ''}</span>
        <button onclick="window.hexEditor?.finishZonePolygon()" style="background: #4caf50; border: none; padding: 4px 8px; border-radius: 3px; cursor: pointer; color: white;" ${!canFinish ? 'disabled' : ''}>Finish</button>
        <button onclick="window.hexEditor?.undoLastZonePoint()" style="background: #ff9800; border: none; padding: 4px 8px; border-radius: 3px; cursor: pointer; color: white;">Undo</button>
        <button onclick="window.hexEditor?.cancelZoneDrawing()" style="background: #f44336; border: none; padding: 4px 8px; border-radius: 3px; cursor: pointer; color: white;">Cancel</button>
      `;
      statusEl.style.display = 'flex';
    } else {
      statusEl.style.display = 'none';
    }
  }

  // Calculate direction from hex A to hex B (for directional features)
  // Returns one of: 'n', 'ne', 'se', 's', 'sw', 'nw' or null if not adjacent
  getHexDirection(fromX, fromY, toX, toY) {
    const dx = toX - fromX;
    const dy = toY - fromY;

    // For flat-top hexes with offset coordinates:
    // Even columns (0, 2, 4...): neighbors are offset differently than odd columns
    const isFromEvenCol = (fromX % 2 === 0);

    // Check each direction based on offset hex geometry
    // In this grid, moving vertically is +/- Y, diagonals depend on column parity
    if (dx === 0 && dy < 0) return 'n';
    if (dx === 0 && dy > 0) return 's';

    // For diagonals, the y-offset depends on whether we're in an even or odd column
    if (isFromEvenCol) {
      // Even column: NE/NW are at same y, SE/SW are at y+1
      if (dx > 0 && dy === 0) return 'ne';
      if (dx < 0 && dy === 0) return 'nw';
      if (dx > 0 && dy > 0) return 'se';
      if (dx < 0 && dy > 0) return 'sw';
    } else {
      // Odd column: NE/NW are at y-1, SE/SW are at same y
      if (dx > 0 && dy < 0) return 'ne';
      if (dx < 0 && dy < 0) return 'nw';
      if (dx > 0 && dy === 0) return 'se';
      if (dx < 0 && dy === 0) return 'sw';
    }

    // Approximate direction for non-adjacent hexes
    if (dx > 0 && dy < 0) return 'ne';
    if (dx > 0 && dy > 0) return 'se';
    if (dx < 0 && dy < 0) return 'nw';
    if (dx < 0 && dy > 0) return 'sw';
    if (dx > 0) return 'ne'; // Default east-ish to northeast
    if (dx < 0) return 'nw'; // Default west-ish to northwest

    return null;
  }

  // Get the opposite direction
  getOppositeDirection(dir) {
    const opposites = {
      'n': 's', 's': 'n',
      'ne': 'sw', 'sw': 'ne',
      'se': 'nw', 'nw': 'se'
    };
    return opposites[dir] || null;
  }

  // Get the edge midpoint between two hex centers for rendering
  getHexEdgeMidpoint(fromX, fromY, toX, toY) {
    // Calculate screen positions for both hexes
    const startCol = Math.floor(this.viewportX);
    const startRow = Math.floor(this.viewportY);
    const offsetX = (this.viewportX - startCol) * this.horizSpacing;
    const offsetY = (this.viewportY - startRow) * this.vertSpacing;

    const relColFrom = fromX - startCol;
    const relRowFrom = fromY - startRow;
    const posFrom = this.hexToPixel(relColFrom, relRowFrom);
    const screenFromX = posFrom.x - offsetX;
    const screenFromY = posFrom.y - offsetY;

    const relColTo = toX - startCol;
    const relRowTo = toY - startRow;
    const posTo = this.hexToPixel(relColTo, relRowTo);
    const screenToX = posTo.x - offsetX;
    const screenToY = posTo.y - offsetY;

    // Return midpoint (edge crossing)
    return {
      x: (screenFromX + screenToX) / 2,
      y: (screenFromY + screenToY) / 2
    };
  }

  // Feature Tool: Draw a feature (road, river, etc.) between hexes
  drawFeature(worldX, worldY) {
    this.isDrawingFeature = true;

    // Get hex info to store lat/lng for saving
    const key = `${worldX},${worldY}`;
    const hexInfo = this.hexCache.get(key) || {};

    this.featurePoints.push({
      x: worldX,
      y: worldY,
      lat: hexInfo.lat,
      lng: hexInfo.lng,
      globe_hex_id: hexInfo.globe_hex_id
    });

    // Update status indicator
    this.updateDrawingStatus();

    // Show path preview (but don't save until finish)
    this.render();

    // If we have 2+ points, show finish hint
    if (this.featurePoints.length >= 2) {
      console.log('Feature: Press Enter, double-click, or right-click to finish');
    }
  }

  // Finish current feature line and save it.
  // Traces through all intermediate hexes between clicked waypoints,
  // creating proper directional features on each hex edge.
  finishFeatureLine() {
    // Use native mode path if Voronoi renderer is active
    if (this.nativeHexRenderer && this.nativeHexRenderer.isActive()) {
      this._finishNativeFeatureLine();
      return;
    }
    if (this.featurePoints.length >= 2) {
      // Build full path through all intermediate hexes
      const fullPath = [];
      for (let i = 0; i < this.featurePoints.length - 1; i++) {
        const from = this.featurePoints[i];
        const to = this.featurePoints[i + 1];
        const segment = this.traceHexLine(from.x, from.y, to.x, to.y);

        // Append segment (skip first if it overlaps with previous segment end)
        segment.forEach((pt, idx) => {
          if (idx === 0 && fullPath.length > 0 &&
              fullPath[fullPath.length - 1].x === pt.x &&
              fullPath[fullPath.length - 1].y === pt.y) return;
          fullPath.push(pt);
        });
      }

      // Convert adjacent pairs to directional features
      const directionalFeatures = [];
      for (let i = 0; i < fullPath.length - 1; i++) {
        const from = fullPath[i];
        const to = fullPath[i + 1];
        const fromKey = `${from.x},${from.y}`;
        const toKey = `${to.x},${to.y}`;
        const fromInfo = this.hexCache.get(fromKey) || {};
        const toInfo = this.hexCache.get(toKey) || {};

        const direction = this.getHexDirection(from.x, from.y, to.x, to.y);
        const oppositeDir = this.getOppositeDirection(direction);

        if (direction) {
          directionalFeatures.push({
            globe_hex_id: fromInfo.globe_hex_id,
            lat: fromInfo.lat,
            lng: fromInfo.lng,
            direction: direction,
            type: this.selectedFeature
          });

          if (oppositeDir) {
            directionalFeatures.push({
              globe_hex_id: toInfo.globe_hex_id,
              lat: toInfo.lat,
              lng: toInfo.lng,
              direction: oppositeDir,
              type: this.selectedFeature
            });
          }
        }
      }

      // Store directional features
      this.directionalFeatures.push(...directionalFeatures);

      // Save the traced path for rendering (not just the clicked waypoints)
      this.features.push({
        type: this.selectedFeature,
        points: fullPath.map(p => ({ x: p.x, y: p.y }))
      });

      // Mark all hexes along the path as dirty
      fullPath.forEach(point => {
        this.dirtyHexes.add(`${point.x},${point.y}`);
      });

      console.log(`Feature: Completed ${this.selectedFeature} through ${fullPath.length} hexes, ${directionalFeatures.length} directional entries`);

      // Ask for an optional name for this feature
      const featureName = prompt(`Name this ${this.selectedFeature} (leave blank for unnamed):`, '');
      if (featureName && featureName.trim()) {
        directionalFeatures.forEach(f => {
          f.feature_name = featureName.trim();
        });
      }

      // Auto-save directional features to API
      this.saveDirectionalFeatures(directionalFeatures);
    }

    this.featurePoints = [];
    this.isDrawingFeature = false;
    this.updateDrawingStatus();
    this.render();
  }

  // Save directional features to the API
  async saveDirectionalFeatures(features) {
    if (!features || features.length === 0) return;

    try {
      const apiBase = window.API_BASE || `/admin/world_builder/${this.worldId}/api`;
      const csrfToken = window.CSRF_TOKEN || document.querySelector('meta[name="csrf-token"]')?.content;

      const response = await fetch(`${apiBase}/features`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': csrfToken
        },
        body: JSON.stringify({ directional_features: features })
      });

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }

      const result = await response.json();
      console.log('Features saved:', result);

      // If features had names, reload to get IDs and refresh labels
      if (features.some(f => f.feature_name)) {
        await this.loadFeatures();
      }
    } catch (error) {
      console.error('Failed to save features:', error);
    }
  }

  // Undo last feature point
  undoLastFeaturePoint() {
    if (this.featurePoints.length > 0) {
      this.featurePoints.pop();
      if (this.featurePoints.length === 0) {
        this.isDrawingFeature = false;
      }
      this.updateDrawingStatus();
      this.render();
    }
  }

  // Cancel feature drawing
  cancelFeatureDrawing() {
    this.featurePoints = [];
    this.isDrawingFeature = false;
    this.updateDrawingStatus();
    this.render();
  }

  // Toggle hex traversability
  toggleTraversable(worldX, worldY) {
    const key = `${worldX},${worldY}`;
    let hexInfo = this.hexCache.get(key) || { terrain: 'ocean' };

    // Toggle traversable (default is true)
    hexInfo = {
      ...hexInfo,
      traversable: hexInfo.traversable === false ? true : false,
      worldX,
      worldY
    };

    this.updateCachedHex(hexInfo);
    this.render();

    console.log(`Hex (${worldX}, ${worldY}) traversable: ${hexInfo.traversable}`);

    // Auto-save traversability change immediately
    this.saveHexChange(hexInfo);
  }

  // Navigate to specific world coordinates
  navigateTo(worldX, worldY) {
    if (this.isUnwrappedNativeMode) {
      const targetHex = this.getCachedHex(worldX, worldY)
        || this.findNearestLocalPatchHexByGridCoords(worldX, worldY);
      if (!targetHex) return;

      this.nativeViewX = targetHex.projectedX ?? this.nativeViewX;
      this.nativeViewY = targetHex.projectedY ?? this.nativeViewY;
      this.clampProjectedNativeView();
      this.syncNativeCenterFromViewport();
      this.render();
      this.maybeRecenterNativePatch();
      return;
    }

    this.viewportX = worldX - Math.floor(this.visibleCols / 2);
    this.viewportY = worldY - Math.floor(this.visibleRows / 2);
    this.render();
    if (this.isUnwrappedNativeMode) {
      this.maybeRecenterNativePatch();
    } else {
      this.loadVisibleHexes();
    }
  }

  // Tool setters
  setTool(tool) {
    this.selectedTool = tool;
    if (this.svg && !this.isPanning && !this.spacePressed) {
      // Select tool shows grab cursor to indicate pan is available
      // Other tools show crosshair for precision work
      this.svg.style.cursor = tool === 'select' ? 'grab' : 'crosshair';
    }
  }

  setTerrain(terrain) {
    this.selectedTerrain = terrain;
  }

  setFeature(feature) {
    this.selectedFeature = feature;
  }

  // Save dirty hexes
  async save() {
    if (this.dirtyHexes.size === 0) {
      console.log('No changes to save');
      return;
    }

    const hexesToSave = [];
    this.dirtyHexes.forEach(key => {
      const hexInfo = this.hexCache.get(key);
      if (hexInfo) {
        hexesToSave.push({
          x: hexInfo.worldX,
          y: hexInfo.worldY,
          terrain: hexInfo.terrain,
          traversable: hexInfo.traversable !== false,
          ...hexInfo
        });
      }
    });

    this.onSave({
      origin: this.regionOrigin,
      hexes: hexesToSave
    });

    this.dirtyHexes.clear();
    this.render();
  }

  async show() {
    this.container.style.display = 'block';
    this.render();
    await this.loadVisibleHexes();
    await Promise.all([
      this.loadCities(),
      this.loadFeatures(),
      this.loadZones()
    ]);
  }

  hide() {
    // All changes are auto-saved now, so no confirmation needed
    this.container.style.display = 'none';
  }

  get isDirty() {
    return this.dirtyHexes.size > 0;
  }

  // --- Data resolution zoom for globe worlds ---

  // Zoom levels: degrees per cell, or 'native' for true hex resolution (~5km)
  static CELL_SIZE_LEVELS = [1.0, 0.5, 0.2, 0.1, 'native'];

  // Effective cell size in degrees (for coordinate math)
  get effectiveCellSize() {
    return this.cellSize === 'native' ? 0.045 : this.cellSize;
  }

  get isNativeMode() {
    return this.cellSize === 'native';
  }

  get isUnwrappedNativeMode() {
    return this.isNativeMode && this.nativeLayoutMode === 'unwrap';
  }

  get hasLoadedProjectedNativePatch() {
    if (this.nativeHexRenderer && this.nativeHexRenderer.isActive()) {
      return !!this.voronoiLoaded;
    }
    return this.isUnwrappedNativeMode && !!this.localPatchBounds && this.hexCache.size > 0;
  }

  loadingStatusMessage() {
    if (this.isUnwrappedNativeMode) {
      return this.hasLoadedProjectedNativePatch
        ? 'Refreshing 5 km hexes...'
        : 'Loading 5 km island...';
    }

    return 'Loading hex region...';
  }

  notifyLoadingState() {
    this.onLoadingStateChange({
      isLoading: this.isLoading,
      isNativeMode: this.isUnwrappedNativeMode,
      nativePatchReady: this.hasLoadedProjectedNativePatch,
      message: this.isLoading ? this.loadingStatusMessage() : ''
    });
  }

  zoomCellSizeIn() {
    const levels = HexEditor.CELL_SIZE_LEVELS;
    const curEff = this.effectiveCellSize;
    const idx = levels.findIndex(l => (l === 'native' ? 0.045 : l) <= curEff);
    const nextIdx = Math.min((idx >= 0 ? idx : 0) + 1, levels.length - 1);
    this._setCellSize(levels[nextIdx]);
  }

  zoomCellSizeOut() {
    const levels = HexEditor.CELL_SIZE_LEVELS;
    const curEff = this.effectiveCellSize;
    const idx = levels.findIndex(l => (l === 'native' ? 0.045 : l) <= curEff);
    const nextIdx = Math.max((idx >= 0 ? idx : levels.length - 1) - 1, 0);
    this._setCellSize(levels[nextIdx]);
  }

  _setCellSize(newSize) {
    if (newSize === this.cellSize) return;

    const wasNative = this.isNativeMode;
    const oldEff = this.effectiveCellSize;

    // Compute current geographic center regardless of mode
    let centerLng, centerLat;
    if (wasNative) {
      centerLng = this.nativeCenterLng;
      centerLat = this.nativeCenterLat;
    } else {
      const centerCol = this.viewportX + this.visibleCols / 2;
      const centerRow = this.viewportY + this.visibleRows / 2;
      centerLng = (centerCol * oldEff) - 180;
      centerLat = 90 - (centerRow * oldEff);
    }

    this.cellSize = newSize;
    const newEff = this.effectiveCellSize;

    if (newSize === 'native') {
      const currentCenterHex = this.getCurrentPatchCenterHex();
      this.pendingPatchCenterHexId = this.pendingPatchCenterHexId
        || currentCenterHex?.globe_hex_id
        || this.localPatchCenterHexId
        || null;
      this.localPatchCenterHexId = null;
      this.localPatchBounds = null;
    }

    // Convert geographic center to new viewport coordinates
    if (this.isNativeMode) {
      // Entering native mode
      this.nativeCenterLat = centerLat;
      this.nativeCenterLng = centerLng;
    } else {
      // Entering or staying in grid mode
      this.viewportX = ((centerLng + 180) / newEff) - this.visibleCols / 2;
      this.viewportY = ((90 - centerLat) / newEff) - this.visibleRows / 2;
    }

    this.hexCache.clear();

    // Activate/deactivate Three.js native hex renderer
    if (this.isNativeMode && typeof VoronoiHexRenderer !== 'undefined') {
      if (!this.nativeHexRenderer) {
        this.nativeHexRenderer = new VoronoiHexRenderer(this.container, {
          apiBase: window.API_BASE || `/admin/world_builder/${this.worldId}/api`,
          csrfToken: window.CSRF_TOKEN || '',
          onHexClick: (hexId, hexData) => {
            this._onNativeHexClick(hexId, hexData);
          },
          onLoad: (count) => {
            this.voronoiLoaded = true;
            this.notifyLoadingState();
          },
          canDrag: () => {
            // Only select tool drags to pan; all other tools click to act
            return !this.selectedTool || this.selectedTool === 'select';
          }
        });
      }
      this.nativeHexRenderer.show(centerLat, centerLng);
      // Skip the old gnomonic rendering pipeline
      this.render();
      this.notifyLoadingState();
      return;
    } else if (this.nativeHexRenderer) {
      this.nativeHexRenderer.hide();
      // Restore canvas visibility
      if (this.canvas) this.canvas.style.display = '';
      if (this.svg) this.svg.style.display = '';
    }

    this.render();
    this.notifyLoadingState();
    this.loadVisibleHexes();
  }

  _onNativeHexClick(hexId, hexData) {
    // Route click through to the appropriate tool handler
    if (this.selectedTool === 'select' || !this.selectedTool) {
      // Open the sub-hex editor for this hex
      this.selectedHex = hexData;
      if (this.onHexSelect) this.onHexSelect(hexData);
      this.openSubHexEditorForHex({
        globe_hex_id: hexData.globe_hex_id,
        lat: hexData.latitude,
        lng: hexData.longitude,
        terrain: hexData.terrain_type,
        projectedX: hexData.longitude,
        projectedY: hexData.latitude
      });
    } else if (this.selectedTool === 'terrain') {
      var brushHexes = this.nativeHexRenderer.getHexNeighbors(hexId, this.brushSize || 1);
      var undoActions = [];
      brushHexes.forEach(hid => {
        var cached = this.nativeHexRenderer.hexCache[hid];
        if (!cached) return;
        var oldTerrain = cached.data.terrain_type;
        if (oldTerrain === this.selectedTerrain) return;

        undoActions.push({
          globe_hex_id: hid,
          field: 'terrain_type',
          old_value: oldTerrain,
          new_value: this.selectedTerrain
        });

        cached.data.terrain_type = this.selectedTerrain;
        this.nativeHexRenderer.recolorHex(hid, this.selectedTerrain, cached.data.traversable);

        if (!this._nativeDirtyHexes) this._nativeDirtyHexes = new Map();
        if (!this._nativeDirtyHexes.has(hid)) this._nativeDirtyHexes.set(hid, {});
        this._nativeDirtyHexes.get(hid).terrain_type = this.selectedTerrain;
        this._nativeDirtyHexes.get(hid).globe_hex_id = hid;
      });

      // Auto-save after painting
      this._saveNativeDirtyHexes();

      if (undoActions.length > 0) {
        if (!this.undoStack) this.undoStack = [];
        this.undoStack.push(undoActions);
        this.redoStack = [];
      }
    } else if (this.selectedTool === 'traversable') {
      var cached = this.nativeHexRenderer.hexCache[hexId];
      if (!cached) return;
      var newVal = !cached.data.traversable;
      var brushHexes = this.nativeHexRenderer.getHexNeighbors(hexId, this.brushSize || 1);

      brushHexes.forEach(hid => {
        var c = this.nativeHexRenderer.hexCache[hid];
        if (!c) return;
        c.data.traversable = newVal;
        this.nativeHexRenderer.recolorHex(hid, c.data.terrain_type, newVal);

        if (!this._nativeDirtyHexes) this._nativeDirtyHexes = new Map();
        if (!this._nativeDirtyHexes.has(hid)) this._nativeDirtyHexes.set(hid, {});
        this._nativeDirtyHexes.get(hid).traversable = newVal;
        this._nativeDirtyHexes.get(hid).globe_hex_id = hid;
      });

      this._saveNativeDirtyHexes();
    } else if (this.selectedTool === 'city') {
      // Populate the city modal fields directly since hexCache uses different keys in Voronoi mode
      document.getElementById('city-hex-x').value = hexData.longitude;
      document.getElementById('city-hex-y').value = hexData.latitude;
      var globeHexIdField = document.getElementById('city-globe-hex-id');
      if (globeHexIdField) globeHexIdField.value = hexData.globe_hex_id || '';
      var coordsDisplay = document.getElementById('city-coords-display');
      if (coordsDisplay) coordsDisplay.textContent = 'Hex #' + hexData.globe_hex_id + ' (' + hexData.latitude.toFixed(2) + ', ' + hexData.longitude.toFixed(2) + ')';
      var modal = document.getElementById('cityModal');
      if (modal && modal.showModal) modal.showModal();
    } else if (this.selectedTool === 'zone') {
      this.isDrawingZone = true;
      this.zonePoints.push({
        x: hexData.longitude,
        y: hexData.latitude,
        lat: hexData.latitude,
        lng: hexData.longitude,
        globe_hex_id: hexData.globe_hex_id
      });
      this.updateDrawingStatus();
      if (this.zonePoints.length >= 3) {
        console.log('Zone: Press Enter, double-click, or right-click to finish polygon');
      }
    } else if (this.selectedTool === 'feature') {
      this.isDrawingFeature = true;
      // In native mode, trace through neighbor hexes between waypoints
      var newPoint = {
        x: hexData.longitude, y: hexData.latitude,
        lat: hexData.latitude, lng: hexData.longitude,
        globe_hex_id: hexData.globe_hex_id
      };
      if (this.featurePoints.length > 0) {
        // Trace path from last point to this one through adjacent hexes
        var lastPoint = this.featurePoints[this.featurePoints.length - 1];
        var traced = this._traceNativeHexLine(lastPoint.globe_hex_id, hexData.globe_hex_id);
        // Add intermediate hexes (skip first since it's the last point)
        for (var ti = 1; ti < traced.length; ti++) {
          var trHex = traced[ti];
          this.featurePoints.push({
            x: trHex.longitude, y: trHex.latitude,
            lat: trHex.latitude, lng: trHex.longitude,
            globe_hex_id: trHex.globe_hex_id
          });
        }
      } else {
        this.featurePoints.push(newPoint);
      }
      this.updateDrawingStatus();
    } else if (this.selectedTool === 'link') {
      this.selectCityForLink(hexData.longitude, hexData.latitude);
    }
  }
}

/**
 * WorldMinimap - Rotating globe that shows the current viewport area centered
 *
 * The globe rotates as you pan the map, keeping the current viewing area
 * at the center of the sphere. Uses orthographic projection for 3D effect.
 */
class WorldMinimap {
  constructor(containerId, options = {}) {
    this.container = document.getElementById(containerId);
    this.worldId = options.worldId || window.WORLD_ID;
    this.onNavigate = options.onNavigate || (() => {});

    // Canvas for rendering - use 2x resolution for retina displays
    this.canvas = document.createElement('canvas');
    this.canvas.width = 300;
    this.canvas.height = 300;
    this.canvas.style.width = '100%';
    this.canvas.style.height = '100%';
    this.container.innerHTML = '';
    this.container.appendChild(this.canvas);

    // World bounds (will be loaded from API)
    this.worldBounds = { minX: -50, maxX: 50, minY: -50, maxY: 50 };

    // Current viewport (center position)
    this.viewport = { x: 0, y: 0, width: 20, height: 15 };

    // Globe rotation (in radians) - controlled by viewport position
    this.rotationLon = 0;  // Longitude rotation (left-right panning)
    this.rotationLat = 0;  // Latitude rotation (up-down panning)

    // Terrain data (simplified)
    this.terrainData = [];

    // Terrain colors
    this.terrainColors = {
      o: '#2d5f8a', // ocean
      l: '#4a8ab5', // lake
      c: '#8a9a8d', // coast
      p: '#a8b878', // plain
      f: '#c4ba8a', // field
      F: '#3a6632', // forest
      h: '#96a07a', // hill
      m: '#8a7d6b', // mountain
      d: '#c8b48a', // desert
      s: '#5a6b48', // swamp
      u: '#7a7a7a', // urban
      i: '#d8e0e4'  // ice
    };

    this.bindEvents();
  }

  bindEvents() {
    this.canvas.addEventListener('click', (e) => this.handleClick(e));
    this.canvas.style.cursor = 'pointer';
  }

  async loadOverview() {
    try {
      const apiBase = window.API_BASE || `/admin/world_builder/${this.worldId}/api`;
      const resp = await fetch(`${apiBase}/world_overview`);

      if (resp.ok) {
        const data = await resp.json();
        if (data.bounds) this.worldBounds = data.bounds;
        if (data.terrain) this.terrainData = data.terrain;
      }
    } catch (error) {
      console.error('Failed to load world overview:', error);
    }

    this.render();
  }

  setViewport(x, y, width, height) {
    this.viewport = { x, y, width, height };

    // Convert viewport position to globe rotation
    // Map world coordinates to longitude/latitude
    const { minX, maxX, minY, maxY } = this.worldBounds;
    const worldWidth = maxX - minX || 100;
    const worldHeight = maxY - minY || 100;

    // Center of viewport in normalized coordinates (0-1)
    const centerX = (x + width / 2 - minX) / worldWidth;
    const centerY = (y + height / 2 - minY) / worldHeight;

    // Convert to rotation angles
    // Longitude: 0-1 maps to -PI to PI (full rotation around)
    // Latitude: 0-1 maps to PI/2 to -PI/2 (pole to pole)
    this.rotationLon = (centerX - 0.5) * Math.PI * 2;
    this.rotationLat = (0.5 - centerY) * Math.PI;

    this.render();
  }

  /**
   * Project a point from world coordinates to screen coordinates on the globe
   * Uses orthographic projection with rotation
   */
  projectPoint(worldX, worldY) {
    const { minX, maxX, minY, maxY } = this.worldBounds;
    const worldWidth = maxX - minX || 100;
    const worldHeight = maxY - minY || 100;

    // Convert world coords to spherical coordinates (lon, lat)
    const normX = (worldX - minX) / worldWidth;  // 0-1
    const normY = (worldY - minY) / worldHeight; // 0-1

    // Map to longitude (-PI to PI) and latitude (PI/2 to -PI/2)
    const lon = (normX - 0.5) * Math.PI * 2;
    const lat = (0.5 - normY) * Math.PI;

    // Apply rotation (subtract current rotation to center viewport)
    const rotatedLon = lon - this.rotationLon;
    const rotatedLat = lat - this.rotationLat;

    // Convert to 3D cartesian coordinates on unit sphere
    const cosLat = Math.cos(rotatedLat);
    const x3d = Math.cos(rotatedLon) * cosLat;
    const y3d = Math.sin(rotatedLat);
    const z3d = Math.sin(rotatedLon) * cosLat;

    // Orthographic projection (looking down -Z axis)
    // Only render points on the visible hemisphere (z > 0 means facing us)
    if (x3d < -0.1) return null; // Behind the globe (with small margin)

    // Project to 2D (Y is up, Z is right in screen space)
    const screenX = z3d;
    const screenY = -y3d;

    // Return normalized screen coords (-1 to 1) and depth for shading
    return { x: screenX, y: screenY, depth: x3d };
  }

  render() {
    const ctx = this.canvas.getContext('2d');
    const w = this.canvas.width;
    const h = this.canvas.height;
    const centerX = w / 2;
    const centerY = h / 2;
    const radius = Math.min(w, h) / 2 - 4;

    // Clear canvas
    ctx.clearRect(0, 0, w, h);

    // Create circular clipping path
    ctx.save();
    ctx.beginPath();
    ctx.arc(centerX, centerY, radius, 0, Math.PI * 2);
    ctx.clip();

    // Draw globe background with gradient (ocean + sphere shading)
    const bgGradient = ctx.createRadialGradient(
      centerX + radius * 0.2, centerY - radius * 0.2, 0,
      centerX, centerY, radius
    );
    bgGradient.addColorStop(0, '#5a9ac0');
    bgGradient.addColorStop(0.4, '#4a8ab5');
    bgGradient.addColorStop(0.8, '#2d5f8a');
    bgGradient.addColorStop(1, '#1a3a5a');
    ctx.fillStyle = bgGradient;
    ctx.fillRect(0, 0, w, h);

    // Draw terrain data with spherical projection
    if (this.terrainData.length > 0) {
      // Sort by depth so closer points draw on top
      const projectedTerrain = [];

      this.terrainData.forEach(hex => {
        // Skip ocean (already in background)
        if (hex.t === 'o') return;

        const projected = this.projectPoint(hex.x, hex.y);
        if (projected) {
          projectedTerrain.push({
            ...hex,
            screenX: centerX + projected.x * radius,
            screenY: centerY + projected.y * radius,
            depth: projected.depth
          });
        }
      });

      // Sort by depth (back to front)
      projectedTerrain.sort((a, b) => a.depth - b.depth);

      // Draw terrain points
      projectedTerrain.forEach(hex => {
        const color = this.terrainColors[hex.t] || '#333';

        // Size varies slightly with depth (closer = slightly larger)
        const size = 2.5 + hex.depth * 1.5;

        // Darken points at the edge of the globe
        const brightness = 0.5 + hex.depth * 0.5;

        ctx.fillStyle = this.adjustBrightness(color, brightness);
        ctx.beginPath();
        ctx.arc(hex.screenX, hex.screenY, size, 0, Math.PI * 2);
        ctx.fill();
      });
    }

    // Draw a subtle grid/latitude lines for depth perception
    ctx.strokeStyle = 'rgba(255, 255, 255, 0.1)';
    ctx.lineWidth = 1;

    // Draw equator and a few latitude lines
    for (let latDeg = -60; latDeg <= 60; latDeg += 30) {
      const lat = (latDeg / 180) * Math.PI;
      ctx.beginPath();
      for (let lonDeg = -180; lonDeg <= 180; lonDeg += 5) {
        const lon = (lonDeg / 180) * Math.PI;
        const rotatedLon = lon - this.rotationLon;
        const rotatedLat = lat - this.rotationLat;

        const cosLat = Math.cos(rotatedLat);
        const x3d = Math.cos(rotatedLon) * cosLat;
        const y3d = Math.sin(rotatedLat);
        const z3d = Math.sin(rotatedLon) * cosLat;

        if (x3d > 0) {
          const sx = centerX + z3d * radius;
          const sy = centerY - y3d * radius;
          if (lonDeg === -180) ctx.moveTo(sx, sy);
          else ctx.lineTo(sx, sy);
        }
      }
      ctx.stroke();
    }

    ctx.restore();

    // Draw sphere highlight (glossy effect)
    ctx.save();
    const highlightGradient = ctx.createRadialGradient(
      centerX + radius * 0.3, centerY - radius * 0.3, 0,
      centerX, centerY, radius
    );
    highlightGradient.addColorStop(0, 'rgba(255, 255, 255, 0.3)');
    highlightGradient.addColorStop(0.2, 'rgba(255, 255, 255, 0.1)');
    highlightGradient.addColorStop(0.5, 'rgba(255, 255, 255, 0)');
    highlightGradient.addColorStop(1, 'rgba(0, 0, 0, 0.2)');

    ctx.beginPath();
    ctx.arc(centerX, centerY, radius, 0, Math.PI * 2);
    ctx.fillStyle = highlightGradient;
    ctx.fill();

    // Rim lighting effect
    ctx.strokeStyle = 'rgba(255, 255, 255, 0.3)';
    ctx.lineWidth = 2;
    ctx.stroke();
    ctx.restore();
  }

  /**
   * Adjust color brightness
   */
  adjustBrightness(color, factor) {
    // Parse hex color
    const hex = color.replace('#', '');
    const r = parseInt(hex.substr(0, 2), 16);
    const g = parseInt(hex.substr(2, 2), 16);
    const b = parseInt(hex.substr(4, 2), 16);

    // Adjust and clamp
    const newR = Math.min(255, Math.max(0, Math.round(r * factor)));
    const newG = Math.min(255, Math.max(0, Math.round(g * factor)));
    const newB = Math.min(255, Math.max(0, Math.round(b * factor)));

    return `rgb(${newR}, ${newG}, ${newB})`;
  }

  handleClick(e) {
    const rect = this.canvas.getBoundingClientRect();
    const clickX = (e.clientX - rect.left) / rect.width * 2 - 1;  // -1 to 1
    const clickY = (e.clientY - rect.top) / rect.height * 2 - 1;  // -1 to 1

    // Check if click is within the globe circle
    const dist = Math.sqrt(clickX * clickX + clickY * clickY);
    if (dist > 1) return;

    // Reverse the projection to get world coordinates
    // Screen coords to 3D (assuming orthographic projection)
    const z3d = clickX;
    const y3d = -clickY;
    const x3d = Math.sqrt(Math.max(0, 1 - z3d * z3d - y3d * y3d));

    // Convert back to spherical with current rotation
    const rotatedLat = Math.asin(y3d);
    const rotatedLon = Math.atan2(z3d, x3d);

    // Add back the rotation offset
    const lon = rotatedLon + this.rotationLon;
    const lat = rotatedLat + this.rotationLat;

    // Convert to world coordinates
    const { minX, maxX, minY, maxY } = this.worldBounds;
    const worldWidth = maxX - minX || 100;
    const worldHeight = maxY - minY || 100;

    const normX = (lon / (Math.PI * 2)) + 0.5;
    const normY = 0.5 - (lat / Math.PI);

    const worldX = Math.round(minX + normX * worldWidth);
    const worldY = Math.round(minY + normY * worldHeight);

    this.onNavigate(worldX, worldY);
  }
}

// Make available globally
window.HexEditor = HexEditor;
window.WorldMinimap = WorldMinimap;
