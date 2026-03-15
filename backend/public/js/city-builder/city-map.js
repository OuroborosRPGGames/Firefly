/**
 * CityMap - Interactive SVG city editor
 *
 * Features:
 * - Pan (drag) and zoom (scroll wheel)
 * - Display streets, avenues, intersections, blocks, buildings
 * - Create and delete buildings
 * - Navigate to room editor for buildings
 */
class CityMap {
  constructor(containerId, locationId) {
    this.locationId = locationId;
    this.svg = document.getElementById(containerId);
    this.container = this.svg.parentElement;

    // View state
    this.offsetX = 0;
    this.offsetY = 0;
    this.scale = 1;
    this.minScale = 0.25;
    this.maxScale = 4;

    // Pan state
    this.panState = {
      active: false,
      startMouseX: 0,
      startMouseY: 0,
      startOffsetX: 0,
      startOffsetY: 0,
      hasMoved: false
    };

    // Tool state
    this.selectedTool = 'select';
    this.selectedBuildingType = 'house';
    this.selectedElement = null; // { type: 'block'|'building', data: {...} }

    // City data
    this.cityData = null;

    // Colors for building types
    this.categoryColors = {
      residential: '#3498db', // Blue
      commercial: '#e74c3c',  // Red
      civic: '#9b59b6',       // Purple
      recreation: '#2ecc71',  // Green
      infrastructure: '#95a5a6' // Gray
    };

    // Building type to category mapping
    this.buildingCategories = {};

    this.init();
  }

  async init() {
    await this.loadBuildingTypes();
    this.bindEvents();
    await this.loadCityData();
    this.render();
    this.fitToView();
  }

  async loadBuildingTypes() {
    try {
      const response = await fetch(`/admin/city_builder/${this.locationId}/api/building_types`);
      const data = await response.json();

      // Build category lookup
      for (const [category, types] of Object.entries(data)) {
        for (const type of types) {
          this.buildingCategories[type.name] = category;
        }
      }
    } catch (e) {
      console.error('Failed to load building types:', e);
    }
  }

  async loadCityData() {
    try {
      const response = await fetch(`/admin/city_builder/${this.locationId}/api/city`);
      this.cityData = await response.json();
      this.updateBuildingCount();
    } catch (e) {
      console.error('Failed to load city data:', e);
    }
  }

  bindEvents() {
    // Mouse events for pan
    this.svg.addEventListener('mousedown', (e) => this.handleMouseDown(e));
    document.addEventListener('mousemove', (e) => this.handleMouseMove(e));
    document.addEventListener('mouseup', (e) => this.handleMouseUp(e));

    // Wheel event for zoom
    this.svg.addEventListener('wheel', (e) => this.handleWheel(e), { passive: false });

    // Tool buttons
    document.querySelectorAll('.tool-btn').forEach(btn => {
      btn.addEventListener('click', () => this.selectTool(btn.dataset.tool));
    });

    // Building type buttons
    document.querySelectorAll('.building-type-btn').forEach(btn => {
      btn.addEventListener('click', () => this.selectBuildingType(btn.dataset.type));
    });

    // Zoom buttons
    document.getElementById('btn-zoom-in')?.addEventListener('click', () => this.zoom(1.5));
    document.getElementById('btn-zoom-out')?.addEventListener('click', () => this.zoom(0.67));
    document.getElementById('btn-zoom-reset')?.addEventListener('click', () => this.resetZoom());
    document.getElementById('btn-fit-to-view')?.addEventListener('click', () => this.fitToView());

    // Delete button
    document.getElementById('delete-building-btn')?.addEventListener('click', () => this.deleteSelectedBuilding());
  }

  // ==========================================
  // Tool Selection
  // ==========================================

