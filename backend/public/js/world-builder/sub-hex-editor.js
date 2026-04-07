/**
 * SubHexEditor - Detailed hex editing at feet-level precision
 *
 * When you double-click a hex in the HexEditor, this opens a zoomed-in view
 * showing the interior of that hex at feet-level detail. Used for:
 * - Drawing zone polygons within a single hex
 * - Placing cities/locations with precise positions
 * - Editing sub-hex terrain features
 *
 * One world hex = ~3 miles = 15,840 feet
 */
class SubHexEditor {
  constructor(containerId, options = {}) {
    this.containerId = containerId;
    this.container = document.getElementById(containerId);
    this.svg = null;

    // World hex we're editing - prefer globe_hex_id + lat/lng for identity
    this.worldHexCoords = options.hexCoords || { globe_hex_id: null, lat: 0, lng: 0, x: 0, y: 0 };
    this.worldId = options.worldId || window.WORLD_ID;

    // Terrain data for this hex and its neighbors
    this.terrain = options.terrain || 'unknown';
    this.neighbors = options.neighbors || [];

    // Terrain color map (passed from HexEditor or default)
    this.terrainColors = options.terrainColors || {
      ocean: '#2d5f8a', lake: '#4a8ab5', coast: '#8a9a8d',
      rocky_coast: '#8a8a7d', sandy_coast: '#d4c9a8',
      plain: '#a8b878', grassy_plains: '#a8b878', rocky_plains: '#b0a88a',
      field: '#c4ba8a', forest: '#3a6632', light_forest: '#6d9a52',
      dense_forest: '#3a6632', jungle: '#2d5a2d', swamp: '#5a6b48',
      hill: '#96a07a', grassy_hills: '#96a07a', rocky_hills: '#9a8d78',
      mountain: '#8a7d6b', ice: '#d8e0e4', tundra: '#c8d5d8',
      desert: '#c8b48a', volcanic: '#4a2828', urban: '#7a7a7a',
      light_urban: '#9a9a9a', unknown: '#4a4a4a'
    };

    // Scale: 1 world hex = ~3 miles = 15,840 feet
    this.hexSizeInFeet = 15840;

    // Viewport settings (in feet)
    this.viewportX = 0;
    this.viewportY = 0;
    this.scale = 0.1; // Will be recalculated in show()

    // Drawing state
    this.selectedTool = 'select';
    this.zonePoints = [];
    this.isDrawingZone = false;

    // Existing data in this hex
    this.zones = [];
    this.locations = [];

    // Pan/drag state
    this.isPanning = false;
    this.panStart = { x: 0, y: 0 };
    this.hasDragged = false;

    // Callbacks
    this.onClose = options.onClose || (() => {});
    this.onCityCreate = options.onCityCreate || (() => {});

    this.init();
  }

  init() {
    if (!this.container) {
      console.error('SubHexEditor: Container not found:', this.containerId);
      return;
    }

    this.container.innerHTML = '';
    this.createUI();
    this.bindEvents();
    console.log('SubHexEditor initialized for hex', this.worldHexCoords);
  }

