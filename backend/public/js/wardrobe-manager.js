/**
 * WardrobeManager - Handles wardrobe GUI functionality
 *
 * Features:
 * - Vault access checking and UI state
 * - Item fetch/fetch-wear operations
 * - Pattern creation with half-cost
 * - Tooltip display on hover
 * - Toast notifications
 * - Trash confirmation dialog
 */
class WardrobeManager {
  constructor(container, characterId, options = {}) {
    this.container = container;
    this.characterId = characterId;
    this.options = {
      popout: false,
      ...options
    };

    this.vaultAccessible = false;
    this.currentRoomOnly = false;
    this.currentRoomId = null;
    this.tooltipEl = null;
    this.tooltipTimeout = null;

    this.init();
  }

  async init() {
    await this.checkVaultAccess();
    this.updateVaultWarning();
    this.initTooltip();
  }

  /**
   * Check if character has vault access in current room
   */
  async checkVaultAccess() {
    try {
      const response = await fetch('/api/wardrobe');
      const data = await response.json();

      if (data.success) {
        this.vaultAccessible = data.vault_accessible;
        this.currentRoomId = data.current_room_id;
      }
    } catch (err) {
      console.error('Error checking vault access:', err);
      this.vaultAccessible = false;
    }
  }

  /**
   * Update vault warning visibility and button states
   */
  updateVaultWarning() {
    const warning = document.getElementById('vaultWarning');
    if (warning) {
      warning.classList.toggle('hidden', this.vaultAccessible);
    }

    // Disable all wardrobe action buttons if no vault access
    this.container.querySelectorAll('.wardrobe-action').forEach(btn => {
      btn.disabled = !this.vaultAccessible;
      if (!this.vaultAccessible) {
        btn.title = 'No vault access - must be in vault room';
      }
    });
  }

  /**
   * Initialize tooltip element
   */
  initTooltip() {
    this.tooltipEl = document.getElementById('itemTooltip');
    if (!this.tooltipEl) {
      // Create tooltip if not in DOM
      this.tooltipEl = document.createElement('div');
      this.tooltipEl.id = 'itemTooltip';
      this.tooltipEl.className = 'wardrobe-tooltip hidden';
      this.tooltipEl.innerHTML = `
        <div class="tooltip-image"></div>
        <div class="tooltip-content">
          <h6 class="tooltip-title"></h6>
          <p class="tooltip-description"></p>
        </div>
      `;
      document.body.appendChild(this.tooltipEl);
    }
  }

  /**
   * Check if a string looks like a URL
   */
  isUrlLike(text) {
    if (!text) return false;
    return /^https?:\/\//i.test(text) || /\.(png|jpg|jpeg|gif|webp|svg)$/i.test(text);
  }

  /**
   * Show tooltip for an item
   */
  async showTooltip(itemId, event) {
    if (this.tooltipTimeout) {
      clearTimeout(this.tooltipTimeout);
    }

    // Delay to prevent flicker
    this.tooltipTimeout = setTimeout(async () => {
      try {
        const response = await fetch(`/api/wardrobe/items/${itemId}`);
        const data = await response.json();

        if (!data.success || !data.item) return;

        const item = data.item;
        const imageEl = this.tooltipEl.querySelector('.tooltip-image');
        const titleEl = this.tooltipEl.querySelector('.tooltip-title');
        const descEl = this.tooltipEl.querySelector('.tooltip-description');

        // Set content
        titleEl.textContent = item.name;

        // Filter out URL-like descriptions
        const desc = item.long_description || item.description || '';
        descEl.textContent = this.isUrlLike(desc) ? '' : desc;

        // Set image with proper sizing
        if (item.image_url) {
          const img = document.createElement('img');
          img.src = item.image_url;
          img.alt = item.name || '';
          imageEl.textContent = '';
          imageEl.appendChild(img);
          imageEl.style.display = 'block';
        } else {
          imageEl.style.display = 'none';
        }

        // Position tooltip
        const rect = event.target.closest('.wardrobe-card, .item-card, .pattern-card').getBoundingClientRect();
        const tooltipWidth = 280;

        let left = rect.right + 10;
        if (left + tooltipWidth > window.innerWidth) {
          left = rect.left - tooltipWidth - 10;
        }

        let top = rect.top;
        if (top + 200 > window.innerHeight) {
          top = window.innerHeight - 210;
        }

        this.tooltipEl.style.left = `${left}px`;
        this.tooltipEl.style.top = `${top}px`;
        this.tooltipEl.classList.remove('hidden');

      } catch (err) {
        console.error('Error loading item for tooltip:', err);
      }
    }, 200);
  }

