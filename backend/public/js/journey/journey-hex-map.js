/**
 * JourneyHexMap - Interactive flat-top hex map for journey planning
 *
 * Features:
 * - Flat-top hex rendering matching hex-editor.js and ZonemapService
 * - Terrain coloring with feature lines (roads, rivers, railways)
 * - Lazy-loading hex chunks as the user pans
 * - Pan/zoom with mouse drag and scroll wheel
 * - Hover tooltips on hexes
 * - Click-to-select destination locations
 * - Route preview line from current location to selected destination
 * - Pulsing "you are here" indicator
 */

const JOURNEY_TERRAIN_COLORS = {
  ocean: '#2d5f8a',
  lake: '#4a8ab5',
  rocky_coast: '#8a8a7d',
  sandy_coast: '#d4c9a8',
  grassy_plains: '#a8b878',
  rocky_plains: '#b0a88a',
  light_forest: '#6d9a52',
  dense_forest: '#3a6632',
  jungle: '#2d5a2d',
  swamp: '#5a6b48',
  mountain: '#8a7d6b',
  grassy_hills: '#96a07a',
  rocky_hills: '#9a8d78',
  tundra: '#c8d5d8',
  desert: '#c8b48a',
  volcanic: '#4a2828',
  urban: '#7a7a7a',
  light_urban: '#9a9a9a'
};

const JOURNEY_FEATURE_COLORS = {
  road: '#7f8c8d',
  highway: '#f39c12',
  street: '#95a5a6',
  trail: '#d7ccc8',
  river: '#3498db',
  canal: '#4a8ab5',
  railway: '#2c3e50'
};

const JOURNEY_TERRAIN_LABELS = {
  ocean: 'Ocean', lake: 'Lake', rocky_coast: 'Rocky Coast', sandy_coast: 'Sandy Coast',
  grassy_plains: 'Grassy Plains', rocky_plains: 'Rocky Plains', light_forest: 'Light Forest',
  dense_forest: 'Dense Forest', jungle: 'Jungle', swamp: 'Swamp', mountain: 'Mountain',
  grassy_hills: 'Grassy Hills', rocky_hills: 'Rocky Hills', tundra: 'Tundra',
  desert: 'Desert', volcanic: 'Volcanic', urban: 'Urban', light_urban: 'Light Urban'
};

class JourneyHexMap {
  constructor(containerId, options = {}) {
    this.container = document.getElementById(containerId);
    if (!this.container) return;

    // Callbacks
    this.onDestinationSelect = options.onDestinationSelect || null;

    // Hex geometry (flat-top)
    this.hexRadius = 28;
    this.hexHeight = Math.round(Math.sqrt(3) * this.hexRadius);
    this.horizSpacing = Math.round(this.hexRadius * 1.5);
    this.vertSpacing = this.hexHeight;

    // View state
    this.offsetX = 0;
    this.offsetY = 0;
    this.scale = 1.0;
    this.minScale = 0.3;
    this.maxScale = 4.0;

    // Data
    this.hexData = new Map();       // "cell_x,cell_y" -> hex object
    this.locations = new Map();     // location_id -> location object
    this.loadedRegions = new Set(); // "minLat,maxLat,minLon,maxLon" strings
    this.currentLocation = null;    // { latitude, longitude, name, id }
    this.worldId = null;

    // Selection
    this.selectedDestination = null;
    this.hoveredHex = null;

    // Pan state
    this.panState = { active: false, startMouseX: 0, startMouseY: 0, startOffsetX: 0, startOffsetY: 0, moved: false };

    // Lazy load debounce
    this._loadDebounce = null;

    // Region origin for coordinate mapping
    this.originLon = 0;
    this.originLat = 0;

    this.init();
  }

  init() {
    this.createSVG();
    this.createTooltip();
    this.bindEvents();
  }

