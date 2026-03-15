/**
 * Property Panel - Right sidebar for editing selected item properties
 */
class PropertyPanel {
  constructor() {
    this.panel = document.getElementById('propertiesPanel');
    this.currentItem = null;
    this.currentType = null;
    this.uploadHandler = null;
  }

  showProperties(type, item) {
    this.currentType = type;
    this.currentItem = item;

    let html = '';

    switch (type) {
      case 'place':
        html = this.renderPlaceProperties(item);
        break;
      case 'subroom':
        html = this.renderSubroomProperties(item);
        break;
      case 'feature':
        html = this.renderFeatureProperties(item);
        break;
      case 'exit':
        html = this.renderExitProperties(item);
        break;
      case 'decoration':
        html = this.renderDecorationProperties(item);
        break;
    }

    this.panel.innerHTML = html;
    this.setupEventListeners();
  }

  clearProperties() {
    this.currentItem = null;
    this.currentType = null;
    this.panel.innerHTML = '<div class="text-base-content/60 text-sm">Select an item to edit its properties</div>';
  }

  renderPlaceProperties(place) {
    return `
      <div class="property-field">
        <label>Name</label>
        <input type="text" class="input input-bordered input-sm bg-base-300 w-full"
               id="propName" value="${escapeHtml(place.name)}">
      </div>
      <div class="property-field">
        <label>Description</label>
        <div id="propDescriptionEditor" class="description-editor-container" style="min-height: 60px;"
             data-initial="${this.escapeAttr(place.description || '')}"></div>
        <input type="hidden" id="propDescription" value="${this.escapeAttr(place.description || '')}">
      </div>
      <div class="grid grid-cols-2 gap-2">
        <div class="property-field">
          <label>X Position</label>
          <input type="number" class="input input-bordered input-sm bg-base-300 w-full"
                 id="propX" value="${place.x || 0}">
        </div>
        <div class="property-field">
          <label>Y Position</label>
          <input type="number" class="input input-bordered input-sm bg-base-300 w-full"
                 id="propY" value="${place.y || 0}">
        </div>
      </div>
      <div class="grid grid-cols-2 gap-2">
        <div class="property-field">
          <label>Width</label>
          <input type="number" class="input input-bordered input-sm bg-base-300 w-full"
                 id="propWidth" value="${place.width || 4}">
        </div>
        <div class="property-field">
          <label>Height</label>
          <input type="number" class="input input-bordered input-sm bg-base-300 w-full"
                 id="propHeight" value="${place.height || 4}">
        </div>
      </div>
      <div class="property-field">
        <label>Capacity</label>
        <input type="number" class="input input-bordered input-sm bg-base-300 w-full"
               id="propCapacity" value="${place.capacity || 1}" min="0">
      </div>
      <div class="property-field">
        <label>Icon</label>
        <div class="flex gap-2">
          <div class="input input-sm input-bordered bg-base-300 flex-1 flex items-center justify-center text-lg" id="propIconPreview">
            ${this.renderIconPreview(place.icon)}
          </div>
          <button class="btn btn-sm btn-outline" id="propIconPickerBtn">Choose</button>
        </div>
        <input type="hidden" id="propIcon" value="${escapeHtml(place.icon || '')}">
      </div>
      <div class="property-field">
        <label>Default Action</label>
        <div class="grid grid-cols-2 gap-2">
          <select class="select select-bordered select-sm bg-base-300 w-full" id="propAction">
            ${['sit','stand','lean','rest','kneel','lounge','perch'].map(a =>
              `<option value="${a}" ${(() => { const sa = place.default_sit_action || 'sit on'; const p = sa.split(' '); const act = p.length >= 2 ? p[0] : 'sit'; return act === a ? 'selected' : ''; })()}>${a}</option>`
            ).join('')}
          </select>
          <select class="select select-bordered select-sm bg-base-300 w-full" id="propPreposition">
            ${['on','at','near','around','against','in','beside','behind','before'].map(p =>
              `<option value="${p}" ${(() => { const sa = place.default_sit_action || 'sit on'; const parts = sa.split(' '); const prep = parts.length >= 2 ? parts.slice(1).join(' ') : (parts[0] || 'on'); return prep === p ? 'selected' : ''; })()}>${p}</option>`
            ).join('')}
          </select>
        </div>
        <small class="text-base-content/60">e.g., "sit on the chair", "stand at the bar"</small>
      </div>
      <button class="btn btn-primary btn-sm w-full mt-3" id="savePropertiesBtn">Save Changes</button>
    `;
  }