  /**
   * Hide tooltip
   */
  hideTooltip() {
    if (this.tooltipTimeout) {
      clearTimeout(this.tooltipTimeout);
      this.tooltipTimeout = null;
    }

    if (this.tooltipEl) {
      this.tooltipEl.classList.add('hidden');
    }
  }

  /**
   * Show trash confirmation dialog
   */
  confirmTrash(itemId, itemName, onSuccess) {
    const modal = document.getElementById('trashConfirmModal');
    const nameEl = document.getElementById('trashItemName');
    const confirmBtn = document.getElementById('trashConfirmBtn');

    if (!modal || !confirmBtn) return;

    nameEl.textContent = itemName || 'this item';

    // Remove old listener by cloning
    const newBtn = confirmBtn.cloneNode(true);
    confirmBtn.parentNode.replaceChild(newBtn, confirmBtn);
    newBtn.id = 'trashConfirmBtn';

    newBtn.addEventListener('click', async () => {
      modal.close();
      try {
        const response = await fetch(`/api/wardrobe/items/${itemId}/trash`, {
          method: 'POST',
          headers: { 'X-CSRF-Token': getCsrfToken() }
        });
        const result = await response.json();

        if (result.success) {
          this.showToast(result.message || 'Item destroyed.', 'success');
          if (onSuccess) onSuccess();
        } else {
          this.showToast(result.error || 'Failed to destroy item', 'danger');
        }
      } catch (err) {
        console.error('Error trashing item:', err);
        this.showToast('Error destroying item', 'danger');
      }
    });

    modal.showModal();
  }

  /**
   * Show copy confirmation dialog
   */
  confirmCopy(patternId, onSuccess) {
    const existing = document.getElementById('copyConfirmModal');
    if (existing) existing.remove();

    const modal = document.createElement('dialog');
    modal.id = 'copyConfirmModal';
    modal.className = 'modal';
    modal.innerHTML = `
      <div class="modal-box bg-base-200">
        <h3 class="font-bold text-lg"><i class="bi bi-plus-circle mr-2"></i>Create Copy</h3>
        <p class="py-4">Create another copy of this item?</p>
        <p class="text-sm text-base-content/60">Pattern will be created at half price.</p>
        <div class="modal-action">
          <form method="dialog"><button class="btn btn-ghost">Cancel</button></form>
          <button class="btn btn-success" id="copyConfirmBtn">
            <i class="bi bi-plus-circle mr-1"></i>Create
          </button>
        </div>
      </div>
      <form method="dialog" class="modal-backdrop"><button>close</button></form>
    `;
    document.body.appendChild(modal);

    const confirmBtn = modal.querySelector('#copyConfirmBtn');
    confirmBtn.addEventListener('click', async () => {
      modal.close();
      try {
        const response = await fetch(`/api/wardrobe/patterns/${patternId}/create`, {
          method: 'POST',
          headers: { 'X-CSRF-Token': getCsrfToken() }
        });
        const result = await response.json();
        if (result.success) {
          this.showToast(result.message || 'Item created!', 'success');
          if (onSuccess) onSuccess();
        } else {
          this.showToast(result.error || 'Failed to create item', 'danger');
        }
      } catch (err) {
        console.error('Error creating copy:', err);
        this.showToast('Error creating item', 'danger');
      }
      modal.remove();
    });

    modal.showModal();
  }

