/**
 * Description Manager Component
 * Handles displaying, reordering, and managing character descriptions
 */
class DescriptionManager {
  constructor(container, characterId, options = {}) {
    this.container = typeof container === 'string' ? document.querySelector(container) : container;
    this.characterId = characterId;
    this.options = {
      onDescriptionChange: null,
      showPreview: true,
      ...options
    };

    this.descriptions = [];
    this.bodyPositions = {};
    this.currentRegion = 'all';  // Default to showing all
    this.regions = ['all', 'head', 'torso', 'arms', 'hands', 'legs', 'feet'];

    this.init();
  }

  async init() {
    await this.loadBodyPositions();
    await this.loadDescriptions();
    this.render();
    this.bindEvents();

    // Trigger callback after initial load so live preview updates
    if (this.options.onDescriptionChange) {
      this.options.onDescriptionChange(this.descriptions);
    }
  }

  async loadBodyPositions() {
    try {
      const response = await fetch('/api/body-positions');
      const data = await response.json();
      if (data.success) {
        this.bodyPositions = data.positions;
      }
    } catch (error) {
      console.error('Failed to load body positions:', error);
    }
  }

  async loadDescriptions() {
    try {
      const response = await fetch(`/characters/${this.characterId}/descriptions`, {
        headers: {
          'Accept': 'application/json'
        }
      });
      const data = await response.json();
      if (data.success) {
        this.descriptions = data.descriptions;
      }
    } catch (error) {
      console.error('Failed to load descriptions:', error);
    }
  }

  render() {
    const activeDescs = this.descriptions.filter(d => d.active);
    const inactiveDescs = this.descriptions.filter(d => !d.active);

    // Sort by display_order for consistent ordering
    const sortedActive = [...activeDescs].sort((a, b) => a.display_order - b.display_order);

    // Filter by region if not 'all'
    const filteredDescs = this.currentRegion === 'all'
      ? sortedActive
      : sortedActive.filter(d => d.region === this.currentRegion);

    this.container.innerHTML = `
      <div class="desc-manager">
        <div class="desc-manager-header">
          <h5>Character Descriptions</h5>
          <button type="button" class="btn btn-primary btn-sm" id="addDescBtn">
            <i class="bi bi-plus"></i> Add Description
          </button>
        </div>

        <!-- Region Filter Tabs -->
        <div role="tablist" class="tabs tabs-boxed desc-region-tabs">
          ${this.regions.map(region => `
            <button class="tab ${region === this.currentRegion ? 'tab-active' : ''}"
                    data-region="${region}" type="button">
              ${this.formatRegionName(region)}
              <span class="badge badge-ghost ml-1">${region === 'all' ? activeDescs.length : activeDescs.filter(d => d.region === region).length}</span>
            </button>
          `).join('')}
        </div>

        <!-- Active Descriptions (drag to reorder) -->
        <div class="desc-list desc-active-list" id="activeDescList">
          ${filteredDescs.length === 0 ? `
            <div class="desc-empty-state">
              <p class="text-base-content/60">${this.currentRegion === 'all' ? 'No descriptions yet' : `No descriptions for ${this.formatRegionName(this.currentRegion)}`}</p>
              <button type="button" class="btn btn-outline btn-primary btn-sm add-region-desc"
                      data-region="${this.currentRegion === 'all' ? 'head' : this.currentRegion}">
                Add Description
              </button>
            </div>
          ` : filteredDescs.map(desc => this.renderDescriptionCard(desc, true)).join('')}
        </div>

        <!-- Inactive Descriptions -->
        ${inactiveDescs.length > 0 ? `
          <div class="desc-inactive-section">
            <div class="collapse collapse-arrow bg-base-200 rounded-lg">
              <input type="checkbox" id="inactiveDescsToggle" />
              <div class="collapse-title text-base-content/60 font-medium">
                <i class="bi bi-eye-slash mr-2"></i>Inactive Descriptions (${inactiveDescs.length})
              </div>
              <div class="collapse-content">
                <div class="desc-list desc-inactive-list">
                  ${inactiveDescs.map(desc => this.renderDescriptionCard(desc, false)).join('')}
                </div>
              </div>
            </div>
          </div>
        ` : ''}

        ${this.options.showPreview ? `
          <div class="desc-preview-section">
            <h6>Preview</h6>
            <div class="desc-preview-content">
              ${this.renderPreview(activeDescs)}
            </div>
          </div>
        ` : ''}
      </div>
    `;
  }

