/**
 * WorldMap - Main map canvas component for the World Builder
 *
 * Features:
 * - SVG-based rendering with smooth pan and zoom
 * - Mouse wheel zoom (centered on cursor)
 * - Grab and drag panning
 * - Minimap for orientation
 * - Arrow key navigation
 * - Hierarchical zoom (3x3 grid at each level)
 */
class WorldMap {
  constructor() {
    this.svg = document.getElementById('world-map');
    this.container = document.getElementById('world-map-container');
    this.zoomLevel = 0;
    this.centerX = 1;
    this.centerY = 1;
    this.rotation = 0;

    this.selectedTool = 'select';
    this.selectedTerrain = 'plain';
    this.selectedFeature = 'road';

    this.regions = [];

    // City, Zone, and Link tool state
    this.cities = [];
    this.zones = [];
    this.linkState = { start: null, end: null };
    // Zone polygon drawing state
    this.zoneDrawingState = {
      active: false,
      points: []      // Array of {x, y} hex coordinates
    };

    // Pan state (for grab and drag)
    this.panState = {
      active: false,
      startMouseX: 0,
      startMouseY: 0,
      startCenterX: 0,
      startCenterY: 0
    };

    // Viewport transform for smooth pan/zoom
    this.viewTransform = {
      offsetX: 0,
      offsetY: 0,
      scale: 1
    };

    // Debounce timer for API calls
    this.loadDebounceTimer = null;

    this.init();
  }

  init() {
    this.initTerrainPalette();
    this.initFeaturePalette();
    this.initMinimap();
    this.bindEvents();
    this.bindModalEvents();
    this.loadRegions();
    this.loadCitiesAndZones();
  }

  initTerrainPalette() {
    const palette = document.getElementById('terrain-palette');
    TERRAIN_TYPES.forEach(terrain => {
      const swatch = document.createElement('div');
      swatch.className = 'terrain-swatch' + (terrain.id === this.selectedTerrain ? ' active' : '');
      swatch.style.backgroundColor = terrain.color;
      swatch.title = terrain.label;
      swatch.dataset.terrain = terrain.id;
      swatch.addEventListener('click', () => this.selectTerrain(terrain.id));
      palette.appendChild(swatch);
    });
  }

  initFeaturePalette() {
    const palette = document.getElementById('feature-palette');
    FEATURE_TYPES.forEach(feature => {
      const btn = document.createElement('button');
      btn.className = 'btn btn-outline btn-ghost btn-sm feature-btn' + (feature.id === this.selectedFeature ? ' active' : '');
      btn.style.borderLeftColor = feature.color;
      btn.style.borderLeftWidth = '4px';
      btn.textContent = feature.label;
      btn.dataset.feature = feature.id;
      btn.addEventListener('click', () => this.selectFeature(feature.id));
      palette.appendChild(btn);
    });
  }

  initMinimap() {
    // Create minimap container if it doesn't exist
    let minimapContainer = document.getElementById('minimap-container');
    if (!minimapContainer) {
      minimapContainer = document.createElement('div');
      minimapContainer.id = 'minimap-container';
      minimapContainer.innerHTML = `
        <div class="minimap-title">Overview</div>
        <svg id="minimap" viewBox="0 0 100 100"></svg>
        <div class="minimap-coords" id="minimap-coords">0, 0</div>
      `;

      // Insert after coords display
      const coordsDisplay = document.querySelector('.position-absolute.bottom-0');
      if (coordsDisplay) {
        coordsDisplay.parentNode.insertBefore(minimapContainer, coordsDisplay);
      }
    }
    this.minimap = document.getElementById('minimap');
  }

  bindEvents() {
    // Tool selection
    document.querySelectorAll('.tool-btn').forEach(btn => {
      btn.addEventListener('click', () => this.selectTool(btn.dataset.tool));
    });

    // Zoom controls
    document.getElementById('btn-zoom-in').addEventListener('click', () => this.zoomIn());
    document.getElementById('btn-zoom-out').addEventListener('click', () => this.zoomOut());

    // Rotation controls
    document.getElementById('btn-rotate-left').addEventListener('click', () => this.rotate(-1));
    document.getElementById('btn-rotate-right').addEventListener('click', () => this.rotate(1));

    // Ocean slider
    document.getElementById('gen-ocean').addEventListener('input', (e) => {
      document.getElementById('ocean-value').textContent = e.target.value;
    });

    // Generation buttons
    document.getElementById('btn-generate-random').addEventListener('click', () => this.generateRandom());
    document.getElementById('btn-import-earth').addEventListener('click', () => this.importEarth());

    // Bulk operations
    document.getElementById('btn-all-traversable').addEventListener('click', () => this.setAllTraversable(true));
    document.getElementById('btn-none-traversable').addEventListener('click', () => this.setAllTraversable(false));

    // Keyboard shortcuts
    document.addEventListener('keydown', (e) => this.handleKeydown(e));

    // Mouse events for panning and tools
    this.svg.addEventListener('mousedown', (e) => this.handleMouseDown(e));
    this.svg.addEventListener('mousemove', (e) => this.handleMouseMove(e));
    this.svg.addEventListener('mouseup', (e) => this.handleMouseUp(e));
    this.svg.addEventListener('mouseleave', (e) => this.handleMouseLeave(e));

    // Mouse wheel zoom
    this.svg.addEventListener('wheel', (e) => this.handleWheel(e), { passive: false });

    // Touch events for mobile
    this.svg.addEventListener('touchstart', (e) => this.handleTouchStart(e), { passive: false });
    this.svg.addEventListener('touchmove', (e) => this.handleTouchMove(e), { passive: false });
    this.svg.addEventListener('touchend', (e) => this.handleTouchEnd(e));

    // Prevent context menu on right-click (could use for future features)
    this.svg.addEventListener('contextmenu', (e) => e.preventDefault());
  }

  bindModalEvents() {
    // City modal
    const cityForm = document.getElementById('city-form');
    if (cityForm) {
      cityForm.addEventListener('submit', (e) => {
        e.preventDefault();
        this.createCity();
      });
    }

    // Zone modal
    const zoneForm = document.getElementById('zone-form');
    if (zoneForm) {
      zoneForm.addEventListener('submit', (e) => {
        e.preventDefault();
        this.createZone();
      });
    }

    // Link modal
    const linkForm = document.getElementById('link-form');
    if (linkForm) {
      linkForm.addEventListener('submit', (e) => {
        e.preventDefault();
        this.createLink();
      });
    }

    // Cancel link button
    const cancelLinkBtn = document.getElementById('btn-cancel-link');
    if (cancelLinkBtn) {
      cancelLinkBtn.addEventListener('click', () => this.cancelLink());
    }
  }