  /**
   * Fetch an item from storage
   */
  async fetchItem(itemId) {
    return this.makeRequest(`/api/wardrobe/items/${itemId}/fetch`, 'POST');
  }

  /**
   * Fetch and wear an item
   */
  async fetchAndWear(itemId) {
    return this.makeRequest(`/api/wardrobe/items/${itemId}/fetch-wear`, 'POST');
  }

  /**
   * Create item from pattern
   */
  async createFromPattern(patternId) {
    return this.makeRequest(`/api/wardrobe/patterns/${patternId}/create`, 'POST');
  }

  /**
   * Open the transfer management modal
   */
  async openTransferModal() {
    document.getElementById('transferModal')?.remove();

    const modal = document.createElement('dialog');
    modal.id = 'transferModal';
    modal.className = 'modal';
    modal.innerHTML = `
      <div class="modal-box bg-base-200 max-w-lg">
        <h3 class="font-bold text-lg mb-4"><i class="bi bi-truck mr-2"></i>Manage Transfers</h3>
        <div id="activeTransfers" class="mb-4 hidden">
          <h4 class="text-sm font-semibold text-base-content/70 mb-2">Active Transfers</h4>
          <div id="transfersList"></div>
        </div>
        <div class="divider" id="transferDivider"></div>
        <h4 class="text-sm font-semibold text-base-content/70 mb-2">Start New Transfer</h4>
        <div class="form-control mb-2">
          <label class="label"><span class="label-text">From</span></label>
          <select class="select select-bordered select-sm w-full" id="transferFrom">
            <option value="">Loading...</option>
          </select>
        </div>
        <div class="form-control mb-3">
          <label class="label"><span class="label-text">To</span></label>
          <select class="select select-bordered select-sm w-full" id="transferTo">
            <option value="">Select source first</option>
          </select>
        </div>
        <p class="text-xs text-base-content/50 mb-3"><i class="bi bi-info-circle mr-1"></i>Transfers take 12 hours to complete.</p>
        <button class="btn btn-primary btn-sm w-full" id="startTransferBtn" disabled>
          <i class="bi bi-truck mr-1"></i>Move All Items
        </button>
        <div class="modal-action">
          <form method="dialog"><button class="btn btn-ghost btn-sm">Close</button></form>
        </div>
      </div>
      <form method="dialog" class="modal-backdrop"><button>close</button></form>
    `;
    document.body.appendChild(modal);
    await this.loadTransferModalData(modal);
    modal.showModal();
  }