  renderDescriptionCard(desc, isActive) {
    // Support multiple body positions
    const positionLabels = this.getPositionLabels(desc);
    const regionLabels = this.getRegionLabels(desc);
    const suffixLabel = this.getSuffixLabel(desc.suffix);
    const prefixLabel = this.getPrefixLabel(desc.prefix);

    return `
      <div class="desc-card ${isActive ? '' : 'desc-card-inactive'}"
           data-id="${desc.id}"
           data-order="${desc.display_order}"
           data-suffix="${desc.suffix || 'period'}"
           data-prefix="${desc.prefix || 'none'}"
           draggable="${isActive}">
        <div class="desc-card-header">
          <span class="desc-card-drag-handle" title="Drag to reorder">
            <i class="bi bi-grip-vertical"></i>
          </span>
          <span class="desc-card-position">${positionLabels}</span>
          <span class="desc-card-region badge badge-ghost">${regionLabels}</span>
          <span class="desc-card-prefix badge badge-accent clickable-prefix"
                data-id="${desc.id}"
                data-prefix="${desc.prefix || 'none'}"
                title="Click to change prefix">${prefixLabel || '∅'}</span>
          <span class="desc-card-suffix badge badge-neutral clickable-suffix"
                data-id="${desc.id}"
                data-suffix="${desc.suffix || 'period'}"
                title="Click to change suffix">${suffixLabel}</span>
          ${desc.concealed_by_clothing ? '<span class="badge badge-info" title="Hidden by clothing"><i class="bi bi-eye-slash"></i></span>' : ''}
        </div>
        <div class="desc-card-content">
          ${desc.image_url ? `<img src="${desc.image_url}" class="desc-card-image desc-thumbnail-clickable" data-full-url="${desc.image_url}" alt="" title="Click to view full size">` : ''}
          <div class="desc-card-text">${desc.content}</div>
        </div>
        <div class="desc-card-actions">
          <button type="button" class="btn btn-outline btn-ghost btn-sm desc-action-edit"
                  data-id="${desc.id}" title="Edit">
            <i class="bi bi-pencil"></i>
          </button>
          <button type="button" class="btn btn-outline btn-${isActive ? 'warning' : 'success'} btn-sm desc-action-toggle"
                  data-id="${desc.id}" title="${isActive ? 'Deactivate' : 'Activate'}">
            <i class="bi bi-${isActive ? 'eye-slash' : 'eye'}"></i>
          </button>
          <button type="button" class="btn btn-outline btn-error btn-sm desc-action-delete"
                  data-id="${desc.id}" title="Delete">
            <i class="bi bi-trash"></i>
          </button>
        </div>
      </div>
    `;
  }

  getPositionLabels(desc) {
    // If description has multiple body positions, show all
    if (desc.body_positions && desc.body_positions.length > 0) {
      return desc.body_positions.map(p => this.formatLabel(p.label)).join(', ');
    }
    // Fall back to single position
    if (desc.body_position) {
      return this.formatLabel(desc.body_position.label);
    }
    return desc.body_position_label || 'Unknown';
  }

  getRegionLabels(desc) {
    // If description has multiple body positions with different regions, show all unique
    if (desc.body_positions && desc.body_positions.length > 0) {
      const uniqueRegions = [...new Set(desc.body_positions.map(p => p.region))];
      return uniqueRegions.map(r => this.formatRegionName(r)).join(', ');
    }
    // Fall back to single region
    return this.formatRegionName(desc.region);
  }