  createSVG() {
    this.svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    this.svg.setAttribute('width', '100%');
    this.svg.setAttribute('height', '100%');
    this.svg.classList.add('journey-map-svg');

    // Defs for patterns/gradients
    const defs = document.createElementNS('http://www.w3.org/2000/svg', 'defs');
    this.svg.appendChild(defs);

    // Content group for pan/zoom transform
    this.contentGroup = document.createElementNS('http://www.w3.org/2000/svg', 'g');
    this.contentGroup.id = 'journey-content';

    // Layers (bottom to top)
    this.terrainLayer = document.createElementNS('http://www.w3.org/2000/svg', 'g');
    this.featureLayer = document.createElementNS('http://www.w3.org/2000/svg', 'g');
    this.routeLayer = document.createElementNS('http://www.w3.org/2000/svg', 'g');
    this.locationLayer = document.createElementNS('http://www.w3.org/2000/svg', 'g');
    this.currentLocLayer = document.createElementNS('http://www.w3.org/2000/svg', 'g');

    this.contentGroup.appendChild(this.terrainLayer);
    this.contentGroup.appendChild(this.featureLayer);
    this.contentGroup.appendChild(this.routeLayer);
    this.contentGroup.appendChild(this.locationLayer);
    this.contentGroup.appendChild(this.currentLocLayer);

    this.svg.appendChild(this.contentGroup);
    this.container.appendChild(this.svg);
  }

  createTooltip() {
    this.tooltip = document.createElement('div');
    this.tooltip.className = 'journey-hex-tooltip';
    this.tooltip.style.display = 'none';
    this.container.appendChild(this.tooltip);
  }

  bindEvents() {
    this.svg.addEventListener('mousedown', (e) => this.handleMouseDown(e));
    this.svg.addEventListener('mousemove', (e) => this.handleMouseMove(e));
    this.svg.addEventListener('mouseup', (e) => this.handleMouseUp(e));
    this.svg.addEventListener('mouseleave', (e) => this.handleMouseLeave(e));
    this.svg.addEventListener('wheel', (e) => this.handleWheel(e), { passive: false });

    this.svg.addEventListener('touchstart', (e) => this.handleTouchStart(e), { passive: false });
    this.svg.addEventListener('touchmove', (e) => this.handleTouchMove(e), { passive: false });
    this.svg.addEventListener('touchend', () => this.handleTouchEnd());
  }

  // ─── Coordinate Math (flat-top, matching hex-editor.js) ──────────────

  /**
   * Convert grid cell coordinates to SVG pixel position.
   * Uses world column parity for stagger (same as hex-editor.js:534).
   */
  cellToPixel(cellX, cellY) {
    // cellX maps to column, cellY maps to row
    // World column = originLon + cellX (determines stagger)
    const worldCol = Math.floor(this.originLon) + cellX;

    const x = this.hexRadius + cellX * this.horizSpacing;
    const y = this.hexHeight / 2 + cellY * this.vertSpacing + ((worldCol & 1) ? this.hexHeight / 2 : 0);

    return { x, y };
  }

  /**
   * Generate 6 vertices for flat-top hexagon (matching hex-editor.js:645)
   */
  hexPoints(cx, cy, size) {
    const points = [];
    for (let i = 0; i < 6; i++) {
      const angle = (Math.PI / 3) * i; // flat-top: no offset
      points.push({
        x: cx + size * Math.cos(angle),
        y: cy + size * Math.sin(angle)
      });
    }
    return points;
  }

  /**
   * Feature edge offsets (center to edge midpoint) for flat-top hex.
   * Matches ZonemapService FEATURE_EDGE_OFFSETS.
   */
  featureEdgeOffset(direction) {
    const r = this.hexRadius;
    const h = this.hexHeight;
    const offsets = {
      n:  [0, -(h * 0.5)],
      s:  [0,  (h * 0.5)],
      ne: [ (r * 0.75), -(h * 0.25)],
      nw: [-(r * 0.75), -(h * 0.25)],
      se: [ (r * 0.75),  (h * 0.25)],
      sw: [-(r * 0.75),  (h * 0.25)]
    };
    return offsets[direction] || [0, 0];
  }

  /**
   * Convert SVG pixel back to approximate cell coordinates (for tooltip).
   */
  pixelToCell(svgX, svgY) {
    // Approximate column
    const col = Math.round((svgX - this.hexRadius) / this.horizSpacing);
    const worldCol = Math.floor(this.originLon) + col;
    const yOff = (worldCol & 1) ? this.hexHeight / 2 : 0;
    const row = Math.round((svgY - this.hexHeight / 2 - yOff) / this.vertSpacing);
    return { cellX: col, cellY: row };
  }

