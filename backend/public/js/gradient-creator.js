/**
 * Gradient Creator Modal
 * Full-featured modal for creating and editing color gradients
 */

class GradientCreator {
  constructor(options = {}) {
    this.options = {
      onSave: options.onSave || null,
      onCancel: options.onCancel || null,
      apiEndpoint: options.apiEndpoint || '/api/gradients',
      minStops: 2,
      maxStops: 10,
      defaultEasing: 100,
      minEasing: 50,
      maxEasing: 200,
      previewText: options.previewText || 'The quick brown fox jumps over the lazy dog'
    };

    this.colorStops = ['#ff0000', '#0000ff'];
    this.easings = [];
    this.name = '';
    this.gradientId = null;
    this.modal = null;
    this.isOpen = false;
  }

  /**
   * Open the creator modal
   * @param {Object} existingGradient - Optional gradient to edit
   */
  open(existingGradient = null) {
    if (existingGradient) {
      this.gradientId = existingGradient.id || null;
      this.name = existingGradient.name || '';
      this.colorStops = existingGradient.colors || ['#ff0000', '#0000ff'];
      this.easings = existingGradient.easings || [];
    } else {
      this.gradientId = null;
      this.name = '';
      this.colorStops = ['#ff0000', '#0000ff'];
      this.easings = [];
    }

    this.render();
    this.isOpen = true;
  }

  /**
   * Close the modal
   */
  close() {
    if (this.modal) {
      this.modal.remove();
      this.modal = null;
    }
    this.isOpen = false;
  }

  /**
   * Render the modal
   */
  render() {
    // Remove existing modal if present
    if (this.modal) {
      this.modal.remove();
    }

    this.modal = document.createElement('div');
    this.modal.className = 'gradient-creator-modal';
    this.modal.innerHTML = this.getModalHTML();

    // Append to existing dialog if inside one, otherwise to body
    const existingDialog = document.querySelector('dialog[open]');
    if (existingDialog) {
      // Inside a dialog - need higher z-index and append to dialog
      this.modal.style.zIndex = '10002';
      existingDialog.appendChild(this.modal);
    } else {
      document.body.appendChild(this.modal);
    }

    this.bindEvents();
    this.updatePreviews();
  }

  /**
   * Generate modal HTML
   */
  getModalHTML() {
    const isEditing = this.gradientId !== null;
    const title = isEditing ? 'Edit Gradient' : 'Create Gradient';
    const saveText = isEditing ? 'Update' : 'Save';

    return `
      <div class="gradient-creator-overlay">
        <div class="gradient-creator-dialog">
          <div class="gradient-creator-header">
            <h2>${title}</h2>
            <button type="button" class="gradient-creator-close" aria-label="Close">&times;</button>
          </div>

          <div class="gradient-creator-body">
            <!-- Name Input -->
            <div class="gradient-creator-section">
              <label class="gradient-creator-label">Gradient Name</label>
              <input type="text" class="gradient-creator-name-input"
                     value="${escapeHtml(this.name)}"
                     placeholder="My Gradient"
                     maxlength="100">
            </div>

            <!-- Color Stops -->
            <div class="gradient-creator-section">
              <label class="gradient-creator-label">Color Stops</label>
              <div class="gradient-creator-stops">
                ${this.renderColorStops()}
              </div>
              <button type="button" class="gradient-creator-add-stop"
                      ${this.colorStops.length >= this.options.maxStops ? 'disabled' : ''}>
                + Add Color Stop
              </button>
            </div>

            <!-- Easings (only shown if 3+ colors) -->
            ${this.colorStops.length >= 3 ? this.renderEasingsSection() : ''}

            <!-- Preview -->
            <div class="gradient-creator-section">
              <label class="gradient-creator-label">Preview</label>
              <div class="gradient-creator-preview-bar"></div>
              <div class="gradient-creator-preview-text">${this.options.previewText}</div>
            </div>
          </div>

          <div class="gradient-creator-footer">
            <button type="button" class="gradient-creator-btn gradient-creator-btn-cancel">Cancel</button>
            <button type="button" class="gradient-creator-btn gradient-creator-btn-save">${saveText}</button>
          </div>
        </div>
      </div>
    `;
  }