  formatLabel(label) {
    if (!label) return 'Unknown';
    return label.replace(/_/g, ' ').split(' ').map(w => w.charAt(0).toUpperCase() + w.slice(1)).join(' ');
  }

  renderPreview(activeDescs) {
    if (activeDescs.length === 0) {
      return '<p class="text-base-content/60">No active descriptions to preview</p>';
    }

    // Sort all descriptions by display_order (global ordering)
    const sorted = [...activeDescs].sort((a, b) => a.display_order - b.display_order);

    let preview = '<div class="preview-content">';
    let previousSuffix = null;

    sorted.forEach((desc, index, arr) => {
      if (desc.image_url) {
        preview += `<img src="${desc.image_url}" class="preview-image desc-thumbnail-clickable" data-full-url="${desc.image_url}" alt="">`;
      }

      // Get prefix text
      const prefix = desc.prefix || 'none';
      const prefixText = this.getPrefixText(prefix);

      // Apply capitalization based on prefix and previous suffix
      let content = desc.content || '';
      if (prefixText) {
        // Content after prefix should be lowercase
        content = this.lowercaseFirst(content);
      } else if (index > 0 && previousSuffix && ['comma', 'space'].includes(previousSuffix)) {
        // After comma/space: lowercase first letter
        content = this.lowercaseFirst(content);
      } else {
        // First description or after sentence-ending suffix: capitalize
        content = this.capitalizeFirst(content);
      }

      preview += `<span class="preview-text">${prefixText}${content}</span>`;

      // Add suffix after each description (including last)
      const suffix = desc.suffix || 'period';
      const suffixText = this.getSuffixText(suffix);
      if (suffixText.includes('\n')) {
        preview += `<br>`;
        if (suffixText.includes('\n\n')) preview += `<br>`;
      } else {
        preview += suffixText;
      }

      previousSuffix = suffix;
    });
    preview += '</div>';

    return preview;
  }

  capitalizeFirst(text) {
    if (!text || text.length === 0) return text;
    return text.charAt(0).toUpperCase() + text.slice(1);
  }

  lowercaseFirst(text) {
    if (!text || text.length === 0) return text;
    return text.charAt(0).toLowerCase() + text.slice(1);
  }

  formatRegionName(region) {
    if (region === 'all') return 'All';
    return region.charAt(0).toUpperCase() + region.slice(1);
  }

  getSuffixLabel(suffix) {
    switch (suffix) {
      case 'period': return '. ';
      case 'comma': return ', ';
      case 'space': return '␣';
      case 'newline': return '↵';
      case 'double_newline': return '¶';
      default: return '. ';
    }
  }

  getSuffixText(suffix) {
    switch (suffix) {
      case 'period': return '. ';
      case 'comma': return ', ';
      case 'space': return ' ';
      case 'newline': return '.\n';
      case 'double_newline': return '.\n\n';
      default: return '. ';
    }
  }

  getPrefixLabel(prefix) {
    switch (prefix) {
      case 'pronoun_has': return '(S)he has';
      case 'pronoun_is': return '(S)he is';
      case 'and': return 'and';
      default: return '';
    }
  }

  getPrefixText(prefix) {
    // Use character gender from page data (window.characterGender)
    const gender = (window.characterGender || '').toLowerCase();
    let pronoun, hasVerb, isVerb;

    if (gender === 'female') {
      pronoun = 'She';
      hasVerb = 'has';
      isVerb = 'is';
    } else if (gender === 'male') {
      pronoun = 'He';
      hasVerb = 'has';
      isVerb = 'is';
    } else {
      // Non-binary or unspecified - use they/have/are
      pronoun = 'They';
      hasVerb = 'have';
      isVerb = 'are';
    }

    switch (prefix) {
      case 'pronoun_has': return `${pronoun} ${hasVerb} `;
      case 'pronoun_is': return `${pronoun} ${isVerb} `;
      case 'and': return 'and ';
      default: return '';
    }
  }