  // ─── Data Loading ────────────────────────────────────────────────────

  async loadInitialData() {
    try {
      // Get current location and world info
      const resp = await fetch('/api/journey/map');
      const data = await resp.json();
      if (!data.success) {
        console.error('Failed to load journey map:', data.error);
        return;
      }

      this.currentLocation = data.current_location;
      this.worldId = data.world_id;

      if (!this.currentLocation) return;

      // Load initial region centered on current location (30x20 degrees)
      const lat = this.currentLocation.latitude || 0;
      const lon = this.currentLocation.longitude || 0;
      const halfW = 15;
      const halfH = 10;

      this.originLon = Math.floor(lon - halfW);
      this.originLat = Math.floor(lat + halfH); // max_lat (north = top = y=0)

      await this.loadRegion(lat - halfH, lat + halfH, lon - halfW, lon + halfW);
      this.centerOnCurrentLocation();
    } catch (e) {
      console.error('Error loading initial map data:', e);
    }
  }

  async loadRegion(minLat, maxLat, minLon, maxLon) {
    // Round to integers for caching
    const key = `${Math.floor(minLat)},${Math.ceil(maxLat)},${Math.floor(minLon)},${Math.ceil(maxLon)}`;
    if (this.loadedRegions.has(key)) return;
    this.loadedRegions.add(key);

    this.showLoading(true);

    try {
      const params = new URLSearchParams({
        min_lat: Math.floor(minLat),
        max_lat: Math.ceil(maxLat),
        min_lon: Math.floor(minLon),
        max_lon: Math.ceil(maxLon)
      });

      const resp = await fetch(`/api/journey/hexes?${params}`);
      const data = await resp.json();

      if (!data.success) {
        console.error('Failed to load hex region:', data.error);
        return;
      }

      // Merge hex data
      const region = data.region;
      for (const hex of data.hexes) {
        // Convert API cell coords to our global cell system
        const globalCellX = hex.cell_x + Math.floor(region.min_lon) - Math.floor(this.originLon);
        const globalCellY = hex.cell_y + (Math.floor(this.originLat) - Math.ceil(region.max_lat));

        const mapKey = `${globalCellX},${globalCellY}`;
        if (!this.hexData.has(mapKey)) {
          this.hexData.set(mapKey, { ...hex, globalCellX, globalCellY });
        }
      }

      // Merge locations
      for (const loc of data.locations) {
        if (!this.locations.has(loc.id)) {
          // Convert location lat/lon to global cell coords
          const cellX = Math.floor(loc.longitude) - Math.floor(this.originLon);
          const cellY = Math.floor(this.originLat) - Math.floor(loc.latitude);
          this.locations.set(loc.id, { ...loc, cellX, cellY });
        }
      }

      this.render();
    } catch (e) {
      console.error('Error loading hex region:', e);
    } finally {
      this.showLoading(false);
    }
  }

  showLoading(show) {
    let indicator = this.container.querySelector('.journey-loading-indicator');
    if (show) {
      if (!indicator) {
        indicator = document.createElement('div');
        indicator.className = 'journey-loading-indicator';
        indicator.innerHTML = '<span class="loading loading-spinner loading-sm"></span> Loading...';
        this.container.appendChild(indicator);
      }
      indicator.style.display = 'flex';
    } else if (indicator) {
      indicator.style.display = 'none';
    }
  }

  // ─── Rendering ───────────────────────────────────────────────────────

  render() {
    this.renderTerrain();
    this.renderFeatures();
    this.renderLocations();
    this.renderCurrentLocation();
    this.renderRoute();
    this.updateTransform();
  }

  renderTerrain() {
    this.terrainLayer.innerHTML = '';

    for (const [, hex] of this.hexData) {
      const { x, y } = this.cellToPixel(hex.globalCellX, hex.globalCellY);
      const color = JOURNEY_TERRAIN_COLORS[hex.terrain] || '#8a8a78';
      const points = this.hexPoints(x, y, this.hexRadius);
      const pointsStr = points.map(p => `${p.x.toFixed(1)},${p.y.toFixed(1)}`).join(' ');

      const polygon = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
      polygon.setAttribute('points', pointsStr);
      polygon.setAttribute('fill', color);
      polygon.setAttribute('stroke', 'rgba(255,255,255,0.1)');
      polygon.setAttribute('stroke-width', '0.5');
      polygon.dataset.cellX = hex.globalCellX;
      polygon.dataset.cellY = hex.globalCellY;

      this.terrainLayer.appendChild(polygon);
    }
  }

