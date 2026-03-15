/**
 * Draft Character Preview Manager
 * Creates a draft character on page load and syncs field changes via API
 * to provide live preview using the actual game display service
 */
class DraftCharacterPreviewManager {
  constructor() {
    this.draftId = null;
    this.updateTimer = null;
    this.previewContainer = document.getElementById('liveAppearancePreview');
    this.pendingUpdates = {};
    this.isUpdating = false;

    // All fields that should be synced to the draft
    this.fieldMappings = {
      // Basic info
      'forename': 'forename',
      'surname': 'surname',
      'nickname': 'nickname',
      'birthdate': 'birthdate',
      'gender': 'gender',
      'point_of_view': 'point_of_view',
      'recruited_by': 'recruited_by',
      'discord_name': 'discord_name',
      'discord_number': 'discord_number',

      // Appearance
      'short_desc': 'short_desc',
      'distinctive_color': 'distinctive_color',
      'picture_url': 'picture_url',
      'height_ft': 'height_ft',
      'height_in': 'height_in',
      'height_cm': 'height_cm',
      'ethnicity': 'ethnicity',
      'custom_ethnicity': 'custom_ethnicity',
      'body_type': 'body_type',
      'eye_color': 'eye_color',
      'custom_eye_color': 'custom_eye_color',
      'hair_color': 'hair_color',
      'custom_hair_color': 'custom_hair_color',
      'hair_style': 'hair_style',
      'custom_hair_style': 'custom_hair_style',
      'beard_color': 'beard_color',
      'custom_beard_color': 'custom_beard_color',
      'beard_style': 'beard_style',
      'custom_beard_style': 'custom_beard_style',

      // Background
      'personality': 'personality',
      'backstory': 'backstory',
      'goals': 'goals',

      // Voice
      'voice_type': 'voice_type',
      'voice_speed': 'voice_speed',
      'voice_pitch': 'voice_pitch'
    };

    // Store local picture data URL for file uploads (not sent to server)
    this.localPictureDataUrl = null;

    this.init();
  }

  async init() {
    await this.createDraft();
    this.setupFieldListeners();
    this.setupFileInputListener();
  }

  async createDraft() {
    try {
      const response = await fetch('/characters/draft', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' }
      });

      const data = await response.json();
      if (data.success) {
        this.draftId = data.draft_id;
        console.log('[DraftPreview] Created draft character:', this.draftId);
      } else {
        console.error('[DraftPreview] Failed to create draft:', data.error);
      }
    } catch (err) {
      console.error('[DraftPreview] Error creating draft:', err);
    }
  }

  setupFieldListeners() {
    // Attach listeners to all mapped fields
    for (const fieldId in this.fieldMappings) {
      const element = document.getElementById(fieldId);
      if (element) {
        element.addEventListener('input', () => this.queueUpdate(fieldId));
        element.addEventListener('change', () => this.queueUpdate(fieldId));
      }
    }
  }

  setupFileInputListener() {
    // Handle character_picture file input for local preview
    const fileInput = document.getElementById('character_picture');
    if (fileInput) {
      fileInput.addEventListener('change', (e) => {
        const file = e.target.files[0];
        if (file) {
          const reader = new FileReader();
          reader.onload = (event) => {
            this.localPictureDataUrl = event.target.result;
            this.updateLocalPicturePreview();
          };
          reader.readAsDataURL(file);
        } else {
          this.localPictureDataUrl = null;
          this.updateLocalPicturePreview();
        }
      });
    }
  }

  updateLocalPicturePreview() {
    // Find or create the picture preview element within the preview container
    if (!this.previewContainer) return;

    let pictureEl = this.previewContainer.querySelector('.portrait-container');

    if (this.localPictureDataUrl) {
      // Add or update picture preview - float left to match in-game display
      if (!pictureEl) {
        pictureEl = document.createElement('div');
        pictureEl.className = 'portrait-container';
        this.previewContainer.insertBefore(pictureEl, this.previewContainer.firstChild);
      }
      pictureEl.innerHTML = `<img src="${this.localPictureDataUrl}" alt="Character preview" class="preview-profile-pic rounded-lg">`;
    } else if (pictureEl) {
      // Remove picture preview if no picture
      pictureEl.remove();
    }
  }

  queueUpdate(fieldId) {
    if (!this.draftId) {
      console.warn('[DraftPreview] No draft ID yet, skipping update');
      return;
    }

    const element = document.getElementById(fieldId);
    if (!element) return;

    const apiField = this.fieldMappings[fieldId];
    this.pendingUpdates[apiField] = element.value;

    // Debounce updates - wait 300ms after last change before sending
    clearTimeout(this.updateTimer);
    this.updateTimer = setTimeout(() => this.sendUpdates(), 300);
  }

  async sendUpdates() {
    if (this.isUpdating || Object.keys(this.pendingUpdates).length === 0) {
      return;
    }

    this.isUpdating = true;
    const updates = { ...this.pendingUpdates };
    this.pendingUpdates = {};

    try {
      const response = await fetch(`/characters/draft/${this.draftId}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(updates)
      });

      const data = await response.json();
      if (data.success) {
        // Fetch updated preview
        await this.refreshPreview();
      } else {
        console.error('[DraftPreview] Failed to update draft:', data.error);
      }
    } catch (err) {
      console.error('[DraftPreview] Error updating draft:', err);
    } finally {
      this.isUpdating = false;

      // If more updates queued while we were updating, send them
      if (Object.keys(this.pendingUpdates).length > 0) {
        this.sendUpdates();
      }
    }
  }

  async refreshPreview() {
    if (!this.draftId || !this.previewContainer) return;

    try {
      const response = await fetch(`/characters/draft/${this.draftId}/preview`);
      const data = await response.json();

      if (data.success && data.html) {
        this.previewContainer.innerHTML = data.html;
        // Re-apply local picture preview (file uploads are client-side only)
        this.updateLocalPicturePreview();
        // Bind click handlers for clickable thumbnails
        this.bindThumbnailClicks();
      }
    } catch (err) {
      console.error('[DraftPreview] Error fetching preview:', err);
    }
  }

  bindThumbnailClicks() {
    if (!this.previewContainer) return;

    // Add click handlers for all clickable thumbnails in the preview
    this.previewContainer.querySelectorAll('[data-full-url]').forEach(img => {
      img.addEventListener('click', (e) => {
        e.stopPropagation();
        this.showImageModal(img.dataset.fullUrl);
      });
    });
  }

  showImageModal(imageUrl) {
    // Use shared lightbox from /js/lightbox.js
    if (typeof openLightbox === 'function') {
      openLightbox(imageUrl);
    }
  }

  // Get the draft ID for form submission (optional - can finalize via API or just use draft_id)
  getDraftId() {
    return this.draftId;
  }
}

// Export for module systems
if (typeof module !== 'undefined' && module.exports) {
  module.exports = DraftCharacterPreviewManager;
}