  selectTool(tool) {
    this.selectedTool = tool;

    // Update tool button states
    document.querySelectorAll('.tool-btn').forEach(btn => {
      btn.classList.toggle('active', btn.dataset.tool === tool);
    });

    // Show/hide building palette
    const palette = document.getElementById('building-palette-container');
    if (palette) {
      palette.style.display = tool === 'building' ? 'block' : 'none';
    }

    // Update cursor
    if (tool === 'building') {
      this.svg.style.cursor = 'crosshair';
    } else if (tool === 'delete') {
      this.svg.style.cursor = 'not-allowed';
    } else {
      this.svg.style.cursor = 'grab';
    }
  }

  selectBuildingType(type) {
    this.selectedBuildingType = type;

    // Update button states
    document.querySelectorAll('.building-type-btn').forEach(btn => {
      btn.classList.toggle('active', btn.dataset.type === type);
    });
  }

  // ==========================================
  // Pan and Zoom
  // ==========================================

  handleMouseDown(e) {
    if (e.button !== 0) return; // Left click only

    this.panState.active = true;
    this.panState.startMouseX = e.clientX;
    this.panState.startMouseY = e.clientY;
    this.panState.startOffsetX = this.offsetX;
    this.panState.startOffsetY = this.offsetY;
    this.panState.hasMoved = false;

    // Cache pixel-to-SVG scale for this pan gesture
    const ctm = this.svg.getScreenCTM();
    this.panState.pxToSvgX = ctm ? 1 / ctm.a : 1;
    this.panState.pxToSvgY = ctm ? 1 / ctm.d : 1;

    this.svg.style.cursor = 'grabbing';
    e.preventDefault();
  }

  handleMouseMove(e) {
    // Update coordinates display
    this.updateCoordsDisplay(e);

    if (!this.panState.active) return;

    const dx = e.clientX - this.panState.startMouseX;
    const dy = e.clientY - this.panState.startMouseY;

    if (Math.abs(dx) > 3 || Math.abs(dy) > 3) {
      this.panState.hasMoved = true;
    }

    // Convert pixel delta to SVG viewBox units
    const dxSvg = dx * this.panState.pxToSvgX;
    const dySvg = dy * this.panState.pxToSvgY;

    this.offsetX = this.panState.startOffsetX + dxSvg / this.scale;
    this.offsetY = this.panState.startOffsetY + dySvg / this.scale;

    this.updateTransform();
  }

  handleMouseUp(e) {
    if (!this.panState.active) return;

    this.panState.active = false;
    this.svg.style.cursor = this.selectedTool === 'building' ? 'crosshair' :
                            this.selectedTool === 'delete' ? 'not-allowed' : 'grab';

    // If we didn't pan, treat as click
    if (!this.panState.hasMoved) {
      this.handleClick(e);
    }
  }

  handleWheel(e) {
    e.preventDefault();

    const svgPt = this._clientToSvg(e.clientX, e.clientY);

    // Zoom factor
    const factor = e.deltaY < 0 ? 1.2 : 0.83;
    const newScale = Math.max(this.minScale, Math.min(this.maxScale, this.scale * factor));

    if (newScale === this.scale) return;

    // Adjust offset to zoom toward mouse position (keep game point under cursor fixed)
    const gameMouseX = svgPt.x / this.scale - this.offsetX;
    const gameMouseY = svgPt.y / this.scale - this.offsetY;
    this.offsetX = svgPt.x / newScale - gameMouseX;
    this.offsetY = svgPt.y / newScale - gameMouseY;

    this.scale = newScale;
    this.updateTransform();
    this.updateZoomDisplay();
  }

  zoom(factor) {
    const newScale = Math.max(this.minScale, Math.min(this.maxScale, this.scale * factor));
    if (newScale !== this.scale) {
      this.scale = newScale;
      this.updateTransform();
      this.updateZoomDisplay();
    }
  }

  resetZoom() {
    this.fitToView();
  }

  fitToView() {
    if (!this.cityData) return;

    const grid = this.cityData.grid;

    // The viewBox is sized to fit the city plus padding (set in render()).
    // At scale=1, city coordinates map 1:1 to SVG viewBox coordinates.
    // The browser handles fitting the viewBox into the container.
    this.scale = 1;

    // Center the city in the viewBox.
    // With Y-flip transform: city(cx,cy) → SVG(cx + offsetX, offsetY - cy)
    // City center (W/2, H/2) maps to viewBox center (W/2, H/2):
    //   W/2 + offsetX = W/2  →  offsetX = 0
    //   offsetY - H/2 = H/2  →  offsetY = H
    this.offsetX = 0;
    this.offsetY = grid.height;

    this.updateTransform();
    this.updateZoomDisplay();
  }