  renderFeatures() {
    this.featureLayer.innerHTML = '';

    for (const [, hex] of this.hexData) {
      if (!hex.features) continue;

      const { x: cx, y: cy } = this.cellToPixel(hex.globalCellX, hex.globalCellY);

      for (const [dir, featureType] of Object.entries(hex.features)) {
        const color = JOURNEY_FEATURE_COLORS[featureType] || JOURNEY_FEATURE_COLORS.road;
        const [dx, dy] = this.featureEdgeOffset(dir);

        const line = document.createElementNS('http://www.w3.org/2000/svg', 'line');
        line.setAttribute('x1', cx);
        line.setAttribute('y1', cy);
        line.setAttribute('x2', cx + dx);
        line.setAttribute('y2', cy + dy);
        line.setAttribute('stroke', color);
        line.setAttribute('stroke-width', '3');
        line.setAttribute('stroke-linecap', 'round');

        this.featureLayer.appendChild(line);
      }
    }
  }

  renderLocations() {
    this.locationLayer.innerHTML = '';

    for (const [, loc] of this.locations) {
      const { x, y } = this.cellToPixel(loc.cellX, loc.cellY);
      const isSelected = this.selectedDestination?.id === loc.id;
      const isCurrent = this.currentLocation && loc.id === this.currentLocation.id;

      const group = document.createElementNS('http://www.w3.org/2000/svg', 'g');
      group.classList.add('journey-location-marker');
      group.dataset.locationId = loc.id;
      group.style.cursor = isCurrent ? 'default' : 'pointer';

      // Marker circle
      const circle = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
      circle.setAttribute('cx', x);
      circle.setAttribute('cy', y);
      circle.setAttribute('r', isSelected ? 10 : 8);
      circle.setAttribute('fill', isCurrent ? '#00cc44' : (isSelected ? '#ff6600' : '#4488ff'));
      circle.setAttribute('stroke', '#fff');
      circle.setAttribute('stroke-width', isSelected ? '3' : '2');
      group.appendChild(circle);

      // Label
      const label = document.createElementNS('http://www.w3.org/2000/svg', 'text');
      label.setAttribute('x', x);
      label.setAttribute('y', y + this.hexRadius * 0.7);
      label.setAttribute('text-anchor', 'middle');
      label.setAttribute('fill', '#fff');
      label.setAttribute('font-size', '11');
      label.setAttribute('font-weight', 'bold');
      label.setAttribute('style', 'text-shadow: 1px 1px 3px #000, -1px -1px 3px #000');
      label.setAttribute('pointer-events', 'none');
      label.textContent = loc.city_name || loc.name;
      group.appendChild(label);

      // Click handler
      if (!isCurrent) {
        group.addEventListener('click', (e) => {
          e.stopPropagation();
          this.selectDestination(loc);
        });
      }

      // Hover effects
      group.addEventListener('mouseenter', () => {
        if (!isCurrent) circle.setAttribute('r', isSelected ? 12 : 10);
      });
      group.addEventListener('mouseleave', () => {
        circle.setAttribute('r', isSelected ? 10 : 8);
      });

      this.locationLayer.appendChild(group);
    }
  }

