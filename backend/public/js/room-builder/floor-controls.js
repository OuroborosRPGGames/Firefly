/**
 * Floor Controls - Manages floor navigation for multi-story rooms
 *
 * Derives floors from room min_z/max_z (default 10ft per floor).
 * Shows floating buttons on canvas to switch between floors.
 * Filters subrooms and auto-assigns z-range to new subrooms.
 */
class FloorControls {
  constructor(containerEl) {
    this.container = containerEl;
    this.floors = [];         // Array of { number, minZ, maxZ, label }
    this.currentFloor = 0;    // Index into this.floors
    this.floorHeight = 10;    // Feet per floor
    this.roomData = null;
    this.onFloorChange = null; // Callback: (floorIndex) => {}

    this.render();
    this.setupKeyboardShortcuts();
  }

  /**
   * Calculate floors from room z-range.
   * Called after room data loads.
   */
  update(roomData) {
    this.roomData = roomData;
    const minZ = roomData.min_z ?? 0;
    const maxZ = roomData.max_z ?? 10;
    const totalHeight = maxZ - minZ;

    // Calculate number of floors (minimum 1)
    const numFloors = Math.max(1, Math.round(totalHeight / this.floorHeight));
    this.floorHeight = totalHeight / numFloors;

    this.floors = [];
    for (let i = 0; i < numFloors; i++) {
      const floorMinZ = minZ + i * this.floorHeight;
      const floorMaxZ = minZ + (i + 1) * this.floorHeight;
      this.floors.push({
        number: i + 1,
        minZ: floorMinZ,
        maxZ: floorMaxZ,
        label: `F${i + 1}`
      });
    }

    // Default to floor 1
    this.currentFloor = 0;
    this.render();
  }

  /**
   * Check if a subroom overlaps the current floor's z-range.
   */
  isOnCurrentFloor(subroom) {
    if (this.floors.length <= 1) return true; // Single floor shows everything

    const floor = this.floors[this.currentFloor];
    if (!floor) return true;

    const subMinZ = subroom.min_z ?? 0;
    const subMaxZ = subroom.max_z ?? 10;

    // Overlap check: subroom overlaps floor if subMinZ < floor.maxZ AND subMaxZ > floor.minZ
    return subMinZ < floor.maxZ && subMaxZ > floor.minZ;
  }

  /**
   * Get the z-range for the current floor (for new subroom creation).
   */
  currentFloorZRange() {
    const floor = this.floors[this.currentFloor];
    if (!floor) return { minZ: 0, maxZ: 10 };
    return { minZ: floor.minZ, maxZ: floor.maxZ };
  }

  /**
   * Get display text for the current floor (for status bar).
   */
  currentFloorLabel() {
    const floor = this.floors[this.currentFloor];
    if (!floor || this.floors.length <= 1) return '';
    return `Floor ${floor.number} (${floor.minZ}-${floor.maxZ} ft)`;
  }

  setFloor(index) {
    if (index < 0 || index >= this.floors.length) return;
    this.currentFloor = index;
    this.render();
    if (this.onFloorChange) this.onFloorChange(index);
  }

  goUp() {
    this.setFloor(this.currentFloor + 1);
  }

  goDown() {
    this.setFloor(this.currentFloor - 1);
  }

  /**
   * Create a floor room at the current level matching the building's XY bounds.
   */
  async addFloor() {
    if (!this.roomData || !window.roomAPI) return;

    const zRange = this.currentFloorZRange();
    const floor = this.floors[this.currentFloor];
    const floorNum = floor ? floor.number : 1;

    const data = {
      name: `Floor ${floorNum}`,
      room_type: 'floor',
      min_x: this.roomData.min_x,
      max_x: this.roomData.max_x,
      min_y: this.roomData.min_y,
      max_y: this.roomData.max_y,
      min_z: zRange.minZ,
      max_z: zRange.maxZ
    };

    try {
      const result = await window.roomAPI.createSubroom(data);
      if (result && result.subroom && window.roomEditor) {
        window.roomEditor.roomData.subrooms.push(result.subroom);
        window.roomEditor.render();
        window.roomEditor.updateElementsList();
      }
    } catch (error) {
      alert('Failed to create floor room: ' + error.message);
    }
  }

  setupKeyboardShortcuts() {
    document.addEventListener('keydown', (e) => {
      // Skip when in form fields or modals
      const tag = e.target.tagName;
      if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return;
      if (e.target.isContentEditable) return;
      if (document.querySelector('dialog[open]')) return;

      if (e.key === ']') {
        e.preventDefault();
        this.goUp();
      } else if (e.key === '[') {
        e.preventDefault();
        this.goDown();
      }
    });
  }

  render() {
    if (!this.container) return;

    // Hide if single floor
    if (this.floors.length <= 1) {
      this.container.style.display = 'none';
      return;
    }

    this.container.style.display = 'flex';
    this.container.innerHTML = '';

    // Add floor button at top
    const addBtn = document.createElement('button');
    addBtn.className = 'floor-btn';
    addBtn.innerHTML = '<i class="bi bi-plus"></i>';
    addBtn.title = 'Add floor room at current level';
    addBtn.addEventListener('click', () => this.addFloor());
    this.container.appendChild(addBtn);

    // Render buttons top-to-bottom (highest floor first)
    for (let i = this.floors.length - 1; i >= 0; i--) {
      const floor = this.floors[i];
      const btn = document.createElement('button');
      btn.className = i === this.currentFloor
        ? 'floor-btn active'
        : 'floor-btn';
      btn.textContent = floor.label;
      btn.title = `Floor ${floor.number} (${floor.minZ}-${floor.maxZ} ft)`;
      btn.addEventListener('click', () => this.setFloor(i));
      this.container.appendChild(btn);
    }
  }
}
