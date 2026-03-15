const ROOM_TYPE_COLORS = {
  residence: 'rgba(139, 119, 101, 0.15)',
  bedroom: 'rgba(139, 119, 101, 0.15)',
  living_room: 'rgba(139, 119, 101, 0.15)',
  kitchen: 'rgba(204, 136, 51, 0.12)',
  bathroom: 'rgba(100, 149, 237, 0.12)',
  shop: 'rgba(160, 140, 80, 0.12)',
  commercial: 'rgba(160, 140, 80, 0.12)',
  bar: 'rgba(139, 69, 19, 0.12)',
  restaurant: 'rgba(139, 69, 19, 0.12)',
  hallway: 'rgba(128, 128, 128, 0.08)',
  lobby: 'rgba(128, 128, 128, 0.08)',
  temple: 'rgba(128, 80, 160, 0.12)',
  church: 'rgba(128, 80, 160, 0.12)',
  storage: 'rgba(100, 100, 80, 0.10)',
  warehouse: 'rgba(100, 100, 80, 0.10)',
  apartment: 'rgba(139, 119, 101, 0.12)',
  office: 'rgba(70, 130, 180, 0.10)',
  attic: 'rgba(160, 140, 100, 0.10)',
  basement: 'rgba(80, 80, 90, 0.12)',
};

/**
 * Room Editor - Main SVG canvas editor for Room Builder
 */
class RoomEditor {
  constructor(svgElement) {
    this.svg = svgElement;
    this.roomData = null;
    this.currentTool = 'select';
    this.selectedItem = null;
    this.selectedType = null;
    this.zoom = 1;
    this.pan = { x: 0, y: 0 };
    this.gridSize = 10;
    this.showGrid = true;
    this.snapToGrid = true;
    this.showLabels = true;

    // Floor navigation
    this.floorControls = null;

    // Drawing state
    this.isDrawing = false;
    this.drawStart = null;
    this.drawRect = null;

    // Polygon drawing state (advanced mode)
    this.drawingMode = 'simple';  // 'simple' or 'advanced'
    this.polygonPoints = [];      // For advanced mode vertex collection

    // Dragging state
    this.isDragging = false;
    this.dragStart = null;
    this.dragOffset = null;

    // Panning state
    this.isPanning = false;
    this.panStart = null;
    this.panStartOffset = null;

    // Layers
    this.gridLayer = this.svg.querySelector('#gridLayer');
    this.zoneLayer = this.svg.querySelector('#zoneLayer');
    this.roomLayer = this.svg.querySelector('#roomLayer');
    this.subroomLayer = this.svg.querySelector('#subroomLayer');
    this.furnitureLayer = this.svg.querySelector('#furnitureLayer');
    this.featureLayer = this.svg.querySelector('#featureLayer');
    this.exitLayer = this.svg.querySelector('#exitLayer');
    this.decorationLayer = this.svg.querySelector('#decorationLayer');
    this.selectionLayer = this.svg.querySelector('#selectionLayer');

    this.setupEventListeners();
  }

  setupEventListeners() {
    // Tool selection
    document.querySelectorAll('.tool-btn').forEach(btn => {
      btn.addEventListener('click', () => this.setTool(btn.dataset.tool));
    });

    // Canvas events
    this.svg.addEventListener('mousedown', e => this.onMouseDown(e));
    this.svg.addEventListener('mousemove', e => this.onMouseMove(e));
    this.svg.addEventListener('mouseup', e => this.onMouseUp(e));
    this.svg.addEventListener('mouseleave', e => this.onMouseUp(e));
    this.svg.addEventListener('wheel', e => this.onWheel(e));
    this.svg.addEventListener('contextmenu', e => e.preventDefault());

    // Zoom controls
    document.getElementById('zoomIn')?.addEventListener('click', () => this.setZoom(this.zoom * 1.2));
    document.getElementById('zoomOut')?.addEventListener('click', () => this.setZoom(this.zoom / 1.2));
    document.getElementById('zoomReset')?.addEventListener('click', () => this.setZoom(1));

    // View toggles
    document.getElementById('showGrid')?.addEventListener('change', e => {
      this.showGrid = e.target.checked;
      this.renderGrid();
    });
    document.getElementById('snapToGrid')?.addEventListener('change', e => {
      this.snapToGrid = e.target.checked;
    });
    document.getElementById('showLabels')?.addEventListener('change', e => {
      this.showLabels = e.target.checked;
      this.render();
    });

    // Delete button
    document.getElementById('deleteSelectedBtn')?.addEventListener('click', () => this.deleteSelected());

    // Drawing mode toggle
    document.querySelectorAll('input[name="drawingMode"]').forEach(radio => {
      radio.addEventListener('change', e => {
        this.drawingMode = e.target.value;
        this.clearPolygonDrawing();
        this.updateDrawingModeHelp();
      });
    });

    // Save button
    document.getElementById('saveBtn')?.addEventListener('click', () => this.saveRoomProperties());

    // Keyboard shortcuts
    document.addEventListener('keydown', e => this.onKeyDown(e));
  }

  async loadRoom() {
    try {
      const result = await window.roomAPI.getRoom();
      this.roomData = result.room;
      // Exits are spatial/read-only. Keep legacy key for older UI paths.
      if (!Array.isArray(this.roomData.exits) && Array.isArray(this.roomData.spatial_exits)) {
        this.roomData.exits = this.roomData.spatial_exits;
      }
      window.ROOM_DATA = this.roomData;

      // Initialize floor controls
      const floorContainer = document.getElementById('floorControls');
      if (floorContainer && !this.floorControls) {
        this.floorControls = new FloorControls(floorContainer);
        this.floorControls.onFloorChange = () => {
          this.render();
          this.updateElementsList();
          const floorLabel = document.getElementById('floorLabel');
          if (floorLabel) floorLabel.textContent = this.floorControls.currentFloorLabel();
        };
      }
      if (this.floorControls) {
        this.floorControls.update(this.roomData);
        const floorLabel = document.getElementById('floorLabel');
        if (floorLabel) floorLabel.textContent = this.floorControls.currentFloorLabel();
      }

      this.render(); // applyTransform() inside render() calls drawZoneShading()
      this.updateElementsList();
      this.updateRoomInfo();
    } catch (error) {
      console.error('Failed to load room:', error);
      alert('Failed to load room data: ' + error.message);
    }
  }

  setTool(tool) {
    this.currentTool = tool;
    document.querySelectorAll('.tool-btn').forEach(btn => {
      btn.classList.toggle('active', btn.dataset.tool === tool);
    });
    this.clearSelection();
    this.clearPolygonDrawing();

    // Show/hide drawing mode section for subroom tool
    const drawingModeSection = document.getElementById('drawingModeSection');
    if (drawingModeSection) {
      drawingModeSection.style.display = tool === 'subroom' ? 'block' : 'none';
    }

    // Show furniture catalog for furniture tool
    if (tool === 'furniture') {
      window.furnitureCatalog?.show();
    }
  }

  setZoom(zoom) {
    this.zoom = Math.max(0.1, Math.min(100, zoom));
    const pct = Math.round(this.zoom * 100);
    document.getElementById('zoomLevel').textContent = `Zoom: ${pct}%`;
    const resetBtn = document.getElementById('zoomReset');
    if (resetBtn) resetBtn.textContent = pct === 100 ? '1:1' : `${pct}%`;
    this.applyTransform();
    this.updateScaleBar();
  }

  _computeTransform() {
    const roomWidth = (this.roomData?.max_x ?? 100) - (this.roomData?.min_x ?? 0);
    const roomHeight = (this.roomData?.max_y ?? 100) - (this.roomData?.min_y ?? 0);
    const svgRect = this.svg.getBoundingClientRect();
    const scale = Math.min(svgRect.width / roomWidth, svgRect.height / roomHeight) * 0.9 * this.zoom;
    const minX = this.roomData?.min_x ?? 0;
    const minY = this.roomData?.min_y ?? 0;
    const maxY = this.roomData?.max_y ?? 100;
    const offsetX = (svgRect.width - roomWidth * scale) / 2 - minX * scale + this.pan.x;
    // Y-flip: higher Y (north) at top of screen. scale(scale, -scale) negates Y,
    // so we offset to re-center: screen_y = -(worldY * scale) + offsetY
    const offsetY = (svgRect.height + (minY + maxY) * scale) / 2 + this.pan.y;
    return { scale, offsetX, offsetY, svgRect };
  }

