// backend/public/js/world-builder/voronoi-hex-renderer.js
// Flat 2D hex renderer using Voronoi boundary data from the server.
// Renders hex polygons on a flat lat/lon plane with orthographic camera.
'use strict';

class VoronoiHexRenderer {
  constructor(container, options) {
    this.container = container;
    this.apiBase = options.apiBase;
    this.csrfToken = options.csrfToken;
    this.onHexClick = options.onHexClick || null;
    this.onLoad = options.onLoad || null;
    this.canDrag = options.canDrag || null;

    this.hexCache = {};
    this.hexNeighbors = {};
    this._pendingFetch = false;
    this._lastViewport = null;
    this._active = false;

    // Terrain color lookup
    this.terrainColors = {};
    this.terrainNames = [];
    if (typeof TERRAIN_TYPES !== 'undefined' && Array.isArray(TERRAIN_TYPES)) {
      TERRAIN_TYPES.forEach(function(t) {
        if (typeof t === 'object') {
          this.terrainNames.push(t.id);
          this.terrainColors[t.id] = this._parseColor(t.color || '#888888');
        } else {
          this.terrainNames.push(t);
        }
      }.bind(this));
    }

    // Feature colors (RGB 0-1)
    this.featureColors = {
      road:    { r: 0.50, g: 0.55, b: 0.56 },
      highway: { r: 0.17, g: 0.24, b: 0.31 },
      street:  { r: 0.74, g: 0.76, b: 0.78 },
      trail:   { r: 0.63, g: 0.25, b: 0.00 },
      river:   { r: 0.20, g: 0.60, b: 0.86 },
      canal:   { r: 0.18, g: 0.53, b: 0.76 },
      railway: { r: 0.11, g: 0.15, b: 0.20 }
    };
    this._featureLineData = [];

    this._initThree();
  }

  _parseColor(hex) {
    hex = hex.replace('#', '');
    return {
      r: parseInt(hex.substring(0, 2), 16) / 255,
      g: parseInt(hex.substring(2, 4), 16) / 255,
      b: parseInt(hex.substring(4, 6), 16) / 255
    };
  }

  _initThree() {
    var w = this.container.clientWidth || 800;
    var h = this.container.clientHeight || 600;

    this.scene = new THREE.Scene();
    this.scene.background = new THREE.Color(0x4a4a4a); // Grey for unloaded areas

    // Orthographic camera: x = longitude, y = latitude, z = up
    // _viewSize = degrees of latitude visible vertically
    this._viewSize = 2.0;
    var aspect = w / h;
    this.camera = new THREE.OrthographicCamera(
      -this._viewSize * aspect / 2, this._viewSize * aspect / 2,
      this._viewSize / 2, -this._viewSize / 2,
      0.1, 100
    );
    this.camera.position.set(0, 0, 10);
    this.camera.lookAt(0, 0, 0);

    this.renderer3d = new THREE.WebGLRenderer({ antialias: true });
    this.renderer3d.setSize(w, h);
    this.renderer3d.setPixelRatio(window.devicePixelRatio);
    this.renderer3d.domElement.style.cssText = 'position:absolute;top:0;left:0;width:100%;height:100%;display:none;z-index:5;';
    this.container.appendChild(this.renderer3d.domElement);

    // Pan/zoom state
    this._centerLat = 0;
    this._centerLon = 0;
    // The lat/lon that was used as origin when chunks were built
    this._chunkOriginLat = 0;
    this._chunkOriginLon = 0;
    this._isDragging = false;
    this._didDrag = false;
    this._dragStartX = 0;
    this._dragStartY = 0;
    this._dragStartLat = 0;
    this._dragStartLon = 0;

    var canvas = this.renderer3d.domElement;
    canvas.addEventListener('mousedown', this._onMouseDown.bind(this));
    canvas.addEventListener('mousemove', this._onMouseMove.bind(this));
    canvas.addEventListener('mouseup', this._onMouseUp.bind(this));
    canvas.addEventListener('mouseleave', this._onMouseUp.bind(this));
    canvas.addEventListener('wheel', this._onWheel.bind(this), { passive: false });
    canvas.addEventListener('click', this._onClick.bind(this));
    canvas.addEventListener('contextmenu', function(e) { e.preventDefault(); });

    // Mesh state: array of { fillMesh, edgeLines, triToHexId } chunks
    this._chunks = [];
    this._tiltAngle = null; // measured once from first batch
    this.fillMesh = null; // kept for picking compat (points to last chunk)
    this.triToHexId = [];
    this.raycaster = new THREE.Raycaster();
    this.mouse = new THREE.Vector2();

    this._resizeObserver = new ResizeObserver(this._onResize.bind(this));
    this._resizeObserver.observe(this.container);
  }