  bindEvents() {
    // Region tab switching
    this.container.querySelectorAll('[data-region]').forEach(btn => {
      btn.addEventListener('click', () => {
        this.currentRegion = btn.dataset.region;
        this.render();
        this.bindEvents();
      });
    });

    // Add description button
    const addBtn = this.container.querySelector('#addDescBtn');
    if (addBtn) {
      addBtn.addEventListener('click', () => this.openAddModal());
    }

    // Add region-specific description
    this.container.querySelectorAll('.add-region-desc').forEach(btn => {
      btn.addEventListener('click', () => this.openAddModal(btn.dataset.region));
    });

    // Description actions
    this.container.querySelectorAll('.desc-action-edit').forEach(btn => {
      btn.addEventListener('click', () => this.openEditModal(parseInt(btn.dataset.id)));
    });

    this.container.querySelectorAll('.desc-action-toggle').forEach(btn => {
      btn.addEventListener('click', () => this.toggleDescription(parseInt(btn.dataset.id)));
    });

    this.container.querySelectorAll('.desc-action-delete').forEach(btn => {
      btn.addEventListener('click', () => this.deleteDescription(parseInt(btn.dataset.id)));
    });

    // Inline suffix picker
    this.container.querySelectorAll('.clickable-suffix').forEach(badge => {
      badge.addEventListener('click', (e) => {
        e.stopPropagation();
        this.showSuffixPicker(badge, parseInt(badge.dataset.id), badge.dataset.suffix);
      });
    });

    // Inline prefix picker
    this.container.querySelectorAll('.clickable-prefix').forEach(badge => {
      badge.addEventListener('click', (e) => {
        e.stopPropagation();
        this.showPrefixPicker(badge, parseInt(badge.dataset.id), badge.dataset.prefix);
      });
    });

    // Thumbnail click handlers (both in cards and preview)
    this.container.querySelectorAll('.desc-thumbnail-clickable').forEach(img => {
      img.addEventListener('click', (e) => {
        e.stopPropagation();
        this.showImageModal(img.dataset.fullUrl);
      });
    });

    // Also bind to preview images
    this.container.querySelectorAll('.preview-image').forEach(img => {
      if (img.dataset.fullUrl) {
        img.addEventListener('click', (e) => {
          e.stopPropagation();
          this.showImageModal(img.dataset.fullUrl);
        });
      }
    });

    // Drag and drop for reordering
    this.initDragDrop();
  }

  initDragDrop() {
    const list = this.container.querySelector('#activeDescList');
    if (!list) return;

    let draggedItem = null;

    list.querySelectorAll('.desc-card[draggable="true"]').forEach(card => {
      card.addEventListener('dragstart', (e) => {
        draggedItem = card;
        card.classList.add('dragging');
        e.dataTransfer.effectAllowed = 'move';
      });

      card.addEventListener('dragend', () => {
        card.classList.remove('dragging');
        draggedItem = null;
        this.saveOrder();
      });

      card.addEventListener('dragover', (e) => {
        e.preventDefault();
        if (draggedItem && draggedItem !== card) {
          const rect = card.getBoundingClientRect();
          const midY = rect.top + rect.height / 2;
          if (e.clientY < midY) {
            list.insertBefore(draggedItem, card);
          } else {
            list.insertBefore(draggedItem, card.nextSibling);
          }
        }
      });
    });
  }

  async saveOrder() {
    const cards = this.container.querySelectorAll('#activeDescList .desc-card');
    const orders = [];

    cards.forEach((card, index) => {
      orders.push({
        id: parseInt(card.dataset.id),
        display_order: index
      });
    });

    try {
      const response = await fetch(`/characters/${this.characterId}/descriptions/reorder`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': getCsrfToken()
        },
        body: JSON.stringify({ orders })
      });