  // Counter-flip an SVG element so it reads upright despite the Y-axis flip.
  // The layer transform uses scale(s, -s), which mirrors text/foreignObject.
  // This applies a local SVG transform that flips it back around its center.
  _unflipText(el) {
    const x = parseFloat(el.getAttribute('x') || 0);
    const y = parseFloat(el.getAttribute('y') || 0);
    const w = parseFloat(el.getAttribute('width') || 0);
    const h = parseFloat(el.getAttribute('height') || 0);
    // For text (no w/h), x,y is the anchor point. For foreignObject, use center.
    const cx = w ? x + w / 2 : x;
    const cy = h ? y + h / 2 : y;
    el.setAttribute('transform', `translate(${cx}, ${cy}) scale(1, -1) translate(${-cx}, ${-cy})`);
  }

  labelFontSize(baseSizeFeet) {
    const roomWidth = (this.roomData?.max_x ?? 100) - (this.roomData?.min_x ?? 0);
    const roomHeight = (this.roomData?.max_y ?? 100) - (this.roomData?.min_y ?? 0);
    const roomSize = Math.max(roomWidth, roomHeight);
    // Scale label to ~2.5% of room size, clamped between 1 and 4 feet
    const autoSize = Math.max(1, Math.min(4, roomSize * 0.025));
    const base = baseSizeFeet ?? autoSize;
    const { scale } = this._computeTransform();
    const minScreenPx = 9;
    const minFeetSize = minScreenPx / scale;
    return Math.max(minFeetSize, base);
  }

  updateScaleBar() {
    const { scale } = this._computeTransform();
    const barEl = document.getElementById('scaleBarLine');
    const labelEl = document.getElementById('scaleBarLabel');
    if (!barEl || !labelEl) return;

    const targetBarPx = 80;
    const feetPerPx = 1 / scale;
    const rawFeet = targetBarPx * feetPerPx;

    const niceSteps = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000];
    let niceFeet = niceSteps[0];
    for (const step of niceSteps) {
      if (step <= rawFeet * 1.5) niceFeet = step;
    }