  updateTransform() {
    const content = this.svg.querySelector('#city-content');
    if (content) {
      // Y-flip: scale(s, -s) so higher Y (north) renders at top of screen
      content.setAttribute('transform', `translate(${this.offsetX * this.scale}, ${this.offsetY * this.scale}) scale(${this.scale}, ${-this.scale})`);
    }
  }

  // Counter-flip an SVG element so it reads upright despite the Y-axis flip.
  _unflipText(el) {
    const x = parseFloat(el.getAttribute('x') || 0);
    const y = parseFloat(el.getAttribute('y') || 0);
    el.setAttribute('transform', `translate(${x}, ${y}) scale(1, -1) translate(${-x}, ${-y})`);
  }

  // Convert client (screen) coordinates to SVG viewBox coordinates.
  _clientToSvg(clientX, clientY) {
    const ctm = this.svg.getScreenCTM();
    if (!ctm) return { x: 0, y: 0 };
    const pt = new DOMPoint(clientX, clientY).matrixTransform(ctm.inverse());
    return { x: pt.x, y: pt.y };
  }

  updateZoomDisplay() {
    const display = document.getElementById('zoom-level-display');
    if (display) {
      display.textContent = `${Math.round(this.scale * 100)}%`;
    }
  }

  updateCoordsDisplay(e) {
    const svgPt = this._clientToSvg(e.clientX, e.clientY);

    // Convert to city coordinates (Y-flip: negate Y conversion)
    const cityX = Math.round(svgPt.x / this.scale - this.offsetX);
    const cityY = Math.round(this.offsetY - svgPt.y / this.scale);

    const display = document.getElementById('coords-display');
    if (display) {
      display.textContent = `Position: (${cityX}, ${cityY}) ft`;
    }
  }

  updateBuildingCount() {
    const display = document.getElementById('building-count');
    if (display && this.cityData) {
      const count = this.cityData.buildings.length;
      const total = this.cityData.blocks.length;
      display.textContent = `Buildings: ${count}/${total}`;
    }
  }

  // ==========================================
  // Click Handling
  // ==========================================

  handleClick(e) {
    const svgPt = this._clientToSvg(e.clientX, e.clientY);
    const mouseX = svgPt.x / this.scale - this.offsetX;
    const mouseY = this.offsetY - svgPt.y / this.scale;  // Y-flip

    // Find what was clicked
    const clicked = this.findElementAt(mouseX, mouseY);

    if (!clicked) {
      this.clearSelection();
      return;
    }

    if (clicked.type === 'building') {
      if (this.selectedTool === 'delete') {
        this.deleteBuilding(clicked.data.id);
      } else {
        this.selectBuilding(clicked.data);
      }
    } else if (clicked.type === 'block') {
      if (this.selectedTool === 'building' && !clicked.data.has_building) {
        this.createBuilding(clicked.data.grid_x, clicked.data.grid_y);
      } else {
        this.selectBlock(clicked.data);
      }
    }
  }

  findElementAt(x, y) {
    if (!this.cityData) return null;

    // Check buildings first (on top)
    for (const building of this.cityData.buildings) {
      const b = building.bounds;
      if (x >= b.min_x && x <= b.max_x && y >= b.min_y && y <= b.max_y) {
        return { type: 'building', data: building };
      }
    }

    // Check blocks
    for (const block of this.cityData.blocks) {
      const b = block.bounds;
      if (x >= b.min_x && x <= b.max_x && y >= b.min_y && y <= b.max_y) {
        return { type: 'block', data: block };
      }
    }

    return null;
  }

  // ==========================================
  // Selection
  // ==========================================