  // ========================================
  // MOUSE AND TOUCH HANDLERS
  // ========================================

  handleMouseDown(e) {
    const rect = this.svg.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;

    // Middle mouse button or Space+click for panning (regardless of tool)
    if (e.button === 1 || (e.button === 0 && e.shiftKey)) {
      e.preventDefault();
      this.startPan(e.clientX, e.clientY);
      return;
    }

    // Left mouse button actions
    if (e.button === 0) {
      if (this.selectedTool === 'zone') {
        // Zone tool uses click-to-add-point instead of drag
        // Handled in handleRegionClick
      } else if (this.selectedTool === 'select' && !e.shiftKey) {
        // Select tool can also pan with left mouse
        this.startPan(e.clientX, e.clientY);
      }
    }
  }

  handleMouseMove(e) {
    const rect = this.svg.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;

    // Update coordinates display
    const col = Math.floor(x / (rect.width / 3));
    const row = Math.floor(y / (rect.height / 3));
    const targetX = this.centerX - 1 + col;
    const targetY = this.centerY + 1 - row;
    document.getElementById('coords-display').textContent =
      `Position: (${targetX}, ${targetY}) | Zoom: ${this.zoomLevel} | ${ZOOM_NAMES[this.zoomLevel]}`;

    // Handle panning
    if (this.panState.active) {
      this.updatePan(e.clientX, e.clientY);
      return;
    }

  }

  handleMouseUp(e) {
    // End panning
    if (this.panState.active) {
      this.endPan();
      return;
    }

    // Handle tool-specific actions
    if (e.button === 0) {
      // Click actions (only if we weren't panning)
      const rect = this.svg.getBoundingClientRect();
      const x = e.clientX - rect.left;
      const y = e.clientY - rect.top;
      const col = Math.floor(x / (rect.width / 3));
      const row = Math.floor(y / (rect.height / 3));

      // Find the region at this position
      const region = this.findRegion(col, row);
      this.handleRegionClick(e, col, row, region);
    }
  }

  handleMouseLeave(e) {
    if (this.panState.active) {
      this.endPan();
    }
  }

  handleWheel(e) {
    e.preventDefault();

    const rect = this.svg.getBoundingClientRect();
    const mouseX = e.clientX - rect.left;
    const mouseY = e.clientY - rect.top;

    // Calculate which cell the mouse is over
    const cellSize = rect.width / 3;
    const col = Math.floor(mouseX / cellSize);
    const row = Math.floor(mouseY / cellSize);

    // Clamp to valid range
    const clampedCol = Math.max(0, Math.min(2, col));
    const clampedRow = Math.max(0, Math.min(2, row));

    if (e.deltaY < 0) {
      // Zoom in, centered on the cell under the mouse
      if (this.zoomLevel < 7) {
        // Calculate new center based on mouse position
        this.centerX = (this.centerX - 1 + clampedCol) * 3 + 1;
        this.centerY = (this.centerY + 1 - clampedRow) * 3 + 1;
        this.zoomLevel++;
        this.loadRegionsDebounced();
      }
    } else if (e.deltaY > 0) {
      // Zoom out
      if (this.zoomLevel > 0) {
        this.zoomLevel--;
        // Recalculate center for parent region
        this.centerX = Math.floor((this.centerX + 1) / 3);
        this.centerY = Math.floor((this.centerY + 1) / 3);
        if (this.centerX < 1) this.centerX = 1;
        if (this.centerY < 1) this.centerY = 1;
        this.loadRegionsDebounced();
      }
    }
  }

  // Touch event handlers for mobile
  handleTouchStart(e) {
    if (e.touches.length === 1) {
      const touch = e.touches[0];
      if (this.selectedTool === 'select') {
        this.startPan(touch.clientX, touch.clientY);
      }
    }
  }

  handleTouchMove(e) {
    if (e.touches.length === 1 && this.panState.active) {
      e.preventDefault();
      const touch = e.touches[0];
      this.updatePan(touch.clientX, touch.clientY);
    }
  }

  handleTouchEnd(e) {
    if (this.panState.active) {
      this.endPan();
    }
  }

  // ========================================
  // PANNING
  // ========================================

  startPan(clientX, clientY) {
    this.panState = {
      active: true,
      startMouseX: clientX,
      startMouseY: clientY,
      startCenterX: this.centerX,
      startCenterY: this.centerY,
      hasMoved: false
    };
    this.svg.style.cursor = 'grabbing';
  }

  updatePan(clientX, clientY) {
    if (!this.panState.active) return;

    const rect = this.svg.getBoundingClientRect();
    const cellSize = rect.width / 3;

    // Calculate how many cells we've moved
    const deltaX = clientX - this.panState.startMouseX;
    const deltaY = clientY - this.panState.startMouseY;

    // Mark as moved if we've moved more than a small threshold
    if (Math.abs(deltaX) > 5 || Math.abs(deltaY) > 5) {
      this.panState.hasMoved = true;
    }

    // Apply visual offset (smooth panning)
    this.viewTransform.offsetX = deltaX;
    this.viewTransform.offsetY = deltaY;
    this.applyViewTransform();

    // If we've moved a full cell, update the center and reset offset
    const cellsMovedX = Math.round(-deltaX / cellSize);
    const cellsMovedY = Math.round(deltaY / cellSize);

    if (cellsMovedX !== 0 || cellsMovedY !== 0) {
      // Calculate max bounds based on zoom level
      const maxCoord = Math.pow(3, this.zoomLevel + 1);

      // Update center position
      let newCenterX = this.panState.startCenterX + cellsMovedX;
      let newCenterY = this.panState.startCenterY + cellsMovedY;

      // Clamp to valid range (allow wrapping for X in world view)
      if (this.zoomLevel === 0) {
        // World level - allow horizontal wrapping
        newCenterX = ((newCenterX - 1) % maxCoord + maxCoord) % maxCoord + 1;
      } else {
        // Clamp to bounds
        newCenterX = Math.max(1, Math.min(maxCoord - 1, newCenterX));
      }
      newCenterY = Math.max(1, Math.min(maxCoord - 1, newCenterY));

      if (newCenterX !== this.centerX || newCenterY !== this.centerY) {
        this.centerX = newCenterX;
        this.centerY = newCenterY;

        // Reset the pan start to current position
        this.panState.startMouseX = clientX;
        this.panState.startMouseY = clientY;
        this.panState.startCenterX = this.centerX;
        this.panState.startCenterY = this.centerY;

        // Reset visual offset
        this.viewTransform.offsetX = 0;
        this.viewTransform.offsetY = 0;

        // Load new regions
        this.loadRegionsDebounced();
      }
    }
  }