  // --- Public API ---

  show(centerLat, centerLon) {
    this._active = true;
    this.renderer3d.domElement.style.display = 'block';
    this._onResize();
    this._centerLat = centerLat;
    this._centerLon = centerLon;
    this._chunkOriginLat = centerLat;
    this._chunkOriginLon = centerLon;
    this._updateCamera();
    this._loadHexes();
    this._loadZones();
    this._animate();
  }

  hide() {
    this._active = false;
    this.renderer3d.domElement.style.display = 'none';
    this._clearChunks();
    this._clearZones();
  }

  isActive() { return this._active; }

  zoomIn() {
    this._viewSize = Math.max(0.05, this._viewSize * 0.87);
    this._updateCamera();
    this._updateEdgeVisibility();
    this._clearChunks();
    this.hexCache = {};
    this._tiltAngle = null;
    this._lastViewport = null;
    this._pendingFetch = false;
  }

  zoomOut() {
    this._viewSize = Math.min(90, this._viewSize * 1.15);
    this._updateCamera();
    this._updateEdgeVisibility();
    this._clearChunks();
    this.hexCache = {};
    this._tiltAngle = null;
    this._lastViewport = null;
    this._pendingFetch = false;
  }

  recolorHex(hexId, terrainType, traversable) {
    var cached = this.hexCache[hexId];
    if (!cached || cached.chunkIndex === undefined) return;

    var rgb = traversable === false
      ? { r: 0.67, g: 0.13, b: 0.13 }
      : (this.terrainColors[terrainType] || { r: 0.53, g: 0.53, b: 0.53 });

    var chunk = this._chunks[cached.chunkIndex];
    if (!chunk) return;

    var colors = chunk.fillMesh.geometry.getAttribute('color');
    if (!colors) return;

    // Update all vertices for this hex (center + boundary)
    for (var i = 0; i < cached.vertexCount; i++) {
      var vi = (cached.vertexStart + i) * 3;
      colors.array[vi] = rgb.r;
      colors.array[vi + 1] = rgb.g;
      colors.array[vi + 2] = rgb.b;
    }
    colors.needsUpdate = true;
  }

  getHexNeighbors(hexId, radius) {
    if (radius <= 1) return [hexId];
    var visited = new Set([hexId]);
    var frontier = [hexId];
    var result = [hexId];
    for (var hop = 1; hop < radius; hop++) {
      var next = [];
      for (var i = 0; i < frontier.length; i++) {
        var nbs = this.hexNeighbors[frontier[i]];
        if (!nbs) continue;
        for (var j = 0; j < nbs.length; j++) {
          if (!visited.has(nbs[j])) {
            visited.add(nbs[j]);
            next.push(nbs[j]);
            result.push(nbs[j]);
          }
        }
      }
      frontier = next;
      if (frontier.length === 0) break;
    }
    return result;
  }

  // --- Camera ---

  _updateCamera() {
    var w = this.container.clientWidth || 800;
    var h = this.container.clientHeight || 600;
    var aspect = w / h;
    var DEG_TO_M = 111320;
    // _viewSize is in degrees of latitude; convert to meters for uniform frustum
    var halfH = this._viewSize / 2 * DEG_TO_M;
    var halfW = halfH * aspect;

    // Camera offset: difference between current center and chunk origin, in meters
    var cosLat = Math.cos(this._chunkOriginLat * Math.PI / 180);
    var camX = (this._centerLon - this._chunkOriginLon) * cosLat * DEG_TO_M;
    var camY = (this._centerLat - this._chunkOriginLat) * DEG_TO_M;
    // Apply tilt rotation to camera offset so it tracks the rotated geometry
    if (this._tiltAngle !== null) {
      var cosR = Math.cos(-this._tiltAngle);
      var sinR = Math.sin(-this._tiltAngle);
      var rx = camX * cosR - camY * sinR;
      var ry = camX * sinR + camY * cosR;
      camX = rx;
      camY = ry;
    }

    this.camera.position.set(camX, camY, 10);
    this.camera.left = -halfW;
    this.camera.right = halfW;
    this.camera.top = halfH;
    this.camera.bottom = -halfH;
    this.camera.updateProjectionMatrix();
  }

