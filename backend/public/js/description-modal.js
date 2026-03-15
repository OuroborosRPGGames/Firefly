/**
 * Description Modal Component
 * Handles the modal for creating and editing descriptions
 * Supports multiple description types: natural, tattoo, makeup, hairstyle
 * Updated to use DaisyUI modal pattern (native dialog element)
 */
class DescriptionModal {
  constructor() {
    this.modal = null;
    this.editor = null;
    this.currentData = null;
    this.init();
  }

  init() {
    // Listen for modal open events
    document.addEventListener('openDescriptionModal', (e) => {
      this.open(e.detail);
    });

    // Create modal element if it doesn't exist
    if (!document.getElementById('descriptionModal')) {
      this.createModalElement();
    }

    this.modal = document.getElementById('descriptionModal');
  }

  createModalElement() {
    const modalHtml = `
      <dialog id="descriptionModal" class="modal">
        <div class="modal-box w-11/12 max-w-4xl bg-base-200">
          <form method="dialog">
            <button class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2">✕</button>
          </form>
          <h3 class="font-bold text-lg modal-title">Add Description</h3>

          <div class="modal-body py-4">
            <form id="descriptionForm">
              <input type="hidden" id="descriptionType" value="natural">

              <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mb-4" id="bodyPositionRow">
                <div class="md:col-span-2">
                  <label for="bodyPositionSelect" class="label">
                    <span class="label-text">Body Position</span>
                  </label>
                  <select class="select select-bordered w-full" id="bodyPositionSelect" required>
                    <option value="">Select a body position...</option>
                  </select>
                  <label class="label">
                    <span class="label-text-alt text-base-content/60" id="bodyPositionHelp"></span>
                  </label>
                  <div class="alert alert-info py-2 px-3 mt-2 text-sm" id="multiSelectHint" style="display: none;">
                    <i class="bi bi-info-circle mr-1"></i>
                    <span><strong>Tip:</strong> Hold <kbd class="kbd kbd-sm">Ctrl</kbd> (or <kbd class="kbd kbd-sm">Cmd</kbd> on Mac) to select multiple positions</span>
                  </div>
                </div>
                <div>
                  <label class="label">
                    <span class="label-text">Options</span>
                  </label>
                  <div class="form-control" id="concealedCheckContainer">
                    <label class="label cursor-pointer justify-start gap-2">
                      <input type="checkbox" class="checkbox checkbox-sm" id="concealedCheck">
                      <span class="label-text">Concealed by clothing</span>
                    </label>
                  </div>
                </div>
              </div>

              <div class="mb-4">
                <label class="label">
                  <span class="label-text">Description</span>
                </label>
                <div id="descEditorContainer"></div>
              </div>

              <div class="mb-4">
                <label class="label">
                  <span class="label-text">Image (optional)</span>
                </label>
                <div class="desc-image-upload">
                  <input type="file" id="descImageInput" accept="image/*" class="file-input file-input-bordered w-full">
                  <div id="descImagePreview" class="desc-image-preview mt-2 flex items-start gap-2" style="display: none;">
                    <img src="" alt="Preview" class="rounded-lg max-h-48 object-cover">
                    <button type="button" class="btn btn-outline btn-error btn-sm remove-image">
                      <i class="bi bi-trash"></i> Remove
                    </button>
                  </div>
                </div>
              </div>

              <div class="mb-4" id="displayOrderRow" style="display: none;">
                <label for="displayOrder" class="label">
                  <span class="label-text">Display Order</span>
                </label>
                <input type="number" class="input input-bordered w-full" id="displayOrder" value="0" min="0">
                <label class="label">
                  <span class="label-text-alt text-base-content/60">Lower numbers appear first</span>
                </label>
              </div>

              <div class="mb-4" id="prefixRow">
                <label for="prefixSelect" class="label">
                  <span class="label-text">Prefix</span>
                </label>
                <select class="select select-bordered w-full" id="prefixSelect">
                  <option value="none">None</option>
                  <option value="pronoun_has">(Pronoun) has/have</option>
                  <option value="pronoun_is">(Pronoun) is/are</option>
                  <option value="and">and</option>
                </select>
                <label class="label">
                  <span class="label-text-alt text-base-content/60">What appears before this description</span>
                </label>
              </div>

              <div class="mb-4" id="suffixRow">
                <label for="suffixSelect" class="label">
                  <span class="label-text">Suffix</span>
                </label>
                <select class="select select-bordered w-full" id="suffixSelect">
                  <option value="period">Period and space (. )</option>
                  <option value="comma">Comma and space (, )</option>
                  <option value="space">Space only</option>
                  <option value="newline">New line (. + line break)</option>
                  <option value="double_newline">Double new line (. + paragraph)</option>
                </select>
                <label class="label">
                  <span class="label-text-alt text-base-content/60">What appears after this description</span>
                </label>
              </div>
            </form>
          </div>

          <div class="modal-action">
            <button type="button" class="btn btn-ghost" id="cancelDescBtn">Cancel</button>
            <button type="button" class="btn btn-primary" id="saveDescBtn">Save Description</button>
          </div>
        </div>
        <form method="dialog" class="modal-backdrop">
          <button>close</button>
        </form>
      </dialog>
    `;

    document.body.insertAdjacentHTML('beforeend', modalHtml);
  }