  endPan() {
    const hasMoved = this.panState.hasMoved;
    this.panState.active = false;
    this.panState.hasMoved = false;

    // Reset visual transform
    this.viewTransform.offsetX = 0;
    this.viewTransform.offsetY = 0;
    this.applyViewTransform();

    // Reset cursor
    this.updateCursor();
  }

  applyViewTransform() {
    const content = this.svg.querySelector('#map-content');
    if (content) {
      content.style.transform = `translate(${this.viewTransform.offsetX}px, ${this.viewTransform.offsetY}px)`;
    }
  }

  // ========================================
  // KEYBOARD HANDLING
  // ========================================

  handleKeydown(e) {
    // Skip keyboard shortcuts when user is in a form field or modal
    const tag = e.target.tagName;
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return;
    if (e.target.isContentEditable) return;

    // Skip if any DaisyUI modal is currently open
    const openModal = document.querySelector('dialog[open]');
    if (openModal) return;

    switch(e.key) {
      case '1': this.selectTool('select'); break;
      case '2': this.selectTool('terrain'); break;
      case '3': this.selectTool('feature'); break;
      case '4': this.selectTool('traversable'); break;
      case '5': this.selectTool('city'); break;
      case '6': this.selectTool('zone'); break;
      case '7': this.selectTool('link'); break;
      case 'Escape': this.cancelCurrentOperation(); break;
      case '+':
      case '=': this.zoomIn(); break;
      case '-': this.zoomOut(); break;
      // Arrow keys for panning
      case 'ArrowLeft':
        e.preventDefault();
        this.panBy(-1, 0);
        break;
      case 'ArrowRight':
        e.preventDefault();
        this.panBy(1, 0);
        break;
      case 'ArrowUp':
        e.preventDefault();
        this.panBy(0, 1);
        break;
      case 'ArrowDown':
        e.preventDefault();
        this.panBy(0, -1);
        break;
      // WASD for panning (alternative)
      case 'a':
      case 'A':
        if (!e.ctrlKey) this.panBy(-1, 0);
        break;
      case 'd':
      case 'D':
        if (!e.ctrlKey) this.panBy(1, 0);
        break;
      case 'w':
      case 'W':
        if (!e.ctrlKey) this.panBy(0, 1);
        break;
      case 's':
      case 'S':
        if (!e.ctrlKey) this.panBy(0, -1);
        break;
      case 'q':
      case 'Q':
        this.rotate(-1);
        break;
      case 'e':
      case 'E':
        this.rotate(1);
        break;
    }
  }

  panBy(dx, dy) {
    const maxCoord = Math.pow(3, this.zoomLevel + 1);

    let newCenterX = this.centerX + dx;
    let newCenterY = this.centerY + dy;

    // Handle wrapping/clamping
    if (this.zoomLevel === 0) {
      newCenterX = ((newCenterX - 1) % maxCoord + maxCoord) % maxCoord + 1;
    } else {
      newCenterX = Math.max(1, Math.min(maxCoord - 1, newCenterX));
    }
    newCenterY = Math.max(1, Math.min(maxCoord - 1, newCenterY));

    if (newCenterX !== this.centerX || newCenterY !== this.centerY) {
      this.centerX = newCenterX;
      this.centerY = newCenterY;
      this.loadRegions();
    }
  }

  // ========================================
  // TOOL SELECTION
  // ========================================

  selectTool(tool) {
    this.selectedTool = tool;

    // Clear link state when switching tools
    if (tool !== 'link') {
      this.linkState = { start: null, end: null };
      this.updateLinkPreview();
    }

    document.querySelectorAll('.tool-btn').forEach(btn => {
      btn.classList.toggle('active', btn.dataset.tool === tool);
      // Handle different button colors
      const isActive = btn.dataset.tool === tool;
      // DaisyUI button state toggling
      if (btn.classList.contains('btn-warning')) {
        btn.classList.toggle('btn-outline', !isActive);
      } else if (btn.classList.contains('btn-info')) {
        btn.classList.toggle('btn-outline', !isActive);
      } else if (btn.classList.contains('btn-success')) {
        btn.classList.toggle('btn-outline', !isActive);
      } else {
        btn.classList.toggle('btn-primary', isActive);
        btn.classList.toggle('btn-outline', !isActive);
        btn.classList.toggle('btn-ghost', !isActive);
      }
    });

    // Show/hide palettes
    document.getElementById('terrain-palette-container').style.display = tool === 'terrain' ? 'block' : 'none';
    document.getElementById('feature-palette-container').style.display = tool === 'feature' ? 'block' : 'none';

    // Update cursor
    this.updateCursor();
  }

  updateCursor() {
    const tool = this.selectedTool;
    if (this.panState.active) {
      this.svg.style.cursor = 'grabbing';
    } else if (tool === 'select') {
      this.svg.style.cursor = 'grab';
    } else if (tool === 'zone') {
      this.svg.style.cursor = 'crosshair';
    } else if (tool === 'city') {
      this.svg.style.cursor = 'cell';
    } else if (tool === 'link') {
      this.svg.style.cursor = 'pointer';
    } else if (tool === 'terrain' || tool === 'feature') {
      this.svg.style.cursor = 'pointer';
    } else {
      this.svg.style.cursor = 'default';
    }
  }

  cancelCurrentOperation() {
    if (this.selectedTool === 'link' && this.linkState.start) {
      this.linkState = { start: null, end: null };
      this.updateLinkPreview();
    }
    if (this.zoneDrawingState.active) {
      this.zoneDrawingState = { active: false, points: [] };
      this.renderZoneDrawingPreview();
    }
  }

  selectTerrain(terrain) {
    this.selectedTerrain = terrain;
    document.querySelectorAll('.terrain-swatch').forEach(swatch => {
      swatch.classList.toggle('active', swatch.dataset.terrain === terrain);
    });
  }