  renderSubroomProperties(subroom) {
    const isPolygon = subroom.room_polygon && subroom.room_polygon.length >= 3;
    const polygonMode = subroom.polygon_mode || 'simple';

    let shapeInfo = '';
    if (isPolygon) {
      const vertexCount = subroom.room_polygon.length;
      const vertices = subroom.room_polygon.map(p => {
        const x = p.x || p['x'] || 0;
        const y = p.y || p['y'] || 0;
        return `(${Math.round(x)}, ${Math.round(y)})`;
      }).join('\n');
      shapeInfo = `
        <div class="property-field">
          <label>Shape</label>
          <input type="text" class="input input-bordered input-sm bg-base-300 w-full"
                 value="Polygon (${vertexCount} vertices)" disabled>
        </div>
        <div class="property-field">
          <label>Vertices</label>
          <textarea class="textarea textarea-bordered textarea-sm bg-base-300 w-full"
                    rows="4" disabled>${vertices}</textarea>
        </div>
      `;
    } else {
      shapeInfo = `
        <div class="property-field">
          <label>Shape</label>
          <input type="text" class="input input-bordered input-sm bg-base-300 w-full"
                 value="Rectangle" disabled>
        </div>
        <div class="grid grid-cols-2 gap-2">
          <div class="property-field">
            <label>Min X</label>
            <input type="number" class="input input-bordered input-sm bg-base-300 w-full"
                   value="${subroom.min_x}" disabled>
          </div>
          <div class="property-field">
            <label>Max X</label>
            <input type="number" class="input input-bordered input-sm bg-base-300 w-full"
                   value="${subroom.max_x}" disabled>
          </div>
        </div>
        <div class="grid grid-cols-2 gap-2">
          <div class="property-field">
            <label>Min Y</label>
            <input type="number" class="input input-bordered input-sm bg-base-300 w-full"
                   value="${subroom.min_y}" disabled>
          </div>
          <div class="property-field">
            <label>Max Y</label>
            <input type="number" class="input input-bordered input-sm bg-base-300 w-full"
                   value="${subroom.max_y}" disabled>
          </div>
        </div>
      `;
    }

    return `
      <div class="property-field">
        <label>Name</label>
        <input type="text" class="input input-bordered input-sm bg-base-300 w-full"
               id="propName" value="${escapeHtml(subroom.name)}" disabled>
      </div>
      <div class="property-field">
        <label>Type</label>
        <input type="text" class="input input-bordered input-sm bg-base-300 w-full"
               value="${subroom.room_type}" disabled>
      </div>
      ${shapeInfo}
      <a href="/admin/room_builder/${subroom.id}" class="btn btn-outline btn-primary btn-sm w-full mt-3">
        <i class="bi bi-pencil mr-1"></i>Edit This Room
      </a>
    `;
  }