  renderCurrentLocation() {
    this.currentLocLayer.innerHTML = '';
    if (!this.currentLocation) return;

    // Find location cell coords
    const cellX = Math.floor(this.currentLocation.longitude) - Math.floor(this.originLon);
    const cellY = Math.floor(this.originLat) - Math.floor(this.currentLocation.latitude);
    const { x, y } = this.cellToPixel(cellX, cellY);

    // Outer pulsing ring
    const pulse = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
    pulse.setAttribute('cx', x);
    pulse.setAttribute('cy', y);
    pulse.setAttribute('r', '12');
    pulse.setAttribute('fill', 'none');
    pulse.setAttribute('stroke', '#00ff44');
    pulse.setAttribute('stroke-width', '2');
    pulse.setAttribute('opacity', '0.7');

    const anim = document.createElementNS('http://www.w3.org/2000/svg', 'animate');
    anim.setAttribute('attributeName', 'r');
    anim.setAttribute('values', '12;18;12');
    anim.setAttribute('dur', '2s');
    anim.setAttribute('repeatCount', 'indefinite');
    pulse.appendChild(anim);

    const animOpacity = document.createElementNS('http://www.w3.org/2000/svg', 'animate');
    animOpacity.setAttribute('attributeName', 'opacity');
    animOpacity.setAttribute('values', '0.7;0.2;0.7');
    animOpacity.setAttribute('dur', '2s');
    animOpacity.setAttribute('repeatCount', 'indefinite');
    pulse.appendChild(animOpacity);

    this.currentLocLayer.appendChild(pulse);

    // "You are here" label above
    const label = document.createElementNS('http://www.w3.org/2000/svg', 'text');
    label.setAttribute('x', x);
    label.setAttribute('y', y - this.hexRadius * 0.8);
    label.setAttribute('text-anchor', 'middle');
    label.setAttribute('fill', '#00ff44');
    label.setAttribute('font-size', '10');
    label.setAttribute('font-weight', 'bold');
    label.setAttribute('style', 'text-shadow: 1px 1px 3px #000');
    label.setAttribute('pointer-events', 'none');
    label.textContent = 'You are here';
    this.currentLocLayer.appendChild(label);
  }

  renderRoute() {
    this.routeLayer.innerHTML = '';
    if (!this.selectedDestination || !this.currentLocation) return;

    const startCellX = Math.floor(this.currentLocation.longitude) - Math.floor(this.originLon);
    const startCellY = Math.floor(this.originLat) - Math.floor(this.currentLocation.latitude);
    const start = this.cellToPixel(startCellX, startCellY);

    const dest = this.selectedDestination;
    const end = this.cellToPixel(dest.cellX, dest.cellY);

    const line = document.createElementNS('http://www.w3.org/2000/svg', 'line');
    line.setAttribute('x1', start.x);
    line.setAttribute('y1', start.y);
    line.setAttribute('x2', end.x);
    line.setAttribute('y2', end.y);
    line.setAttribute('stroke', '#ffcc00');
    line.setAttribute('stroke-width', '3');
    line.setAttribute('stroke-dasharray', '10,5');
    line.setAttribute('opacity', '0.8');
    line.setAttribute('pointer-events', 'none');

    this.routeLayer.appendChild(line);
  }

  // ─── View Transforms ─────────────────────────────────────────────────

  updateTransform() {
    this.contentGroup.setAttribute('transform',
      `translate(${this.offsetX}, ${this.offsetY}) scale(${this.scale})`);
  }

  centerOnCurrentLocation() {
    if (!this.currentLocation) return;

    const cellX = Math.floor(this.currentLocation.longitude) - Math.floor(this.originLon);
    const cellY = Math.floor(this.originLat) - Math.floor(this.currentLocation.latitude);
    const { x, y } = this.cellToPixel(cellX, cellY);

    const rect = this.svg.getBoundingClientRect();
    this.offsetX = rect.width / 2 - x * this.scale;
    this.offsetY = rect.height / 2 - y * this.scale;
    this.updateTransform();
  }

  // ─── Selection ───────────────────────────────────────────────────────

  selectDestination(location) {
    this.selectedDestination = location;
    this.renderLocations();
    this.renderRoute();

    if (this.onDestinationSelect) {
      this.onDestinationSelect(location);
    }
  }

  clearSelection() {
    this.selectedDestination = null;
    this.renderLocations();
    this.renderRoute();
  }

  // ─── Tooltip ─────────────────────────────────────────────────────────