  clearSelection() {
    this.selectedElement = null;
    this.render();
    this.updateSelectionPanel();
  }

  selectBlock(block) {
    this.selectedElement = { type: 'block', data: block };
    this.render();
    this.updateSelectionPanel();
  }

  selectBuilding(building) {
    this.selectedElement = { type: 'building', data: building };
    this.render();
    this.updateSelectionPanel();
  }

  updateSelectionPanel() {
    const noSelection = document.getElementById('no-selection');
    const blockSelection = document.getElementById('block-selection');
    const buildingSelection = document.getElementById('building-selection');

    // Hide all panels
    if (noSelection) noSelection.style.display = 'none';
    if (blockSelection) blockSelection.style.display = 'none';
    if (buildingSelection) buildingSelection.style.display = 'none';

    if (!this.selectedElement) {
      if (noSelection) noSelection.style.display = 'block';
      return;
    }

    if (this.selectedElement.type === 'block') {
      if (blockSelection) {
        blockSelection.style.display = 'block';
        const block = this.selectedElement.data;

        document.getElementById('block-grid-pos').textContent = `(${block.grid_x}, ${block.grid_y})`;

        // Find street and avenue names
        const streetNames = this.cityData.street_names || [];
        const avenueNames = this.cityData.avenue_names || [];
        document.getElementById('block-street').textContent = streetNames[block.grid_y] || '-';
        document.getElementById('block-avenue').textContent = avenueNames[block.grid_x] || '-';
      }
    } else if (this.selectedElement.type === 'building') {
      if (buildingSelection) {
        buildingSelection.style.display = 'block';
        const building = this.selectedElement.data;

        document.getElementById('building-name').textContent = building.name || 'Building';
        document.getElementById('building-type-badge').textContent =
          (building.building_type || building.type || 'Building').replace(/_/g, ' ');
        document.getElementById('building-grid-pos').textContent = `(${building.grid_x}, ${building.grid_y})`;
        document.getElementById('building-floors').textContent = building.floors || 1;
        document.getElementById('building-rooms').textContent = building.room_count || 0;
        document.getElementById('building-address').textContent = building.street_name || '-';

        // Update edit rooms link
        const editBtn = document.getElementById('edit-rooms-btn');
        if (editBtn) {
          editBtn.href = `/admin/room_builder/${building.id}`;
        }
      }
    }
  }

  // ==========================================
  // Building Operations
  // ==========================================