  /**
   * Load data into the transfer modal
   */
  async loadTransferModalData(modal) {
    try {
      const [roomsRes, transfersRes] = await Promise.all([
        fetch('/api/wardrobe/stash-rooms'),
        fetch('/api/wardrobe/transfers')
      ]);
      const roomsData = await roomsRes.json();
      const transfersData = await transfersRes.json();

      const rooms = roomsData.rooms || [];
      const transfers = transfersData.transfers || [];

      // Populate active transfers
      const activeSection = modal.querySelector('#activeTransfers');
      const transfersList = modal.querySelector('#transfersList');
      const divider = modal.querySelector('#transferDivider');

      if (transfers.length > 0) {
        activeSection.classList.remove('hidden');
        divider.classList.remove('hidden');
        transfersList.innerHTML = transfers.map(t => {
          const timeText = t.ready ? 'Ready!' : this.formatTimeRemaining(t.seconds_remaining);
          return `
            <div class="flex items-center justify-between py-1 px-2 bg-base-300 rounded mb-1 text-sm">
              <span>${this.escapeHtml(t.from_room_name)} &rarr; ${this.escapeHtml(t.to_room_name)} (${t.item_count} items)</span>
              <span class="flex items-center gap-2">
                <span class="text-xs text-base-content/50">${timeText}</span>
                <button class="btn btn-ghost btn-xs text-error cancel-transfer-btn"
                        data-from="${t.from_room_id}" data-to="${t.to_room_id}"
                        title="Cancel transfer"><i class="bi bi-x-circle"></i></button>
              </span>
            </div>`;
        }).join('');

        // Bind cancel buttons
        transfersList.querySelectorAll('.cancel-transfer-btn').forEach(btn => {
          btn.addEventListener('click', async () => {
            try {
              const res = await fetch('/api/wardrobe/transfers/cancel', {
                method: 'POST',
                headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-CSRF-Token': getCsrfToken() },
                body: `from_room_id=${btn.dataset.from}&to_room_id=${btn.dataset.to}`
              });
              const result = await res.json();
              if (result.success) {
                this.showToast(result.message, 'success');
                await this.loadTransferModalData(modal);
              } else {
                this.showToast(result.error || 'Failed to cancel', 'danger');
              }
            } catch (err) {
              console.error('Error cancelling transfer:', err);
              this.showToast('Error cancelling transfer', 'danger');
            }
          });
        });
      } else {
        activeSection.classList.add('hidden');
        divider.classList.add('hidden');
      }

      // Clone-and-replace dropdowns/button to prevent listener accumulation on reload
      const oldFrom = modal.querySelector('#transferFrom');
      const fromSelect = oldFrom.cloneNode(false);
      oldFrom.parentNode.replaceChild(fromSelect, oldFrom);

      const oldTo = modal.querySelector('#transferTo');
      const toSelect = oldTo.cloneNode(false);
      oldTo.parentNode.replaceChild(toSelect, oldTo);

      const oldBtn = modal.querySelector('#startTransferBtn');
      const startBtn = oldBtn.cloneNode(true);
      oldBtn.parentNode.replaceChild(startBtn, oldBtn);

      fromSelect.innerHTML = '<option value="">Select source...</option>' +
        rooms.map(r => `<option value="${r.id}">${this.escapeHtml(r.name)} (${r.item_count} items)</option>`).join('');

      fromSelect.addEventListener('change', () => {
        const selectedFrom = fromSelect.value;
        toSelect.innerHTML = '<option value="">Select destination...</option>' +
          rooms.filter(r => r.id.toString() !== selectedFrom)
               .map(r => `<option value="${r.id}">${this.escapeHtml(r.name)}</option>`).join('');
        startBtn.disabled = !selectedFrom || !toSelect.value;
      });

      toSelect.addEventListener('change', () => {
        startBtn.disabled = !fromSelect.value || !toSelect.value;
      });

      startBtn.addEventListener('click', async () => {
        startBtn.disabled = true;
        startBtn.innerHTML = '<span class="loading loading-spinner loading-xs"></span> Starting...';
        try {
          const res = await fetch('/api/wardrobe/transfers', {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-CSRF-Token': getCsrfToken() },
            body: `from_room_id=${fromSelect.value}&to_room_id=${toSelect.value}`
          });
          const result = await res.json();
          if (result.success) {
            this.showToast(result.message, 'success');
            await this.loadTransferModalData(modal);
          } else {
            this.showToast(result.error || 'Failed to start transfer', 'danger');
          }
        } catch (err) {
          console.error('Error starting transfer:', err);
          this.showToast('Error starting transfer', 'danger');
        }
        startBtn.disabled = false;
        startBtn.innerHTML = '<i class="bi bi-truck mr-1"></i>Move All Items';
      });

    } catch (err) {
      console.error('Error loading transfer data:', err);
      this.showToast('Error loading transfer data', 'danger');
    }
  }

  /**
   * Format seconds remaining into human-readable time
   */
  formatTimeRemaining(seconds) {
    if (seconds <= 0) return 'Ready!';
    const hours = Math.floor(seconds / 3600);
    const mins = Math.floor((seconds % 3600) / 60);
    if (hours > 0) return `${hours}h ${mins}m`;
    return `${mins}m`;
  }