  open(data) {
    this.currentData = data;

    const descType = data.descriptionType || 'natural';
    document.getElementById('descriptionType').value = descType;

    // Set modal title based on type
    const modalTitle = document.querySelector('#descriptionModal .modal-title');
    modalTitle.textContent = this.getTitleForType(descType, data.mode === 'edit');

    // Configure UI based on description type
    this.configureForType(descType, data);

    // Populate body position dropdown/select
    this.populateBodyPositions(data.bodyPositions, data.preselectedRegion, descType, data.allowMultiple);

    // Initialize editor
    const editorContainer = document.getElementById('descEditorContainer');
    editorContainer.innerHTML = '';
    this.editor = new DescriptionEditor(editorContainer);

    // If editing, populate fields
    if (data.mode === 'edit' && data.description) {
      this.populateEditFields(data.description, data.allowMultiple);
    } else {
      this.resetFields(data.allowMultiple);
    }

    // Bind event handlers
    this.bindEventHandlers();

    // Show modal using native dialog API
    this.modal.showModal();
  }

  close() {
    this.modal.close();
  }

  getTitleForType(descType, isEdit) {
    const action = isEdit ? 'Edit' : 'Add';
    switch (descType) {
      case 'tattoo':
        return `${action} Tattoo`;
      case 'makeup':
        return `${action} Makeup`;
      case 'hairstyle':
        return `${action} Hairstyle`;
      default:
        return `${action} Description`;
    }
  }

  configureForType(descType, data) {
    const bodyPositionRow = document.getElementById('bodyPositionRow');
    const concealedContainer = document.getElementById('concealedCheckContainer');
    const displayOrderRow = document.getElementById('displayOrderRow');
    const bodyPositionHelp = document.getElementById('bodyPositionHelp');

    // Show/hide elements based on type
    switch (descType) {
      case 'hairstyle':
        // Hide body position selector for hairstyle (always scalp)
        bodyPositionRow.style.display = 'none';
        concealedContainer.style.display = 'none';
        displayOrderRow.style.display = 'block';
        break;

      case 'makeup':
        bodyPositionRow.style.display = 'grid';
        concealedContainer.style.display = 'none';
        displayOrderRow.style.display = 'block';
        bodyPositionHelp.textContent = 'Select one or more face areas for the makeup';
        break;

      case 'tattoo':
        bodyPositionRow.style.display = 'grid';
        concealedContainer.style.display = 'block';
        displayOrderRow.style.display = 'block';
        bodyPositionHelp.textContent = 'Select one or more body positions for the tattoo';
        break;

      default:
        bodyPositionRow.style.display = 'grid';
        concealedContainer.style.display = 'block';
        displayOrderRow.style.display = 'none';
        bodyPositionHelp.textContent = '';
    }
  }