  createUI() {
    // Create wrapper with toolbar and canvas
    const wrapper = document.createElement('div');
    wrapper.className = 'sub-hex-editor-wrapper bg-neutral text-neutral-content';
    wrapper.style.cssText = 'width: 100%; height: 100%; display: flex; flex-direction: column;';

    // Toolbar
    const toolbar = document.createElement('div');
    toolbar.className = 'sub-hex-toolbar';
    toolbar.style.cssText = 'padding: 8px; border-bottom: 1px solid oklch(50% 0 0 / 0.3); display: flex; gap: 8px; align-items: center;';
    toolbar.innerHTML = `
      <button class="btn btn-sm btn-ghost" id="sub-hex-back" title="Back to Globe">
        <i class="bi bi-arrow-left"></i> Back
      </button>
      <span class="text-sm text-neutral-content/70">
        ${this.worldHexCoords.globe_hex_id != null
          ? `Hex #${this.worldHexCoords.globe_hex_id} (${(this.worldHexCoords.lat ?? 0).toFixed(2)}, ${(this.worldHexCoords.lng ?? 0).toFixed(2)})`
          : `Hex (${this.worldHexCoords.x}, ${this.worldHexCoords.y})`}
        <span class="badge badge-sm ml-1" style="background: ${this.terrainColors[this.terrain] || '#333'}; color: #fff;">${this.terrain}</span>
      </span>
      <div class="flex-1"></div>
      <div class="btn-group">
        <button class="btn btn-sm tool-btn active" data-tool="select" title="Select/Pan">
          <i class="bi bi-cursor"></i>
        </button>
        <button class="btn btn-sm tool-btn" data-tool="zone" title="Draw Zone">
          <i class="bi bi-hexagon"></i>
        </button>
      </div>
      <button class="btn btn-sm btn-warning" id="sub-hex-create-city" title="Convert this hex to a city">
        <i class="bi bi-building"></i> Convert to City
      </button>
      <button class="btn btn-sm btn-info" id="sub-hex-create-location" title="Convert this hex to a location">
        <i class="bi bi-geo-alt"></i> Convert to Location
      </button>
    `;

    // Zone drawing toolbar (hidden by default, shown when zone tool is active)
    const zoneToolbar = document.createElement('div');
    zoneToolbar.id = 'sub-hex-zone-toolbar';
    zoneToolbar.className = 'sub-hex-zone-toolbar';
    zoneToolbar.style.cssText = 'display: none; padding: 6px 8px; border-bottom: 1px solid oklch(50% 0 0 / 0.3); gap: 6px; align-items: center;';
    zoneToolbar.innerHTML = `
      <span class="text-sm text-warning mr-2"><i class="bi bi-hexagon"></i> Drawing Zone</span>
      <span class="text-xs text-neutral-content/50 mr-2" id="sub-hex-zone-point-count">0 points</span>
      <div class="flex-1"></div>
      <button class="btn btn-sm btn-ghost" id="sub-hex-zone-undo" title="Undo last point" disabled>
        <i class="bi bi-arrow-counterclockwise"></i> Undo
      </button>
      <button class="btn btn-sm btn-error btn-outline" id="sub-hex-zone-cancel" title="Cancel drawing">
        <i class="bi bi-x-lg"></i> Cancel
      </button>
      <button class="btn btn-sm btn-success" id="sub-hex-zone-finish-plain" title="Finish and save as zone" disabled>
        <i class="bi bi-hexagon"></i> Finish & Save Zone
      </button>
      <button class="btn btn-sm btn-info" id="sub-hex-zone-finish-location" title="Finish and create location" disabled>
        <i class="bi bi-geo-alt"></i> Finish & Make Location
      </button>
      <button class="btn btn-sm btn-warning" id="sub-hex-zone-finish-city" title="Finish and create city" disabled>
        <i class="bi bi-building"></i> Finish & Make City
      </button>
    `;
    wrapper.appendChild(toolbar);
    wrapper.appendChild(zoneToolbar);

    // SVG canvas area
    const canvasArea = document.createElement('div');
    canvasArea.id = 'sub-hex-canvas';
    canvasArea.style.cssText = 'flex: 1; overflow: hidden; position: relative;';
    wrapper.appendChild(canvasArea);

    this.container.appendChild(wrapper);

    // Create SVG
    this.svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    this.svg.id = 'sub-hex-svg';
    this.svg.style.cssText = 'width: 100%; height: 100%; cursor: crosshair;';
    canvasArea.appendChild(this.svg);
  }

  bindEvents() {
    // Tool buttons
    this.container.querySelectorAll('.tool-btn').forEach(btn => {
      btn.addEventListener('click', () => this.selectTool(btn.dataset.tool));
    });

    // Back button
    document.getElementById('sub-hex-back')?.addEventListener('click', () => this.hide());

    // Create city button
    document.getElementById('sub-hex-create-city')?.addEventListener('click', () => this.openCityModal());

    // Create location button
    document.getElementById('sub-hex-create-location')?.addEventListener('click', () => this.openLocationModal());

    // Zone toolbar buttons
    document.getElementById('sub-hex-zone-undo')?.addEventListener('click', () => this.undoZonePoint());
    document.getElementById('sub-hex-zone-cancel')?.addEventListener('click', () => this.cancelZoneDrawing());
    document.getElementById('sub-hex-zone-finish-plain')?.addEventListener('click', () => this.finishZoneAsPlain());
    document.getElementById('sub-hex-zone-finish-location')?.addEventListener('click', () => this.finishZoneAsLocation());
    document.getElementById('sub-hex-zone-finish-city')?.addEventListener('click', () => this.finishZoneAsCity());

    // SVG events
    this.svg.addEventListener('pointerdown', (e) => this.handlePointerDown(e));
    this.svg.addEventListener('pointermove', (e) => this.handlePointerMove(e));
    this.svg.addEventListener('pointerup', (e) => this.handlePointerUp(e));
    this.svg.addEventListener('wheel', (e) => this.handleWheel(e), { passive: false });
    this.svg.addEventListener('dblclick', (e) => this.handleDoubleClick(e));

    // Keyboard
    document.addEventListener('keydown', (e) => this.handleKeyDown(e));
  }

  selectTool(tool) {
    this.selectedTool = tool;
    this.container.querySelectorAll('.tool-btn').forEach(btn => {
      btn.classList.toggle('active', btn.dataset.tool === tool);
      btn.classList.toggle('btn-primary', btn.dataset.tool === tool);
      btn.classList.toggle('btn-ghost', btn.dataset.tool !== tool);
    });

    if (tool !== 'zone') {
      this.zonePoints = [];
      this.isDrawingZone = false;
    }

    // Show/hide zone drawing toolbar
    const zoneToolbar = document.getElementById('sub-hex-zone-toolbar');
    if (zoneToolbar) {
      zoneToolbar.style.display = tool === 'zone' ? 'flex' : 'none';
    }
    this.updateZoneToolbarState();

    this.svg.style.cursor = tool === 'select' ? 'grab' : 'crosshair';
    this.render();
  }

  // Convert screen pixels to feet coordinates
  screenToFeet(screenX, screenY) {
    const rect = this.svg.getBoundingClientRect();
    const x = (screenX - rect.width / 2) / this.scale + this.viewportX;
    const y = (screenY - rect.height / 2) / this.scale + this.viewportY;
    return { x, y };
  }

  // Convert feet coordinates to screen pixels
  feetToScreen(feetX, feetY) {
    const rect = this.svg.getBoundingClientRect();
    const x = (feetX - this.viewportX) * this.scale + rect.width / 2;
    const y = (feetY - this.viewportY) * this.scale + rect.height / 2;
    return { x, y };
  }

  handlePointerDown(e) {
    if (e.button === 0 && this.selectedTool === 'select') {
      this.isPanning = true;
      this.panStart = { x: e.clientX, y: e.clientY };
      this.hasDragged = false;
      this.svg.style.cursor = 'grabbing';
      this.svg.setPointerCapture(e.pointerId);
    } else if (e.button === 0 && this.selectedTool === 'zone') {
      const rect = this.svg.getBoundingClientRect();
      const feet = this.screenToFeet(e.clientX - rect.left, e.clientY - rect.top);
      this.addZonePoint(feet.x, feet.y);
    }
  }

  handlePointerMove(e) {
    if (!this.isPanning) return;

    const dx = e.clientX - this.panStart.x;
    const dy = e.clientY - this.panStart.y;

    if (Math.abs(dx) > 5 || Math.abs(dy) > 5) {
      this.hasDragged = true;
    }

    if (this.hasDragged) {
      this.viewportX -= dx / this.scale;
      this.viewportY -= dy / this.scale;
      this.panStart = { x: e.clientX, y: e.clientY };
      this.render();
    }
  }

  handlePointerUp(e) {
    if (this.isPanning) {
      this.svg.releasePointerCapture(e.pointerId);
      this.isPanning = false;
      this.svg.style.cursor = this.selectedTool === 'select' ? 'grab' : 'crosshair';
    }
  }

  handleWheel(e) {
    e.preventDefault();
    const zoomFactor = e.deltaY > 0 ? 0.9 : 1.1;
    const newScale = this.scale * zoomFactor;

    // Limit zoom range
    if (newScale >= 0.01 && newScale <= 1) {
      this.scale = newScale;
      this.render();
    }
  }

  handleDoubleClick(e) {
    if (this.selectedTool === 'zone' && this.zonePoints.length >= 3) {
      e.preventDefault();
      this.finishZonePolygon();
    }
  }

  handleKeyDown(e) {
    if (e.key === 'Escape') {
      if (this.isDrawingZone) {
        this.cancelZoneDrawing();
      } else {
        this.hide();
      }
    } else if (e.key === 'Enter' && this.zonePoints.length >= 3) {
      this.finishZonePolygon();
    } else if ((e.key === 'z' || e.key === 'Z') && e.ctrlKey && this.isDrawingZone) {
      e.preventDefault();
      this.undoZonePoint();
    }
  }

  addZonePoint(feetX, feetY) {
    this.isDrawingZone = true;
    this.zonePoints.push({ x: feetX, y: feetY });
    this.updateZoneToolbarState();
    this.render();
  }

  undoZonePoint() {
    if (this.zonePoints.length > 0) {
      this.zonePoints.pop();
      if (this.zonePoints.length === 0) {
        this.isDrawingZone = false;
      }
      this.updateZoneToolbarState();
      this.render();
    }
  }

  cancelZoneDrawing() {
    this.zonePoints = [];
    this.isDrawingZone = false;
    this.updateZoneToolbarState();
    this.render();
  }

  updateZoneToolbarState() {
    const count = this.zonePoints.length;
    const countEl = document.getElementById('sub-hex-zone-point-count');
    const undoBtn = document.getElementById('sub-hex-zone-undo');
    const finishPlainBtn = document.getElementById('sub-hex-zone-finish-plain');
    const finishLocBtn = document.getElementById('sub-hex-zone-finish-location');
    const finishCityBtn = document.getElementById('sub-hex-zone-finish-city');

    if (countEl) countEl.textContent = `${count} point${count !== 1 ? 's' : ''}`;
    if (undoBtn) undoBtn.disabled = count === 0;
    if (finishPlainBtn) finishPlainBtn.disabled = count < 3;
    if (finishLocBtn) finishLocBtn.disabled = count < 3;
    if (finishCityBtn) finishCityBtn.disabled = count < 3;
  }

  async finishZoneAsPlain() {
    if (this.zonePoints.length < 3) return;
    await this.finishZoneWithType('plain');
  }

  async finishZoneAsLocation() {
    if (this.zonePoints.length < 3) return;
    await this.finishZoneWithType('location');
  }

  async finishZoneAsCity() {
    if (this.zonePoints.length < 3) return;
    await this.finishZoneWithType('city');
  }

  async finishZoneWithType(zoneType) {
    let zoneName, locationType, zoneSubtype;

    if (zoneType === 'location') {
      try {
        const result = await window.showLocationModal();
        zoneName = result.name;
        locationType = result.locationType;
      } catch {
        return; // user cancelled
      }
    } else if (zoneType === 'city') {
      zoneName = prompt('Enter city name:');
      if (!zoneName) return;
    } else {
      // plain zone (political, area) — use modal for name + type
      try {
        const result = await window.showPlainZoneModal();
        zoneName = result.name;
        zoneType = result.zoneType;
        zoneSubtype = result.zoneSubtype || null;
      } catch {
        return; // user cancelled
      }
    }

    const apiBase = window.API_BASE;
    const csrfToken = window.CSRF_TOKEN;

    try {
      // Create the zone
      const zoneResponse = await fetch(`${apiBase}/sub_hex_zone`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken },
        body: JSON.stringify({
          globe_hex_id: this.worldHexCoords.globe_hex_id,
          lat: this.worldHexCoords.lat,
          lng: this.worldHexCoords.lng,
          name: zoneName,
          zone_type: zoneType,
          zone_subtype: zoneSubtype,
          polygon_points: this.zonePoints,
          polygon_scale: 'local'
        })
      });

      const zoneResult = await zoneResponse.json();
      if (!zoneResult.success) {
        alert('Failed to create zone: ' + (zoneResult.error || zoneResult.errors?.join(', ') || 'Unknown error'));
        return;
      }

      this.zones.push(zoneResult.zone);

      if (zoneType === 'city') {
        // Open the city creation modal pre-filled with zone data
        const cityNameField = document.getElementById('city-name');
        const hexXField = document.getElementById('city-hex-x');
        const hexYField = document.getElementById('city-hex-y');
        const globeHexIdField = document.getElementById('city-globe-hex-id');
        const cityForm = document.getElementById('city-form');

        if (cityNameField) cityNameField.value = zoneName;
        if (hexXField) hexXField.value = this.worldHexCoords.lng ?? this.worldHexCoords.x;
        if (hexYField) hexYField.value = this.worldHexCoords.lat ?? this.worldHexCoords.y;
        if (globeHexIdField) globeHexIdField.value = this.worldHexCoords.globe_hex_id ?? '';
        if (cityForm) cityForm.dataset.zoneId = zoneResult.zone.id;

        const coordsDisplay = document.getElementById('city-coords-display');
        if (coordsDisplay) {
          const hexId = this.worldHexCoords.globe_hex_id;
          const lat = this.worldHexCoords.lat != null ? this.worldHexCoords.lat.toFixed(2) : '?';
          const lng = this.worldHexCoords.lng != null ? this.worldHexCoords.lng.toFixed(2) : '?';
          coordsDisplay.textContent = hexId != null
            ? `Hex #${hexId} (${lat}, ${lng})`
            : `World Hex: (${this.worldHexCoords.x}, ${this.worldHexCoords.y})`;
        }

        const modal = document.getElementById('cityModal');
        if (modal?.showModal) modal.showModal();
      } else {
        // Create a location from the zone, passing zone_id to avoid duplicate zone creation
        const center = this.getPolygonCenter(this.zonePoints);
        const locResponse = await fetch(`${apiBase}/create_location`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken },
          body: JSON.stringify({
            zone_id: zoneResult.zone.id,
            globe_hex_id: this.worldHexCoords.globe_hex_id,
            name: zoneName,
            location_type: locationType,
            feet_x: center.x,
            feet_y: center.y
          })
        });

        const locResult = await locResponse.json();
        if (locResult.success) {
          this.locations.push(locResult.location);
          alert(`Location "${zoneName}" created!`);
          if (locResult.location_id && confirm('Open in Location Editor?')) {
            window.location.href = `/admin/world_builder/${this.worldId}/location/${locResult.location_id}`;
          }
        } else {
          alert('Zone created but location failed: ' + (locResult.error || locResult.errors?.join(', ') || 'Unknown error'));
        }
      }
    } catch (error) {
      console.error('Failed to create zone:', error);
      alert('Error: ' + error.message);
    }

    this.zonePoints = [];
    this.isDrawingZone = false;
    this.updateZoneToolbarState();
    this.render();
  }

  async finishZonePolygon() {
    if (this.zonePoints.length < 3) return;
    await this.finishZoneAsPlain();
  }

  openCityModal() {
    // Set hidden fields for world hex identity
    const hexXField = document.getElementById('city-hex-x');
    const hexYField = document.getElementById('city-hex-y');
    const globeHexIdField = document.getElementById('city-globe-hex-id');
    const coordsDisplay = document.getElementById('city-coords-display');

    if (hexXField) hexXField.value = this.worldHexCoords.lng ?? this.worldHexCoords.x;
    if (hexYField) hexYField.value = this.worldHexCoords.lat ?? this.worldHexCoords.y;
    if (globeHexIdField) globeHexIdField.value = this.worldHexCoords.globe_hex_id ?? '';
    if (coordsDisplay) {
      const hexId = this.worldHexCoords.globe_hex_id;
      const lat = this.worldHexCoords.lat != null ? this.worldHexCoords.lat.toFixed(2) : '?';
      const lng = this.worldHexCoords.lng != null ? this.worldHexCoords.lng.toFixed(2) : '?';
      coordsDisplay.textContent = hexId != null
        ? `Hex #${hexId} (${lat}, ${lng})`
        : `World Hex: (${this.worldHexCoords.x}, ${this.worldHexCoords.y})`;
    }

    const modal = document.getElementById('cityModal');
    if (modal?.showModal) {
      modal.showModal();
    }
  }

  openLocationModal() {
    const name = prompt('Enter location name:');
    if (!name) return;

    this.createLocation(name, this.hexSizeInFeet / 2, this.hexSizeInFeet / 2);
  }

  async createLocation(name, feetX, feetY) {
    const apiBase = window.API_BASE;
    const csrfToken = window.CSRF_TOKEN;

    try {
      const response = await fetch(`${apiBase}/create_location`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken },
        body: JSON.stringify({
          globe_hex_id: this.worldHexCoords.globe_hex_id,
          lat: this.worldHexCoords.lat,
          lng: this.worldHexCoords.lng,
          name: name,
          feet_x: feetX,
          feet_y: feetY
        })
      });

      const result = await response.json();
      if (result.success) {
        this.locations.push(result.location);
        alert(`Location "${name}" created!`);

        if (result.location_id && confirm('Open in Location Editor?')) {
          window.location.href = `/admin/world_builder/${this.worldId}/location/${result.location_id}`;
        }
      } else {
        alert('Failed: ' + (result.error || 'Unknown error'));
      }
    } catch (error) {
      console.error('Failed to create location:', error);
      alert('Error: ' + error.message);
    }

    this.render();
  }

  async loadHexDetails() {
    const apiBase = window.API_BASE;

    try {
      const params = new URLSearchParams();
      if (this.worldHexCoords.globe_hex_id != null) {
        params.set('globe_hex_id', this.worldHexCoords.globe_hex_id);
      } else {
        params.set('x', this.worldHexCoords.x);
        params.set('y', this.worldHexCoords.y);
      }
      const response = await fetch(`${apiBase}/hex_details?${params}`);
      if (!response.ok) throw new Error(`HTTP ${response.status}`);

      const data = await response.json();
      this.zones = data.zones || [];
      this.locations = data.locations || [];
      this.render();
    } catch (error) {
      console.error('Failed to load hex details:', error);
    }
  }

  render() {
    if (!this.svg) return;

    const rect = this.svg.parentElement.getBoundingClientRect();
    const width = rect.width || 800;
    const height = rect.height || 600;

    this.svg.setAttribute('viewBox', `0 0 ${width} ${height}`);
    this.svg.innerHTML = '';

    // Background
    const bg = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
    bg.setAttribute('x', 0);
    bg.setAttribute('y', 0);
    bg.setAttribute('width', width);
    bg.setAttribute('height', height);
    bg.setAttribute('fill', '#1a1a1a');
    this.svg.appendChild(bg);

    // Draw hex boundary (the world hex we're inside)
    this.drawHexBoundary(width, height);

    // Draw grid lines (every 1000 feet)
    this.drawGrid(width, height);

    // Draw existing zones
    this.drawZones();

    // Draw existing locations
    this.drawLocations();

    // Draw zone preview if drawing
    if (this.isDrawingZone && this.zonePoints.length > 0) {
      this.drawZonePreview();
    }

    // Draw scale indicator
    this.drawScaleIndicator(width, height);
  }

  // Draw a single hex polygon at a center position (in feet) with given color
  drawHexAtFeet(centerFeetX, centerFeetY, radiusFeet, fillColor, strokeColor, strokeWidth, opacity) {
    const centerScreen = this.feetToScreen(centerFeetX, centerFeetY);
    const radiusScreen = radiusFeet * this.scale;

    const points = [];
    for (let i = 0; i < 6; i++) {
      const angle = (Math.PI / 3) * i;
      points.push({
        x: centerScreen.x + radiusScreen * Math.cos(angle),
        y: centerScreen.y + radiusScreen * Math.sin(angle)
      });
    }

    const hex = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
    hex.setAttribute('points', points.map(p => `${p.x},${p.y}`).join(' '));
    hex.setAttribute('fill', fillColor);
    hex.setAttribute('stroke', strokeColor);
    hex.setAttribute('stroke-width', strokeWidth);
    if (opacity < 1) hex.setAttribute('opacity', opacity);
    this.svg.appendChild(hex);
    return hex;
  }

  drawHexBoundary(width, height) {
    const centerX = this.hexSizeInFeet / 2;
    const centerY = this.hexSizeInFeet / 2;
    const radius = this.hexSizeInFeet / 2;
    // Distance between hex centers for neighbors
    const neighborDist = radius * Math.sqrt(3);

    // Draw 6 neighbor hexes first (behind center hex)
    // getHexNeighbors returns: [NW, SW, NE, SE, N, S]
    // In SVG coords (Y-down): NW=210°, SW=150°, NE=330°, SE=30°, N=270°, S=90°
    const neighborAngles = [210, 150, 330, 30, 270, 90];
    this.neighbors.forEach((neighbor, i) => {
      const angleDeg = neighborAngles[i];
      const angleRad = (angleDeg * Math.PI) / 180;
      const nx = centerX + neighborDist * Math.cos(angleRad);
      const ny = centerY + neighborDist * Math.sin(angleRad);
      const color = this.terrainColors[neighbor.terrain] || this.terrainColors.unknown;
      this.drawHexAtFeet(nx, ny, radius, color, 'rgba(255,255,255,0.1)', '1', 0.5);
    });

    // Draw center hex with terrain color
    const centerColor = this.terrainColors[this.terrain] || this.terrainColors.unknown;
    this.drawHexAtFeet(centerX, centerY, radius, centerColor, 'rgba(255,255,255,0.4)', '2', 0.8);
  }

  drawGrid(width, height) {
    const gridGroup = document.createElementNS('http://www.w3.org/2000/svg', 'g');
    gridGroup.setAttribute('stroke', 'rgba(255, 255, 255, 0.1)');
    gridGroup.setAttribute('stroke-width', '1');

    // Grid spacing based on zoom level
    let spacing = 1000; // feet
    if (this.scale > 0.2) spacing = 500;
    if (this.scale > 0.5) spacing = 100;

    // Calculate visible range in feet
    const minFeetX = this.viewportX - width / (2 * this.scale);
    const maxFeetX = this.viewportX + width / (2 * this.scale);
    const minFeetY = this.viewportY - height / (2 * this.scale);
    const maxFeetY = this.viewportY + height / (2 * this.scale);

    // Vertical lines
    const startX = Math.floor(minFeetX / spacing) * spacing;
    for (let feetX = startX; feetX <= maxFeetX; feetX += spacing) {
      const screen = this.feetToScreen(feetX, 0);
      const line = document.createElementNS('http://www.w3.org/2000/svg', 'line');
      line.setAttribute('x1', screen.x);
      line.setAttribute('y1', 0);
      line.setAttribute('x2', screen.x);
      line.setAttribute('y2', height);
      gridGroup.appendChild(line);
    }

    // Horizontal lines
    const startY = Math.floor(minFeetY / spacing) * spacing;
    for (let feetY = startY; feetY <= maxFeetY; feetY += spacing) {
      const screen = this.feetToScreen(0, feetY);
      const line = document.createElementNS('http://www.w3.org/2000/svg', 'line');
      line.setAttribute('x1', 0);
      line.setAttribute('y1', screen.y);
      line.setAttribute('x2', width);
      line.setAttribute('y2', screen.y);
      gridGroup.appendChild(line);
    }

    this.svg.appendChild(gridGroup);
  }

  drawZones() {
    this.zones.forEach(zone => {
      if (!zone.polygon_points?.length) return;

      const screenPoints = zone.polygon_points.map(p => {
        const screen = this.feetToScreen(p.x, p.y);
        return `${screen.x},${screen.y}`;
      }).join(' ');

      // Build a click handler that navigates to the appropriate editor
      const handleZoneClick = (e) => {
        e.stopPropagation();
        if (zone.has_city_grid && zone.location_id) {
          window.location.href = `/admin/city_builder/${zone.location_id}`;
        } else if (zone.location_id) {
          window.location.href = `/admin/world_builder/${this.worldId}/location/${zone.location_id}`;
        } else {
          alert(`Zone: ${zone.name}\nType: ${zone.zone_type}\nID: ${zone.id}\n\nThis zone has no associated location yet.`);
        }
      };

      const polygon = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
      polygon.setAttribute('points', screenPoints);
      polygon.setAttribute('fill', 'rgba(23, 162, 184, 0.2)');
      polygon.setAttribute('stroke', '#17a2b8');
      polygon.setAttribute('stroke-width', '2');
      polygon.style.cursor = 'pointer';
      polygon.addEventListener('click', handleZoneClick);
      this.svg.appendChild(polygon);

      // Label
      if (zone.polygon_points.length > 0) {
        const center = this.getPolygonCenter(zone.polygon_points);
        const screenCenter = this.feetToScreen(center.x, center.y);

        const label = document.createElementNS('http://www.w3.org/2000/svg', 'text');
        label.setAttribute('x', screenCenter.x);
        label.setAttribute('y', screenCenter.y);
        label.setAttribute('text-anchor', 'middle');
        label.setAttribute('fill', '#17a2b8');
        label.setAttribute('font-size', '14');
        label.style.cursor = 'pointer';
        label.addEventListener('click', handleZoneClick);
        label.textContent = zone.name;
        this.svg.appendChild(label);
      }
    });
  }

  drawLocations() {
    this.locations.forEach(loc => {
      const screen = this.feetToScreen(loc.feet_x || 0, loc.feet_y || 0);

      // Marker circle
      const circle = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
      circle.setAttribute('cx', screen.x);
      circle.setAttribute('cy', screen.y);
      circle.setAttribute('r', 10);
      circle.setAttribute('fill', '#ffc107');
      circle.setAttribute('stroke', '#fff');
      circle.setAttribute('stroke-width', '2');
      circle.style.cursor = 'pointer';
      circle.addEventListener('click', () => {
        if (loc.has_city_grid) {
          window.location.href = `/admin/city_builder/${loc.id}`;
        } else {
          window.location.href = `/admin/world_builder/${this.worldId}/location/${loc.id}`;
        }
      });
      this.svg.appendChild(circle);

      // Label
      const label = document.createElementNS('http://www.w3.org/2000/svg', 'text');
      label.setAttribute('x', screen.x);
      label.setAttribute('y', screen.y + 20);
      label.setAttribute('text-anchor', 'middle');
      label.setAttribute('fill', '#fff');
      label.setAttribute('font-size', '12');
      label.textContent = loc.name;
      this.svg.appendChild(label);
    });
  }

  drawZonePreview() {
    if (this.zonePoints.length === 0) return;

    const screenPoints = this.zonePoints.map(p => {
      const screen = this.feetToScreen(p.x, p.y);
      return { x: screen.x, y: screen.y };
    });

    // Draw polygon if 3+ points
    if (screenPoints.length >= 3) {
      const polygon = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
      polygon.setAttribute('points', screenPoints.map(p => `${p.x},${p.y}`).join(' '));
      polygon.setAttribute('fill', 'rgba(23, 162, 184, 0.3)');
      polygon.setAttribute('stroke', '#17a2b8');
      polygon.setAttribute('stroke-width', '2');
      polygon.setAttribute('stroke-dasharray', '5,5');
      this.svg.appendChild(polygon);
    }

    // Draw lines
    if (screenPoints.length >= 2) {
      for (let i = 0; i < screenPoints.length - 1; i++) {
        const line = document.createElementNS('http://www.w3.org/2000/svg', 'line');
        line.setAttribute('x1', screenPoints[i].x);
        line.setAttribute('y1', screenPoints[i].y);
        line.setAttribute('x2', screenPoints[i + 1].x);
        line.setAttribute('y2', screenPoints[i + 1].y);
        line.setAttribute('stroke', '#17a2b8');
        line.setAttribute('stroke-width', '2');
        this.svg.appendChild(line);
      }
    }

    // Draw point markers
    screenPoints.forEach((p, i) => {
      const marker = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
      marker.setAttribute('cx', p.x);
      marker.setAttribute('cy', p.y);
      marker.setAttribute('r', i === 0 ? 8 : 5);
      marker.setAttribute('fill', i === 0 ? '#17a2b8' : '#fff');
      marker.setAttribute('stroke', i === 0 ? '#fff' : '#17a2b8');
      marker.setAttribute('stroke-width', '2');
      this.svg.appendChild(marker);
    });
  }

  drawScaleIndicator(width, height) {
    // Draw a scale bar in the corner
    const barLengthFeet = this.scale > 0.3 ? 500 : 1000;
    const barLengthPixels = barLengthFeet * this.scale;

    const x = 20;
    const y = height - 30;

    const line = document.createElementNS('http://www.w3.org/2000/svg', 'line');
    line.setAttribute('x1', x);
    line.setAttribute('y1', y);
    line.setAttribute('x2', x + barLengthPixels);
    line.setAttribute('y2', y);
    line.setAttribute('stroke', '#fff');
    line.setAttribute('stroke-width', '3');
    this.svg.appendChild(line);

    // End caps
    [x, x + barLengthPixels].forEach(capX => {
      const cap = document.createElementNS('http://www.w3.org/2000/svg', 'line');
      cap.setAttribute('x1', capX);
      cap.setAttribute('y1', y - 5);
      cap.setAttribute('x2', capX);
      cap.setAttribute('y2', y + 5);
      cap.setAttribute('stroke', '#fff');
      cap.setAttribute('stroke-width', '2');
      this.svg.appendChild(cap);
    });

    // Label
    const label = document.createElementNS('http://www.w3.org/2000/svg', 'text');
    label.setAttribute('x', x + barLengthPixels / 2);
    label.setAttribute('y', y - 10);
    label.setAttribute('text-anchor', 'middle');
    label.setAttribute('fill', '#fff');
    label.setAttribute('font-size', '12');
    label.textContent = `${barLengthFeet} ft`;
    this.svg.appendChild(label);
  }

  getPolygonCenter(points) {
    const sum = points.reduce((acc, p) => ({
      x: acc.x + (p.x || 0),
      y: acc.y + (p.y || 0)
    }), { x: 0, y: 0 });

    return {
      x: sum.x / points.length,
      y: sum.y / points.length
    };
  }

  show() {
    this.container.style.display = 'block';
    // Center viewport on hex center
    this.viewportX = this.hexSizeInFeet / 2;
    this.viewportY = this.hexSizeInFeet / 2;

    // Calculate scale so the center hex is about 2/3rds of the viewport
    // This leaves room for neighbor hexes to be visible around the edges
    const rect = this.container.getBoundingClientRect();
    const viewSize = Math.min(rect.width || 800, rect.height || 600);
    // hex diameter in feet = hexSizeInFeet; we want it to fill 2/3 of viewport
    this.scale = (viewSize * 0.67) / this.hexSizeInFeet;

    this.loadHexDetails();
    this.render();
  }

  hide() {
    this.container.style.display = 'none';
    this.onClose();
  }
}

// Make available globally
window.SubHexEditor = SubHexEditor;