  // --- Input Handlers ---

  _onMouseDown(e) {
    // Right/middle click always drags (pan), left click depends on tool
    if (e.button === 2 || e.button === 1) {
      this._isDragging = true;
      this._didDrag = false;
      this._dragStartX = e.clientX;
      this._dragStartY = e.clientY;
      this._dragStartLat = this._centerLat;
      this._dragStartLon = this._centerLon;
      this.renderer3d.domElement.style.cursor = 'grabbing';
      e.preventDefault();
      return;
    }
    if (e.button !== 0) return;
    // If a tool is active (not select), left click does tool action immediately
    if (this.canDrag && !this.canDrag()) {
      this._didDrag = false;
      this._toolClickHandled = true; // Prevent duplicate from click event
      this._onClick(e);
      return;
    }
    // Select tool or no tool: left click = drag to pan, click without drag = pick
    this._isDragging = true;
    this._didDrag = false;
    this._dragStartX = e.clientX;
    this._dragStartY = e.clientY;
    this._dragStartLat = this._centerLat;
    this._dragStartLon = this._centerLon;
    this.renderer3d.domElement.style.cursor = 'grabbing';
    e.preventDefault();
  }

  _onMouseMove(e) {
    if (!this._isDragging) return;

    var dx = e.clientX - this._dragStartX;
    var dy = e.clientY - this._dragStartY;

    if (Math.abs(dx) > 4 || Math.abs(dy) > 4) this._didDrag = true;

    var rect = this.renderer3d.domElement.getBoundingClientRect();
    // Convert pixel drag to degrees, accounting for tilt rotation
    var DEG_TO_M = 111320;
    var cosLat = Math.cos(this._dragStartLat * Math.PI / 180) || 1;
    var metersPerPixelX = this._viewSize * DEG_TO_M * (rect.width / rect.height) / rect.width;
    var metersPerPixelY = this._viewSize * DEG_TO_M / rect.height;

    // Counter-rotate drag vector by tilt angle so dragging aligns with screen axes
    var dragMx = -dx * metersPerPixelX;
    var dragMy = dy * metersPerPixelY;
    if (this._tiltAngle !== null) {
      var cosR = Math.cos(-this._tiltAngle);
      var sinR = Math.sin(-this._tiltAngle);
      var rx = dragMx * cosR + dragMy * sinR;
      var ry = -dragMx * sinR + dragMy * cosR;
      dragMx = rx;
      dragMy = ry;
    }

    this._centerLon = this._dragStartLon + dragMx / (cosLat * DEG_TO_M);
    this._centerLat = this._dragStartLat + dragMy / DEG_TO_M;
    this._updateCamera();
  }

  _onMouseUp() {
    this._isDragging = false;
    this.renderer3d.domElement.style.cursor = '';
  }

  _onWheel(e) {
    e.preventDefault();
    var oldSize = this._viewSize;
    var zoomFactor = e.deltaY > 0 ? 1.15 : 0.87;
    this._viewSize = Math.max(0.05, Math.min(90, this._viewSize * zoomFactor));
    this._updateCamera();
    // Clear cache on zoom change so we fetch fresh for the new scale
    if (Math.abs(this._viewSize - oldSize) / oldSize > 0.1) {
      this._clearChunks();
      this._clearZones();
      this.hexCache = {};
      this._tiltAngle = null;
      this._lastViewport = null;
      this._pendingFetch = false;
    }
    this._updateEdgeVisibility();
  }

  // --- Hex Loading ---

  _getVisibleBounds() {
    var w = this.container.clientWidth || 800;
    var h = this.container.clientHeight || 600;
    var aspect = w / h;
    var cosLat = Math.cos(this._centerLat * Math.PI / 180) || 1;
    // The viewport diagonal in degrees, plus extra for tilt rotation
    var halfDeg = this._viewSize / 2 * Math.sqrt(1 + aspect * aspect);
    var halfLonDeg = halfDeg / cosLat;
    // 40% padding covers tilt rotation corners + preloading
    return {
      minLat: this._centerLat - halfDeg * 1.4,
      maxLat: this._centerLat + halfDeg * 1.4,
      minLon: this._centerLon - halfLonDeg * 1.4,
      maxLon: this._centerLon + halfLonDeg * 1.4
    };
  }