  populateBodyPositions(positions, preselectedRegion = null, descType = 'natural', allowMultiple = false) {
    const select = document.getElementById('bodyPositionSelect');
    const multiSelectHint = document.getElementById('multiSelectHint');

    // Convert to multi-select if needed
    if (allowMultiple) {
      select.setAttribute('multiple', 'multiple');
      select.size = 10;
      select.classList.add('h-48');
      // Show the multi-select hint
      if (multiSelectHint) {
        multiSelectHint.style.display = 'flex';
      }
    } else {
      select.removeAttribute('multiple');
      select.removeAttribute('size');
      select.classList.remove('h-48');
      // Hide the multi-select hint
      if (multiSelectHint) {
        multiSelectHint.style.display = 'none';
      }
    }

    select.innerHTML = allowMultiple ? '' : '<option value="">Select a body position...</option>';

    // Filter positions based on description type
    const filteredPositions = this.filterPositionsForType(positions, descType);

    const regions = ['head', 'torso', 'arms', 'hands', 'legs', 'feet'];

    regions.forEach(region => {
      if (filteredPositions[region] && filteredPositions[region].length > 0) {
        const optgroup = document.createElement('optgroup');
        optgroup.label = region.charAt(0).toUpperCase() + region.slice(1);

        filteredPositions[region].forEach(pos => {
          const option = document.createElement('option');
          option.value = pos.id;
          option.textContent = pos.display_label;
          if (pos.is_private) {
            option.textContent += ' (private)';
          }
          optgroup.appendChild(option);
        });

        select.appendChild(optgroup);
      }
    });

    // If preselected region, try to select first position in that region
    if (preselectedRegion && filteredPositions[preselectedRegion] && filteredPositions[preselectedRegion].length > 0) {
      select.value = filteredPositions[preselectedRegion][0].id;
    }

    // For hairstyle, auto-select scalp if available
    if (descType === 'hairstyle') {
      const scalpOption = select.querySelector('option[value]');
      if (scalpOption) {
        scalpOption.selected = true;
      }
    }
  }

  filterPositionsForType(positions, descType) {
    if (!positions) return {};

    // Face positions for makeup
    const faceLabels = ['forehead', 'eyes', 'nose', 'cheeks', 'chin', 'mouth'];
    // Scalp for hairstyle
    const scalpLabels = ['scalp'];

    switch (descType) {
      case 'makeup':
        return this.filterPositionsByLabels(positions, faceLabels);

      case 'hairstyle':
        return this.filterPositionsByLabels(positions, scalpLabels);

      case 'tattoo':
      default:
        // All positions available for tattoos and natural descriptions
        return positions;
    }
  }

  filterPositionsByLabels(positions, allowedLabels) {
    const filtered = {};

    Object.keys(positions).forEach(region => {
      const regionPositions = positions[region].filter(pos =>
        allowedLabels.includes(pos.label || pos.display_label?.toLowerCase())
      );
      if (regionPositions.length > 0) {
        filtered[region] = regionPositions;
      }
    });

    return filtered;
  }

  populateEditFields(description, allowMultiple) {
    const select = document.getElementById('bodyPositionSelect');

    if (allowMultiple && description.body_position_ids) {
      // Multi-select: select all positions
      description.body_position_ids.forEach(id => {
        const option = select.querySelector(`option[value="${id}"]`);
        if (option) option.selected = true;
      });
    } else if (description.body_position_id) {
      select.value = description.body_position_id;
    }

    // Can't change positions on edit for single-select
    if (!allowMultiple) {
      select.disabled = true;
    }

    document.getElementById('concealedCheck').checked = description.concealed_by_clothing || false;
    document.getElementById('displayOrder').value = description.display_order || 0;
    document.getElementById('prefixSelect').value = description.prefix || 'none';
    document.getElementById('suffixSelect').value = description.suffix || 'period';

    this.editor.setContent(description.content);

    if (description.image_url) {
      this.showImagePreview(description.image_url);
    }
  }

  resetFields(allowMultiple) {
    const select = document.getElementById('bodyPositionSelect');
    select.disabled = false;

    if (allowMultiple) {
      // Deselect all options
      Array.from(select.options).forEach(opt => opt.selected = false);
    } else {
      select.value = '';
    }

    document.getElementById('concealedCheck').checked = true;
    document.getElementById('displayOrder').value = 0;
    document.getElementById('prefixSelect').value = 'none';
    document.getElementById('suffixSelect').value = 'period';
    this.hideImagePreview();
  }

  bindEventHandlers() {
    // Bind save button
    const saveBtn = document.getElementById('saveDescBtn');
    saveBtn.onclick = () => this.save();

    // Bind cancel button
    const cancelBtn = document.getElementById('cancelDescBtn');
    cancelBtn.onclick = () => this.close();

    // Bind image input
    const imageInput = document.getElementById('descImageInput');
    imageInput.onchange = (e) => this.handleImageSelect(e);

    // Bind remove image button
    const removeBtn = document.querySelector('#descImagePreview .remove-image');
    if (removeBtn) {
      removeBtn.onclick = () => this.hideImagePreview();
    }
  }