  /**
   * Render color stop inputs
   */
  renderColorStops() {
    return this.colorStops.map((color, index) => {
      const canRemove = this.colorStops.length > this.options.minStops;
      const stopNumber = index + 1;
      const hasEasing = index > 0 && index % 2 === 1;

      return `
        <div class="gradient-color-stop" data-index="${index}">
          <span class="gradient-color-stop-num">${stopNumber}</span>
          <input type="color" class="gradient-color-picker" value="${color}">
          <input type="text" class="gradient-color-hex" value="${color}"
                 pattern="^#?[0-9a-fA-F]{6}$" maxlength="7"
                 placeholder="#000000">
          ${hasEasing ? '<span class="gradient-easing-indicator" title="Easing point">E</span>' : ''}
          <button type="button" class="gradient-color-remove"
                  ${canRemove ? '' : 'disabled'}
                  aria-label="Remove color">&times;</button>
        </div>
      `;
    }).join('');
  }

  /**
   * Render easing controls section
   */
  renderEasingsSection() {
    // Easings apply at alternating stops (2nd, 4th, 6th...)
    const easingPoints = [];
    for (let i = 1; i < this.colorStops.length; i += 2) {
      easingPoints.push(i);
    }

    if (easingPoints.length === 0) return '';

    const easingControls = easingPoints.map((stopIndex, easingIndex) => {
      const value = this.easings[easingIndex] ?? this.options.defaultEasing;
      const stopNum = stopIndex + 1;

      return `
        <div class="gradient-easing-control" data-easing-index="${easingIndex}">
          <label>Stop ${stopNum} easing:</label>
          <input type="range" class="gradient-easing-slider"
                 min="${this.options.minEasing}" max="${this.options.maxEasing}"
                 value="${value}">
          <input type="number" class="gradient-easing-value"
                 min="${this.options.minEasing}" max="${this.options.maxEasing}"
                 value="${value}">
        </div>
      `;
    }).join('');

    return `
      <div class="gradient-creator-section gradient-easings-section">
        <label class="gradient-creator-label">
          Transition Easing
          <span class="gradient-creator-help" title="100 = linear, higher = slower at first then faster near the stop">?</span>
        </label>
        <div class="gradient-easing-controls">
          ${easingControls}
        </div>
      </div>
    `;
  }

  /**
   * Bind event handlers
   */
  bindEvents() {
    const modal = this.modal;
    if (!modal) return;

    // Close button
    modal.querySelector('.gradient-creator-close').addEventListener('click', () => this.handleCancel());

    // Cancel button
    modal.querySelector('.gradient-creator-btn-cancel').addEventListener('click', () => this.handleCancel());

    // Save button
    modal.querySelector('.gradient-creator-btn-save').addEventListener('click', () => this.handleSave());

    // Overlay click to close
    modal.querySelector('.gradient-creator-overlay').addEventListener('click', (e) => {
      if (e.target === e.currentTarget) {
        this.handleCancel();
      }
    });

    // Name input
    modal.querySelector('.gradient-creator-name-input').addEventListener('input', (e) => {
      this.name = e.target.value;
    });

    // Add color stop
    modal.querySelector('.gradient-creator-add-stop').addEventListener('click', () => {
      this.addColorStop();
    });

    // Color stop events (delegated)
    modal.querySelector('.gradient-creator-stops').addEventListener('input', (e) => {
      const stopEl = e.target.closest('.gradient-color-stop');
      if (!stopEl) return;

      const index = parseInt(stopEl.dataset.index, 10);

      if (e.target.classList.contains('gradient-color-picker')) {
        this.colorStops[index] = e.target.value;
        stopEl.querySelector('.gradient-color-hex').value = e.target.value;
        this.updatePreviews();
      } else if (e.target.classList.contains('gradient-color-hex')) {
        const normalized = GradientGenerator.normalizeHex(e.target.value);
        if (normalized) {
          this.colorStops[index] = normalized;
          stopEl.querySelector('.gradient-color-picker').value = normalized;
          this.updatePreviews();
        }
      }
    });

    // Remove color stop
    modal.querySelector('.gradient-creator-stops').addEventListener('click', (e) => {
      if (e.target.classList.contains('gradient-color-remove')) {
        const stopEl = e.target.closest('.gradient-color-stop');
        if (stopEl) {
          const index = parseInt(stopEl.dataset.index, 10);
          this.removeColorStop(index);
        }
      }
    });

    // Easing controls (if present)
    const easingsSection = modal.querySelector('.gradient-easing-controls');
    if (easingsSection) {
      easingsSection.addEventListener('input', (e) => {
        const controlEl = e.target.closest('.gradient-easing-control');
        if (!controlEl) return;

        const easingIndex = parseInt(controlEl.dataset.easingIndex, 10);
        const value = parseInt(e.target.value, 10);

        if (!isNaN(value)) {
          this.easings[easingIndex] = value;

          // Sync slider and number input
          if (e.target.classList.contains('gradient-easing-slider')) {
            controlEl.querySelector('.gradient-easing-value').value = value;
          } else {
            controlEl.querySelector('.gradient-easing-slider').value = value;
          }

          this.updatePreviews();
        }
      });
    }

    // Keyboard shortcuts
    document.addEventListener('keydown', this.handleKeydown.bind(this));
  }