    const barWidthPx = niceFeet * scale;
    barEl.style.width = barWidthPx + 'px';
    labelEl.textContent = niceFeet + ' ft';
  }

  applyTransform() {
    const { scale, offsetX, offsetY } = this._computeTransform();
    // Y-flip: scale(scale, -scale) so higher Y (north) renders at top of screen
    const t = `translate(${offsetX}, ${offsetY}) scale(${scale}, ${-scale})`;

    this.roomLayer.setAttribute('transform', t);
    this.zoneLayer.setAttribute('transform', t);
    this.subroomLayer.setAttribute('transform', t);
    this.furnitureLayer.setAttribute('transform', t);
    this.featureLayer.setAttribute('transform', t);
    this.exitLayer.setAttribute('transform', t);
    this.decorationLayer.setAttribute('transform', t);
    this.selectionLayer.setAttribute('transform', t);
    this.gridLayer.setAttribute('transform', t);

    this.drawZoneShading(this.roomData?.zone_polygon);
    this.updateScaleBar();
  }

  drawZoneShading(zonePolygon) {
    this.zoneLayer.innerHTML = '';
    if (!zonePolygon || zonePolygon.length < 3) return;

    // All coordinates are in feet — same space as gridLayer/roomLayer.
    // The zoneLayer receives the same translate+scale transform as all other
    // layers, so we draw directly in feet coordinates here.
    //
    // Technique: evenodd fill rule with a huge outer rectangle minus the zone
    // polygon. Everything outside the zone polygon gets shaded; inside is clear.
    const minX = this.roomData?.min_x ?? 0;
    const minY = this.roomData?.min_y ?? 0;
    const maxX = this.roomData?.max_x ?? 100;
    const maxY = this.roomData?.max_y ?? 100;
    const pad = Math.max(maxX - minX, maxY - minY) * 2 + 1000;

    // Outer rectangle path (clockwise winding)
    const outerRect = `M ${minX - pad} ${minY - pad} L ${maxX + pad} ${minY - pad} L ${maxX + pad} ${maxY + pad} L ${minX - pad} ${maxY + pad} Z`;

    // Inner zone polygon path (counter-clockwise ensures evenodd cuts it out)
    // Build points from the zone_polygon array of {x, y} objects.
    const pts = zonePolygon.map(p => `${p.x},${p.y}`);
    const innerPolygon = `M ${pts[0]} L ${pts.slice(1).join(' L ')} Z`;

    const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    path.setAttribute('d', `${outerRect} ${innerPolygon}`);
    path.setAttribute('fill-rule', 'evenodd');
    path.setAttribute('fill', 'rgba(0,0,0,0.35)');
    path.setAttribute('pointer-events', 'none');
    this.zoneLayer.appendChild(path);
  }

  getMousePos(e) {
    const { scale, offsetX, offsetY, svgRect: rect } = this._computeTransform();

    let x = (e.clientX - rect.left - offsetX) / scale;
    // Y-flip: screen Y maps to negative world Y (scale is -scale for Y axis)
    let y = (e.clientY - rect.top - offsetY) / (-scale);

    if (this.snapToGrid) {
      x = Math.round(x / this.gridSize) * this.gridSize;
      y = Math.round(y / this.gridSize) * this.gridSize;
    }

    return { x, y };
  }

  startPanning(e) {
    this.isPanning = true;
    this.panStart = { x: e.clientX, y: e.clientY };
    this.panStartOffset = { x: this.pan.x, y: this.pan.y };
    this.svg.style.cursor = 'grabbing';
  }

  onMouseDown(e) {
    const pos = this.getMousePos(e);
    const target = e.target.closest('[data-item-type]');

    // Middle-click or right-click always pans, regardless of tool
    if (e.button === 1 || e.button === 2) {
      e.preventDefault();
      this.startPanning(e);
      return;
    }

    // Subroom clicks always navigate (any tool)
    if (target && target.dataset.itemType === 'subroom') {
      const subroomId = parseInt(target.dataset.itemId);
      window.location.href = `/admin/room_builder/${subroomId}`;
      return;
    }

    if (this.currentTool === 'select') {
      if (target) {
        this.selectItem(target.dataset.itemType, parseInt(target.dataset.itemId));
        this.isDragging = true;
        this.dragStart = pos;
        this.dragOffset = {
          x: pos.x - (this.selectedItem?.x || 0),
          y: pos.y - (this.selectedItem?.y || 0)
        };
      } else {
        this.clearSelection();
        this.startPanning(e);
      }
    } else if (this.currentTool === 'subroom') {
      if (this.drawingMode === 'advanced') {
        this.addPolygonPoint(pos);
        return;
      }
      this.isDrawing = true;
      this.drawStart = pos;
    } else if (this.currentTool === 'furniture') {
      if (window.furnitureCatalog?.selectedItem) {
        this.placeFurniture(pos);
      } else {
        this.startPanning(e);
      }
    } else if (this.currentTool === 'door' || this.currentTool === 'window') {
      // Always place on nearest edge - no distance check for tool clicks
      this.placeFeature(pos, this.currentTool);
    } else if (this.currentTool === 'decoration') {
      if (!target) {
        this.placeDecoration(pos);
      }
    }
  }

  onMouseMove(e) {
    const pos = this.getMousePos(e);
    document.getElementById('cursorPosition').textContent = `X: ${Math.round(pos.x)}, Y: ${Math.round(pos.y)}`;

    if (this.isDragging && this.selectedItem) {
      const newX = pos.x - this.dragOffset.x;
      const newY = pos.y - this.dragOffset.y;
      this.moveSelectedItem(newX, newY);
    }

    if (this.isPanning && this.panStart) {
      this.pan.x = this.panStartOffset.x + (e.clientX - this.panStart.x);
      this.pan.y = this.panStartOffset.y + (e.clientY - this.panStart.y);
      this.applyTransform();
    }

    if (this.isDrawing && this.drawStart) {
      this.updateDrawingRect(pos);
    }
  }

  onMouseUp(e) {
    if (this.isPanning) {
      this.isPanning = false;
      this.panStart = null;
      this.panStartOffset = null;
      this.svg.style.cursor = '';
    }

    if (this.isDragging && this.selectedItem) {
      this.saveItemPosition();
    }
    this.isDragging = false;
    this.dragStart = null;

    if (this.isDrawing && this.drawStart) {
      const pos = this.getMousePos(e);
      this.finishDrawing(pos);
    }
    this.isDrawing = false;
    this.drawStart = null;
  }

  onWheel(e) {
    e.preventDefault();
    const delta = e.deltaY > 0 ? 0.9 : 1.1;
    this.setZoom(this.zoom * delta);
  }

  onKeyDown(e) {
    // Skip keyboard shortcuts when user is in a form field or modal
    const tag = e.target.tagName;
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return;
    if (e.target.isContentEditable) return;
    if (document.querySelector('dialog[open]')) return;

    if (e.key === 'Delete' || e.key === 'Backspace') {
      if (this.selectedItem) {
        e.preventDefault();
        this.deleteSelected();
      }
    } else if (e.key === 'Escape') {
      this.clearSelection();
      this.setTool('select');
    }
  }

  render() {
    if (!this.roomData) return;

    this.renderGrid();
    this.renderRoom();
    this.renderSubrooms();
    this.renderFurniture();
    this.renderFeatures();
    this.renderExits();
    this.renderDecorations();
    this.applyTransform();
  }

  renderGrid() {
    this.gridLayer.innerHTML = '';
    if (!this.showGrid || !this.roomData) return;

    const minX = this.roomData.min_x || 0;
    const maxX = this.roomData.max_x || 100;
    const minY = this.roomData.min_y || 0;
    const maxY = this.roomData.max_y || 100;

    // Auto-adapt grid spacing so lines are ~30-60px apart on screen
    const { scale } = this._computeTransform();
    const targetScreenPx = 40;
    const targetFeet = targetScreenPx / scale;
    // Round to a nice number: 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000...
    const niceNumbers = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000];
    let spacing = niceNumbers.find(n => n >= targetFeet) || Math.ceil(targetFeet / 1000) * 1000;
    // Cap max lines to 200 to avoid performance issues
    const roomW = maxX - minX;
    const roomH = maxY - minY;
    while ((roomW / spacing) + (roomH / spacing) > 200) spacing *= 2;

    // Align grid start to spacing multiple
    const startX = Math.floor(minX / spacing) * spacing;
    const startY = Math.floor(minY / spacing) * spacing;

    for (let x = startX; x <= maxX; x += spacing) {
      if (x < minX) continue;
      const line = document.createElementNS('http://www.w3.org/2000/svg', 'line');
      line.setAttribute('x1', x);
      line.setAttribute('y1', minY);
      line.setAttribute('x2', x);
      line.setAttribute('y2', maxY);
      line.setAttribute('class', 'grid-line');
      line.setAttribute('vector-effect', 'non-scaling-stroke');
      this.gridLayer.appendChild(line);
    }

    for (let y = startY; y <= maxY; y += spacing) {
      if (y < minY) continue;
      const line = document.createElementNS('http://www.w3.org/2000/svg', 'line');
      line.setAttribute('x1', minX);
      line.setAttribute('y1', y);
      line.setAttribute('x2', maxX);
      line.setAttribute('y2', y);
      line.setAttribute('class', 'grid-line');
      line.setAttribute('vector-effect', 'non-scaling-stroke');
      this.gridLayer.appendChild(line);
    }

    // Update scale bar with current grid spacing
    const scaleBar = document.getElementById('scaleValue');
    if (scaleBar) scaleBar.textContent = spacing >= 1000 ? `${(spacing/1000).toFixed(0)}k ft` : `${spacing} ft`;
  }

  renderRoom() {
    this.roomLayer.innerHTML = '';
    if (!this.roomData) return;

    // Use polygon if available, otherwise rectangle
    if (this.roomData.room_polygon && this.roomData.room_polygon.length >= 3) {
      const points = this.roomData.room_polygon.map(p => {
        const x = p.x || p['x'] || 0;
        const y = p.y || p['y'] || 0;
        return `${x},${y}`;
      }).join(' ');
      const polygon = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
      polygon.setAttribute('points', points);
      polygon.setAttribute('class', 'room-bg');
      this.roomLayer.appendChild(polygon);
    } else {
      const rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
      rect.setAttribute('x', this.roomData.min_x || 0);
      rect.setAttribute('y', this.roomData.min_y || 0);
      rect.setAttribute('width', (this.roomData.max_x || 100) - (this.roomData.min_x || 0));
      rect.setAttribute('height', (this.roomData.max_y || 100) - (this.roomData.min_y || 0));
      rect.setAttribute('class', 'room-bg');
      this.roomLayer.appendChild(rect);
    }
  }

  renderSubrooms() {
    this.subroomLayer.innerHTML = '';
    if (!this.roomData?.subrooms) return;

    // Filter subrooms by current floor
    const visibleSubrooms = this.floorControls
      ? this.roomData.subrooms.filter(s => this.floorControls.isOnCurrentFloor(s))
      : this.roomData.subrooms;

    visibleSubrooms.forEach(subroom => {
      const g = document.createElementNS('http://www.w3.org/2000/svg', 'g');
      g.setAttribute('data-item-type', 'subroom');
      g.setAttribute('data-item-id', subroom.id);
      g.style.cursor = 'pointer';

      if (subroom.room_polygon && subroom.room_polygon.length >= 3) {
        const points = subroom.room_polygon.map(p => {
          const x = p.x || p['x'] || 0;
          const y = p.y || p['y'] || 0;
          return `${x},${y}`;
        }).join(' ');

        const polygon = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
        polygon.setAttribute('points', points);
        polygon.setAttribute('class', 'subroom');
        const fillColor = ROOM_TYPE_COLORS[subroom.room_type] || 'rgba(128, 128, 128, 0.12)';
        polygon.setAttribute('fill', fillColor);
        g.appendChild(polygon);

        if (this.showLabels) {
          const centroid = this.polygonCentroid(subroom.room_polygon);
          const text = document.createElementNS('http://www.w3.org/2000/svg', 'text');
          text.setAttribute('x', centroid.x);
          text.setAttribute('y', centroid.y);
          text.setAttribute('text-anchor', 'middle');
          text.setAttribute('dominant-baseline', 'middle');
          text.setAttribute('font-size', this.labelFontSize());
          text.setAttribute('fill', 'oklch(var(--bc))');
          text.setAttribute('pointer-events', 'none');
          text.textContent = subroom.name;
          this._unflipText(text);
          g.appendChild(text);
        }
      } else {
        const rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
        rect.setAttribute('x', subroom.min_x);
        rect.setAttribute('y', subroom.min_y);
        rect.setAttribute('width', subroom.max_x - subroom.min_x);
        rect.setAttribute('height', subroom.max_y - subroom.min_y);
        rect.setAttribute('class', 'subroom');
        const fillColor = ROOM_TYPE_COLORS[subroom.room_type] || 'rgba(128, 128, 128, 0.12)';
        rect.setAttribute('fill', fillColor);
        g.appendChild(rect);

        if (this.showLabels) {
          const cx = subroom.min_x + (subroom.max_x - subroom.min_x) / 2;
          const cy = subroom.min_y + (subroom.max_y - subroom.min_y) / 2;
          const text = document.createElementNS('http://www.w3.org/2000/svg', 'text');
          text.setAttribute('x', cx);
          text.setAttribute('y', cy);
          text.setAttribute('text-anchor', 'middle');
          text.setAttribute('dominant-baseline', 'middle');
          text.setAttribute('font-size', this.labelFontSize());
          text.setAttribute('fill', 'oklch(var(--bc))');
          text.setAttribute('pointer-events', 'none');
          text.textContent = subroom.name;
          this._unflipText(text);
          g.appendChild(text);
        }
      }

      // Render sub-room feature indicators (doors, windows)
      if (subroom.features?.length) {
        subroom.features.forEach(feat => {
          if (feat.x == null || feat.y == null) return;

          let color;
          if (feat.feature_type === 'door' || feat.feature_type === 'gate') {
            color = '#8B4513';
          } else if (feat.feature_type === 'window') {
            color = '#87CEEB';
          } else {
            return;
          }

          const indicator = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
          indicator.setAttribute('cx', feat.x);
          indicator.setAttribute('cy', feat.y);
          indicator.setAttribute('r', 1.5);
          indicator.setAttribute('fill', color);
          indicator.setAttribute('opacity', '0.7');
          indicator.classList.add('subroom-feature-indicator');
          g.appendChild(indicator);
        });
      }

      this.subroomLayer.appendChild(g);
    });
  }

  renderFurniture() {
    this.furnitureLayer.innerHTML = '';
    if (!this.roomData?.places) return;

    this.roomData.places.forEach(place => {
      const g = document.createElementNS('http://www.w3.org/2000/svg', 'g');
      g.setAttribute('data-item-type', 'place');
      g.setAttribute('data-item-id', place.id);

      const pw = place.width || 4;
      const ph = place.height || 4;

      const rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
      rect.setAttribute('x', place.x);
      rect.setAttribute('y', place.y);
      rect.setAttribute('width', pw);
      rect.setAttribute('height', ph);
      rect.setAttribute('class', 'furniture');
      rect.setAttribute('rx', 2);
      g.appendChild(rect);

      if (place.icon) {
        if (place.icon.startsWith('bi-')) {
          const fo = document.createElementNS('http://www.w3.org/2000/svg', 'foreignObject');
          fo.setAttribute('x', place.x);
          fo.setAttribute('y', place.y);
          fo.setAttribute('width', pw);
          fo.setAttribute('height', ph);
          fo.setAttribute('pointer-events', 'none');
          const div = document.createElement('div');
          div.style.cssText = 'width:100%;height:100%;display:flex;align-items:center;justify-content:center;';
          const iconSize = Math.min(pw, ph) * 0.5;
          div.innerHTML = `<i class="bi ${escapeHtml(place.icon)}" style="font-size:${iconSize}px;color:oklch(var(--bc)/0.7)"></i>`;
          fo.appendChild(div);
          g.appendChild(fo);
          this._unflipText(fo);
        } else {
          const svgNs = 'http://www.w3.org/2000/svg';
          const iconText = document.createElementNS(svgNs, 'text');
          const cx = place.x + pw / 2;
          const cy = place.y + ph / 2;
          iconText.setAttribute('x', cx);
          iconText.setAttribute('y', cy);
          iconText.setAttribute('text-anchor', 'middle');
          iconText.setAttribute('dominant-baseline', 'middle');
          iconText.setAttribute('font-size', Math.min(pw, ph) * 0.6);
          iconText.setAttribute('pointer-events', 'none');
          iconText.setAttribute('class', 'furniture-icon');
          iconText.textContent = place.icon;
          g.appendChild(iconText);
          this._unflipText(iconText);
        }
      } else if (this.showLabels) {
        const text = document.createElementNS('http://www.w3.org/2000/svg', 'text');
        text.setAttribute('x', place.x + pw / 2);
        text.setAttribute('y', place.y + ph / 2);
        text.setAttribute('text-anchor', 'middle');
        text.setAttribute('dominant-baseline', 'middle');
        text.setAttribute('font-size', this.labelFontSize());
        text.setAttribute('fill', 'oklch(var(--bc))');
        text.setAttribute('pointer-events', 'none');
        text.textContent = place.name.substring(0, 12);
        g.appendChild(text);
        this._unflipText(text);
      }

      this.furnitureLayer.appendChild(g);
    });
  }

  renderFeatures() {
    this.featureLayer.innerHTML = '';
    if (!this.roomData?.features) return;

    this.roomData.features.forEach(feature => {
      const g = document.createElementNS('http://www.w3.org/2000/svg', 'g');
      g.setAttribute('data-item-type', 'feature');
      g.setAttribute('data-item-id', feature.id);

      const isDoor = ['door', 'gate', 'opening', 'archway'].includes(feature.feature_type);
      const isFloorFeature = ['hatch', 'portal', 'trapdoor'].includes(feature.feature_type);
      const isWindow = feature.feature_type === 'window';
      const iconSize = this.labelFontSize() * 0.9;

      if (isFloorFeature) {
        // Floor features: render as a small square at position (not on walls)
        const size = Math.max(3, feature.width || 3);
        const rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
        rect.setAttribute('x', feature.x - size / 2);
        rect.setAttribute('y', feature.y - size / 2);
        rect.setAttribute('width', size);
        rect.setAttribute('height', size);
        rect.setAttribute('class', 'feature-floor');
        rect.setAttribute('rx', 1);
        g.appendChild(rect);

        // Icon centered on position
        const floorIcon = document.createElementNS('http://www.w3.org/2000/svg', 'text');
        floorIcon.setAttribute('x', feature.x);
        floorIcon.setAttribute('y', feature.y);
        floorIcon.setAttribute('text-anchor', 'middle');
        floorIcon.setAttribute('dominant-baseline', 'middle');
        floorIcon.setAttribute('font-size', iconSize);
        floorIcon.setAttribute('pointer-events', 'none');
        floorIcon.setAttribute('fill', '#6B5B3D');
        floorIcon.textContent = feature.feature_type === 'portal' ? '\u{1F300}' : '\u{1FA9C}'; // spiral or ladder
        g.appendChild(floorIcon);
        this._unflipText(floorIcon);

        // Label below
        if (this.showLabels) {
          const text = document.createElementNS('http://www.w3.org/2000/svg', 'text');
          text.setAttribute('x', feature.x);
          text.setAttribute('y', feature.y + size / 2 + iconSize * 0.8);
          text.setAttribute('text-anchor', 'middle');
          text.setAttribute('dominant-baseline', 'middle');
          text.setAttribute('font-size', this.labelFontSize());
          text.setAttribute('fill', 'oklch(var(--bc))');
          text.setAttribute('pointer-events', 'none');
          text.textContent = feature.name.substring(0, 12);
          g.appendChild(text);
          this._unflipText(text);
        }
      } else {
        // Wall features: render as a line along the nearest wall edge
        const featureWidth = feature.width || (isDoor ? 4 : 3);
        const visibleWidth = Math.max(featureWidth, this.labelFontSize() * 0.5);
        const halfWidth = visibleWidth / 2;

        // Find nearest wall edge for angle-aware rendering
        const edge = this._findNearestEdge(feature);
        const edgeAngle = edge ? edge.angle : (['north', 'south'].includes(feature.orientation) ? 0 : Math.PI / 2);
        const normalAngle = edge ? edge.normalAngle : (feature.orientation === 'north' ? Math.PI / 2 : feature.orientation === 'south' ? -Math.PI / 2 : feature.orientation === 'west' ? 0 : Math.PI);

        // Draw the line along the wall edge angle
        const line = document.createElementNS('http://www.w3.org/2000/svg', 'line');
        const cosA = Math.cos(edgeAngle), sinA = Math.sin(edgeAngle);
        line.setAttribute('x1', feature.x - halfWidth * cosA);
        line.setAttribute('y1', feature.y - halfWidth * sinA);
        line.setAttribute('x2', feature.x + halfWidth * cosA);
        line.setAttribute('y2', feature.y + halfWidth * sinA);

        if (isDoor) {
          line.setAttribute('class', 'feature-door');
        } else if (isWindow) {
          line.setAttribute('class', 'feature-window');
        } else {
          line.setAttribute('class', 'feature-other');
        }
        g.appendChild(line);

        // Icon: offset perpendicular to wall (inward) from feature position
        const iconOffset = iconSize * 0.7;
        const cosN = Math.cos(normalAngle), sinN = Math.sin(normalAngle);
        const iconX = feature.x + iconOffset * cosN;
        const iconY = feature.y + iconOffset * sinN;

        const iconText = document.createElementNS('http://www.w3.org/2000/svg', 'text');
        iconText.setAttribute('x', iconX);
        iconText.setAttribute('y', iconY);
        iconText.setAttribute('text-anchor', 'middle');
        iconText.setAttribute('dominant-baseline', 'middle');
        iconText.setAttribute('font-size', iconSize);
        iconText.setAttribute('pointer-events', 'none');
        if (isDoor) {
          iconText.setAttribute('fill', '#8B4513');
          iconText.textContent = '\uD83D\uDEAA'; // door emoji
        } else if (isWindow) {
          iconText.setAttribute('fill', '#87CEEB');
          iconText.textContent = '\uD83E\uDE9F'; // window emoji
        }
        if (iconText.textContent) {
          g.appendChild(iconText);
          this._unflipText(iconText);
        }

        // Label: placed along the wall from the icon, not stacked on top
        if (this.showLabels) {
          const labelAlongOffset = iconSize * 1.2;
          const labelX = iconX + labelAlongOffset * cosA;
          const labelY = iconY + labelAlongOffset * sinA;

          const text = document.createElementNS('http://www.w3.org/2000/svg', 'text');
          text.setAttribute('x', labelX);
          text.setAttribute('y', labelY);
          text.setAttribute('text-anchor', 'middle');
          text.setAttribute('dominant-baseline', 'middle');
          text.setAttribute('font-size', this.labelFontSize());
          text.setAttribute('fill', 'oklch(var(--bc))');
          text.setAttribute('pointer-events', 'none');
          text.textContent = feature.name.substring(0, 12);
          g.appendChild(text);
          this._unflipText(text);
        }
      }

      this.featureLayer.appendChild(g);
    });
  }

  renderExits() {
    this.exitLayer.innerHTML = '';
    if (!this.roomData?.exits) return;

    // Directions in world-space (higher Y = north). The Y-flip transform
    // negates Y on screen, so north (dy:1) renders upward on screen.
    const directions = {
      north: { dx: 0, dy: 1 },
      south: { dx: 0, dy: -1 },
      east: { dx: 1, dy: 0 },
      west: { dx: -1, dy: 0 },
      up: { dx: 0.5, dy: 0.5 },
      down: { dx: 0.5, dy: -0.5 }
    };

    this.roomData.exits.forEach(exit => {
      const g = document.createElementNS('http://www.w3.org/2000/svg', 'g');
      // Spatial exits are display-only in the room builder.
      g.setAttribute('pointer-events', 'none');

      const dir = directions[exit.direction] || { dx: 1, dy: 0 };
      const x = exit.from_x || (this.roomData.max_x + this.roomData.min_x) / 2;
      const y = exit.from_y || (this.roomData.max_y + this.roomData.min_y) / 2;

      // Draw arrow
      const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
      const size = 8;
      const points = [
        [x, y],
        [x + dir.dx * size * 2, y + dir.dy * size * 2],
        [x + dir.dx * size * 1.5 - dir.dy * size * 0.5, y + dir.dy * size * 1.5 + dir.dx * size * 0.5],
        [x + dir.dx * size * 2, y + dir.dy * size * 2],
        [x + dir.dx * size * 1.5 + dir.dy * size * 0.5, y + dir.dy * size * 1.5 - dir.dx * size * 0.5]
      ];
      path.setAttribute('d', `M ${points[0].join(',')} L ${points[1].join(',')} M ${points[2].join(',')} L ${points[3].join(',')} L ${points[4].join(',')}`);
      path.setAttribute('class', 'exit-arrow');
      path.setAttribute('stroke', '#ef4444');
      path.setAttribute('stroke-width', '2');
      path.setAttribute('fill', 'none');
      g.appendChild(path);

      if (this.showLabels) {
        const text = document.createElementNS('http://www.w3.org/2000/svg', 'text');
        text.setAttribute('x', x + dir.dx * size * 2.5);
        text.setAttribute('y', y + dir.dy * size * 2.5);
        text.setAttribute('font-size', this.labelFontSize());
        text.setAttribute('fill', '#ef4444');
        text.setAttribute('pointer-events', 'none');
        text.textContent = exit.direction;
        g.appendChild(text);
        this._unflipText(text);
      }

      this.exitLayer.appendChild(g);
    });
  }

  renderDecorations() {
    this.decorationLayer.innerHTML = '';
    if (!this.roomData?.decorations) return;

    const svgNs = 'http://www.w3.org/2000/svg';
    this.roomData.decorations.forEach(decoration => {
      const g = document.createElementNS(svgNs, 'g');
      g.setAttribute('data-item-type', 'decoration');
      g.setAttribute('data-item-id', decoration.id);

      const size = 18;
      const x = decoration.x || 0;
      const y = decoration.y || 0;

      const rect = document.createElementNS(svgNs, 'rect');
      rect.setAttribute('x', x);
      rect.setAttribute('y', y);
      rect.setAttribute('width', size);
      rect.setAttribute('height', size);
      rect.setAttribute('class', 'decoration');
      rect.setAttribute('rx', 3);
      g.appendChild(rect);

      if (decoration.icon && decoration.icon.startsWith('bi-')) {
        const fo = document.createElementNS(svgNs, 'foreignObject');
        fo.setAttribute('x', x);
        fo.setAttribute('y', y);
        fo.setAttribute('width', size);
        fo.setAttribute('height', size);
        fo.setAttribute('pointer-events', 'none');
        const div = document.createElement('div');
        div.style.cssText = 'width:100%;height:100%;display:flex;align-items:center;justify-content:center;';
        const iconSize = size * 0.6;
        div.innerHTML = `<i class="bi ${escapeHtml(decoration.icon)}" style="font-size:${iconSize}px;color:oklch(var(--bc)/0.7)"></i>`;
        fo.appendChild(div);
        g.appendChild(fo);
        this._unflipText(fo);
      } else {
        const label = decoration.icon || (decoration.name?.charAt(0) || '?').toUpperCase();
        const text = document.createElementNS(svgNs, 'text');
        text.setAttribute('x', x + size / 2);
        text.setAttribute('y', y + size / 2);
        text.setAttribute('text-anchor', 'middle');
        text.setAttribute('dominant-baseline', 'middle');
        text.setAttribute('font-size', decoration.icon ? size * 0.7 : this.labelFontSize());
        text.setAttribute('fill', 'oklch(var(--bc))');
        text.setAttribute('pointer-events', 'none');
        text.textContent = label;
        g.appendChild(text);
        this._unflipText(text);
      }

      this.decorationLayer.appendChild(g);
    });
  }

  selectItem(type, id) {
    this.clearSelection();
    if (type === 'exit') return;
    this.selectedType = type;

    let item;
    switch (type) {
      case 'place':
        item = this.roomData.places.find(p => p.id === id);
        break;
      case 'feature':
        item = this.roomData.features.find(f => f.id === id);
        break;
      case 'decoration':
        item = this.roomData.decorations.find(d => d.id === id);
        break;
    }

    if (item) {
      this.selectedItem = item;
      this.highlightSelected(type, id);
      window.propertyPanel?.showProperties(type, item);
      document.getElementById('deleteSelectedBtn').disabled = false;
    }
  }

  highlightSelected(type, id) {
    const el = this.svg.querySelector(`[data-item-type="${type}"][data-item-id="${id}"]`);
    if (el) {
      el.classList.add('selected');
    }
  }

  clearSelection() {
    this.svg.querySelectorAll('.selected').forEach(el => el.classList.remove('selected'));
    this.selectedItem = null;
    this.selectedType = null;
    window.propertyPanel?.clearProperties();
    document.getElementById('deleteSelectedBtn').disabled = true;
  }

  moveSelectedItem(x, y) {
    if (!this.selectedItem || !this.selectedType) return;

    this.selectedItem.x = Math.round(x);
    this.selectedItem.y = Math.round(y);

    // Update visual position
    if (this.selectedType === 'place') {
      const el = this.furnitureLayer.querySelector(`[data-item-id="${this.selectedItem.id}"] rect`);
      if (el) {
        el.setAttribute('x', x);
        el.setAttribute('y', y);
      }
      const text = this.furnitureLayer.querySelector(`[data-item-id="${this.selectedItem.id}"] text`);
      if (text) {
        text.setAttribute('x', x + 2);
        text.setAttribute('y', y + 10);
      }
    }

    if (this.selectedType === 'decoration') {
      const item = this.roomData.decorations.find(p => p.id === this.selectedItem.id);
      if (item) { item.x = Math.round(x); item.y = Math.round(y); }
      const g = this.decorationLayer.querySelector(`[data-item-id="${this.selectedItem.id}"]`);
      if (g) {
        const rect = g.querySelector('rect.decoration');
        const text = g.querySelector('text');
        if (rect) { rect.setAttribute('x', x); rect.setAttribute('y', y); }
        if (text) { text.setAttribute('x', x + 9); text.setAttribute('y', y + 9); }
      }
    }
  }

  async saveItemPosition() {
    if (!this.selectedItem || !this.selectedType) return;

    try {
      switch (this.selectedType) {
        case 'place':
          await window.roomAPI.updatePlace(this.selectedItem.id, {
            x: this.selectedItem.x,
            y: this.selectedItem.y
          });
          break;
        case 'feature':
          await window.roomAPI.updateFeature(this.selectedItem.id, {
            x: this.selectedItem.x,
            y: this.selectedItem.y
          });
          break;
        case 'decoration': {
          const item = this.roomData.decorations.find(p => p.id === this.selectedItem.id);
          if (item) {
            window.roomAPI.updateDecoration(this.selectedItem.id, { x: item.x, y: item.y })
              .catch(e => console.error('Failed to save decoration position:', e));
          }
          break;
        }
      }
    } catch (error) {
      console.error('Failed to save position:', error);
    }
  }

  updateDrawingRect(pos) {
    this.selectionLayer.innerHTML = '';

    const x = Math.min(this.drawStart.x, pos.x);
    const y = Math.min(this.drawStart.y, pos.y);
    const width = Math.abs(pos.x - this.drawStart.x);
    const height = Math.abs(pos.y - this.drawStart.y);

    const rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
    rect.setAttribute('x', x);
    rect.setAttribute('y', y);
    rect.setAttribute('width', width);
    rect.setAttribute('height', height);
    rect.setAttribute('fill', 'rgba(16, 185, 129, 0.3)');
    rect.setAttribute('stroke', '#10b981');
    rect.setAttribute('stroke-width', '2');
    rect.setAttribute('stroke-dasharray', '4');
    this.selectionLayer.appendChild(rect);
  }

  async finishDrawing(pos) {
    this.selectionLayer.innerHTML = '';

    let minX = Math.round(Math.min(this.drawStart.x, pos.x));
    let minY = Math.round(Math.min(this.drawStart.y, pos.y));
    let maxX = Math.round(Math.max(this.drawStart.x, pos.x));
    let maxY = Math.round(Math.max(this.drawStart.y, pos.y));

    if (maxX - minX < 10 || maxY - minY < 10) return;

    const parentPoly = this.roomData?.room_polygon;
    let roomPolygon = null;
    if (parentPoly && parentPoly.length >= 3) {
      roomPolygon = this.clipRectToPolygon(minX, minY, maxX, maxY, parentPoly);
      if (!roomPolygon || roomPolygon.length < 3) {
        alert('The drawn area does not overlap with the room polygon.');
        return;
      }
    }

    const name = prompt('Enter sub-room name:', 'New Room');
    if (!name) return;

    try {
      // Get current floor z-range for new subroom
      const floorZ = this.floorControls?.currentFloorZRange();

      const data = {
        name,
        min_x: minX, min_y: minY,
        max_x: maxX, max_y: maxY,
        polygon_mode: roomPolygon ? 'advanced' : 'simple'
      };
      if (roomPolygon) {
        data.room_polygon = roomPolygon;
      }
      if (floorZ) {
        data.min_z = floorZ.minZ;
        data.max_z = floorZ.maxZ;
      }
      const result = await window.roomAPI.createSubroom(data);
      this.roomData.subrooms.push(result.subroom);
      this.render();
      this.updateElementsList();
    } catch (error) {
      alert('Failed to create sub-room: ' + error.message);
    }
  }

  clipRectToPolygon(minX, minY, maxX, maxY, polygon) {
    let output = [
      { x: minX, y: minY },
      { x: maxX, y: minY },
      { x: maxX, y: maxY },
      { x: minX, y: maxY }
    ];

    // Detect winding order via shoelace formula.
    // _isInsideEdge assumes CCW winding; CW polygons cause all points
    // to classify as "outside", returning null. Fix: reverse if CW.
    let windingSum = 0;
    for (let i = 0; i < polygon.length; i++) {
      const a = polygon[i], b = polygon[(i + 1) % polygon.length];
      windingSum += ((b.x || 0) - (a.x || 0)) * ((b.y || 0) + (a.y || 0));
    }
    const clipPoly = windingSum > 0 ? [...polygon].reverse() : polygon;

    for (let i = 0; i < clipPoly.length; i++) {
      if (output.length === 0) return null;
      const a = clipPoly[i];
      const b = clipPoly[(i + 1) % clipPoly.length];
      const ax = a.x || a['x'] || 0, ay = a.y || a['y'] || 0;
      const bx = b.x || b['x'] || 0, by = b.y || b['y'] || 0;

      const input = output;
      output = [];

      for (let j = 0; j < input.length; j++) {
        const curr = input[j];
        const prev = input[(j + input.length - 1) % input.length];
        const currInside = this._isInsideEdge(curr, ax, ay, bx, by);
        const prevInside = this._isInsideEdge(prev, ax, ay, bx, by);

        if (currInside) {
          if (!prevInside) {
            output.push(this._lineIntersect(prev, curr, { x: ax, y: ay }, { x: bx, y: by }));
          }
          output.push(curr);
        } else if (prevInside) {
          output.push(this._lineIntersect(prev, curr, { x: ax, y: ay }, { x: bx, y: by }));
        }
      }
    }

    return output.length >= 3 ? output.map(p => ({ x: Math.round(p.x), y: Math.round(p.y) })) : null;
  }

  _isInsideEdge(p, ax, ay, bx, by) {
    return (bx - ax) * (p.y - ay) - (by - ay) * (p.x - ax) >= 0;
  }

  _lineIntersect(p1, p2, p3, p4) {
    const x1 = p1.x, y1 = p1.y, x2 = p2.x, y2 = p2.y;
    const x3 = p3.x, y3 = p3.y, x4 = p4.x, y4 = p4.y;
    const denom = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4);
    if (Math.abs(denom) < 0.001) return p1;
    const t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / denom;
    return { x: x1 + t * (x2 - x1), y: y1 + t * (y2 - y1) };
  }

  // ========================================
  // Polygon Drawing Methods (Advanced Mode)
  // ========================================

  addPolygonPoint(pos) {
    const snappedPos = this.snapToGrid ? {
      x: Math.round(pos.x / this.gridSize) * this.gridSize,
      y: Math.round(pos.y / this.gridSize) * this.gridSize
    } : pos;

    // Check if closing the polygon (clicking near start)
    if (this.polygonPoints.length >= 3) {
      const start = this.polygonPoints[0];
      const dist = Math.hypot(pos.x - start.x, pos.y - start.y);
      if (dist < 15) {
        this.finishPolygonDrawing();
        return;
      }
    }

    this.polygonPoints.push({ x: Math.round(snappedPos.x), y: Math.round(snappedPos.y) });
    this.updatePolygonPreview();
  }

  updatePolygonPreview() {
    this.selectionLayer.innerHTML = '';
    if (this.polygonPoints.length < 1) return;

    // Draw polygon shape
    if (this.polygonPoints.length >= 2) {
      const points = this.polygonPoints.map(p => `${p.x},${p.y}`).join(' ');
      const polygon = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
      polygon.setAttribute('points', points);
      polygon.setAttribute('fill', 'rgba(16, 185, 129, 0.3)');
      polygon.setAttribute('stroke', '#10b981');
      polygon.setAttribute('stroke-width', '2');
      polygon.setAttribute('stroke-dasharray', '4');
      this.selectionLayer.appendChild(polygon);
    }

    // Draw vertex handles
    this.polygonPoints.forEach((p, i) => {
      const circle = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
      circle.setAttribute('cx', p.x);
      circle.setAttribute('cy', p.y);
      circle.setAttribute('r', i === 0 ? 8 : 5);  // First point larger (close target)
      circle.setAttribute('fill', i === 0 ? '#ef4444' : '#10b981');
      this.selectionLayer.appendChild(circle);
    });

    // Draw hint text
    if (this.polygonPoints.length >= 3) {
      const start = this.polygonPoints[0];
      const text = document.createElementNS('http://www.w3.org/2000/svg', 'text');
      text.setAttribute('x', start.x + 10);
      text.setAttribute('y', start.y - 5);
      text.setAttribute('fill', '#ef4444');
      text.setAttribute('font-size', '10');
      text.textContent = 'Click to close';
      this.selectionLayer.appendChild(text);
      this._unflipText(text);
    }
  }

  async finishPolygonDrawing() {
    if (this.polygonPoints.length < 3) {
      this.clearPolygonDrawing();
      return;
    }

    const name = prompt('Enter sub-room name:', 'New Room');
    if (!name) {
      this.clearPolygonDrawing();
      return;
    }

    // Calculate bounding box for min/max columns (needed for hex grid sizing)
    const xs = this.polygonPoints.map(p => p.x);
    const ys = this.polygonPoints.map(p => p.y);

    try {
      // Get current floor z-range for new subroom
      const floorZ = this.floorControls?.currentFloorZRange();
      const subroomData = {
        name,
        min_x: Math.min(...xs),
        min_y: Math.min(...ys),
        max_x: Math.max(...xs),
        max_y: Math.max(...ys),
        room_polygon: this.polygonPoints.map(p => ({ x: p.x, y: p.y })),
        polygon_mode: 'advanced'
      };
      if (floorZ) {
        subroomData.min_z = floorZ.minZ;
        subroomData.max_z = floorZ.maxZ;
      }
      const result = await window.roomAPI.createSubroom(subroomData);
      this.roomData.subrooms.push(result.subroom);
      this.render();
      this.updateElementsList();
    } catch (error) {
      alert('Failed to create polygon room: ' + error.message);
    }

    this.clearPolygonDrawing();
  }

  clearPolygonDrawing() {
    this.polygonPoints = [];
    this.selectionLayer.innerHTML = '';
  }

  updateDrawingModeHelp() {
    const help = document.getElementById('drawingModeHelp');
    if (help) {
      help.textContent = this.drawingMode === 'simple'
        ? 'Simple: Drag to draw rectangles'
        : 'Polygon: Click to add vertices, click near start (red) to close';
    }
  }

  polygonCentroid(polygon) {
    const n = polygon.length;
    let cx = 0, cy = 0;
    polygon.forEach(p => {
      cx += (p.x || p['x'] || 0);
      cy += (p.y || p['y'] || 0);
    });
    return { x: cx / n, y: cy / n };
  }

  async placeFurniture(pos) {
    const catalogItem = window.furnitureCatalog?.selectedItem;
    if (!catalogItem) {
      alert('Please select furniture from the catalog first');
      return;
    }

    try {
      const result = await window.roomAPI.createPlace({
        name: catalogItem.name,
        description: catalogItem.description,
        x: pos.x,
        y: pos.y,
        width: catalogItem.width || 20,
        height: catalogItem.height || 20,
        capacity: catalogItem.capacity || 1,
        is_furniture: true,
        default_sit_action: catalogItem.default_sit_action || 'on',
        icon: catalogItem.icon || null
      });
      this.roomData.places.push(result.place);
      this.render();
      this.updateElementsList();
      this.selectItem('place', result.place.id);
    } catch (error) {
      alert('Failed to place furniture: ' + error.message);
    }
  }

  /**
   * Find the nearest wall edge to a feature's position.
   * Returns edge info for rendering features aligned to angled walls.
   */
  _findNearestEdge(feature) {
    const minX = this.roomData.min_x || 0;
    const maxX = this.roomData.max_x || 100;
    const minY = this.roomData.min_y || 0;
    const maxY = this.roomData.max_y || 100;
    const pos = { x: feature.x, y: feature.y };

    // Compute room centroid for inward normal direction
    let centroidX, centroidY;

    if (this.roomData.room_polygon && this.roomData.room_polygon.length >= 3) {
      const poly = this.roomData.room_polygon;
      centroidX = poly.reduce((s, p) => s + (p.x || 0), 0) / poly.length;
      centroidY = poly.reduce((s, p) => s + (p.y || 0), 0) / poly.length;

      let bestDist = Infinity;
      let bestEdge = null;

      for (let i = 0; i < poly.length; i++) {
        const a = poly[i];
        const b = poly[(i + 1) % poly.length];
        const ax = a.x || 0, ay = a.y || 0;
        const bx = b.x || 0, by = b.y || 0;
        const dx = bx - ax, dy = by - ay;
        const len2 = dx * dx + dy * dy;
        if (len2 === 0) continue;
        let t = ((pos.x - ax) * dx + (pos.y - ay) * dy) / len2;
        t = Math.max(0, Math.min(1, t));
        const px = ax + t * dx, py = ay + t * dy;
        const dist = Math.hypot(pos.x - px, pos.y - py);

        if (dist < bestDist) {
          bestDist = dist;
          const edgeAngle = Math.atan2(dy, dx);
          // Normal perpendicular to edge
          let normalAngle = edgeAngle - Math.PI / 2;
          // Ensure normal points toward centroid (inward)
          const testX = (ax + bx) / 2 + Math.cos(normalAngle);
          const testY = (ay + by) / 2 + Math.sin(normalAngle);
          const midX = (ax + bx) / 2, midY = (ay + by) / 2;
          const dCentroidBefore = Math.hypot(midX - centroidX, midY - centroidY);
          const dCentroidAfter = Math.hypot(testX - centroidX, testY - centroidY);
          if (dCentroidAfter > dCentroidBefore) normalAngle += Math.PI;

          bestEdge = {
            start: { x: ax, y: ay },
            end: { x: bx, y: by },
            midpoint: { x: midX, y: midY },
            angle: edgeAngle,
            normalAngle: normalAngle
          };
        }
      }
      return bestEdge;
    }

    // Rectangle room: 4 edges
    centroidX = (minX + maxX) / 2;
    centroidY = (minY + maxY) / 2;
    const edges = [
      { start: { x: minX, y: minY }, end: { x: maxX, y: minY }, angle: 0,          normalAngle: Math.PI / 2 },  // north wall
      { start: { x: maxX, y: minY }, end: { x: maxX, y: maxY }, angle: Math.PI / 2, normalAngle: Math.PI },     // east wall
      { start: { x: maxX, y: maxY }, end: { x: minX, y: maxY }, angle: Math.PI,     normalAngle: -Math.PI / 2 }, // south wall
      { start: { x: minX, y: maxY }, end: { x: minX, y: minY }, angle: -Math.PI / 2, normalAngle: 0 },          // west wall
    ];

    let bestDist = Infinity;
    let bestEdge = null;
    for (const edge of edges) {
      const a = edge.start, b = edge.end;
      const dx = b.x - a.x, dy = b.y - a.y;
      const len2 = dx * dx + dy * dy;
      if (len2 === 0) continue;
      let t = ((pos.x - a.x) * dx + (pos.y - a.y) * dy) / len2;
      t = Math.max(0, Math.min(1, t));
      const px = a.x + t * dx, py = a.y + t * dy;
      const dist = Math.hypot(pos.x - px, pos.y - py);
      if (dist < bestDist) {
        bestDist = dist;
        const midX = (a.x + b.x) / 2, midY = (a.y + b.y) / 2;
        bestEdge = { ...edge, midpoint: { x: midX, y: midY } };
      }
    }
    return bestEdge;
  }

  snapToRoomEdge(pos, force = false) {
    const minX = this.roomData.min_x || 0;
    const maxX = this.roomData.max_x || 100;
    const minY = this.roomData.min_y || 0;
    const maxY = this.roomData.max_y || 100;

    // If room has a polygon, use polygon edges
    if (this.roomData.room_polygon && this.roomData.room_polygon.length >= 3) {
      return this.snapToPolygonEdge(pos, this.roomData.room_polygon, force);
    }

    // Rectangle room: find closest edge
    const edges = [
      { x: Math.max(minX, Math.min(maxX, pos.x)), y: minY, orientation: 'north', dist: Math.abs(pos.y - minY) },
      { x: Math.max(minX, Math.min(maxX, pos.x)), y: maxY, orientation: 'south', dist: Math.abs(pos.y - maxY) },
      { x: minX, y: Math.max(minY, Math.min(maxY, pos.y)), orientation: 'west', dist: Math.abs(pos.x - minX) },
      { x: maxX, y: Math.max(minY, Math.min(maxY, pos.y)), orientation: 'east', dist: Math.abs(pos.x - maxX) },
    ];

    const closest = edges.sort((a, b) => a.dist - b.dist)[0];

    if (!force) {
      // Max snap distance: 15% of room size or 15ft, whichever is smaller
      const maxSnapDist = Math.min(Math.max(maxX - minX, maxY - minY) * 0.15, 15);
      if (closest.dist > maxSnapDist) return null;
    }

    return closest;
  }

  snapToPolygonEdge(pos, polygon, force = false) {
    let bestDist = Infinity;
    let bestPoint = null;
    let bestOrientation = 'north';
    let bestEdgeAngle = 0;
    let bestEdgeStart = null;
    let bestEdgeEnd = null;

    for (let i = 0; i < polygon.length; i++) {
      const a = polygon[i];
      const b = polygon[(i + 1) % polygon.length];
      const ax = a.x || a['x'] || 0;
      const ay = a.y || a['y'] || 0;
      const bx = b.x || b['x'] || 0;
      const by = b.y || b['y'] || 0;

      const dx = bx - ax, dy = by - ay;
      const len2 = dx * dx + dy * dy;
      if (len2 === 0) continue;
      let t = ((pos.x - ax) * dx + (pos.y - ay) * dy) / len2;
      t = Math.max(0, Math.min(1, t));
      const px = ax + t * dx, py = ay + t * dy;
      const dist = Math.hypot(pos.x - px, pos.y - py);

      if (dist < bestDist) {
        bestDist = dist;
        bestPoint = { x: Math.round(px), y: Math.round(py) };
        bestOrientation = Math.abs(dx) > Math.abs(dy) ? 'north' : 'east';
        bestEdgeAngle = Math.atan2(dy, dx);
        bestEdgeStart = { x: ax, y: ay };
        bestEdgeEnd = { x: bx, y: by };
      }
    }

    if (!force) {
      const roomSize = Math.max(
        (this.roomData.max_x || 100) - (this.roomData.min_x || 0),
        (this.roomData.max_y || 100) - (this.roomData.min_y || 0)
      );
      if (bestDist > Math.min(roomSize * 0.15, 15)) return null;
    }

    return { ...bestPoint, orientation: bestOrientation, edgeAngle: bestEdgeAngle, edgeStart: bestEdgeStart, edgeEnd: bestEdgeEnd };
  }

  async placeFeature(pos, type) {
    const snapped = this.snapToRoomEdge(pos, true);
    if (!snapped) return;

    const name = prompt(`Enter ${type} name:`, type === 'door' ? 'Front Door' : 'Window');
    if (!name) return;

    const defaultWidth = type === 'door' ? 4 : 3;

    try {
      const result = await window.roomAPI.createFeature({
        name,
        feature_type: type,
        x: snapped.x,
        y: snapped.y,
        z: 0,
        width: defaultWidth,
        height: 7,
        orientation: snapped.orientation,
        allows_movement: type === 'door',
        allows_sight: true
      });
      this.roomData.features.push(result.feature);
      this.render();
      this.updateElementsList();
      this.selectItem('feature', result.feature.id);
    } catch (error) {
      alert('Failed to create feature: ' + error.message);
    }
  }

  async placeDecoration(pos) {
    const name = prompt('Enter decoration name:', 'New Decoration');
    if (!name) return;

    try {
      const result = await window.roomAPI.createDecoration({
        name,
        description: '',
        x: pos.x,
        y: pos.y
      });
      this.roomData.decorations.push(result.decoration);
      this.render();
      this.updateElementsList();
      this.selectItem('decoration', result.decoration.id);
    } catch (error) {
      alert('Failed to create decoration: ' + error.message);
    }
  }

  async deleteSelected() {
    if (!this.selectedItem || !this.selectedType) return;

    if (!confirm(`Delete this ${this.selectedType}?`)) return;

    try {
      switch (this.selectedType) {
        case 'place':
          await window.roomAPI.deletePlace(this.selectedItem.id);
          this.roomData.places = this.roomData.places.filter(p => p.id !== this.selectedItem.id);
          break;
        case 'feature':
          await window.roomAPI.deleteFeature(this.selectedItem.id);
          this.roomData.features = this.roomData.features.filter(f => f.id !== this.selectedItem.id);
          break;
        case 'decoration':
          await window.roomAPI.deleteDecoration(this.selectedItem.id);
          this.roomData.decorations = this.roomData.decorations.filter(d => d.id !== this.selectedItem.id);
          break;
      }
      this.clearSelection();
      this.render();
      this.updateElementsList();
    } catch (error) {
      alert('Failed to delete: ' + error.message);
    }
  }

  async saveRoomProperties() {
    // Collect seasonal descriptions
    const seasonalDescriptions = {};
    document.querySelectorAll('.seasonal-desc').forEach(ta => {
      const time = ta.dataset.time;
      const season = ta.dataset.season;
      if (ta.value.trim()) {
        if (!seasonalDescriptions[time]) seasonalDescriptions[time] = {};
        seasonalDescriptions[time][season] = ta.value.trim();
      }
    });

    const descEl = document.getElementById('roomDescriptionValue');
    const description = descEl ? descEl.value : (document.getElementById('roomDescription')?.value || '');
    const descValue = description;

    const data = {
      name: document.getElementById('roomNameValue')?.value || document.getElementById('roomName')?.value || '',
      short_description: descValue,
      long_description: descValue,
      room_type: document.getElementById('roomType')?.value || null,
      publicity: document.getElementById('roomPublicity')?.value || null,
      indoors: document.getElementById('roomIndoors')?.checked || false,
      default_background_url: document.getElementById('roomBackground')?.value || null,
      seasonal_descriptions: Object.keys(seasonalDescriptions).length > 0 ? seasonalDescriptions : null,
      safe_room: document.getElementById('roomSafeRoom')?.checked || false,
      tutorial_room: document.getElementById('roomTutorialRoom')?.checked || false,
      is_vault: document.getElementById('roomIsVault')?.checked || false,
    };

    try {
      await window.roomAPI.updateRoom(data);
      alert('Room properties saved!');
    } catch (error) {
      alert('Failed to save: ' + error.message);
    }
  }

  updateElementsList() {
    const list = document.getElementById('elementsList');
    if (!list || !this.roomData) return;

    let html = '';

    if (this.roomData.subrooms?.length) {
      const floorLabel = this.floorControls?.currentFloorLabel();
      const heading = floorLabel ? `Sub-rooms (${floorLabel})` : 'Sub-rooms';
      html += `<div class="mb-2"><small class="text-base-content/60">${heading}</small></div>`;

      const visibleSubrooms = this.floorControls
        ? this.roomData.subrooms.filter(s => this.floorControls.isOnCurrentFloor(s))
        : this.roomData.subrooms;

      visibleSubrooms.forEach(s => {
        html += `<a href="/admin/room_builder/${s.id}" class="elements-item">
          <i class="bi bi-bounding-box text-success"></i>${escapeHtml(s.name)}
        </a>`;
      });
    }

    if (this.roomData.places?.length) {
      html += '<div class="mb-2 mt-2"><small class="text-base-content/60">Furniture / Places</small></div>';
      this.roomData.places.forEach(p => {
        html += `<div class="small mb-1 cursor-pointer" onclick="window.roomEditor.selectItem('place', ${p.id})">
          <i class="bi bi-lamp-fill text-warning mr-1"></i>${escapeHtml(p.name)}
        </div>`;
      });
    }

    if (this.roomData.features?.length) {
      html += '<div class="mb-2 mt-2"><small class="text-base-content/60">Features</small></div>';
      this.roomData.features.forEach(f => {
        const icon = f.feature_type === 'door' ? 'bi-door-open' : 'bi-window';
        html += `<div class="small mb-1 cursor-pointer" onclick="window.roomEditor.selectItem('feature', ${f.id})">
          <i class="bi ${icon} text-info mr-1"></i>${escapeHtml(f.name)}
        </div>`;
      });
    }

    if (this.roomData.exits?.length) {
      html += '<div class="mb-2 mt-2"><small class="text-base-content/60">Exits</small></div>';
      this.roomData.exits.forEach(e => {
        html += `<div class="small mb-1">
          <i class="bi bi-box-arrow-right text-danger mr-1"></i>${e.direction} → ${escapeHtml(e.to_room_name || 'Unknown')}
        </div>`;
      });
    }

    if (this.roomData.decorations?.length) {
      html += '<div class="mb-2 mt-2"><small class="text-base-content/60">Decorations</small></div>';
      this.roomData.decorations.forEach(d => {
        html += `<div class="small mb-1 cursor-pointer" onclick="window.roomEditor.selectItem('decoration', ${d.id})">
          <i class="bi bi-brush text-secondary mr-1"></i>${escapeHtml(d.name)}
        </div>`;
      });
    }

    if (!html) {
      html = '<div class="text-base-content/60 small">No elements yet</div>';
    }

    list.innerHTML = html;
  }

  updateRoomInfo() {
    if (!this.roomData) return;

    const width = (this.roomData.max_x || 100) - (this.roomData.min_x || 0);
    const height = (this.roomData.max_y || 100) - (this.roomData.min_y || 0);
    document.getElementById('roomDimensions').textContent = `${width} x ${height}`;
  }

}

// Initialize
document.addEventListener('DOMContentLoaded', () => {
  const svg = document.getElementById('roomCanvas');
  if (svg && window.ROOM_ID) {
    window.roomEditor = new RoomEditor(svg);
    // Wait for API client to initialize
    setTimeout(() => {
      window.roomEditor.loadRoom();
    }, 100);
  }
});