  selectFeature(feature) {
    this.selectedFeature = feature;
    document.querySelectorAll('.feature-btn').forEach(btn => {
      btn.classList.toggle('active', btn.dataset.feature === feature);
    });
  }

  // ========================================
  // DATA LOADING
  // ========================================

  loadRegionsDebounced() {
    // Debounce rapid zoom/pan to avoid hammering the API
    if (this.loadDebounceTimer) {
      clearTimeout(this.loadDebounceTimer);
    }
    this.loadDebounceTimer = setTimeout(() => this.loadRegions(), 100);
  }

  async loadRegions() {
    try {
      const response = await fetch(
        `${API_BASE}/regions?zoom=${this.zoomLevel}&center_x=${this.centerX}&center_y=${this.centerY}`,
        { headers: { 'Accept': 'application/json' } }
      );
      const data = await response.json();

      if (data.success) {
        this.regions = data.regions;
        this.render();
        this.updateMinimap();
      }
    } catch (error) {
      console.error('Failed to load regions:', error);
    }
  }

  // ========================================
  // RENDERING
  // ========================================

  render() {
    const svg = this.svg;
    svg.innerHTML = '';

    // Create a group for transformable content
    const content = document.createElementNS('http://www.w3.org/2000/svg', 'g');
    content.id = 'map-content';
    content.style.transition = 'transform 0.1s ease-out';
    svg.appendChild(content);

    const viewSize = 600;
    const cellSize = viewSize / 3;
    const padding = 8;

    // Create 3x3 grid
    for (let row = 0; row < 3; row++) {
      for (let col = 0; col < 3; col++) {
        const region = this.findRegion(col, row);
        const x = col * cellSize + padding;
        const y = row * cellSize + padding;
        const size = cellSize - padding * 2;

        const color = region ? this.getTerrainColor(region.dominant_terrain) : '#1a1a2e';

        // Create region rectangle with rounded corners
        const rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
        rect.setAttribute('x', x);
        rect.setAttribute('y', y);
        rect.setAttribute('width', size);
        rect.setAttribute('height', size);
        rect.setAttribute('fill', color);
        rect.setAttribute('class', 'map-region');
        rect.setAttribute('rx', '12');
        rect.setAttribute('ry', '12');
        rect.dataset.col = col;
        rect.dataset.row = row;
        rect.dataset.regionId = region?.id || '';
        content.appendChild(rect);

        // Draw feature indicators
        if (region) {
          this.drawFeatureIndicators(content, x, y, size, region);
        }

        // Add terrain label
        const label = document.createElementNS('http://www.w3.org/2000/svg', 'text');
        label.setAttribute('x', x + size / 2);
        label.setAttribute('y', y + size / 2 + 5);
        label.setAttribute('class', 'region-label');
        label.textContent = region ? this.formatTerrainLabel(region.dominant_terrain) : 'Empty';
        content.appendChild(label);

        // Add coordinates label (smaller, at bottom)
        const coordLabel = document.createElementNS('http://www.w3.org/2000/svg', 'text');
        coordLabel.setAttribute('x', x + size / 2);
        coordLabel.setAttribute('y', y + size - 10);
        coordLabel.setAttribute('class', 'coord-label');
        const coordX = this.centerX - 1 + col;
        const coordY = this.centerY + 1 - row;
        coordLabel.textContent = `(${coordX}, ${coordY})`;
        content.appendChild(coordLabel);

        // Draw grid border
        const border = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
        border.setAttribute('x', x);
        border.setAttribute('y', y);
        border.setAttribute('width', size);
        border.setAttribute('height', size);
        border.setAttribute('class', 'region-border');
        border.setAttribute('rx', '12');
        border.setAttribute('ry', '12');
        content.appendChild(border);
      }
    }

    this.updateZoomDisplay();

    // Re-render overlays
    this.renderZoneOverlays();
    this.renderCityMarkers();
    this.updateLinkPreview();
    this.renderZoneDrawingPreview();
    this.updateCursor();
  }

  formatTerrainLabel(terrain) {
    if (!terrain) return 'Empty';
    return terrain.charAt(0).toUpperCase() + terrain.slice(1);
  }

  findRegion(col, row) {
    // Map grid position to actual region coordinates based on current view
    const targetX = this.centerX - 1 + col;
    const targetY = this.centerY + 1 - row;

    return this.regions.find(r =>
      r.region_x === targetX &&
      r.region_y === targetY &&
      r.zoom_level === this.zoomLevel
    );
  }

  drawFeatureIndicators(parent, x, y, size, region) {
    const indicatorSize = 12;
    const indicatorY = y + size - 25;
    let indicatorX = x + 15;

    const features = [];
    if (region.has_road) features.push({ color: '#7f8c8d', label: 'R' });
    if (region.has_river) features.push({ color: '#3498db', label: 'W' });
    if (region.has_railway) features.push({ color: '#1c2833', label: 'T' });

    features.forEach(feature => {
      // Background circle
      const circle = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
      circle.setAttribute('cx', indicatorX);
      circle.setAttribute('cy', indicatorY);
      circle.setAttribute('r', indicatorSize / 2);
      circle.setAttribute('fill', feature.color);
      circle.setAttribute('stroke', '#fff');
      circle.setAttribute('stroke-width', '2');
      circle.setAttribute('class', 'feature-indicator');
      parent.appendChild(circle);

      indicatorX += 18;
    });
  }

  getTerrainColor(terrain) {
    const t = TERRAIN_TYPES.find(t => t.id === terrain);
    return t ? t.color : '#1a1a2e';
  }

  // ========================================
  // MINIMAP
  // ========================================