  renderFeatureProperties(feature) {
    const featureTypes = ['door', 'window', 'opening', 'archway', 'portal', 'gate', 'hatch', 'staircase', 'elevator'];
    const openStates = ['open', 'closed', 'locked', 'ajar', 'broken'];
    const transparencies = ['transparent', 'translucent', 'opaque'];
    const orientations = ['north', 'south', 'east', 'west', 'up', 'down'];
    const isDoor = ['door', 'gate', 'hatch', 'portal', 'opening', 'archway'].includes(feature.feature_type);

    return `
      <div class="property-field">
        <label>Name</label>
        <input type="text" class="input input-bordered input-sm bg-base-300 w-full"
               id="propName" value="${escapeHtml(feature.name)}">
      </div>
      <div class="property-field">
        <label>Type</label>
        <select class="select select-bordered select-sm bg-base-300 w-full" id="propFeatureType">
          ${featureTypes.map(t => `<option value="${t}" ${feature.feature_type === t ? 'selected' : ''}>${t}</option>`).join('')}
        </select>
      </div>
      <div class="property-field">
        <label>Orientation</label>
        <select class="select select-bordered select-sm bg-base-300 w-full" id="propOrientation">
          ${orientations.map(o => `<option value="${o}" ${feature.orientation === o ? 'selected' : ''}>${o}</option>`).join('')}
        </select>
      </div>
      <div class="property-field">
        <label>Width (ft)</label>
        <input type="number" class="input input-bordered input-sm bg-base-300 w-full"
               id="propWidth" value="${feature.width || (isDoor ? 4 : 3)}" min="1" max="20" step="0.5">
      </div>
      <div class="property-field">
        <label>State</label>
        <select class="select select-bordered select-sm bg-base-300 w-full" id="propOpenState">
          ${openStates.map(s => `<option value="${s}" ${feature.open_state === s ? 'selected' : ''}>${s}</option>`).join('')}
        </select>
      </div>
      <div class="property-field">
        <label>Transparency</label>
        <select class="select select-bordered select-sm bg-base-300 w-full" id="propTransparency">
          ${transparencies.map(t => `<option value="${t}" ${feature.transparency_state === t ? 'selected' : ''}>${t}</option>`).join('')}
        </select>
      </div>
      <div class="form-control mt-2">
        <label class="label cursor-pointer justify-start gap-2">
          <input type="checkbox" class="toggle toggle-sm" id="propAllowsMovement" ${feature.allows_movement ? 'checked' : ''}>
          <span class="label-text">Allows Movement</span>
        </label>
      </div>
      <div class="form-control mt-2">
        <label class="label cursor-pointer justify-start gap-2">
          <input type="checkbox" class="toggle toggle-sm" id="propAllowsSight" ${feature.allows_sight ? 'checked' : ''}>
          <span class="label-text">Allows Sight</span>
        </label>
      </div>
      <div class="form-control mt-2">
        <label class="label cursor-pointer justify-start gap-2">
          <input type="checkbox" class="toggle toggle-sm" id="propHasLock" ${feature.has_lock ? 'checked' : ''}>
          <span class="label-text">Has Lock</span>
        </label>
      </div>
      <div class="form-control mt-2">
        <label class="label cursor-pointer justify-start gap-2">
          <input type="checkbox" class="toggle toggle-sm" id="propHasCurtains" ${feature.has_curtains ? 'checked' : ''}
                 onchange="document.getElementById('propCurtainStateRow').style.display = this.checked ? 'block' : 'none'">
          <span class="label-text">Has Curtains</span>
        </label>
      </div>
      <div class="property-field mt-1" id="propCurtainStateRow" style="display: ${feature.has_curtains ? 'block' : 'none'}">
        <label>Curtain State</label>
        <select class="select select-bordered select-sm bg-base-300 w-full" id="propCurtainState">
          <option value="open" ${feature.curtain_state === 'open' ? 'selected' : ''}>Open</option>
          <option value="closed" ${feature.curtain_state === 'closed' ? 'selected' : ''}>Closed</option>
        </select>
      </div>
      <button class="btn btn-primary btn-sm w-full mt-3" id="savePropertiesBtn">Save Changes</button>
    `;
  }

