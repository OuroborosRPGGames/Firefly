/**
 * JourneyModal - Orchestrator for the journey planning dialog
 *
 * Manages the DaisyUI <dialog> lifecycle, wires the hex map and config panel
 * together, handles state persistence via sessionStorage, and loads active
 * travel parties on open.
 */

class JourneyModal {
  constructor() {
    this.dialog = document.getElementById('journeyModal');
    if (!this.dialog) return;

    this.mapRenderer = null;
    this.configPanel = null;
    this.initialized = false;
  }

  open() {
    if (!this.dialog) return;

    this.dialog.showModal();

    if (!this.initialized) {
      this.initComponents();
      this.initialized = true;
    } else {
      // Reload map data in case location changed
      this.mapRenderer?.loadInitialData().then(() => {
        if (!this.mapRenderer.restoreViewport()) {
          this.mapRenderer.centerOnCurrentLocation();
        }
      });
    }

    this.loadActiveParty();
  }

  close() {
    if (!this.dialog) return;

    // Save viewport state
    this.mapRenderer?.saveViewport();
    this.configPanel?.stopPolling();
    this.dialog.close();

    // Return focus to game input
    document.getElementById('messageInput')?.focus();
  }

  initComponents() {
    // Init hex map
    this.mapRenderer = new JourneyHexMap('journey-map-container', {
      onDestinationSelect: (location) => this.onDestinationSelect(location)
    });

    // Init config panel
    this.configPanel = new JourneyConfigPanel('journey-config-container', {
      onTravelStarted: () => this.close(),
      onClearSelection: () => {
        this.mapRenderer?.clearSelection();
      }
    });

    // Zoom controls
    document.getElementById('journey-zoom-in')?.addEventListener('click', () => this.mapRenderer?.zoomIn());
    document.getElementById('journey-zoom-out')?.addEventListener('click', () => this.mapRenderer?.zoomOut());
    document.getElementById('journey-recenter')?.addEventListener('click', () => this.mapRenderer?.recenter());

    // Close button and backdrop
    document.getElementById('journeyCloseBtn')?.addEventListener('click', () => this.close());
    document.getElementById('journeyBackdrop')?.addEventListener('click', () => this.close());

    // Keyboard shortcuts while modal is open
    this.dialog.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        this.close();
      } else if (e.key === '+' || e.key === '=') {
        this.mapRenderer?.zoomIn();
      } else if (e.key === '-') {
        this.mapRenderer?.zoomOut();
      }
    });

    // Load initial map data
    this.mapRenderer.loadInitialData().then(() => {
      if (!this.mapRenderer.restoreViewport()) {
        this.mapRenderer.centerOnCurrentLocation();
      }
    });
  }

  onDestinationSelect(location) {
    if (this.configPanel) {
      this.configPanel.showOptionsForDestination(location);
    }
  }

  async loadActiveParty() {
    if (this.configPanel) {
      const hasParty = await this.configPanel.loadActiveParty();
      if (hasParty) {
        // Party found - config panel will show party state
        return;
      }
    }
  }
}

// ─── Global Integration ────────────────────────────────────────────────

let journeyModalInstance = null;

function openTravelMap() {
  if (!journeyModalInstance) {
    journeyModalInstance = new JourneyModal();
  }
  journeyModalInstance.open();
}

function closeTravelMap() {
  if (journeyModalInstance) {
    journeyModalInstance.close();
  }
}

window.openTravelMap = openTravelMap;
window.closeTravelMap = closeTravelMap;
window.JourneyModal = JourneyModal;