  _loadHexes() {
    if (this._pendingFetch || !this._active) return;

    var bounds = this._getVisibleBounds();
    var key = bounds.minLat.toFixed(2) + ',' + bounds.maxLat.toFixed(2) + ',' +
              bounds.minLon.toFixed(2) + ',' + bounds.maxLon.toFixed(2);
    if (key === this._lastViewport) return;
    this._lastViewport = key;
    this._pendingFetch = true;

    this._fetchPage(bounds);
  }

  _fetchPage(bounds) {
    var self = this;
    var BATCH = 10000;

    // Use keyset pagination by lat/lon (matches index order, no sort needed)
    var url = this.apiBase + '/hexregion?min_lat=' + bounds.minLat.toFixed(4) +
              '&max_lat=' + bounds.maxLat.toFixed(4) +
              '&min_lon=' + bounds.minLon.toFixed(4) +
              '&max_lon=' + bounds.maxLon.toFixed(4) +
              '&limit=' + BATCH;
    if (this._lastFetchedLat !== undefined) {
      url += '&after_lat=' + this._lastFetchedLat.toFixed(8) +
             '&after_lon=' + this._lastFetchedLon.toFixed(8);
    }

    fetch(url)
      .then(function(r) {
        if (!r.ok) return null;
        var ct = r.headers.get('content-type') || '';
        if (ct.indexOf('json') === -1) return null;
        return r.json();
      })
      .then(function(data) {
        if (!data || !data.hexes) { self._pendingFetch = false; return; }

        var newHexIds = [];
        data.hexes.forEach(function(h) {
          // Track last lat/lon for keyset pagination
          self._lastFetchedLat = h.la;
          self._lastFetchedLon = h.lo;
          if (self.hexCache[h.id]) return;
          var terrainType = self.terrainNames[h.t] || 'ocean';
          self.hexCache[h.id] = {
            data: { globe_hex_id: h.id, terrain_type: terrainType, traversable: h.tr === 1, latitude: h.la, longitude: h.lo, neighbor_ids: h.nb || null, features: h.ft || null },
            boundary: h.bv || null
          };
          if (h.nb) self.hexNeighbors[h.id] = h.nb;
          newHexIds.push(h.id);
        });

        if (newHexIds.length > 0) {
          if (self._viewSize > 3) {
            self._addPointChunk(newHexIds);
          } else {
            self._addChunk(newHexIds);
          }
          if (self.onLoad) self.onLoad(Object.keys(self.hexCache).length);
          // Re-render zones once tilt/origin are known (first chunk sets them)
          if (self._zoneMeshes.length === 0 && self._chunkOriginLat) {
            self._loadZones();
          }
        }

        // If we got a full batch, there may be more — fetch next page
        if (data.hexes.length >= BATCH && self._active) {
          setTimeout(function() { self._fetchPage(bounds); }, 50);
        } else {
          self._pendingFetch = false;
        }
      })
      .catch(function(err) {
        console.warn('VoronoiHexRenderer: fetch error, retrying in 2s', err);
        // Retry after a delay (server may be temporarily busy)
        setTimeout(function() {
          self._pendingFetch = false;
          self._lastViewport = null; // Allow re-trigger
        }, 2000);
      });
  }

  // --- Geometry ---

  // Measure the average hex tilt angle from a sample of hexes.
  // Returns radians to rotate each hex so its "top" points north.
  _measureTiltAngle() {
    var angles = [];
    var ids = Object.keys(this.hexCache);
    var step = Math.max(1, Math.floor(ids.length / 20));
    for (var i = 0; i < ids.length && angles.length < 20; i += step) {
      var cached = this.hexCache[ids[i]];
      var bv = cached.boundary;
      if (!bv || bv.length < 5) continue;
      var clat = cached.data.latitude;
      var clon = cached.data.longitude;
      var cosLat = Math.cos(clat * Math.PI / 180);
      // Find the northernmost vertex
      var northIdx = 0, northLat = -999;
      for (var v = 0; v < bv.length; v++) {
        if (bv[v][0] > northLat) { northLat = bv[v][0]; northIdx = v; }
      }
      var dx = (bv[northIdx][1] - clon) * cosLat;
      var dy = bv[northIdx][0] - clat;
      // Angle of north vertex from center (0 = due north)
      angles.push(Math.atan2(dx, dy));
    }
    if (angles.length === 0) return 0;
    // Average angle
    var sumSin = 0, sumCos = 0;
    for (var a = 0; a < angles.length; a++) {
      sumSin += Math.sin(angles[a]);
      sumCos += Math.cos(angles[a]);
    }
    return Math.atan2(sumSin / angles.length, sumCos / angles.length);
  }

