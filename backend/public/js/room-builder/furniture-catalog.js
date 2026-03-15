/**
 * Furniture Catalog - Modal for selecting furniture from predefined catalog
 */
class FurnitureCatalog {
  constructor() {
    this.modal = document.getElementById('furnitureCatalogModal');
    this.catalog = {};
    this.selectedItem = null;

    if (this.modal) {
      this.loadCatalog();
      this.setupEventListeners();
    }
  }

  async loadCatalog() {
    try {
      const result = await window.roomAPI.getFurnitureCatalog();
      if (result.success) {
        this.catalog = result.catalog;
        this.renderCatalogGrid();
      }
    } catch (error) {
      console.error('Failed to load furniture catalog:', error);
    }
  }

  renderCatalogGrid() {
    const contentContainer = document.getElementById('catalogContent');
    if (!contentContainer) return;

    let html = '';

    for (const [category, items] of Object.entries(this.catalog)) {
      const categoryName = category.charAt(0).toUpperCase() + category.slice(1);
      html += `<div class="mb-3">
        <div class="text-xs uppercase text-base-content/50 mb-1 font-semibold">${categoryName}</div>
        <div class="grid grid-cols-2 gap-1">
          ${items.map(item => this.renderPresetItem(item)).join('')}
        </div>
      </div>`;
    }

    contentContainer.innerHTML = html;

    contentContainer.querySelectorAll('.preset-item').forEach(el => {
      el.addEventListener('click', () => this.fillFormFromPreset(el));
    });
  }

  renderPresetItem(item) {
    const icon = item.icon ? escapeHtml(item.icon) : '';
    return `
      <button class="preset-item btn btn-ghost btn-xs justify-start text-left h-auto py-1"
              data-item='${JSON.stringify(item).replace(/'/g, "&#39;")}'>
        ${icon ? `<span class="text-base mr-1">${icon}</span>` : ''}
        <span class="truncate">${escapeHtml(item.name)}</span>
      </button>
    `;
  }

  fillFormFromPreset(el) {
    try {
      const item = JSON.parse(el.dataset.item);
      const nameField = document.getElementById('customFurnitureName');
      const iconField = document.getElementById('customFurnitureIcon');
      const capacityField = document.getElementById('customFurnitureCapacity');
      const widthField = document.getElementById('customFurnitureWidth');
      const heightField = document.getElementById('customFurnitureHeight');
      const descField = document.getElementById('customFurnitureDescription');
      const prepField = document.getElementById('customFurniturePreposition');

      if (nameField) nameField.value = item.name || '';
      if (iconField) iconField.value = item.icon || '';
      this.updateIconPreview(item.icon || null);
      if (capacityField) capacityField.value = item.capacity || 1;
      if (widthField) widthField.value = item.width || 4;
      if (heightField) heightField.value = item.height || 4;
      if (descField) descField.value = item.description || '';
      if (item.default_sit_action) {
        const parts = item.default_sit_action.split(' ');
        const actionField = document.getElementById('customFurnitureAction');
        if (parts.length >= 2 && actionField) {
          actionField.value = parts[0];
          if (prepField) prepField.value = parts.slice(1).join(' ');
        } else if (prepField) {
          prepField.value = item.default_sit_action;
        }
      }

      // Focus the name field as visual feedback
      nameField?.focus();
    } catch (e) {
      console.error('Failed to fill from preset:', e);
    }
  }

  setupEventListeners() {
    document.getElementById('addCustomFurniture')?.addEventListener('click', () => {
      const name = document.getElementById('customFurnitureName').value.trim();
      if (!name) {
        alert('Please enter a name for the furniture');
        return;
      }

      this.selectedItem = {
        id: 'custom',
        name: name,
        capacity: parseInt(document.getElementById('customFurnitureCapacity').value) || 1,
        width: parseInt(document.getElementById('customFurnitureWidth').value) || 4,
        height: parseInt(document.getElementById('customFurnitureHeight').value) || 4,
        description: document.getElementById('customFurnitureDescription').value.trim() || 'Custom furniture',
        icon: document.getElementById('customFurnitureIcon')?.value?.trim() || null,
        default_sit_action: `${document.getElementById('customFurnitureAction')?.value || 'sit'} ${document.getElementById('customFurniturePreposition')?.value || 'on'}`
      };

      this.modal.close();
      // Clear the form
      document.getElementById('customFurnitureName').value = '';
      document.getElementById('customFurnitureIcon').value = '';
      this.updateIconPreview(null);
      document.getElementById('customFurnitureCapacity').value = '1';
      document.getElementById('customFurnitureDescription').value = '';
      document.getElementById('customFurnitureWidth').value = '4';
      document.getElementById('customFurnitureHeight').value = '4';
      const actionField = document.getElementById('customFurnitureAction');
      if (actionField) actionField.value = 'sit';
      const prepField = document.getElementById('customFurniturePreposition');
      if (prepField) prepField.value = 'on';
    });

    // Icon picker button for catalog form
    document.getElementById('customFurnitureIconPickerBtn')?.addEventListener('click', () => {
      window.iconPicker?.show((icon) => {
        document.getElementById('customFurnitureIcon').value = icon || '';
        this.updateIconPreview(icon);
      });
    });
  }

  updateIconPreview(icon) {
    const preview = document.getElementById('customFurnitureIconPreview');
    if (!preview) return;
    if (!icon) {
      preview.innerHTML = '<span class="text-base-content/30 text-sm">None</span>';
    } else if (icon.startsWith('bi-')) {
      preview.innerHTML = `<i class="bi ${icon}"></i>`;
    } else {
      preview.innerHTML = escapeHtml(icon);
    }
  }

  show() {
    if (this.modal) {
      this.modal.showModal();
    }
  }

}

// Initialize
document.addEventListener('DOMContentLoaded', () => {
  // Wait for API client
  setTimeout(() => {
    window.furnitureCatalog = new FurnitureCatalog();
  }, 200);
});