  /**
   * Make an API request
   */
  async makeRequest(url, method) {
    try {
      const options = { method };
      if (method !== 'GET' && method !== 'HEAD') {
        options.headers = { 'X-CSRF-Token': getCsrfToken() };
      }
      const response = await fetch(url, options);
      return await response.json();
    } catch (err) {
      console.error(`Error making request to ${url}:`, err);
      return { success: false, error: 'Network error' };
    }
  }

  /**
   * Show a toast notification
   */
  showToast(message, type = 'info') {
    let toastContainer = document.querySelector('.toast-container');
    if (!toastContainer) {
      toastContainer = document.createElement('div');
      toastContainer.className = 'toast toast-end toast-bottom z-50';
      document.body.appendChild(toastContainer);
    }

    const alertClass = type === 'success' ? 'alert-success' :
                       type === 'danger' ? 'alert-error' :
                       type === 'warning' ? 'alert-warning' : 'alert-info';

    const toastEl = document.createElement('div');
    toastEl.className = `alert ${alertClass}`;
    toastEl.innerHTML = `
      <span>${this.escapeHtml(message)}</span>
      <button type="button" class="btn btn-ghost btn-sm" onclick="this.closest('.alert').remove()">
        <i class="bi bi-x-lg"></i>
      </button>
    `;

    toastContainer.appendChild(toastEl);

    // Auto-dismiss after 3 seconds
    setTimeout(() => {
      toastEl.style.transition = 'opacity 0.3s';
      toastEl.style.opacity = '0';
      setTimeout(() => toastEl.remove(), 300);
    }, 3000);
  }

  /**
   * Escape HTML to prevent XSS
   */
  escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text || '';
    return div.innerHTML;
  }
}

/**
 * Open lightbox for a wardrobe item
 */
function openWardrobeLightbox(data) {
  document.querySelector('.wardrobe-lightbox-overlay')?.remove();

  const overlay = document.createElement('div');
  overlay.className = 'wardrobe-lightbox-overlay';
  overlay.onclick = (e) => {
    if (e.target === overlay) overlay.remove();
  };

  const imgUrl = data.image_url || data.thumbnail_url || '';
  const name = data.name || 'Item';
  const desc = data.description || data.long_description || '';
  const condition = data.condition || '';
  const location = data.stored_room_name || 'Unknown';

  let html = '<div class="wardrobe-lightbox">';
  if (imgUrl) {
    html += `<img src="${escapeHtml(imgUrl)}" alt="${escapeHtml(name)}" onerror="this.style.display='none'">`;
  }
  html += '<div class="lightbox-body">';
  html += `<div class="lightbox-name">${escapeHtml(name)}</div>`;
  if (desc) {
    html += `<div class="lightbox-desc">${escapeHtml(desc)}</div>`;
  }
  html += '<div class="lightbox-meta">';
  if (condition) {
    html += `<span>Condition: ${escapeHtml(condition)}</span>`;
  }
  html += `<span>Stored in: ${escapeHtml(location)}</span>`;
  html += '</div>';
  html += `<button class="lightbox-close" onclick="this.closest('.wardrobe-lightbox-overlay').remove()">Close</button>`;
  html += '</div></div>';

  overlay.innerHTML = html;
  document.body.appendChild(overlay);
}

/**
 * Open wardrobe as a pop-out window
 */
function openWardrobePopout() {
  const width = 900;
  const height = 700;
  const left = (screen.width - width) / 2;
  const top = (screen.height - height) / 2;

  window.open(
    '/wardrobe?popout=true',
    'wardrobePopout',
    `width=${width},height=${height},left=${left},top=${top},menubar=no,toolbar=no,location=no,status=no,resizable=yes,scrollbars=yes`
  );
}

// Export for use in modules
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { WardrobeManager, openWardrobePopout };
}