  renderExitProperties(exit) {
    return `
      <div class="property-field">
        <label>Direction</label>
        <input type="text" class="input input-bordered input-sm bg-base-300 w-full"
               value="${escapeHtml(exit.direction || 'unknown')}" disabled>
      </div>
      <div class="property-field">
        <label>Type</label>
        <input type="text" class="input input-bordered input-sm bg-base-300 w-full"
               value="${escapeHtml(exit.exit_type || 'spatial')}" disabled>
      </div>
      <div class="property-field">
        <label>Destination</label>
        <input type="text" class="input input-bordered input-sm bg-base-300 w-full"
               value="${escapeHtml(exit.to_room_name || 'Unknown')}" disabled>
      </div>
      <div class="alert alert-info mt-3 py-2 px-3 text-xs">
        <i class="bi bi-info-circle"></i>
        Exits are computed from room geometry and features in this system.
      </div>
    `;
  }

  renderDecorationProperties(decoration) {
    return `
      <div class="property-field">
        <label>Name</label>
        <input type="text" class="input input-bordered input-sm bg-base-300 w-full"
               id="propName" value="${escapeHtml(decoration.name || '')}">
      </div>
      <div class="property-field">
        <label>Icon</label>
        <div class="flex gap-2">
          <div class="input input-sm input-bordered bg-base-300 flex-1 flex items-center justify-center text-lg" id="propIconPreview">
            ${this.renderIconPreview(decoration.icon)}
          </div>
          <button class="btn btn-sm btn-outline" id="propIconPickerBtn">Choose</button>
        </div>
        <input type="hidden" id="propIcon" value="${escapeHtml(decoration.icon || '')}">
      </div>
      <div class="property-field">
        <label>Description</label>
        <div id="propDescriptionEditor" class="description-editor-container" style="min-height: 60px;"
             data-initial="${this.escapeAttr(decoration.description || '')}"></div>
        <input type="hidden" id="propDescription" value="${this.escapeAttr(decoration.description || '')}">
      </div>
      <div class="property-field">
        <label>Image</label>
        <div class="flex gap-2 mb-1">
          <input type="file" id="propImageUpload" class="file-input file-input-sm file-input-bordered flex-1" accept="image/*">
          <button class="btn btn-sm btn-square btn-primary" id="propUploadImageBtn" title="Upload">
            <i class="bi bi-upload"></i>
          </button>
        </div>
        <input type="text" class="input input-bordered input-sm bg-base-300 w-full"
               id="propImageUrl" value="${escapeHtml(decoration.image_url || '')}" placeholder="Or paste URL...">
      </div>
      <div class="property-field">
        <label>Display Order</label>
        <input type="number" class="input input-bordered input-sm bg-base-300 w-full"
               id="propDisplayOrder" value="${decoration.display_order || 0}">
      </div>
      <button class="btn btn-primary btn-sm w-full mt-3" id="savePropertiesBtn">Save Changes</button>
    `;
  }

  setupEventListeners() {
    const saveBtn = document.getElementById('savePropertiesBtn');
    if (saveBtn) {
      saveBtn.addEventListener('click', () => this.saveProperties());
    }

    // Initialize DescriptionEditor for description fields
    const descContainer = document.getElementById('propDescriptionEditor');
    if (descContainer && typeof DescriptionEditor !== 'undefined') {
      const initialContent = descContainer.dataset.initial || '';
      this.descEditor = new DescriptionEditor('#propDescriptionEditor', {
        placeholder: 'Enter description...',
        maxLength: 2000,
        onChange: (html) => {
          const hidden = document.getElementById('propDescription');
          if (hidden) hidden.value = html;
        }
      });
      if (initialContent && this.descEditor.editorEl) {
        this.descEditor.editorEl.innerHTML = initialContent;
      }
    }

    // Remove old upload handler if present
    if (this.uploadHandler) {
      this.panel?.removeEventListener('click', this.uploadHandler);
    }
    // Add new upload handler on the panel element
    this.uploadHandler = (e) => {
      if (e.target.closest('#propUploadImageBtn')) {
        const fileInput = document.getElementById('propImageUpload');
        const file = fileInput?.files?.[0];
        if (!file) { alert('Select a file first.'); return; }
        const formData = new FormData();
        formData.append('image', file);
        const roomId = window.ROOM_ID;
        fetch(`/admin/room_builder/${roomId}/api/upload_image`, {
          method: 'POST', body: formData
        }).then(r => r.json()).then(data => {
          if (data.success && data.url) {
            document.getElementById('propImageUrl').value = data.url;
            if (fileInput) fileInput.value = '';
          } else {
            alert('Upload failed: ' + (data.error || 'Unknown'));
          }
        }).catch(e => alert('Upload error: ' + e.message));
      }
    };
    this.panel?.addEventListener('click', this.uploadHandler);

    // Icon picker button
    document.getElementById('propIconPickerBtn')?.addEventListener('click', () => {
      window.iconPicker?.show((icon) => {
        document.getElementById('propIcon').value = icon || '';
        const preview = document.getElementById('propIconPreview');
        if (preview) {
          preview.innerHTML = this.renderIconPreview(icon);
        }
      });
    });
  }