  updateMinimap() {
    if (!this.minimap) return;

    this.minimap.innerHTML = '';

    // Calculate the visible area relative to total world size
    const maxCoord = Math.pow(3, this.zoomLevel + 1);
    const viewportSize = 3; // We show 3x3 at any zoom level

    // Draw world background
    const bg = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
    bg.setAttribute('x', '0');
    bg.setAttribute('y', '0');
    bg.setAttribute('width', '100');
    bg.setAttribute('height', '100');
    bg.setAttribute('fill', '#1a1a2e');
    bg.setAttribute('rx', '4');
    this.minimap.appendChild(bg);

    // Draw simplified regions as colored dots
    const dotSize = Math.max(2, Math.floor(80 / maxCoord));
    const offsetX = 10;
    const offsetY = 10;

    this.regions.forEach(region => {
      const px = offsetX + (region.region_x * 80 / maxCoord);
      const py = offsetY + ((maxCoord - 1 - region.region_y) * 80 / maxCoord);

      const dot = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
      dot.setAttribute('x', px);
      dot.setAttribute('y', py);
      dot.setAttribute('width', dotSize);
      dot.setAttribute('height', dotSize);
      dot.setAttribute('fill', this.getTerrainColor(region.dominant_terrain));
      this.minimap.appendChild(dot);
    });

    // Draw viewport indicator
    const vpX = offsetX + ((this.centerX - 1.5) * 80 / maxCoord);
    const vpY = offsetY + ((maxCoord - this.centerY - 1.5) * 80 / maxCoord);
    const vpSize = (3 * 80 / maxCoord);

    const viewport = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
    viewport.setAttribute('x', Math.max(offsetX, vpX));
    viewport.setAttribute('y', Math.max(offsetY, vpY));
    viewport.setAttribute('width', Math.min(vpSize, 80));
    viewport.setAttribute('height', Math.min(vpSize, 80));
    viewport.setAttribute('fill', 'none');
    viewport.setAttribute('stroke', '#e74c3c');
    viewport.setAttribute('stroke-width', '2');
    viewport.setAttribute('rx', '2');
    this.minimap.appendChild(viewport);

    // Update coordinates display
    const coordsEl = document.getElementById('minimap-coords');
    if (coordsEl) {
      coordsEl.textContent = `${this.centerX}, ${this.centerY}`;
    }
  }

  // ========================================
  // REGION INTERACTIONS
  // ========================================

  handleRegionClick(e, col, row, region) {
    // Skip if this was a drag/pan operation
    if (this.panState.hasMoved || this.dragState.active) return;

    const hexX = this.centerX - 1 + col;
    const hexY = this.centerY + 1 - row;

    if (this.selectedTool === 'select') {
      // With select tool, single click zooms in (double click could be something else)
      // But since we now use select for panning, only zoom on double-click
      // Actually, let's make it a quick click (no movement) zooms in
      this.centerX = (this.centerX - 1 + col) * 3 + 1;
      this.centerY = (this.centerY - 1 + row) * 3 + 1;
      this.zoomIn();
    } else if (this.selectedTool === 'terrain' && region) {
      this.setRegionTerrain(region, this.selectedTerrain);
    } else if (this.selectedTool === 'traversable' && region) {
      this.toggleRegionTraversable(region);
    } else if (this.selectedTool === 'city') {
      this.showCityModal(hexX, hexY);
    } else if (this.selectedTool === 'zone') {
      this.handleZoneClick(hexX, hexY);
    } else if (this.selectedTool === 'link') {
      this.handleLinkClick(hexX, hexY);
    }
  }

  async setRegionTerrain(region, terrain) {
    // Update local state immediately for responsiveness
    region.dominant_terrain = terrain;
    this.render();

    // TODO: Implement API call to update hexes
  }

  async toggleRegionTraversable(region) {
    // Toggle traversable percentage
    const newTraversable = region.traversable_percentage < 50;
    region.traversable_percentage = newTraversable ? 100 : 0;
    this.render();

    // TODO: Implement API call to update hexes
  }

  // ========================================
  // ZOOM AND ROTATION
  // ========================================

  zoomIn() {
    if (this.zoomLevel >= 7) return;
    this.zoomLevel++;
    this.loadRegions();
  }

  zoomOut() {
    if (this.zoomLevel <= 0) return;
    this.zoomLevel--;
    // Recalculate center for parent region
    this.centerX = Math.floor((this.centerX + 1) / 3);
    this.centerY = Math.floor((this.centerY + 1) / 3);
    if (this.centerX < 1) this.centerX = 1;
    if (this.centerY < 1) this.centerY = 1;
    this.loadRegions();
  }

  rotate(direction) {
    this.rotation = (this.rotation + direction + 4) % 4;
    // Adjust center X for rotation (horizontal scroll)
    const maxX = Math.pow(3, this.zoomLevel + 1);
    this.centerX = (this.centerX + direction * Math.floor(maxX / 4) + maxX) % maxX;
    if (this.centerX < 1) this.centerX = 1;
    this.loadRegions();
  }

  updateZoomDisplay() {
    const display = document.getElementById('zoom-level-display');
    display.textContent = `${this.zoomLevel} - ${ZOOM_NAMES[this.zoomLevel] || 'Unknown'}`;

    document.getElementById('btn-zoom-out').disabled = this.zoomLevel <= 0;
    document.getElementById('btn-zoom-in').disabled = this.zoomLevel >= 7;
  }

  // ========================================
  // GENERATION
  // ========================================

  async generateRandom() {
    const seed = document.getElementById('gen-seed').value || null;
    const oceanCoverage = parseInt(document.getElementById('gen-ocean').value);

    try {
      const response = await fetch(`${API_BASE}/generate`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': CSRF_TOKEN
        },
        body: JSON.stringify({
          type: 'procedural',
          options: { seed, ocean_coverage: oceanCoverage, flat_grid: true }
        })
      });