  showTooltip(e) {
    // Convert screen coords to SVG content coords
    const rect = this.svg.getBoundingClientRect();
    const svgX = (e.clientX - rect.left - this.offsetX) / this.scale;
    const svgY = (e.clientY - rect.top - this.offsetY) / this.scale;

    const { cellX, cellY } = this.pixelToCell(svgX, svgY);
    const key = `${cellX},${cellY}`;
    const hex = this.hexData.get(key);

    if (!hex) {
      this.tooltip.style.display = 'none';
      return;
    }

    // Find location at this cell
    let locName = null;
    for (const [, loc] of this.locations) {
      if (loc.cellX === cellX && loc.cellY === cellY) {
        locName = loc.city_name || loc.name;
        break;
      }
    }

    const terrain = JOURNEY_TERRAIN_LABELS[hex.terrain] || hex.terrain;
    let html = `<strong>${terrain}</strong>`;
    if (locName) html = `<strong>${this.escapeHtml(locName)}</strong><br>${terrain}`;
    if (hex.features) {
      const featureList = Object.values(hex.features).map(f => f.charAt(0).toUpperCase() + f.slice(1));
      html += `<br><span style="color:#aaa">${featureList.join(', ')}</span>`;
    }

    this.tooltip.innerHTML = html;
    this.tooltip.style.display = 'block';
    this.tooltip.style.left = (e.clientX - rect.left + 12) + 'px';
    this.tooltip.style.top = (e.clientY - rect.top - 8) + 'px';
  }

  // ─── Mouse Handlers ──────────────────────────────────────────────────

  handleMouseDown(e) {
    if (e.button !== 0) return;
    this.panState.active = true;
    this.panState.moved = false;
    this.panState.startMouseX = e.clientX;
    this.panState.startMouseY = e.clientY;
    this.panState.startOffsetX = this.offsetX;
    this.panState.startOffsetY = this.offsetY;
    this.svg.classList.add('grabbing');
  }

  handleMouseMove(e) {
    if (this.panState.active) {
      const dx = e.clientX - this.panState.startMouseX;
      const dy = e.clientY - this.panState.startMouseY;
      if (Math.abs(dx) > 3 || Math.abs(dy) > 3) this.panState.moved = true;
      this.offsetX = this.panState.startOffsetX + dx;
      this.offsetY = this.panState.startOffsetY + dy;
      this.updateTransform();
      this.tooltip.style.display = 'none';
    } else {
      this.showTooltip(e);
    }
  }

  handleMouseUp() {
    if (this.panState.active && this.panState.moved) {
      this.scheduleEdgeLoad();
    }
    this.panState.active = false;
    this.svg.classList.remove('grabbing');
  }

  handleMouseLeave() {
    this.panState.active = false;
    this.svg.classList.remove('grabbing');
    this.tooltip.style.display = 'none';
  }

  handleWheel(e) {
    e.preventDefault();

    const rect = this.svg.getBoundingClientRect();
    const mouseX = e.clientX - rect.left;
    const mouseY = e.clientY - rect.top;

    const factor = e.deltaY < 0 ? 1.15 : 0.87;
    const newScale = Math.max(this.minScale, Math.min(this.maxScale, this.scale * factor));

    const scaleRatio = newScale / this.scale;
    this.offsetX = mouseX - (mouseX - this.offsetX) * scaleRatio;
    this.offsetY = mouseY - (mouseY - this.offsetY) * scaleRatio;
    this.scale = newScale;

    this.updateTransform();
    this.scheduleEdgeLoad();
  }

  // ─── Touch Handlers ──────────────────────────────────────────────────

  handleTouchStart(e) {
    if (e.touches.length === 1) {
      const t = e.touches[0];
      this.panState.active = true;
      this.panState.moved = false;
      this.panState.startMouseX = t.clientX;
      this.panState.startMouseY = t.clientY;
      this.panState.startOffsetX = this.offsetX;
      this.panState.startOffsetY = this.offsetY;
    }
  }

  handleTouchMove(e) {
    if (e.touches.length === 1 && this.panState.active) {
      e.preventDefault();
      const t = e.touches[0];
      const dx = t.clientX - this.panState.startMouseX;
      const dy = t.clientY - this.panState.startMouseY;
      if (Math.abs(dx) > 3 || Math.abs(dy) > 3) this.panState.moved = true;
      this.offsetX = this.panState.startOffsetX + dx;
      this.offsetY = this.panState.startOffsetY + dy;
      this.updateTransform();
    }
  }

  handleTouchEnd() {
    if (this.panState.active && this.panState.moved) {
      this.scheduleEdgeLoad();
    }
    this.panState.active = false;
  }