      const data = await response.json();
      if (data.success) {
        await this.loadDescriptions();
        if (this.options.onDescriptionChange) {
          this.options.onDescriptionChange(this.descriptions);
        }
      }
    } catch (error) {
      console.error('Failed to save order:', error);
    }
  }

  async toggleDescription(descId) {
    try {
      const response = await fetch(`/characters/${this.characterId}/descriptions/${descId}/toggle`, {
        method: 'POST',
        headers: {
          'X-CSRF-Token': getCsrfToken()
        }
      });

      const data = await response.json();
      if (data.success) {
        await this.loadDescriptions();
        this.render();
        this.bindEvents();
        if (this.options.onDescriptionChange) {
          this.options.onDescriptionChange(this.descriptions);
        }
      }
    } catch (error) {
      console.error('Failed to toggle description:', error);
    }
  }

  async deleteDescription(descId) {
    if (!confirm('Are you sure you want to delete this description?')) return;

    try {
      const response = await fetch(`/characters/${this.characterId}/descriptions/${descId}`, {
        method: 'DELETE',
        headers: {
          'X-CSRF-Token': getCsrfToken()
        }
      });

      const data = await response.json();
      if (data.success) {
        await this.loadDescriptions();
        this.render();
        this.bindEvents();
        if (this.options.onDescriptionChange) {
          this.options.onDescriptionChange(this.descriptions);
        }
      }
    } catch (error) {
      console.error('Failed to delete description:', error);
    }
  }

  openAddModal(preselectedRegion = null) {
    // Trigger modal open event - handled by description-modal.js
    const event = new CustomEvent('openDescriptionModal', {
      detail: {
        mode: 'add',
        characterId: this.characterId,
        preselectedRegion,
        bodyPositions: this.bodyPositions,
        allowMultiple: true, // Enable multiple body position selection
        onSave: async () => {
          await this.loadDescriptions();
          this.render();
          this.bindEvents();
          if (this.options.onDescriptionChange) {
            this.options.onDescriptionChange(this.descriptions);
          }
        }
      }
    });
    document.dispatchEvent(event);
  }

  openEditModal(descId) {
    const desc = this.descriptions.find(d => d.id === descId);
    if (!desc) return;

    const event = new CustomEvent('openDescriptionModal', {
      detail: {
        mode: 'edit',
        characterId: this.characterId,
        description: desc,
        bodyPositions: this.bodyPositions,
        allowMultiple: true, // Enable multiple body position selection
        onSave: async () => {
          await this.loadDescriptions();
          this.render();
          this.bindEvents();
          if (this.options.onDescriptionChange) {
            this.options.onDescriptionChange(this.descriptions);
          }
        }
      }
    });
    document.dispatchEvent(event);
  }

  showSuffixPicker(badge, descId, currentSuffix) {
    // Close any existing pickers
    this.closePicker();

    const suffixes = [
      { key: 'period', label: '. ', title: 'Period' },
      { key: 'comma', label: ', ', title: 'Comma' },
      { key: 'space', label: '␣', title: 'Space' },
      { key: 'newline', label: '↵', title: 'Newline' },
      { key: 'double_newline', label: '¶', title: 'Paragraph' }
    ];

    const picker = document.createElement('div');
    picker.className = 'suffix-picker';
    picker.innerHTML = suffixes.map(suf => `
      <button type="button"
              class="suffix-option ${suf.key === currentSuffix ? 'active' : ''}"
              data-value="${suf.key}"
              title="${suf.title}">
        ${suf.label}
      </button>
    `).join('');

    // Position picker below the badge
    const rect = badge.getBoundingClientRect();
    const containerRect = this.container.getBoundingClientRect();
    picker.style.position = 'absolute';
    picker.style.top = `${rect.bottom - containerRect.top + 4}px`;
    picker.style.left = `${rect.left - containerRect.left}px`;

    // Add to container
    this.container.style.position = 'relative';
    this.container.appendChild(picker);

    // Handle option clicks
    picker.querySelectorAll('.suffix-option').forEach(btn => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation();
        const newSuffix = btn.dataset.value;
        await this.updateSuffix(descId, newSuffix);
        this.closePicker();
      });
    });

    // Close picker when clicking outside
    this._pickerCloseHandler = (e) => {
      if (!picker.contains(e.target) && e.target !== badge) {
        this.closePicker();
      }
    };
    document.addEventListener('click', this._pickerCloseHandler);

    // Store reference for cleanup
    this._activePicker = picker;
  }

  showPrefixPicker(badge, descId, currentPrefix) {
    // Close any existing pickers
    this.closePicker();

    const prefixes = [
      { key: 'none', label: '∅', title: 'None' },
      { key: 'pronoun_has', label: '(S)he has', title: 'Pronoun has/have' },
      { key: 'pronoun_is', label: '(S)he is', title: 'Pronoun is/are' },
      { key: 'and', label: 'and', title: 'And' }
    ];

    const picker = document.createElement('div');
    picker.className = 'prefix-picker';
    picker.innerHTML = prefixes.map(pre => `
      <button type="button"
              class="prefix-option ${pre.key === currentPrefix ? 'active' : ''}"
              data-value="${pre.key}"
              title="${pre.title}">
        ${pre.label}
      </button>
    `).join('');

    // Position picker below the badge
    const rect = badge.getBoundingClientRect();
    const containerRect = this.container.getBoundingClientRect();
    picker.style.position = 'absolute';
    picker.style.top = `${rect.bottom - containerRect.top + 4}px`;
    picker.style.left = `${rect.left - containerRect.left}px`;

    // Add to container
    this.container.style.position = 'relative';
    this.container.appendChild(picker);

    // Handle option clicks
    picker.querySelectorAll('.prefix-option').forEach(btn => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation();
        const newPrefix = btn.dataset.value;
        await this.updatePrefix(descId, newPrefix);
        this.closePicker();
      });
    });

    // Close picker when clicking outside
    this._pickerCloseHandler = (e) => {
      if (!picker.contains(e.target) && e.target !== badge) {
        this.closePicker();
      }
    };
    document.addEventListener('click', this._pickerCloseHandler);

    // Store reference for cleanup
    this._activePicker = picker;
  }

  closePicker() {
    if (this._activePicker) {
      this._activePicker.remove();
      this._activePicker = null;
    }
    if (this._pickerCloseHandler) {
      document.removeEventListener('click', this._pickerCloseHandler);
      this._pickerCloseHandler = null;
    }
  }

  showImageModal(imageUrl) {
    // Use shared lightbox from /js/lightbox.js
    if (typeof openLightbox === 'function') {
      openLightbox(imageUrl);
    }
  }

  async updateSuffix(descId, suffix) {
    try {
      const response = await fetch(`/characters/${this.characterId}/descriptions/${descId}`, {
        method: 'PUT',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': getCsrfToken()
        },
        body: JSON.stringify({ suffix })
      });

      const data = await response.json();
      if (data.success) {
        await this.loadDescriptions();
        this.render();
        this.bindEvents();
        if (this.options.onDescriptionChange) {
          this.options.onDescriptionChange(this.descriptions);
        }
      }
    } catch (error) {
      console.error('Failed to update suffix:', error);
    }
  }

  async updatePrefix(descId, prefix) {
    try {
      const response = await fetch(`/characters/${this.characterId}/descriptions/${descId}`, {
        method: 'PUT',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': getCsrfToken()
        },
        body: JSON.stringify({ prefix })
      });

      const data = await response.json();
      if (data.success) {
        await this.loadDescriptions();
        this.render();
        this.bindEvents();
        if (this.options.onDescriptionChange) {
          this.options.onDescriptionChange(this.descriptions);
        }
      }
    } catch (error) {
      console.error('Failed to update prefix:', error);
    }
  }

  getDescriptions() {
    return this.descriptions;
  }

  destroy() {
    // Clean up picker event listeners
    this.closePicker();

    // Remove drag-and-drop event listeners by clearing the list innerHTML
    const list = this.container.querySelector('#activeDescList');
    if (list) {
      list.innerHTML = '';
    }

    // Clear the container
    this.container.innerHTML = '';
  }

  getActiveDescriptions() {
    return this.descriptions.filter(d => d.active);
  }
}

// Export for use in other scripts
if (typeof window !== 'undefined') {
  window.DescriptionManager = DescriptionManager;
}