      const data = await response.json();
      if (data.success) {
        this.showProgress(data.job);
        this.pollGenerationStatus();
      } else {
        alert(data.error || 'Failed to start generation');
      }
    } catch (error) {
      console.error('Generation failed:', error);
      alert('Failed to start generation');
    }
  }

  async importEarth() {
    if (!confirm('Import real Earth terrain data (~28 million hexes). This takes 30-60 minutes. Continue?')) return;

    try {
      const response = await fetch(`${API_BASE}/generate`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': CSRF_TOKEN
        },
        body: JSON.stringify({
          type: 'earth_import',
          options: { high_res: true }
        })
      });

      const data = await response.json();
      if (data.success) {
        this.showProgress(data.job);
        this.pollGenerationStatus();
      } else {
        alert(data.error || 'Failed to start import');
      }
    } catch (error) {
      console.error('Import failed:', error);
      alert('Failed to start import');
    }
  }

  showProgress(job) {
    document.getElementById('generation-progress').style.display = 'block';
    this.updateProgress(job);
  }

  updateProgress(job) {
    const bar = document.getElementById('progress-bar');
    const status = document.getElementById('progress-status');

    bar.style.width = `${job.progress_percentage}%`;
    bar.textContent = `${Math.round(job.progress_percentage)}%`;
    status.textContent = job.status === 'running' ?
      `Generating... (${job.completed_regions}/${job.total_regions} regions)` :
      job.status;
  }

  async pollGenerationStatus() {
    try {
      const response = await fetch(`${API_BASE}/generation_status`);
      const data = await response.json();

      if (data.success && data.job) {
        this.updateProgress(data.job);

        if (data.job.status === 'running' || data.job.status === 'pending') {
          setTimeout(() => this.pollGenerationStatus(), 1000);
        } else if (data.job.status === 'completed') {
          document.getElementById('generation-progress').style.display = 'none';
          this.loadRegions();
        } else if (data.job.status === 'failed') {
          alert('Generation failed: ' + (data.job.error_message || 'Unknown error'));
          document.getElementById('generation-progress').style.display = 'none';
        }
      }
    } catch (error) {
      console.error('Status poll failed:', error);
    }
  }

  async setAllTraversable(traversable) {
    if (!confirm(`Set ALL hexes to ${traversable ? 'traversable' : 'non-traversable'}?`)) return;

    // This would need backend implementation
    alert('Bulk traversability update not yet implemented');
  }

  // ========================================
  // CITY, ZONE, AND LINK TOOLS
  // ========================================

  async loadCitiesAndZones() {
    try {
      const [citiesRes, zonesRes] = await Promise.all([
        fetch(`${API_BASE}/cities`, { headers: { 'Accept': 'application/json' } }),
        fetch(`${API_BASE}/zones`, { headers: { 'Accept': 'application/json' } })
      ]);

      const citiesData = await citiesRes.json();
      const zonesData = await zonesRes.json();

      if (citiesData.success) {
        this.cities = citiesData.cities || [];
      }
      if (zonesData.success) {
        this.zones = zonesData.zones || [];
      }

      // Re-render to show markers and overlays
      this.renderCityMarkers();
      this.renderZoneOverlays();
    } catch (error) {
      console.error('Failed to load cities/zones:', error);
    }
  }

  // ========================================
  // CITY TOOL
  // ========================================

  showCityModal(hexX, hexY) {
    // Store coordinates for form submission
    document.getElementById('city-hex-x').value = hexX;
    document.getElementById('city-hex-y').value = hexY;
    document.getElementById('city-coords-display').textContent = `Hex: (${hexX}, ${hexY})`;

    // Reset form
    document.getElementById('city-name').value = '';
    document.getElementById('city-horizontal-streets').value = '10';
    document.getElementById('city-vertical-streets').value = '10';
    document.getElementById('city-max-height').value = '200';

    // Show modal (DaisyUI native dialog)
    const modal = document.getElementById('cityModal');
    if (modal?.showModal) modal.showModal();
  }

  async createCity() {
    const hexX = parseInt(document.getElementById('city-hex-x').value);
    const hexY = parseInt(document.getElementById('city-hex-y').value);
    const cityName = document.getElementById('city-name').value.trim();
    const horizontalStreets = parseInt(document.getElementById('city-horizontal-streets').value) || 10;
    const verticalStreets = parseInt(document.getElementById('city-vertical-streets').value) || 10;
    const maxHeight = parseInt(document.getElementById('city-max-height').value) || 200;

    if (!cityName) {
      alert('Please enter a city name');
      return;
    }

    try {
      const response = await fetch(`${API_BASE}/city`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': CSRF_TOKEN
        },
        body: JSON.stringify({
          hex_x: hexX,
          hex_y: hexY,
          city_name: cityName,
          horizontal_streets: horizontalStreets,
          vertical_streets: verticalStreets,
          max_building_height: maxHeight
        })
      });

      const data = await response.json();

      if (data.success) {
        // Close modal (DaisyUI native dialog)
        const modal = document.getElementById('cityModal');
        if (modal?.close) modal.close();

        // Reload cities and re-render
        await this.loadCitiesAndAreas();
        alert(`City "${cityName}" created with ${data.rooms_created} rooms!`);
      } else {
        alert(data.error || 'Failed to create city');
      }
    } catch (error) {
      console.error('Failed to create city:', error);
      alert('Failed to create city');
    }
  }

  // ========================================
  // ZONE TOOL (POLYGON DRAWING)
  // ========================================

  handleZoneClick(hexX, hexY) {
    if (!this.zoneDrawingState.active) {
      // Start new polygon
      this.zoneDrawingState.active = true;
      this.zoneDrawingState.points = [{x: hexX, y: hexY}];
    } else {
      // Check if clicking first point to close polygon (within 0.5 hex distance)
      const firstPoint = this.zoneDrawingState.points[0];
      const distance = Math.hypot(hexX - firstPoint.x, hexY - firstPoint.y);

      if (distance < 0.5 && this.zoneDrawingState.points.length >= 3) {
        // Close polygon and show creation modal
        this.finishZoneDrawing();
      } else {
        // Add point to polygon
        this.zoneDrawingState.points.push({x: hexX, y: hexY});
      }
    }
    this.renderZoneDrawingPreview();
  }

  finishZoneDrawing() {
    const points = this.zoneDrawingState.points;
    this.zoneDrawingState.active = false;

    if (points.length < 3) {
      this.zoneDrawingState.points = [];
      this.renderZoneDrawingPreview();
      alert('A zone needs at least 3 points.');
      return;
    }

    this.showZoneModal(points);
  }

  renderZoneDrawingPreview() {
    // Remove existing preview
    this.svg.querySelectorAll('.zone-preview').forEach(el => el.remove());

    if (!this.zoneDrawingState.active || this.zoneDrawingState.points.length < 1) return;

    const content = this.svg.querySelector('#map-content');
    if (!content) return;

    const viewSize = 600;
    const cellSize = viewSize / 3;
    const points = this.zoneDrawingState.points;

    // Convert hex coords to screen coords
    const screenPoints = points.map(p => {
      const col = p.x - (this.centerX - 1);
      const row = (this.centerY + 1) - p.y;
      return {
        x: col * cellSize + cellSize / 2,
        y: row * cellSize + cellSize / 2,
        visible: col >= 0 && col <= 2 && row >= 0 && row <= 2
      };
    }).filter(p => p.visible);

    if (screenPoints.length < 1) return;

    // Draw polygon outline
    if (screenPoints.length >= 2) {
      const polygon = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
      polygon.setAttribute('points', screenPoints.map(p => `${p.x},${p.y}`).join(' '));
      polygon.setAttribute('class', 'zone-preview');
      polygon.setAttribute('fill', 'rgba(100, 149, 237, 0.3)');
      polygon.setAttribute('stroke', '#4169E1');
      polygon.setAttribute('stroke-width', '2');
      polygon.setAttribute('stroke-dasharray', '5,5');
      content.appendChild(polygon);
    }

    // Draw vertex handles
    screenPoints.forEach((p, i) => {
      const circle = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
      circle.setAttribute('cx', p.x);
      circle.setAttribute('cy', p.y);
      circle.setAttribute('r', i === 0 ? '8' : '5');  // First point larger
      circle.setAttribute('class', 'zone-preview zone-vertex');
      circle.setAttribute('fill', i === 0 ? '#FF6B6B' : '#4169E1');
      circle.setAttribute('stroke', 'white');
      circle.setAttribute('stroke-width', '2');
      circle.setAttribute('data-index', i);
      content.appendChild(circle);
    });

    // Draw point count indicator
    const countText = document.createElementNS('http://www.w3.org/2000/svg', 'text');
    countText.setAttribute('x', '10');
    countText.setAttribute('y', '20');
    countText.setAttribute('class', 'zone-preview');
    countText.setAttribute('fill', 'white');
    countText.setAttribute('font-size', '12');
    countText.textContent = `Zone: ${points.length} points (click first point to close)`;
    content.appendChild(countText);
  }

  showZoneModal(points) {
    // Store points for form submission
    document.getElementById('zone-polygon-points').value = JSON.stringify(points);
    document.getElementById('zone-points-display').textContent =
      `Polygon: ${points.length} vertices`;

    // Reset form
    document.getElementById('zone-name').value = '';
    document.getElementById('zone-type').value = 'wilderness';
    document.getElementById('zone-danger').value = '1';
    document.getElementById('zone-danger-value').textContent = '1';

    // Show modal (DaisyUI native dialog)
    const modal = document.getElementById('zoneModal');
    if (modal?.showModal) modal.showModal();
  }

  async createZone() {
    const polygonPoints = JSON.parse(document.getElementById('zone-polygon-points').value || '[]');
    const zoneName = document.getElementById('zone-name').value.trim();
    const zoneType = document.getElementById('zone-type').value;
    const dangerLevel = parseInt(document.getElementById('zone-danger').value) || 1;

    if (!zoneName) {
      alert('Please enter a zone name');
      return;
    }

    if (polygonPoints.length < 3) {
      alert('A zone needs at least 3 points');
      return;
    }

    try {
      const response = await fetch(`${API_BASE}/zone`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': CSRF_TOKEN
        },
        body: JSON.stringify({
          name: zoneName,
          zone_type: zoneType,
          danger_level: dangerLevel,
          polygon_points: polygonPoints
        })
      });

      const data = await response.json();

      if (data.success) {
        // Close modal (DaisyUI native dialog)
        const modal = document.getElementById('zoneModal');
        if (modal?.close) modal.close();

        // Clear drawing state
        this.zoneDrawingState = { active: false, points: [] };
        this.renderZoneDrawingPreview();

        // Reload zones and re-render
        await this.loadCitiesAndZones();
        alert(`Zone "${zoneName}" created!`);
      } else {
        alert(data.error || 'Failed to create zone');
      }
    } catch (error) {
      console.error('Failed to create zone:', error);
      alert('Failed to create zone');
    }
  }

  // ========================================
  // LINK TOOL
  // ========================================

  handleLinkClick(hexX, hexY) {
    if (!this.linkState.start) {
      // First click - set start point
      this.linkState.start = { x: hexX, y: hexY };
      this.updateLinkPreview();

      // Update modal display
      document.getElementById('link-start-display').textContent = `Start: (${hexX}, ${hexY})`;
      document.getElementById('link-end-display').textContent = 'End: Click another hex...';
    } else {
      // Second click - set end point and show modal
      this.linkState.end = { x: hexX, y: hexY };
      this.updateLinkPreview();

      document.getElementById('link-end-display').textContent = `End: (${hexX}, ${hexY})`;

      // Store coordinates in hidden fields
      document.getElementById('link-start-x').value = this.linkState.start.x;
      document.getElementById('link-start-y').value = this.linkState.start.y;
      document.getElementById('link-end-x').value = hexX;
      document.getElementById('link-end-y').value = hexY;

      // Show modal (DaisyUI native dialog)
      const modal = document.getElementById('linkModal');
      if (modal?.showModal) modal.showModal();
    }
  }

  cancelLink() {
    this.linkState = { start: null, end: null };
    this.updateLinkPreview();

    // Close modal if open (DaisyUI native dialog)
    const modal = document.getElementById('linkModal');
    if (modal?.close) modal.close();
  }

  updateLinkPreview() {
    // Remove existing preview
    const existing = document.querySelectorAll('.link-preview-element');
    existing.forEach(el => el.remove());

    if (!this.linkState.start) return;

    const content = this.svg.querySelector('#map-content');
    if (!content) return;

    const viewSize = 600;
    const cellSize = viewSize / 3;

    // Calculate screen position of start point
    const startCol = this.linkState.start.x - (this.centerX - 1);
    const startRow = (this.centerY + 1) - this.linkState.start.y;

    if (startCol < 0 || startCol > 2 || startRow < 0 || startRow > 2) return;

    const startScreenX = startCol * cellSize + cellSize / 2;
    const startScreenY = startRow * cellSize + cellSize / 2;

    // Draw start marker
    const startMarker = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
    startMarker.setAttribute('cx', startScreenX);
    startMarker.setAttribute('cy', startScreenY);
    startMarker.setAttribute('r', '15');
    startMarker.setAttribute('class', 'link-start-marker link-preview-element');
    content.appendChild(startMarker);

    // If we have an end point, draw line
    if (this.linkState.end) {
      const endCol = this.linkState.end.x - (this.centerX - 1);
      const endRow = (this.centerY + 1) - this.linkState.end.y;

      if (endCol >= 0 && endCol <= 2 && endRow >= 0 && endRow <= 2) {
        const endScreenX = endCol * cellSize + cellSize / 2;
        const endScreenY = endRow * cellSize + cellSize / 2;

        const line = document.createElementNS('http://www.w3.org/2000/svg', 'line');
        line.setAttribute('x1', startScreenX);
        line.setAttribute('y1', startScreenY);
        line.setAttribute('x2', endScreenX);
        line.setAttribute('y2', endScreenY);
        line.setAttribute('class', 'link-preview-line link-preview-element');
        content.appendChild(line);

        const endMarker = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
        endMarker.setAttribute('cx', endScreenX);
        endMarker.setAttribute('cy', endScreenY);
        endMarker.setAttribute('r', '15');
        endMarker.setAttribute('class', 'link-end-marker link-preview-element');
        content.appendChild(endMarker);
      }
    }
  }

  async createLink() {
    const startX = parseInt(document.getElementById('link-start-x').value);
    const startY = parseInt(document.getElementById('link-start-y').value);
    const endX = parseInt(document.getElementById('link-end-x').value);
    const endY = parseInt(document.getElementById('link-end-y').value);
    const featureType = document.getElementById('link-feature-type').value;

    try {
      const response = await fetch(`${API_BASE}/link`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': CSRF_TOKEN
        },
        body: JSON.stringify({
          start_hex_x: startX,
          start_hex_y: startY,
          end_hex_x: endX,
          end_hex_y: endY,
          feature_type: featureType
        })
      });

      const data = await response.json();

      if (data.success) {
        // Close modal (DaisyUI native dialog)
        const modal = document.getElementById('linkModal');
        if (modal?.close) modal.close();

        // Clear link state
        this.linkState = { start: null, end: null };
        this.updateLinkPreview();

        // Reload map to show new features
        this.loadRegions();
        alert(`Link created! Path length: ${data.path_length} hexes, ${data.hexes_updated} updated`);
      } else {
        alert(data.error || 'Failed to create link');
      }
    } catch (error) {
      console.error('Failed to create link:', error);
      alert('Failed to create link');
    }
  }

  // ========================================
  // RENDERING OVERLAYS
  // ========================================

  renderCityMarkers() {
    // Remove existing markers
    this.svg.querySelectorAll('.city-marker').forEach(el => el.remove());
    this.svg.querySelectorAll('.city-label').forEach(el => el.remove());

    const content = this.svg.querySelector('#map-content');
    if (!content) return;

    const viewSize = 600;
    const cellSize = viewSize / 3;

    this.cities.forEach(city => {
      if (!city.hex_x || !city.hex_y) return;

      // Check if city is visible in current view
      const col = city.hex_x - (this.centerX - 1);
      const row = (this.centerY + 1) - city.hex_y;

      if (col < 0 || col > 2 || row < 0 || row > 2) return;

      const x = col * cellSize + cellSize / 2;
      const y = row * cellSize + cellSize / 2;

      // City marker (red circle with building icon)
      const marker = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
      marker.setAttribute('cx', x);
      marker.setAttribute('cy', y);
      marker.setAttribute('r', '16');
      marker.setAttribute('class', 'city-marker');
      marker.setAttribute('data-city-id', city.id);
      marker.style.cursor = 'pointer';
      marker.setAttribute('title', `Edit ${city.city_name || city.name} in City Builder`);

      // Click handler to navigate to City Builder
      marker.addEventListener('click', (e) => {
        e.stopPropagation();
        if (city.city_built_at) {
          window.location.href = `/admin/city_builder/${city.id}`;
        } else {
          alert(`City "${city.city_name || city.name}" has not been built yet. Use the city creation modal to build it.`);
        }
      });

      content.appendChild(marker);

      // City label
      const label = document.createElementNS('http://www.w3.org/2000/svg', 'text');
      label.setAttribute('x', x);
      label.setAttribute('y', y - 25);
      label.setAttribute('class', 'city-label');
      label.textContent = city.city_name || city.name;
      content.appendChild(label);
    });
  }

  renderZoneOverlays() {
    // Remove existing overlays
    this.svg.querySelectorAll('.zone-overlay').forEach(el => el.remove());
    this.svg.querySelectorAll('.zone-label').forEach(el => el.remove());

    const content = this.svg.querySelector('#map-content');
    if (!content) return;

    const viewSize = 600;
    const cellSize = viewSize / 3;

    const zoneColors = {
      wilderness: 'rgba(46, 204, 113, 0.3)',
      city: 'rgba(155, 89, 182, 0.3)',
      dungeon: 'rgba(231, 76, 60, 0.3)',
      underground: 'rgba(127, 140, 141, 0.3)',
      water: 'rgba(52, 152, 219, 0.3)',
      sky: 'rgba(236, 240, 241, 0.3)'
    };

    this.zones.forEach(zone => {
      const polygonPoints = zone.polygon_points || [];

      if (polygonPoints.length < 3) return;

      // Convert polygon points to screen coordinates
      const screenPoints = polygonPoints.map(p => {
        const col = p.x - (this.centerX - 1);
        const row = (this.centerY + 1) - p.y;
        return {
          x: col * cellSize + cellSize / 2,
          y: row * cellSize + cellSize / 2,
          visible: col >= -0.5 && col <= 2.5 && row >= -0.5 && row <= 2.5
        };
      });

      // Check if any points are visible
      const hasVisiblePoints = screenPoints.some(p => p.visible);
      if (!hasVisiblePoints) return;

      // Draw zone polygon overlay
      const polygon = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
      polygon.setAttribute('points', screenPoints.map(p => `${p.x},${p.y}`).join(' '));
      polygon.setAttribute('fill', zoneColors[zone.zone_type] || 'rgba(128, 128, 128, 0.3)');
      polygon.setAttribute('stroke', (zoneColors[zone.zone_type] || 'rgba(128, 128, 128, 0.3)').replace('0.3', '0.8'));
      polygon.setAttribute('stroke-width', '2');
      polygon.setAttribute('class', 'zone-overlay');
      content.appendChild(polygon);

      // Calculate centroid for label placement
      const centroidX = screenPoints.reduce((sum, p) => sum + p.x, 0) / screenPoints.length;
      const centroidY = screenPoints.reduce((sum, p) => sum + p.y, 0) / screenPoints.length;

      // Zone label
      const label = document.createElementNS('http://www.w3.org/2000/svg', 'text');
      label.setAttribute('x', centroidX);
      label.setAttribute('y', centroidY);
      label.setAttribute('class', 'zone-label');
      label.setAttribute('text-anchor', 'middle');
      label.setAttribute('dominant-baseline', 'middle');
      label.textContent = zone.name;
      content.appendChild(label);
    });
  }
}

// Initialize when DOM is ready (only if the required elements exist)
document.addEventListener('DOMContentLoaded', () => {
  // Only initialize WorldMap if the required elements exist
  // (editor.erb uses GlobeView/HexEditor instead)
  if (document.getElementById('world-map') && document.getElementById('world-map-container')) {
    window.worldMap = new WorldMap();
  }
});