  // ─── Lazy Loading ────────────────────────────────────────────────────

  scheduleEdgeLoad() {
    if (this._loadDebounce) clearTimeout(this._loadDebounce);
    this._loadDebounce = setTimeout(() => this.checkEdgeLoad(), 300);
  }

  checkEdgeLoad() {
    // Determine what lat/lon region is currently visible
    const rect = this.svg.getBoundingClientRect();
    if (!rect.width || !rect.height) return;

    // SVG content coords of viewport corners
    const topLeftX = (0 - this.offsetX) / this.scale;
    const topLeftY = (0 - this.offsetY) / this.scale;
    const bottomRightX = (rect.width - this.offsetX) / this.scale;
    const bottomRightY = (rect.height - this.offsetY) / this.scale;

    // Convert to approximate cell coords
    const tl = this.pixelToCell(topLeftX, topLeftY);
    const br = this.pixelToCell(bottomRightX, bottomRightY);

    // Convert cells back to lat/lon with some padding
    const pad = 5;
    const minCellX = tl.cellX - pad;
    const maxCellX = br.cellX + pad;
    const minCellY = tl.cellY - pad;
    const maxCellY = br.cellY + pad;

    const minLon = Math.floor(this.originLon) + minCellX;
    const maxLon = Math.floor(this.originLon) + maxCellX;
    const maxLat = Math.floor(this.originLat) - minCellY;
    const minLat = Math.floor(this.originLat) - maxCellY;

    // Check if we need to load any new region
    // Chunk into 20-degree blocks
    const chunkSize = 20;
    for (let lat = Math.floor(minLat / chunkSize) * chunkSize; lat < maxLat; lat += chunkSize) {
      for (let lon = Math.floor(minLon / chunkSize) * chunkSize; lon < maxLon; lon += chunkSize) {
        const key = `${lat},${lat + chunkSize},${lon},${lon + chunkSize}`;
        if (!this.loadedRegions.has(key)) {
          this.loadRegion(lat, lat + chunkSize, lon, lon + chunkSize);
        }
      }
    }
  }

  // ─── State Persistence ───────────────────────────────────────────────

  saveViewport() {
    try {
      sessionStorage.setItem('journey_viewport', JSON.stringify({
        offsetX: this.offsetX,
        offsetY: this.offsetY,
        scale: this.scale,
        selectedId: this.selectedDestination?.id || null
      }));
    } catch (e) { /* ignore */ }
  }

  restoreViewport() {
    try {
      const saved = sessionStorage.getItem('journey_viewport');
      if (!saved) return false;

      const state = JSON.parse(saved);
      this.offsetX = state.offsetX || 0;
      this.offsetY = state.offsetY || 0;
      this.scale = state.scale || 1.0;
      this.updateTransform();

      // Re-select destination if it was selected
      if (state.selectedId) {
        const loc = this.locations.get(state.selectedId);
        if (loc) this.selectDestination(loc);
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  // ─── Zoom Controls ───────────────────────────────────────────────────

  zoomIn() {
    const rect = this.svg.getBoundingClientRect();
    const cx = rect.width / 2;
    const cy = rect.height / 2;
    const newScale = Math.min(this.maxScale, this.scale * 1.3);
    const ratio = newScale / this.scale;
    this.offsetX = cx - (cx - this.offsetX) * ratio;
    this.offsetY = cy - (cy - this.offsetY) * ratio;
    this.scale = newScale;
    this.updateTransform();
    this.scheduleEdgeLoad();
  }

  zoomOut() {
    const rect = this.svg.getBoundingClientRect();
    const cx = rect.width / 2;
    const cy = rect.height / 2;
    const newScale = Math.max(this.minScale, this.scale * 0.77);
    const ratio = newScale / this.scale;
    this.offsetX = cx - (cx - this.offsetX) * ratio;
    this.offsetY = cy - (cy - this.offsetY) * ratio;
    this.scale = newScale;
    this.updateTransform();
    this.scheduleEdgeLoad();
  }

  recenter() {
    this.centerOnCurrentLocation();
    this.scheduleEdgeLoad();
  }

  escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text || '';
    return div.innerHTML;
  }
}

window.JourneyHexMap = JourneyHexMap;