  handleImageSelect(e) {
    const file = e.target.files[0];
    if (!file) return;

    if (!file.type.startsWith('image/')) {
      alert('Please select an image file');
      return;
    }

    const reader = new FileReader();
    reader.onload = (e) => {
      this.showImagePreview(e.target.result);
    };
    reader.readAsDataURL(file);
  }

  showImagePreview(src) {
    const preview = document.getElementById('descImagePreview');
    const img = preview.querySelector('img');
    img.src = src;
    preview.style.display = 'flex';
  }

  hideImagePreview() {
    const preview = document.getElementById('descImagePreview');
    preview.style.display = 'none';
    document.getElementById('descImageInput').value = '';
  }

  getSelectedPositions() {
    const select = document.getElementById('bodyPositionSelect');
    const allowMultiple = select.hasAttribute('multiple');

    if (allowMultiple) {
      return Array.from(select.selectedOptions).map(opt => parseInt(opt.value));
    } else {
      return select.value ? [parseInt(select.value)] : [];
    }
  }

  async save() {
    const descType = document.getElementById('descriptionType').value;
    const bodyPositionIds = this.getSelectedPositions();
    const concealed = document.getElementById('concealedCheck').checked;
    const displayOrder = parseInt(document.getElementById('displayOrder').value) || 0;
    const prefix = document.getElementById('prefixSelect').value;
    const suffix = document.getElementById('suffixSelect').value;
    const content = this.editor.getContent();
    const imageInput = document.getElementById('descImageInput');

    // Validate body position (except for hairstyle which auto-selects scalp)
    if (bodyPositionIds.length === 0 && descType !== 'hairstyle') {
      alert('Please select at least one body position');
      return;
    }

    if (!this.editor.isValid()) {
      alert('Please enter a valid description');
      return;
    }

    const csrfToken = getCsrfToken();

    try {
      let response;
      const payload = {
        content,
        concealed_by_clothing: concealed,
        display_order: displayOrder,
        prefix: prefix,
        suffix: suffix,
        description_type: descType
      };

      // Include body position(s)
      if (this.currentData.allowMultiple) {
        payload.body_position_ids = bodyPositionIds;
      } else {
        payload.body_position_id = bodyPositionIds[0];
      }

      if (this.currentData.mode === 'edit') {
        // Update existing description
        response = await fetch(
          `/characters/${this.currentData.characterId}/descriptions/${this.currentData.description.id}`,
          {
            method: 'PUT',
            headers: {
              'Content-Type': 'application/json',
              'X-CSRF-Token': csrfToken
            },
            body: JSON.stringify(payload)
          }
        );
      } else {
        // Create new description
        response = await fetch(`/characters/${this.currentData.characterId}/descriptions`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'X-CSRF-Token': csrfToken
          },
          body: JSON.stringify(payload)
        });
      }

      if (!response.ok) {
        const errorText = await response.text().catch(() => 'Unknown error');
        throw new Error(`Failed to save description: ${response.status} ${errorText}`);
      }

      const data = await response.json();

      if (!data.success) {
        alert(data.error || 'Failed to save description');
        return;
      }

      // Handle image upload if there's a new file
      if (imageInput.files.length > 0) {
        const descId = data.description.id;
        await this.uploadImage(descId, imageInput.files[0]);
      }

      this.close();

      if (this.currentData.onSave) {
        this.currentData.onSave();
      }
    } catch (error) {
      console.error('Failed to save description:', error);
      alert('Failed to save description');
    }
  }

  async uploadImage(descId, file) {
    const formData = new FormData();
    formData.append('image', file);

    try {
      const response = await fetch(
        `/characters/${this.currentData.characterId}/descriptions/${descId}/upload-image`,
        {
          method: 'POST',
          headers: {
            'X-CSRF-Token': getCsrfToken()
          },
          body: formData
        }
      );

      if (!response.ok) {
        console.error('Image upload failed: HTTP', response.status);
        return;
      }

      const data = await response.json();
      if (!data.success) {
        console.error('Image upload failed:', data.error);
      }
    } catch (error) {
      console.error('Image upload error:', error);
    }
  }

}

// Initialize modal handler when DOM is ready
document.addEventListener('DOMContentLoaded', () => {
  new DescriptionModal();
});

// Export for use in other scripts
if (typeof window !== 'undefined') {
  window.DescriptionModal = DescriptionModal;
}