  _clearChunks() {
    for (var i = 0; i < this._chunks.length; i++) {
      var chunk = this._chunks[i];
      this.scene.remove(chunk.fillMesh);
      chunk.fillMesh.geometry.dispose();
      if (chunk.edgeLines) {
        this.scene.remove(chunk.edgeLines);
        chunk.edgeLines.geometry.dispose();
      }
      if (chunk.featureLines) {
        this.scene.remove(chunk.featureLines);
        chunk.featureLines.geometry.dispose();
      }
    }
    this._chunks = [];
    this.triToHexId = [];
    this.fillMesh = null;
    this._featureLineData = [];
    this._lastFetchedLat = undefined;
    this._lastFetchedLon = undefined;
  }

  // --- Zone Rendering ---

  _zoneColors = {
    area:     0xff6b6b,  // red
    location: 0x4ecdc4,  // teal
    city:     0xffe66d,  // yellow
    political: 0x9b59b6, // purple
    dungeon:  0xe74c3c,  // dark red
    quest:    0xf39c12,  // orange
    safe:     0x2ecc71,  // green
    pvp:      0xe74c3c,  // red
    event:    0x3498db   // blue
  };

  _loadZones() {
    var self = this;
    fetch(this.apiBase + '/zones')
      .then(function(r) { return r.ok ? r.json() : null; })
      .then(function(data) {
        if (!data || !data.zones) return;
        self._zones = data.zones;
        self._renderZones();
      })
      .catch(function(err) {
        console.warn('VoronoiHexRenderer: Failed to load zones', err);
      });
  }

  _renderZones() {
    this._clearZones();
    if (!this._zones) return;
    // Need chunk origin set (happens after first chunk builds)
    if (!this._chunkOriginLat) return;

    var tilt = this._tiltAngle || 0;
    var cosR = Math.cos(-tilt);
    var sinR = Math.sin(-tilt);

    for (var z = 0; z < this._zones.length; z++) {
      var zone = this._zones[z];
      var points = zone.polygon_points;
      if (!points || points.length < 3) continue;

      var positions = [];
      for (var p = 0; p < points.length; p++) {
        var lat = points[p].lat ?? points[p].y;
        var lng = points[p].lng ?? points[p].x;
        if (lat == null || lng == null) continue;
        var lp = this._toLocal(lat, lng);
        var rx = lp[0] * cosR - lp[1] * sinR;
        var ry = lp[0] * sinR + lp[1] * cosR;
        positions.push(rx, ry, 0.003);
      }
      // Close the loop
      if (positions.length >= 9) {
        positions.push(positions[0], positions[1], positions[2]);
      }

      if (positions.length < 6) continue;

      var geo = new THREE.BufferGeometry();
      geo.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
      var color = this._zoneColors[zone.zone_type] || 0xffffff;
      var line = new THREE.Line(geo, new THREE.LineBasicMaterial({
        color: color,
        linewidth: 2
      }));
      this.scene.add(line);
      this._zoneMeshes.push(line);
    }
  }

  _clearZones() {
    if (this._zoneMeshes) {
      for (var i = 0; i < this._zoneMeshes.length; i++) {
        this.scene.remove(this._zoneMeshes[i]);
        this._zoneMeshes[i].geometry.dispose();
      }
    }
    this._zoneMeshes = [];
  }

