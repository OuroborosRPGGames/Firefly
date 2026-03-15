/**
 * Gradient Picker Drop-up Component
 * Displays a list of gradients for quick selection
 */

class GradientPicker {
  constructor(options = {}) {
    this.options = {
      buttonContainer: options.buttonContainer || null,
      onSelect: options.onSelect || null,
      onCreate: options.onCreate || null,
      apiEndpoint: options.apiEndpoint || '/api/gradients',
      position: options.position || 'above', // 'above' or 'below'
      maxRecent: 10
    };

    this.gradients = [];
    this.recentIds = [];
    this.isOpen = false;
    this.button = null;
    this.popup = null;
    this.creator = null;

    if (this.options.buttonContainer) {
      this.init();
    }
  }

  /**
   * Initialize the picker
   */
  init() {
    this.createButton();
    this.loadGradients();
  }

  /**
   * Create the picker button
   */
  createButton() {
    this.button = document.createElement('button');
    this.button.type = 'button';
    this.button.className = 'gradient-picker-btn';
    this.button.title = 'Apply Gradient';
    this.button.innerHTML = this.getButtonIcon();

    this.button.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();
      this.toggle();
    });

    if (this.options.buttonContainer) {
      this.options.buttonContainer.appendChild(this.button);
    }

    // Close on outside click
    document.addEventListener('click', (e) => {
      if (this.isOpen && !this.popup?.contains(e.target) && !this.button.contains(e.target)) {
        this.close();
      }
    });
  }

  /**
   * Get SVG icon for button
   */
  getButtonIcon() {
    return `
      <svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg">
        <defs>
          <linearGradient id="gradientIcon" x1="0%" y1="0%" x2="100%" y2="0%">
            <stop offset="0%" style="stop-color:#ff6b6b"/>
            <stop offset="50%" style="stop-color:#4ecdc4"/>
            <stop offset="100%" style="stop-color:#45b7d1"/>
          </linearGradient>
        </defs>
        <rect x="1" y="4" width="14" height="8" rx="1" fill="url(#gradientIcon)"/>
        <path d="M3 8h10" stroke="white" stroke-width="1" stroke-opacity="0.5"/>
      </svg>
    `;
  }

  /**
   * Load gradients from API
   */
  async loadGradients() {
    try {
      // Load all gradients
      const response = await fetch(this.options.apiEndpoint, { credentials: 'same-origin' });
      if (response.ok) {
        this.gradients = await response.json();
      }

      // Load recent
      const recentResponse = await fetch(`${this.options.apiEndpoint}/recent`, { credentials: 'same-origin' });
      if (recentResponse.ok) {
        const recentData = await recentResponse.json();
        this.recentIds = recentData.map(g => g.id);
      }
    } catch (error) {
      console.error('Failed to load gradients:', error);
    }
  }

  /**
   * Toggle popup visibility
   */
  toggle() {
    if (this.isOpen) {
      this.close();
    } else {
      this.open();
    }
  }

  /**
   * Open the popup
   */
  open() {
    if (this.isOpen) return;

    // Refresh data
    this.loadGradients().then(() => {
      this.renderPopup();
      this.isOpen = true;
      this.button.classList.add('active');
    });
  }

  /**
   * Close the popup
   */
  close() {
    if (this.popup) {
      this.popup.remove();
      this.popup = null;
    }
    this.isOpen = false;
    this.button?.classList.remove('active');
  }

  /**
   * Render the popup
   */
  renderPopup() {
    // Remove existing
    if (this.popup) {
      this.popup.remove();
    }

    this.popup = document.createElement('div');
    this.popup.className = `gradient-picker-popup gradient-picker-${this.options.position}`;

    // Get recent gradients
    const recentGradients = this.recentIds
      .map(id => this.gradients.find(g => g.id === id))
      .filter(Boolean)
      .slice(0, this.options.maxRecent);

    // Get all gradients sorted by name
    const allGradients = [...this.gradients].sort((a, b) =>
      (a.name || '').localeCompare(b.name || '')
    );

    this.popup.innerHTML = `
      <div class="gradient-picker-header">
        <span>Gradients</span>
        <button type="button" class="gradient-picker-create-btn" title="Create new gradient">+</button>
      </div>

      ${recentGradients.length > 0 ? `
        <div class="gradient-picker-section">
          <div class="gradient-picker-section-title">Recent</div>
          <div class="gradient-picker-list">
            ${recentGradients.map(g => this.renderGradientItem(g)).join('')}
          </div>
        </div>
      ` : ''}

      <div class="gradient-picker-section">
        <div class="gradient-picker-section-title">All Gradients</div>
        <div class="gradient-picker-list gradient-picker-all">
          ${allGradients.length > 0
            ? allGradients.map(g => this.renderGradientItem(g)).join('')
            : '<div class="gradient-picker-empty">No gradients yet</div>'
          }
        </div>
      </div>
    `;

    // Position the popup
    this.positionPopup();

    // Add to DOM - use modal-box if inside a dialog, otherwise body
    const modalBox = this.button.closest('.modal-box') || this.button.closest('dialog');
    if (modalBox) {
      // Inside a modal - append to modal and use absolute positioning
      this.popup.style.position = 'absolute';
      modalBox.appendChild(this.popup);
    } else {
      document.body.appendChild(this.popup);
    }

    // Bind events
    this.bindPopupEvents();
  }

  /**
   * Render a single gradient item
   */
  renderGradientItem(gradient) {
    const colors = gradient.colors || [];
    const easings = gradient.easings || [];
    const cssGradient = GradientGenerator.toCssGradient(colors, easings);

    return `
      <div class="gradient-picker-item" data-gradient-id="${gradient.id}">
        <div class="gradient-picker-preview" style="background: ${cssGradient}"></div>
        <div class="gradient-picker-name">${escapeHtml(gradient.name || 'Untitled')}</div>
        <button type="button" class="gradient-picker-edit-btn" title="Edit">
          <svg width="12" height="12" viewBox="0 0 12 12" fill="currentColor">
            <path d="M9.5 1.5l1 1-7 7H2.5v-1l7-7z"/>
          </svg>
        </button>
      </div>
    `;
  }

  /**
   * Position popup relative to button
   */
  positionPopup() {
    if (!this.popup || !this.button) return;

    const btnRect = this.button.getBoundingClientRect();
    const popupWidth = 280;
    const popupMaxHeight = 400;

    // Check if we're inside a modal (using absolute positioning)
    const modalBox = this.button.closest('.modal-box') || this.button.closest('dialog');

    let left, top;

    if (modalBox) {
      // Position relative to modal-box
      const modalRect = modalBox.getBoundingClientRect();
      left = btnRect.left - modalRect.left;

      if (this.options.position === 'above') {
        top = btnRect.top - modalRect.top - popupMaxHeight - 8;
        if (top < 10) {
          top = btnRect.bottom - modalRect.top + 8;
          this.popup.classList.remove('gradient-picker-above');
          this.popup.classList.add('gradient-picker-below');
        }
      } else {
        top = btnRect.bottom - modalRect.top + 8;
      }

      // Keep within modal bounds
      if (left + popupWidth > modalRect.width - 10) {
        left = modalRect.width - popupWidth - 10;
      }
      if (left < 10) left = 10;
    } else {
      // Position relative to viewport (fixed positioning)
      left = btnRect.left;

      if (this.options.position === 'above') {
        top = btnRect.top - popupMaxHeight - 8;
        if (top < 10) {
          top = btnRect.bottom + 8;
          this.popup.classList.remove('gradient-picker-above');
          this.popup.classList.add('gradient-picker-below');
        }
      } else {
        top = btnRect.bottom + 8;
      }

      // Keep within viewport
      if (left + popupWidth > window.innerWidth - 10) {
        left = window.innerWidth - popupWidth - 10;
      }
      if (left < 10) left = 10;
    }

    this.popup.style.left = `${left}px`;
    this.popup.style.top = `${top}px`;
    this.popup.style.maxHeight = `${popupMaxHeight}px`;
  }

  /**
   * Bind popup event handlers
   */
  bindPopupEvents() {
    if (!this.popup) return;

    // Create new button
    this.popup.querySelector('.gradient-picker-create-btn')?.addEventListener('click', () => {
      this.close();
      this.openCreator();
    });

    // Click on gradient item
    this.popup.addEventListener('click', (e) => {
      const item = e.target.closest('.gradient-picker-item');
      if (!item) return;

      const gradientId = parseInt(item.dataset.gradientId, 10);
      const gradient = this.gradients.find(g => g.id === gradientId);

      if (e.target.closest('.gradient-picker-edit-btn')) {
        // Edit button clicked
        this.close();
        this.openCreator(gradient);
      } else {
        // Item clicked - select gradient
        this.selectGradient(gradient);
      }
    });
  }

  /**
   * Select a gradient
   */
  async selectGradient(gradient) {
    if (!gradient) return;

    // Track usage
    try {
      await fetch(`${this.options.apiEndpoint}/${gradient.id}/use`, {
        method: 'POST',
        credentials: 'same-origin'
      });
    } catch (error) {
      console.warn('Failed to track gradient usage:', error);
    }

    this.close();

    if (this.options.onSelect) {
      this.options.onSelect(gradient);
    }
  }

  /**
   * Open the gradient creator modal
   */
  openCreator(existingGradient = null) {
    if (!this.creator) {
      this.creator = new GradientCreator({
        apiEndpoint: this.options.apiEndpoint,
        onSave: (savedGradient) => {
          // Reload gradients and trigger callback
          this.loadGradients().then(() => {
            if (this.options.onCreate) {
              this.options.onCreate(savedGradient);
            }
          });
        }
      });
    }

    this.creator.open(existingGradient);
  }

  /**
   * Apply gradient to text (utility method)
   */
  static applyToText(text, gradient) {
    if (!gradient || !gradient.colors || gradient.colors.length < 2) {
      return text;
    }

    return GradientGenerator.applyToText(
      text,
      gradient.colors,
      gradient.easings || []
    );
  }

  /**
   * Destroy the picker
   */
  destroy() {
    this.close();
    if (this.button) {
      this.button.remove();
      this.button = null;
    }
    if (this.creator) {
      this.creator.close();
      this.creator = null;
    }
  }
}

// Export for module systems
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { GradientPicker };
}

// Global export for browser
if (typeof window !== 'undefined') {
  window.GradientPicker = GradientPicker;
}