  async saveProperties() {
    if (!this.currentItem || !this.currentType) return;

    let data = {};

    switch (this.currentType) {
      case 'place':
        data = {
          name: document.getElementById('propName').value,
          description: document.getElementById('propDescription').value,
          x: parseInt(document.getElementById('propX').value),
          y: parseInt(document.getElementById('propY').value),
          capacity: parseInt(document.getElementById('propCapacity').value),
          default_sit_action: `${document.getElementById('propAction')?.value || 'sit'} ${document.getElementById('propPreposition')?.value || 'on'}`,
          icon: document.getElementById('propIcon')?.value?.trim() || null
        };
        break;

      case 'feature':
        data = {
          name: document.getElementById('propName').value,
          feature_type: document.getElementById('propFeatureType').value,
          orientation: document.getElementById('propOrientation').value,
          width: parseFloat(document.getElementById('propWidth')?.value) || 3,
          open_state: document.getElementById('propOpenState').value,
          transparency_state: document.getElementById('propTransparency').value,
          allows_movement: document.getElementById('propAllowsMovement').checked,
          allows_sight: document.getElementById('propAllowsSight').checked,
          has_lock: document.getElementById('propHasLock').checked,
          has_curtains: document.getElementById('propHasCurtains').checked,
          curtain_state: document.getElementById('propCurtainState')?.value || 'open'
        };
        break;

      case 'decoration':
        data = {
          name: document.getElementById('propName').value,
          description: document.getElementById('propDescription').value,
          image_url: document.getElementById('propImageUrl').value,
          display_order: parseInt(document.getElementById('propDisplayOrder').value) || 0,
          icon: document.getElementById('propIcon')?.value?.trim() || null
        };
        break;
    }

    try {
      let result;
      switch (this.currentType) {
        case 'place':
          result = await window.roomAPI.updatePlace(this.currentItem.id, data);
          Object.assign(this.currentItem, result.place);
          break;
        case 'feature':
          result = await window.roomAPI.updateFeature(this.currentItem.id, data);
          Object.assign(this.currentItem, result.feature);
          break;
        case 'decoration':
          result = await window.roomAPI.updateDecoration(this.currentItem.id, data);
          Object.assign(this.currentItem, result.decoration);
          break;
      }

      window.roomEditor?.render();
      window.roomEditor?.updateElementsList();
      alert('Properties saved!');
    } catch (error) {
      alert('Failed to save: ' + error.message);
    }
  }

  renderIconPreview(icon) {
    if (!icon) return '<span class="text-base-content/30 text-sm">None</span>';
    if (icon.startsWith('bi-')) return `<i class="bi ${icon}"></i>`;
    return escapeHtml(icon);
  }

  escapeAttr(str) {
    if (!str) return '';
    return str.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/'/g, '&#39;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }
}

// Initialize
document.addEventListener('DOMContentLoaded', () => {
  window.propertyPanel = new PropertyPanel();
});