  // Map boundary edges to hex directions (n, ne, se, s, sw, nw) by angle.
  // Uses rotated positions from the positions array.
  _mapEdgesToDirections(numVerts, positions, firstBoundaryIdx, cx, cy) {
    // Target angles for each direction (radians from east, counterclockwise)
    // In our coord system: x=east, y=north
    var targetAngles = {
      n:  Math.PI / 2,       // 90°
      ne: Math.PI / 6,       // 30°
      se: -Math.PI / 6,      // -30°
      s:  -Math.PI / 2,      // -90°
      sw: -5 * Math.PI / 6,  // -150°
      nw: 5 * Math.PI / 6    // 150°
    };
    var dirs = ['n', 'ne', 'se', 's', 'sw', 'nw'];
    var result = {};
    var used = {};

    // For each direction, find the edge whose midpoint angle is closest
    for (var di = 0; di < dirs.length; di++) {
      var dir = dirs[di];
      var target = targetAngles[dir];
      var bestEdge = -1;
      var bestDiff = Infinity;

      for (var e = 0; e < numVerts; e++) {
        if (used[e]) continue;
        var e1 = firstBoundaryIdx + e;
        var e2 = firstBoundaryIdx + ((e + 1) % numVerts);
        // Edge midpoint relative to hex center
        var mx = (positions[e1 * 3] + positions[e2 * 3]) / 2 - cx;
        var my = (positions[e1 * 3 + 1] + positions[e2 * 3 + 1]) / 2 - cy;
        var angle = Math.atan2(my, mx);
        var diff = Math.abs(angle - target);
        if (diff > Math.PI) diff = 2 * Math.PI - diff;
        if (diff < bestDiff) {
          bestDiff = diff;
          bestEdge = e;
        }
      }
      if (bestEdge >= 0) {
        result[dir] = bestEdge;
        used[bestEdge] = true;
      }
    }
    return result;
  }

  // Convert (lat, lon) to local tangent plane meters relative to chunk origin.
  // Uses equirectangular approximation (accurate within a few degrees).
  _toLocal(lat, lon) {
    var DEG_TO_M = 111320; // meters per degree latitude
    var cosLat = Math.cos(this._chunkOriginLat * Math.PI / 180);
    var x = (lon - this._chunkOriginLon) * cosLat * DEG_TO_M;
    var y = (lat - this._chunkOriginLat) * DEG_TO_M;
    return [x, y];
  }

  // Lightweight rendering for zoomed-out view: colored points instead of polygons.
  // No boundaries, no picking, no features — just terrain overview for navigation.
  _addPointChunk(hexIds) {
    if (this._tiltAngle === null) {
      this._tiltAngle = this._measureTiltAngle();
      this._chunkOriginLat = this._centerLat;
      this._chunkOriginLon = this._centerLon;
    }
    var cosR = Math.cos(-this._tiltAngle);
    var sinR = Math.sin(-this._tiltAngle);

    var positions = [];
    var colors = [];

    for (var h = 0; h < hexIds.length; h++) {
      var cached = this.hexCache[hexIds[h]];
      if (!cached) continue;
      var data = cached.data;
      // Skip non-traversable hexes in overview mode (ocean background covers them)
      if (data.traversable === false) continue;
      var rgb = this.terrainColors[data.terrain_type] || { r: 0.53, g: 0.53, b: 0.53 };

      var p = this._toLocal(data.latitude, data.longitude);
      var px = p[0] * cosR - p[1] * sinR;
      var py = p[0] * sinR + p[1] * cosR;
      positions.push(px, py, 0);
      colors.push(rgb.r, rgb.g, rgb.b);
    }

    if (positions.length === 0) return;

    var geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
    geo.setAttribute('color', new THREE.Float32BufferAttribute(colors, 3));
    // Point size: compute from hex spacing and viewport so dots just overlap
    var DEG_TO_M = 111320;
    var viewHeightM = this._viewSize * DEG_TO_M;
    var viewHeightPx = this.container.clientHeight || 600;
    var hexSpacingM = (this._chunkOriginLat ? Math.cos(this._chunkOriginLat * Math.PI / 180) : 0.7) * 0.039 * DEG_TO_M;
    var pointSize = Math.max(3, (hexSpacingM / viewHeightM) * viewHeightPx * 1.4);
    var pointsMesh = new THREE.Points(geo, new THREE.PointsMaterial({
      vertexColors: true,
      size: pointSize,
      sizeAttenuation: false
    }));
    this.scene.add(pointsMesh);
    this._chunks.push({ fillMesh: pointsMesh, edgeLines: null, featureLines: null, triToHexId: [] });
  }

