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

  init() {
    // Clear container and create fresh SVG
    this.container.innerHTML = '';
    this.svg = this.createSvg();
    this.bindEvents();
    console.log('HexEditor initialized');
  }

  createSvg() {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.id = 'hex-editor-svg';
    svg.style.width = '100%';
    svg.style.height = '100%';
    svg.style.cursor = 'crosshair';
    svg.style.background = '#111';
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
      const target = e.target.closest('.editor-hex');
      if (target) {
        const worldX = parseInt(target.dataset.worldX);
        const worldY = parseInt(target.dataset.worldY);
        e.preventDefault();
        this.openSubHexEditor(worldX, worldY);
      }
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

  // Load visible hexes from API
  async loadVisibleHexes() {
    if (this.isLoading) return;
    this.isLoading = true;

    const minX = Math.floor(this.viewportX);
    const maxX = minX + this.visibleCols;
    const minY = Math.floor(this.viewportY);
    const maxY = minY + this.visibleRows;

    try {
      const apiBase = window.API_BASE || `/admin/world_builder/${this.worldId}/api`;
      const params = new URLSearchParams({
        face: this.regionOrigin?.face || 0,
        x: minX,
        y: minY,
        size: Math.max(this.visibleCols, this.visibleRows)
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
    } catch (error) {
      console.error('Failed to load hexes:', error);
    } finally {
      this.isLoading = false;
      this.render();
    }
  }

  render() {
    if (!this.svg) return;

    const width = this.container.clientWidth;
    const height = this.container.clientHeight;

    // Set viewBox to match container size
    this.svg.setAttribute('viewBox', `0 0 ${width} ${height}`);
    this.svg.innerHTML = '';

    // Add defs for patterns
    const defs = document.createElementNS('http://www.w3.org/2000/svg', 'defs');

    // Non-traversable pattern (diagonal stripes)
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

    // Background
    const bg = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
    bg.setAttribute('x', 0);
    bg.setAttribute('y', 0);
    bg.setAttribute('width', width);
    bg.setAttribute('height', height);
    bg.setAttribute('fill', '#111');
    this.svg.appendChild(bg);

    // Hex group
    const hexGroup = document.createElementNS('http://www.w3.org/2000/svg', 'g');
    hexGroup.id = 'hex-group';

    // Calculate which hexes to render
    const startCol = Math.floor(this.viewportX);
    const startRow = Math.floor(this.viewportY);
    const endCol = startCol + this.visibleCols;
    const endRow = startRow + this.visibleRows;

    // Fractional offset for smooth scrolling
    const offsetX = (this.viewportX - startCol) * this.horizSpacing;
    const offsetY = (this.viewportY - startRow) * this.vertSpacing;

    for (let row = startRow; row < endRow; row++) {
      for (let col = startCol; col < endCol; col++) {
        const key = `${col},${row}`;
        const hexInfo = this.hexCache.get(key) || { terrain: 'ocean' };

        // Calculate screen position
        const relCol = col - startCol;
        const relRow = row - startRow;
        const screenPos = this.hexToPixel(relCol, relRow);

        // Apply scroll offset
        const x = screenPos.x - offsetX;
        const y = screenPos.y - offsetY;

        // Skip if completely off screen
        if (x < -this.hexWidth || x > width + this.hexWidth ||
            y < -this.hexHeight || y > height + this.hexHeight) {
          continue;
        }

        const hex = this.createHexElement(x, y, hexInfo, col, row);
        hexGroup.appendChild(hex);
      }
    }

    this.svg.appendChild(hexGroup);

    // Features layer (roads, rivers, etc.)
    this.renderFeatures();

    // Zones layer (colored overlays)
    this.renderZones();

    // Cities layer
    this.renderCities();

    // Zone preview layer (when drawing a zone)
    this.renderZonePreview();

    // Update minimap viewport
    if (this.minimap) {
      this.minimap.setViewport(
        this.viewportX,
        this.viewportY,
        this.visibleCols,
        this.visibleRows
      );
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

    // Coordinate label (world coordinates)
    const label = document.createElementNS('http://www.w3.org/2000/svg', 'text');
    label.setAttribute('x', cx);
    label.setAttribute('y', cy + 4);
    label.setAttribute('text-anchor', 'middle');
    label.setAttribute('fill', 'rgba(255,255,255,0.4)');
    label.setAttribute('font-size', '9');
    label.setAttribute('pointer-events', 'none');
    label.textContent = `${worldCol},${worldRow}`;
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

    // Calculate viewport offset for converting world coords to screen
    const startCol = Math.floor(this.viewportX);
    const startRow = Math.floor(this.viewportY);
    const offsetX = (this.viewportX - startCol) * this.horizSpacing;
    const offsetY = (this.viewportY - startRow) * this.vertSpacing;

    // Helper to get screen position for a world coordinate
    const getScreenPos = (worldX, worldY) => {
      const relCol = worldX - startCol;
      const relRow = worldY - startRow;
      const pos = this.hexToPixel(relCol, relRow);
      return { x: pos.x - offsetX, y: pos.y - offsetY };
    };

    // Helper to get edge position (midpoint between hex center and edge)
    const getEdgePos = (hexX, hexY, direction) => {
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

    // Render in-progress feature line (preview)
    if (this.featurePoints.length > 0) {
      const previewPath = document.createElementNS('http://www.w3.org/2000/svg', 'path');
      let d = '';

      for (let i = 0; i < this.featurePoints.length; i++) {
        const point = this.featurePoints[i];
        const center = getScreenPos(point.x, point.y);

        if (i === 0) {
          d = `M ${center.x} ${center.y}`;
        } else {
          // Draw edge-to-edge path
          const prevPoint = this.featurePoints[i - 1];
          const prevCenter = getScreenPos(prevPoint.x, prevPoint.y);
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
    // Build a set of rendered edges to avoid duplicates
    const renderedEdges = new Set();

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
          });
        }
      }
    }
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

    // Draw polygon if we have 3+ points
    if (this.zonePoints.length >= 3) {
      const polygon = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
      const points = this.zonePoints.map(point => {
        const relCol = point.x - startCol;
        const relRow = point.y - startRow;
        const screenPos = this.hexToPixel(relCol, relRow);
        const x = screenPos.x - offsetX;
        const y = screenPos.y - offsetY;
        return `${x},${y}`;
      }).join(' ');

      polygon.setAttribute('points', points);
      polygon.setAttribute('fill', 'rgba(23, 162, 184, 0.3)');
      polygon.setAttribute('stroke', '#17a2b8');
      polygon.setAttribute('stroke-width', 2);
      polygon.setAttribute('stroke-dasharray', '5,5');
      group.appendChild(polygon);
    }

    // Draw lines connecting points
    if (this.zonePoints.length >= 2) {
      const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
      let d = '';

      this.zonePoints.forEach((point, i) => {
        const relCol = point.x - startCol;
        const relRow = point.y - startRow;
        const screenPos = this.hexToPixel(relCol, relRow);
        const x = screenPos.x - offsetX;
        const y = screenPos.y - offsetY;

        if (i === 0) {
          d = `M ${x} ${y}`;
        } else {
          d += ` L ${x} ${y}`;
        }
      });

      path.setAttribute('d', d);
      path.setAttribute('stroke', '#17a2b8');
      path.setAttribute('stroke-width', 2);
      path.setAttribute('fill', 'none');
      group.appendChild(path);
    }

    // Draw point markers
    this.zonePoints.forEach((point, i) => {
      const relCol = point.x - startCol;
      const relRow = point.y - startRow;
      const screenPos = this.hexToPixel(relCol, relRow);
      const x = screenPos.x - offsetX;
      const y = screenPos.y - offsetY;

      const marker = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
      marker.setAttribute('cx', x);
      marker.setAttribute('cy', y);
      marker.setAttribute('r', i === 0 ? 8 : 5);
      marker.setAttribute('fill', i === 0 ? '#17a2b8' : '#fff');
      marker.setAttribute('stroke', i === 0 ? '#fff' : '#17a2b8');
      marker.setAttribute('stroke-width', 2);
      group.appendChild(marker);

      // Number label
      const label = document.createElementNS('http://www.w3.org/2000/svg', 'text');
      label.setAttribute('x', x);
      label.setAttribute('y', y + 3);
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
      const resp = await fetch(`${apiBase}/features`);
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      const data = await resp.json();

      // Load legacy features (polyline format)
      this.features = data.features || [];

      // Load directional features and merge into hex cache
      if (data.directional_features) {
        this.directionalFeatures = data.directional_features;

        // Group directional features by hex for the cache
        const featuresByHex = {};
        data.directional_features.forEach(f => {
          // Use globe_hex_id as key, or lat/lng
          const hexKey = f.globe_hex_id || `${f.lat},${f.lng}`;
          if (!featuresByHex[hexKey]) {
            featuresByHex[hexKey] = { ...f, features: {} };
          }
          featuresByHex[hexKey].features[f.direction] = f.type;
        });

        // Update hex cache with feature data
        this.hexCache.forEach((hexInfo, key) => {
          const hexKey = hexInfo.globe_hex_id || `${hexInfo.lat},${hexInfo.lng}`;
          if (featuresByHex[hexKey]) {
            hexInfo.features = {
              ...(hexInfo.features || {}),
              ...featuresByHex[hexKey].features
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
        const relCol = point.x - startCol;
        const relRow = point.y - startRow;
        const screenPos = this.hexToPixel(relCol, relRow);
        return {
          x: screenPos.x - offsetX,
          y: screenPos.y - offsetY
        };
      });

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

  // Event handlers
  handlePointerDown(e) {
    const target = e.target.closest('.editor-hex');

    // Middle mouse button (1) or right-click (2) or spacebar held = always pan
    const shouldPan = e.button === 1 || e.button === 2 || this.spacePressed ||
                      (e.button === 0 && this.selectedTool === 'select');

    if (shouldPan) {
      // Start potential pan
      this.isPanning = true;
      this.panStart = { x: e.clientX, y: e.clientY };
      this.panAccumulated = { x: 0, y: 0 };
      this.panTarget = target; // Remember if we clicked on a hex
      this.hasDragged = false;
      this.svg.style.cursor = 'grabbing';
      this.svg.setPointerCapture(e.pointerId);
      e.preventDefault();
    } else if (target && e.button === 0) {
      // Left-click on hex with a tool active (not select)
      const worldX = parseInt(target.dataset.worldX);
      const worldY = parseInt(target.dataset.worldY);
      this.handleHexClick(worldX, worldY);
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
      this.viewportX = this.viewportX - (dx - this.panAccumulated.x) / this.horizSpacing;
      this.viewportY = this.viewportY - (dy - this.panAccumulated.y) / this.vertSpacing;

      this.panAccumulated = { x: dx, y: dy };
      this.render();

      // Load more hexes if needed
      this.loadVisibleHexes();
    }
  }

  handlePointerUp(e) {
    if (this.isPanning) {
      this.svg.releasePointerCapture(e.pointerId);

      // If we didn't drag and clicked on a hex with select tool, treat as a click
      if (!this.hasDragged && this.panTarget && this.selectedTool === 'select') {
        const worldX = parseInt(this.panTarget.dataset.worldX);
        const worldY = parseInt(this.panTarget.dataset.worldY);
        this.handleHexClick(worldX, worldY);
      }

      this.isPanning = false;
      this.hasDragged = false;
      this.panTarget = null;
      this.svg.style.cursor = this.spacePressed ? 'grab' : (this.selectedTool === 'select' ? 'grab' : 'crosshair');
    }
  }

  handleWheel(e) {
    e.preventDefault();

    // Zoom in/out by changing hex size
    const zoomFactor = e.deltaY > 0 ? 0.9 : 1.1;
    const newRadius = this.hexRadius * zoomFactor;

    // Limit zoom range (15-80 pixels)
    if (newRadius >= 15 && newRadius <= 80) {
      // Get mouse position in world coordinates before zoom
      const rect = this.svg.getBoundingClientRect();
      const mouseX = e.clientX - rect.left;
      const mouseY = e.clientY - rect.top;
      const worldPosBeforeZoom = this.pixelToHex(mouseX, mouseY);

      // Apply zoom
      this.hexRadius = newRadius;

      // Adjust viewport to keep mouse position stable
      const worldPosAfterZoom = this.pixelToHex(mouseX, mouseY);
      this.viewportX += worldPosBeforeZoom.col - worldPosAfterZoom.col;
      this.viewportY += worldPosBeforeZoom.row - worldPosAfterZoom.row;

      this.render();
      this.loadVisibleHexes();
    }
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

    switch (e.key) {
      case 'ArrowLeft':
        this.viewportX -= scrollAmount;
        this.render();
        this.loadVisibleHexes();
        e.preventDefault();
        break;
      case 'ArrowRight':
        this.viewportX += scrollAmount;
        this.render();
        this.loadVisibleHexes();
        e.preventDefault();
        break;
      case 'ArrowUp':
        this.viewportY -= scrollAmount;
        this.render();
        this.loadVisibleHexes();
        e.preventDefault();
        break;
      case 'ArrowDown':
        this.viewportY += scrollAmount;
        this.render();
        this.loadVisibleHexes();
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

  // Context menu handler for right-click
  handleContextMenu(e) {
    e.preventDefault();

    // Remove any existing context menu
    this.closeContextMenu();

    // Get the clicked hex
    const target = e.target.closest('.editor-hex');
    let worldX = null, worldY = null;
    if (target) {
      worldX = parseInt(target.dataset.worldX);
      worldY = parseInt(target.dataset.worldY);
    }

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

    this.hexCache.set(key, hexInfo);
    this.render();

    // Auto-save terrain change immediately
    this.saveHexChange(hexInfo);
  }

  // Save a single hex change to the API
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
    this.zonePoints.push({ x: worldX, y: worldY });

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

  // Finish current feature line and save it
  finishFeatureLine() {
    if (this.featurePoints.length >= 2) {
      // Convert points to directional features (edge-based)
      const directionalFeatures = [];

      for (let i = 0; i < this.featurePoints.length - 1; i++) {
        const from = this.featurePoints[i];
        const to = this.featurePoints[i + 1];

        // Calculate direction from 'from' to 'to'
        const direction = this.getHexDirection(from.x, from.y, to.x, to.y);
        const oppositeDir = this.getOppositeDirection(direction);

        if (direction) {
          // Add feature to 'from' hex in the direction of 'to'
          directionalFeatures.push({
            globe_hex_id: from.globe_hex_id,
            lat: from.lat,
            lng: from.lng,
            direction: direction,
            type: this.selectedFeature
          });

          // Add feature to 'to' hex in the opposite direction
          if (oppositeDir) {
            directionalFeatures.push({
              globe_hex_id: to.globe_hex_id,
              lat: to.lat,
              lng: to.lng,
              direction: oppositeDir,
              type: this.selectedFeature
            });
          }
        }
      }

      // Store directional features
      this.directionalFeatures.push(...directionalFeatures);

      // Also save the legacy line format for rendering
      this.features.push({
        type: this.selectedFeature,
        points: this.featurePoints.map(p => ({ x: p.x, y: p.y }))
      });

      // Mark all hexes as dirty
      this.featurePoints.forEach(point => {
        this.dirtyHexes.add(`${point.x},${point.y}`);
      });

      console.log(`Feature: Completed ${this.selectedFeature} with ${this.featurePoints.length} points, ${directionalFeatures.length} directional entries`);

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

    this.hexCache.set(key, hexInfo);
    this.render();

    console.log(`Hex (${worldX}, ${worldY}) traversable: ${hexInfo.traversable}`);

    // Auto-save traversability change immediately
    this.saveHexChange(hexInfo);
  }

  // Navigate to specific world coordinates
  navigateTo(worldX, worldY) {
    this.viewportX = worldX - Math.floor(this.visibleCols / 2);
    this.viewportY = worldY - Math.floor(this.visibleRows / 2);
    this.render();
    this.loadVisibleHexes();
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

  show() {
    this.container.style.display = 'block';
    this.render();
    this.loadVisibleHexes();
    this.loadCities();
    this.loadFeatures();
    this.loadZones();
  }

  hide() {
    // All changes are auto-saved now, so no confirmation needed
    this.container.style.display = 'none';
  }

  get isDirty() {
    return this.dirtyHexes.size > 0;
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