  /**
   * Handle keyboard events
   */
  handleKeydown(e) {
    if (!this.isOpen) return;

    if (e.key === 'Escape') {
      this.handleCancel();
    } else if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
      this.handleSave();
    }
  }

  /**
   * Add a new color stop
   */
  addColorStop() {
    if (this.colorStops.length >= this.options.maxStops) return;

    // Add a color interpolated between the last two stops
    const lastColor = this.colorStops[this.colorStops.length - 1];
    const prevColor = this.colorStops[this.colorStops.length - 2] || lastColor;
    const newColor = GradientColorSpace.interpolateHex(prevColor, lastColor, 0.5);

    this.colorStops.push(newColor);
    this.render();
  }

  /**
   * Remove a color stop
   */
  removeColorStop(index) {
    if (this.colorStops.length <= this.options.minStops) return;

    this.colorStops.splice(index, 1);

    // Adjust easings array if needed
    const maxEasings = Math.floor((this.colorStops.length - 1) / 2);
    if (this.easings.length > maxEasings) {
      this.easings = this.easings.slice(0, maxEasings);
    }

    this.render();
  }

  /**
   * Update preview displays
   */
  updatePreviews() {
    if (!this.modal) return;

    // Update gradient bar preview
    const previewBar = this.modal.querySelector('.gradient-creator-preview-bar');
    if (previewBar) {
      const cssGradient = GradientGenerator.toCssGradient(this.colorStops, this.easings);
      previewBar.style.background = cssGradient;
    }

    // Update text preview
    const previewText = this.modal.querySelector('.gradient-creator-preview-text');
    if (previewText) {
      const coloredHtml = GradientGenerator.applyToText(
        this.options.previewText,
        this.colorStops,
        this.easings
      );
      previewText.innerHTML = coloredHtml;
    }
  }

  /**
   * Handle cancel/close
   */
  handleCancel() {
    this.close();
    if (this.options.onCancel) {
      this.options.onCancel();
    }
  }

  /**
   * Handle save
   */
  async handleSave() {
    // Validate
    if (!this.name.trim()) {
      this.showError('Please enter a gradient name');
      return;
    }

    if (this.colorStops.length < 2) {
      this.showError('At least 2 color stops are required');
      return;
    }

    // Prepare data
    const gradientData = {
      name: this.name.trim(),
      colors: this.colorStops,
      easings: this.easings,
      interpolation: 'ciede2000'
    };

    try {
      let response;
      if (this.gradientId) {
        // Update existing
        response = await fetch(`${this.options.apiEndpoint}/${this.gradientId}`, {
          method: 'PUT',
          headers: { 'Content-Type': 'application/json' },
          credentials: 'same-origin',
          body: JSON.stringify(gradientData)
        });
      } else {
        // Create new
        response = await fetch(this.options.apiEndpoint, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          credentials: 'same-origin',
          body: JSON.stringify(gradientData)
        });
      }

      if (!response.ok) {
        const errorData = await response.json().catch(() => ({}));
        throw new Error(errorData.error || 'Failed to save gradient');
      }

      const savedGradient = await response.json();

      this.close();
      if (this.options.onSave) {
        this.options.onSave(savedGradient);
      }
    } catch (error) {
      this.showError(error.message);
    }
  }

  /**
   * Show error message
   */
  showError(message) {
    // Remove existing error
    const existing = this.modal?.querySelector('.gradient-creator-error');
    if (existing) existing.remove();

    const errorEl = document.createElement('div');
    errorEl.className = 'gradient-creator-error';
    errorEl.textContent = message;

    const body = this.modal?.querySelector('.gradient-creator-body');
    if (body) {
      body.insertBefore(errorEl, body.firstChild);

      // Auto-remove after 5 seconds
      setTimeout(() => errorEl.remove(), 5000);
    }
  }

}

// Export for module systems
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { GradientCreator };
}

// Global export for browser
if (typeof window !== 'undefined') {
  window.GradientCreator = GradientCreator;
}