  // Build geometry for a batch of hex IDs and add as a new chunk.
  _addChunk(hexIds) {
    // Measure tilt and set chunk origin once from first batch
    if (this._tiltAngle === null) {
      this._tiltAngle = this._measureTiltAngle();
      this._chunkOriginLat = this._centerLat;
      this._chunkOriginLon = this._centerLon;
    }
    // Correct tilt so hex tops are as close to horizontal as possible
    var cosR = Math.cos(-this._tiltAngle);
    var sinR = Math.sin(-this._tiltAngle);

    var positions = [];
    var colors = [];
    var indices = [];
    var edgePositions = [];
    var chunkTriToHexId = [];
    var vertexCount = 0;

    for (var h = 0; h < hexIds.length; h++) {
      var hexId = hexIds[h];
      var cached = this.hexCache[hexId];
      var bv = cached.boundary;
      if (!bv || bv.length < 3) continue;

      var data = cached.data;
      var rgb = data.traversable === false
        ? { r: 0.67, g: 0.13, b: 0.13 }
        : (this.terrainColors[data.terrain_type] || { r: 0.53, g: 0.53, b: 0.53 });

      // Project hex center to local tangent plane
      var cp = this._toLocal(data.latitude, data.longitude);
      // Rotate around hex center
      var cx = cp[0] * cosR - cp[1] * sinR;
      var cy = cp[0] * sinR + cp[1] * cosR;

      var centerIdx = vertexCount;
      positions.push(cx, cy, 0);
      colors.push(rgb.r, rgb.g, rgb.b);
      vertexCount++;

      var firstBoundaryIdx = vertexCount;
      for (var v = 0; v < bv.length; v++) {
        var bp = this._toLocal(bv[v][0], bv[v][1]);
        var bx = bp[0] * cosR - bp[1] * sinR;
        var by = bp[0] * sinR + bp[1] * cosR;
        positions.push(bx, by, 0);
        colors.push(rgb.r, rgb.g, rgb.b);
        vertexCount++;
      }

      cached.triangleStart = this.triToHexId.length + chunkTriToHexId.length;
      cached.triangleCount = bv.length;
      cached.vertexStart = centerIdx;
      cached.vertexCount = bv.length + 1; // center + boundary vertices
      cached.chunkIndex = this._chunks.length; // which chunk this hex is in
      for (var t = 0; t < bv.length; t++) {
        indices.push(centerIdx, firstBoundaryIdx + t, firstBoundaryIdx + ((t + 1) % bv.length));
        chunkTriToHexId.push(hexId);
      }

      for (var e = 0; e < bv.length; e++) {
        var e1 = firstBoundaryIdx + e;
        var e2 = firstBoundaryIdx + ((e + 1) % bv.length);
        edgePositions.push(
          positions[e1 * 3], positions[e1 * 3 + 1], 0.001,
          positions[e2 * 3], positions[e2 * 3 + 1], 0.001
        );
      }

      // Build feature lines: center-to-edge-midpoint for each direction with a feature
      if (data.features) {
        var edgeDirs = this._mapEdgesToDirections(bv.length, positions, firstBoundaryIdx, cx, cy);
        var dirs = ['n', 'ne', 'se', 's', 'sw', 'nw'];
        for (var di = 0; di < dirs.length; di++) {
          var ft = data.features[dirs[di]];
          if (!ft) continue;
          var edgeIdx = edgeDirs[dirs[di]];
          if (edgeIdx === undefined) continue;
          var fe1 = firstBoundaryIdx + edgeIdx;
          var fe2 = firstBoundaryIdx + ((edgeIdx + 1) % bv.length);
          // Edge midpoint
          var mx = (positions[fe1 * 3] + positions[fe2 * 3]) / 2;
          var my = (positions[fe1 * 3 + 1] + positions[fe2 * 3 + 1]) / 2;
          var fcolor = this.featureColors[ft] || { r: 0.5, g: 0.5, b: 0.5 };
          // Line from hex center to edge midpoint
          this._featureLineData.push(
            cx, cy, 0.002,
            mx, my, 0.002,
            fcolor.r, fcolor.g, fcolor.b
          );
        }
      }
    }

    if (indices.length === 0) return;

    var fillGeo = new THREE.BufferGeometry();
    fillGeo.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
    fillGeo.setAttribute('color', new THREE.Float32BufferAttribute(colors, 3));
    fillGeo.setIndex(indices);
    var fillMesh = new THREE.Mesh(fillGeo, new THREE.MeshBasicMaterial({
      vertexColors: true,
      side: THREE.DoubleSide
    }));
    this.scene.add(fillMesh);

    var edgeLines = null;
    if (edgePositions.length > 0) {
      var edgeGeo = new THREE.BufferGeometry();
      edgeGeo.setAttribute('position', new THREE.Float32BufferAttribute(edgePositions, 3));
      edgeLines = new THREE.LineSegments(edgeGeo, new THREE.LineBasicMaterial({
        color: 0x222222,
        linewidth: 1
      }));
      // Hide edges when zoomed out (they make the view muddy)
      edgeLines.visible = this._viewSize <= 3;
      this.scene.add(edgeLines);
    }

    // Build feature lines mesh from accumulated data
    var featureLines = null;
    if (this._featureLineData && this._featureLineData.length > 0) {
      var fPositions = [];
      var fColors = [];
      for (var fi = 0; fi < this._featureLineData.length; fi += 9) {
        fPositions.push(
          this._featureLineData[fi], this._featureLineData[fi + 1], this._featureLineData[fi + 2],
          this._featureLineData[fi + 3], this._featureLineData[fi + 4], this._featureLineData[fi + 5]
        );
        fColors.push(
          this._featureLineData[fi + 6], this._featureLineData[fi + 7], this._featureLineData[fi + 8],
          this._featureLineData[fi + 6], this._featureLineData[fi + 7], this._featureLineData[fi + 8]
        );
      }
      var fGeo = new THREE.BufferGeometry();
      fGeo.setAttribute('position', new THREE.Float32BufferAttribute(fPositions, 3));
      fGeo.setAttribute('color', new THREE.Float32BufferAttribute(fColors, 3));
      featureLines = new THREE.LineSegments(fGeo, new THREE.LineBasicMaterial({
        vertexColors: true,
        linewidth: 2
      }));
      this.scene.add(featureLines);
      this._featureLineData = [];
    }

    this._chunks.push({ fillMesh: fillMesh, edgeLines: edgeLines, featureLines: featureLines, triToHexId: chunkTriToHexId });
    this.fillMesh = fillMesh; // for recolorHex compat
    this.triToHexId = this.triToHexId.concat(chunkTriToHexId);
  }