  async createBuilding(gridX, gridY) {
    try {
      const response = await fetch(`/admin/city_builder/${this.locationId}/api/building`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          grid_x: gridX,
          grid_y: gridY,
          building_type: this.selectedBuildingType
        })
      });

      const result = await response.json();

      if (result.success) {
        await this.loadCityData();
        this.selectBuilding(result.building);
      } else {
        alert('Failed to create building: ' + (result.error || 'Unknown error'));
      }
    } catch (e) {
      console.error('Failed to create building:', e);
      alert('Failed to create building: ' + e.message);
    }
  }

  async deleteBuilding(buildingId) {
    if (!confirm('Are you sure you want to delete this building and all its rooms?')) {
      return;
    }

    try {
      const response = await fetch(`/admin/city_builder/${this.locationId}/api/building/${buildingId}`, {
        method: 'DELETE'
      });

      const result = await response.json();

      if (result.success) {
        this.clearSelection();
        await this.loadCityData();
      } else {
        alert('Failed to delete building: ' + (result.error || 'Unknown error'));
      }
    } catch (e) {
      console.error('Failed to delete building:', e);
      alert('Failed to delete building: ' + e.message);
    }
  }

  deleteSelectedBuilding() {
    if (this.selectedElement?.type === 'building') {
      this.deleteBuilding(this.selectedElement.data.id);
    }
  }

  // ==========================================
  // Rendering
  // ==========================================

  render() {
    if (!this.cityData) return;

    const grid = this.cityData.grid;

    // Set viewBox to city dimensions plus padding
    const padding = 50;
    this.svg.setAttribute('viewBox', `${-padding} ${-padding} ${grid.width + padding * 2} ${grid.height + padding * 2}`);

    // Clear and rebuild SVG content
    this.svg.innerHTML = '';

    // Create a content group for transforms
    const content = document.createElementNS('http://www.w3.org/2000/svg', 'g');
    content.setAttribute('id', 'city-content');
    this.svg.appendChild(content);

    // Draw layers in order
    this.renderBackground(content, grid);
    this.renderStreets(content);
    this.renderIntersections(content);
    this.renderBlocks(content);
    this.renderBuildings(content);
    this.renderLabels(content);

    this.updateTransform();
  }

  renderBackground(parent, grid) {
    // Background grid pattern
    const defs = document.createElementNS('http://www.w3.org/2000/svg', 'defs');

    const pattern = document.createElementNS('http://www.w3.org/2000/svg', 'pattern');
    pattern.setAttribute('id', 'grid-pattern');
    pattern.setAttribute('width', grid.cell_size);
    pattern.setAttribute('height', grid.cell_size);
    pattern.setAttribute('patternUnits', 'userSpaceOnUse');

    const gridLine = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
    gridLine.setAttribute('width', grid.cell_size);
    gridLine.setAttribute('height', grid.cell_size);
    gridLine.setAttribute('fill', 'none');
    gridLine.setAttribute('stroke', 'rgba(255,255,255,0.05)');
    gridLine.setAttribute('stroke-width', '1');
    pattern.appendChild(gridLine);

    defs.appendChild(pattern);
    parent.appendChild(defs);

    // Background rect
    const bg = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
    bg.setAttribute('x', '0');
    bg.setAttribute('y', '0');
    bg.setAttribute('width', grid.width);
    bg.setAttribute('height', grid.height);
    bg.setAttribute('fill', '#1a1d21');
    parent.appendChild(bg);

    // Grid overlay
    const gridBg = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
    gridBg.setAttribute('x', '0');
    gridBg.setAttribute('y', '0');
    gridBg.setAttribute('width', grid.width);
    gridBg.setAttribute('height', grid.height);
    gridBg.setAttribute('fill', 'url(#grid-pattern)');
    parent.appendChild(gridBg);
  }

  renderStreets(parent) {
    // Streets (E-W running, horizontal lines)
    for (const street of this.cityData.streets) {
      const b = street.bounds;
      const rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
      rect.setAttribute('x', b.min_x);
      rect.setAttribute('y', b.min_y);
      rect.setAttribute('width', b.max_x - b.min_x);
      rect.setAttribute('height', b.max_y - b.min_y);
      rect.setAttribute('fill', '#3a3f44');
      rect.setAttribute('class', 'street');
      parent.appendChild(rect);
    }

    // Avenues (N-S running, vertical lines)
    for (const avenue of this.cityData.avenues) {
      const b = avenue.bounds;
      const rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
      rect.setAttribute('x', b.min_x);
      rect.setAttribute('y', b.min_y);
      rect.setAttribute('width', b.max_x - b.min_x);
      rect.setAttribute('height', b.max_y - b.min_y);
      rect.setAttribute('fill', '#3a3f44');
      rect.setAttribute('class', 'avenue');
      parent.appendChild(rect);
    }
  }

  renderIntersections(parent) {
    for (const intersection of this.cityData.intersections) {
      const b = intersection.bounds;
      const rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
      rect.setAttribute('x', b.min_x);
      rect.setAttribute('y', b.min_y);
      rect.setAttribute('width', b.max_x - b.min_x);
      rect.setAttribute('height', b.max_y - b.min_y);
      rect.setAttribute('fill', '#4a5568');
      rect.setAttribute('class', 'intersection');
      parent.appendChild(rect);
    }
  }

  renderBlocks(parent) {
    for (const block of this.cityData.blocks) {
      if (block.has_building) continue; // Buildings render separately

      const b = block.bounds;
      const isSelected = this.selectedElement?.type === 'block' &&
                         this.selectedElement.data.grid_x === block.grid_x &&
                         this.selectedElement.data.grid_y === block.grid_y;

      const rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
      rect.setAttribute('x', b.min_x);
      rect.setAttribute('y', b.min_y);
      rect.setAttribute('width', b.max_x - b.min_x);
      rect.setAttribute('height', b.max_y - b.min_y);
      rect.setAttribute('fill', 'rgba(255,255,255,0.02)');
      rect.setAttribute('stroke', isSelected ? '#0d6efd' : 'rgba(255,255,255,0.1)');
      rect.setAttribute('stroke-width', isSelected ? '3' : '1');
      rect.setAttribute('stroke-dasharray', isSelected ? 'none' : '5,5');
      rect.setAttribute('class', `block ${isSelected ? 'selected' : ''}`);
      rect.setAttribute('data-grid-x', block.grid_x);
      rect.setAttribute('data-grid-y', block.grid_y);
      parent.appendChild(rect);
    }
  }

  renderBuildings(parent) {
    for (const building of this.cityData.buildings) {
      const b = building.bounds;
      const isSelected = this.selectedElement?.type === 'building' &&
                         this.selectedElement.data.id === building.id;

      // Get color based on category
      const category = this.buildingCategories[building.building_type] || 'commercial';
      const color = this.categoryColors[category] || '#95a5a6';

      const rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
      rect.setAttribute('x', b.min_x);
      rect.setAttribute('y', b.min_y);
      rect.setAttribute('width', b.max_x - b.min_x);
      rect.setAttribute('height', b.max_y - b.min_y);
      rect.setAttribute('fill', color);
      rect.setAttribute('fill-opacity', '0.7');
      rect.setAttribute('stroke', isSelected ? '#fff' : color);
      rect.setAttribute('stroke-width', isSelected ? '4' : '2');
      rect.setAttribute('rx', '4');
      rect.setAttribute('class', `building ${isSelected ? 'selected' : ''}`);
      rect.setAttribute('data-id', building.id);
      parent.appendChild(rect);

      // Building label (floor count)
      if (building.floors > 1) {
        const text = document.createElementNS('http://www.w3.org/2000/svg', 'text');
        text.setAttribute('x', (b.min_x + b.max_x) / 2);
        text.setAttribute('y', (b.min_y + b.max_y) / 2);
        text.setAttribute('text-anchor', 'middle');
        text.setAttribute('dominant-baseline', 'middle');
        text.setAttribute('fill', '#fff');
        text.setAttribute('font-size', '20');
        text.setAttribute('font-weight', 'bold');
        text.setAttribute('pointer-events', 'none');
        text.textContent = building.floors;
        parent.appendChild(text);
        this._unflipText(text);
      }
    }
  }

  renderLabels(parent) {
    const grid = this.cityData.grid;

    // Street names (E-W)
    const streetNames = this.cityData.street_names || [];
    for (let i = 0; i < streetNames.length; i++) {
      const y = i * grid.cell_size + grid.street_width / 2;
      const text = document.createElementNS('http://www.w3.org/2000/svg', 'text');
      text.setAttribute('x', grid.width + 10);
      text.setAttribute('y', y);
      text.setAttribute('text-anchor', 'start');
      text.setAttribute('dominant-baseline', 'middle');
      text.setAttribute('fill', '#6c757d');
      text.setAttribute('font-size', '12');
      text.textContent = streetNames[i];
      parent.appendChild(text);
      this._unflipText(text);
    }

    // Avenue names (N-S)
    const avenueNames = this.cityData.avenue_names || [];
    for (let i = 0; i < avenueNames.length; i++) {
      const x = i * grid.cell_size + grid.street_width / 2;
      const text = document.createElementNS('http://www.w3.org/2000/svg', 'text');
      text.setAttribute('x', x);
      text.setAttribute('y', -20);  // Below grid in world-space (south), appears at bottom after Y-flip
      text.setAttribute('text-anchor', 'middle');
      text.setAttribute('fill', '#6c757d');
      text.setAttribute('font-size', '12');
      text.textContent = avenueNames[i];
      parent.appendChild(text);
      this._unflipText(text);
    }
  }
}