  // Update edge line visibility based on zoom level
  _updateEdgeVisibility() {
    var show = this._viewSize <= 3;
    for (var i = 0; i < this._chunks.length; i++) {
      if (this._chunks[i].edgeLines) {
        this._chunks[i].edgeLines.visible = show;
      }
    }
  }

  // --- Picking ---

  _onClick(e) {
    if (this._didDrag) return;
    // Prevent duplicate fire from mousedown + click event
    if (this._toolClickHandled) { this._toolClickHandled = false; return; }
    if (this._chunks.length === 0) return;

    var rect = this.renderer3d.domElement.getBoundingClientRect();
    this.mouse.x = ((e.clientX - rect.left) / rect.width) * 2 - 1;
    this.mouse.y = -((e.clientY - rect.top) / rect.height) * 2 + 1;
    this.raycaster.setFromCamera(this.mouse, this.camera);

    // Check each chunk's fill mesh for intersection
    for (var c = 0; c < this._chunks.length; c++) {
      var chunk = this._chunks[c];
      var intersects = this.raycaster.intersectObject(chunk.fillMesh);
      if (intersects.length > 0) {
        var triIdx = intersects[0].faceIndex;
        if (triIdx < chunk.triToHexId.length) {
          var hexId = chunk.triToHexId[triIdx];
          var cached = this.hexCache[hexId];
          if (cached && this.onHexClick) {
            this.onHexClick(hexId, cached.data);
          }
        }
        return;
      }
    }
  }

  // --- Resize ---

  _onResize() {
    var w = this.container.clientWidth;
    var h = this.container.clientHeight;
    if (w === 0 || h === 0) return;
    this.renderer3d.setSize(w, h);
    this._updateCamera();
  }

  // --- Animation ---

  _animate() {
    if (!this._active) return;
    requestAnimationFrame(this._animate.bind(this));
    this._loadHexes();
    this.renderer3d.render(this.scene, this.camera);
  }
}
