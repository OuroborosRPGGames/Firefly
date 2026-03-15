/**
 * JourneyConfigPanel - Right-side configuration panel for journey planning
 *
 * Three states:
 *   1. Empty - "Select a destination on the map"
 *   2. Destination Selected - Travel options, flashback modes, action buttons
 *   3. Party Assembling - Member list, invite input, launch/cancel
 *
 * Self-contained dark theme — no DaisyUI/Tailwind dependency (play.erb layout).
 */

class JourneyConfigPanel {
  constructor(containerId, options = {}) {
    this.container = document.getElementById(containerId);
    if (!this.container) return;

    // Callbacks
    this.onTravelStarted = options.onTravelStarted || null;
    this.onClearSelection = options.onClearSelection || null;

    // State
    this.state = 'empty'; // 'empty' | 'options' | 'party'
    this.currentOptions = null;
    this.selectedMode = null;
    this.selectedFlashback = 'none';
    this.currentParty = null;
    this.destination = null;

    // Party polling
    this.pollInterval = null;

    this.renderEmpty();
  }

  // ─── Public API ──────────────────────────────────────────────────────

  showEmpty() {
    this.state = 'empty';
    this.destination = null;
    this.currentOptions = null;
    this.currentParty = null;
    this.stopPolling();
    this.renderEmpty();
  }

  async showOptionsForDestination(location) {
    this.destination = location;
    this.state = 'options';
    this.selectedFlashback = 'none';
    this.renderLoading();

    try {
      const resp = await fetch(`/api/journey/options/${location.id}`);
      const data = await resp.json();

      if (data.success !== false) {
        this.currentOptions = data;
        this.selectedMode = data.available_modes?.[0] || 'land';
        this.renderOptions();
      } else {
        this.renderError(data.error || 'Failed to load options');
      }
    } catch (e) {
      console.error('Error loading travel options:', e);
      this.renderError('Network error');
    }
  }

  showParty(party) {
    this.state = 'party';
    this.currentParty = party;
    this.renderParty();
    this.startPolling();
  }

  async loadActiveParty() {
    try {
      const resp = await fetch('/api/journey/party');
      const data = await resp.json();

      if (data.success && data.party) {
        this.showParty(data.party);
        return true;
      }
    } catch (e) {
      console.error('Error loading active party:', e);
    }
    return false;
  }

  destroy() {
    this.stopPolling();
  }

  // ─── Rendering ───────────────────────────────────────────────────────

  renderEmpty() {
    this.container.innerHTML = `
      <div class="jcp-empty">
        <i class="bi bi-geo-alt"></i>
        <p>Select a destination on the map to begin planning your journey.</p>
      </div>
    `;
  }

  renderLoading() {
    this.container.innerHTML = `
      <div class="jcp-empty" style="height:auto;padding-top:40px;">
        <i class="bi bi-hourglass-split" style="animation:spin 1.5s linear infinite;"></i>
        <p>Loading options…</p>
      </div>
    `;
  }

  renderError(message) {
    this.container.innerHTML = `
      <div style="padding:16px;">
        <div class="jcp-alert jcp-alert-error">${this.escapeHtml(message)}</div>
      </div>
    `;
  }

  renderOptions() {
    const opt = this.currentOptions;
    if (!opt) return;

    const dest = opt.destination || this.destination || {};
    const flashback = opt.flashback || {};

    this.container.innerHTML = `
      <div style="padding:16px;display:flex;flex-direction:column;gap:16px;">
        <!-- Header -->
        <div style="display:flex;align-items:center;gap:8px;">
          <button class="jcp-btn jcp-btn-ghost" id="jcp-back-btn">
            <i class="bi bi-arrow-left"></i>
          </button>
          <h4 style="font-weight:700;font-size:15px;flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;margin:0;">
            ${this.escapeHtml(dest.city_name || dest.name || 'Unknown')}
          </h4>
        </div>

        <!-- Distance & Time -->
        <div class="jcp-info-box">
          <div><span style="opacity:0.6">Distance:</span> <strong>${opt.distance_miles || 0} miles</strong></div>
          <div><span style="opacity:0.6">Journey Time:</span> <strong>${opt.journey_time_display || 'Unknown'}</strong></div>
          <div><span style="opacity:0.6">Flashback:</span> <strong>${flashback.available_display || '0'}</strong></div>
        </div>

        <!-- Travel Mode -->
        ${this.renderTravelModes(opt.available_modes || ['land'])}

        <!-- Flashback Options -->
        ${this.renderFlashbackOptions(flashback, opt.journey_time)}

        <!-- Action Buttons -->
        <div style="display:flex;gap:8px;">
          <button class="jcp-btn jcp-btn-primary" style="flex:1" id="jcp-travel-btn">Travel Now</button>
          <button class="jcp-btn jcp-btn-neutral" style="flex:1" id="jcp-party-btn">
            <i class="bi bi-people-fill"></i> Party
          </button>
        </div>
      </div>
    `;

    this.bindOptionsEvents();
  }

  renderTravelModes(modes) {
    if (!modes || modes.length <= 1) return '';

    const labels = { land: 'Land', water: 'Sea', rail: 'Rail', air: 'Air' };
    const icons = { land: 'bi-signpost', water: 'bi-water', rail: 'bi-train-front', air: 'bi-airplane' };

    const buttons = modes.map(mode => {
      const active = mode === this.selectedMode ? ' active' : '';
      return `<button class="jcp-mode-btn${active}" data-mode="${mode}">
        <i class="${icons[mode] || 'bi-geo'}"></i> ${labels[mode] || mode}
      </button>`;
    }).join('');

    return `
      <div>
        <div class="jcp-label">Travel Mode</div>
        <div style="display:flex;gap:4px;flex-wrap:wrap;">${buttons}</div>
      </div>
    `;
  }

  renderFlashbackOptions(flashback, journeyTime) {
    if (!flashback || flashback.available <= 0) {
      return `
        <div class="jcp-info-box" style="opacity:0.5">
          No flashback time available. Standard travel only.
        </div>
      `;
    }

    const basic = flashback.basic || {};
    const returnOpt = flashback.return || {};
    const backloaded = flashback.backloaded || {};

    const options = [];

    options.push({
      key: 'none', label: 'Standard Travel',
      desc: `Full journey: ${this.currentOptions?.journey_time_display || 'N/A'}`,
      available: true
    });

    if (basic.success) {
      options.push({
        key: 'basic',
        label: basic.can_instant ? 'Flashback (Instant)' : 'Flashback (Reduced)',
        desc: basic.can_instant
          ? `Arrive instantly using ${this.formatTime(basic.flashback_used)}`
          : `Reduced to ${this.formatTime(basic.time_remaining)} (uses ${this.formatTime(basic.flashback_used)})`,
        available: true
      });
    }

    if (returnOpt.success && returnOpt.can_instant) {
      options.push({
        key: 'return', label: 'Flashback Return',
        desc: `Instant arrival, ${this.formatTime(returnOpt.reserved_for_return)} reserved for return`,
        available: true, instanced: true
      });
    } else {
      options.push({
        key: 'return', label: 'Flashback Return',
        desc: `Need ${this.formatTime((journeyTime || 0) * 2)} total`,
        available: false
      });
    }

    if (backloaded.success) {
      options.push({
        key: 'backloaded', label: 'Backloaded',
        desc: `Instant arrival, ${this.formatTime(backloaded.return_debt)} return debt (2x)`,
        available: true, instanced: true
      });
    } else {
      options.push({
        key: 'backloaded', label: 'Backloaded',
        desc: backloaded.error || 'Not available',
        available: false
      });
    }

    const html = options.map(opt => {
      const checked = this.selectedFlashback === opt.key ? 'checked' : '';
      const disabled = !opt.available ? 'disabled' : '';
      const activeClass = this.selectedFlashback === opt.key ? ' active' : '';
      const disabledClass = !opt.available ? ' disabled' : '';

      return `
        <label class="jcp-radio-option${activeClass}${disabledClass}">
          <div style="display:flex;align-items:center;gap:6px;">
            <input type="radio" name="jcp-flashback" value="${opt.key}" ${checked} ${disabled}>
            <span class="jcp-radio-label">${opt.label}</span>
            ${opt.instanced ? '<span class="jcp-badge jcp-badge-warning">INSTANCED</span>' : ''}
          </div>
          <div class="jcp-radio-desc">${opt.desc}</div>
        </label>
      `;
    }).join('');

    return `
      <div>
        <div class="jcp-label">Travel Options</div>
        <div style="display:flex;flex-direction:column;gap:4px;">${html}</div>
      </div>
    `;
  }

  renderParty() {
    const party = this.currentParty;
    if (!party) return;

    const members = party.members || [];
    const acceptedCount = members.filter(m => m.status === 'accepted').length;
    const totalCount = members.length;

    const statusIcons = { accepted: '✓', pending: '…', declined: '✗' };

    const memberHtml = members.length === 0
      ? '<div style="font-size:13px;opacity:0.5;font-style:italic;">No members yet. Invite someone!</div>'
      : members.map(m => `
          <div class="jcp-member">
            <span style="font-size:13px;">
              ${this.escapeHtml(m.name || 'Unknown')}
              ${m.is_leader ? '<span class="jcp-badge jcp-badge-primary">LEADER</span>' : ''}
            </span>
            <span class="jcp-status-${m.status || 'pending'}" style="font-size:13px;">
              ${statusIcons[m.status] || '?'} ${m.status}
            </span>
          </div>
        `).join('');

    this.container.innerHTML = `
      <div style="padding:16px;display:flex;flex-direction:column;gap:16px;">
        <!-- Header -->
        <h4 style="font-weight:700;font-size:15px;margin:0;">Journey Party</h4>

        <!-- Destination Info -->
        <div class="jcp-info-box">
          <div><span style="opacity:0.6">To:</span> <strong>${this.escapeHtml(party.destination?.name || 'Unknown')}</strong></div>
          <div><span style="opacity:0.6">Mode:</span> ${this.formatMode(party.travel_mode)}
            ${party.flashback_mode && party.flashback_mode !== 'none' ? ' | ' + this.formatFlashbackMode(party.flashback_mode) : ''}</div>
        </div>

        <!-- Members -->
        <div>
          <div class="jcp-label">Members (${acceptedCount}/${totalCount} ready)</div>
          <div class="jcp-info-box" style="max-height:160px;overflow-y:auto;">
            ${memberHtml}
          </div>
        </div>

        <!-- Invite -->
        <div>
          <div class="jcp-label">Invite</div>
          <div class="jcp-input-group">
            <input type="text" id="jcp-invite-input" placeholder="Character name...">
            <button class="jcp-btn jcp-btn-success jcp-btn-sm" id="jcp-invite-btn">
              <i class="bi bi-person-plus"></i>
            </button>
          </div>
        </div>

        <!-- Actions -->
        <div style="display:flex;gap:8px;">
          <button class="jcp-btn jcp-btn-primary" style="flex:1" id="jcp-launch-btn"
            ${acceptedCount === 0 ? 'disabled' : ''}>
            Launch Journey
          </button>
          <button class="jcp-btn jcp-btn-outline" style="flex:1" id="jcp-cancel-btn">Cancel</button>
        </div>

        ${acceptedCount === 0 ? '<div style="font-size:11px;text-align:center;opacity:0.4;">Waiting for at least one member to accept…</div>' : ''}
      </div>
    `;

    this.bindPartyEvents();
  }

  // ─── Event Binding ───────────────────────────────────────────────────

  bindOptionsEvents() {
    // Back button
    this.container.querySelector('#jcp-back-btn')?.addEventListener('click', () => {
      this.showEmpty();
      if (this.onClearSelection) this.onClearSelection();
    });

    // Travel mode buttons
    this.container.querySelectorAll('.jcp-mode-btn').forEach(btn => {
      btn.addEventListener('click', () => {
        this.selectedMode = btn.dataset.mode;
        this.renderOptions();
      });
    });

    // Flashback radios
    this.container.querySelectorAll('input[name="jcp-flashback"]').forEach(input => {
      input.addEventListener('change', () => {
        this.selectedFlashback = input.value;
        this.renderOptions();
      });
    });

    // Travel Now
    this.container.querySelector('#jcp-travel-btn')?.addEventListener('click', () => this.handleTravelNow());

    // Assemble Party
    this.container.querySelector('#jcp-party-btn')?.addEventListener('click', () => this.handleAssembleParty());
  }

  bindPartyEvents() {
    // Invite
    const inviteBtn = this.container.querySelector('#jcp-invite-btn');
    const inviteInput = this.container.querySelector('#jcp-invite-input');
    if (inviteBtn && inviteInput) {
      inviteBtn.addEventListener('click', () => this.handleInvite(inviteInput.value));
      inviteInput.addEventListener('keypress', (e) => {
        if (e.key === 'Enter') this.handleInvite(inviteInput.value);
      });
    }

    // Launch
    this.container.querySelector('#jcp-launch-btn')?.addEventListener('click', () => this.handleLaunch());

    // Cancel
    this.container.querySelector('#jcp-cancel-btn')?.addEventListener('click', () => this.handleCancel());
  }

  // ─── API Actions ─────────────────────────────────────────────────────

  async handleTravelNow() {
    const btn = this.container.querySelector('#jcp-travel-btn');
    if (btn) { btn.classList.add('loading'); btn.disabled = true; }

    try {
      const resp = await fetch('/api/journey/start', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          destination_id: this.currentOptions?.destination?.id || this.destination?.id,
          travel_mode: this.selectedMode,
          flashback_mode: this.selectedFlashback === 'none' ? null : this.selectedFlashback
        })
      });
      const data = await resp.json();

      if (data.success) {
        if (window.addGameMessage) {
          window.addGameMessage(data.message || 'Journey started!', 'system');
        }
        if (this.onTravelStarted) this.onTravelStarted();
      } else {
        this.showAlert(data.error || 'Failed to start journey', 'error');
      }
    } catch (e) {
      console.error('Error starting journey:', e);
      this.showAlert('Network error', 'error');
    } finally {
      if (btn) { btn.classList.remove('loading'); btn.disabled = false; }
    }
  }

  async handleAssembleParty() {
    const btn = this.container.querySelector('#jcp-party-btn');
    if (btn) { btn.classList.add('loading'); btn.disabled = true; }

    try {
      const resp = await fetch('/api/journey/party/create', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          destination_id: this.currentOptions?.destination?.id || this.destination?.id,
          travel_mode: this.selectedMode,
          flashback_mode: this.selectedFlashback === 'none' ? null : this.selectedFlashback
        })
      });
      const data = await resp.json();

      if (data.success) {
        this.showParty(data.party);
      } else {
        this.showAlert(data.error || 'Failed to create party', 'error');
      }
    } catch (e) {
      console.error('Error creating party:', e);
      this.showAlert('Network error', 'error');
    } finally {
      if (btn) { btn.classList.remove('loading'); btn.disabled = false; }
    }
  }

  async handleInvite(name) {
    const trimmed = name?.trim();
    if (!trimmed) return;

    const btn = this.container.querySelector('#jcp-invite-btn');
    if (btn) btn.classList.add('loading');

    try {
      const resp = await fetch('/api/journey/party/invite', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: trimmed })
      });
      const data = await resp.json();

      if (data.success) {
        const input = this.container.querySelector('#jcp-invite-input');
        if (input) input.value = '';
        if (window.addGameMessage) {
          window.addGameMessage(data.message || `Invited ${trimmed}`, 'system');
        }
        await this.refreshParty();
      } else {
        this.showAlert(data.error || 'Failed to invite', 'error');
      }
    } catch (e) {
      console.error('Error inviting:', e);
      this.showAlert('Network error', 'error');
    } finally {
      if (btn) btn.classList.remove('loading');
    }
  }

  async handleLaunch() {
    const btn = this.container.querySelector('#jcp-launch-btn');
    if (btn) { btn.classList.add('loading'); btn.disabled = true; }

    try {
      const resp = await fetch('/api/journey/party/launch', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' }
      });
      const data = await resp.json();

      if (data.success) {
        this.stopPolling();
        if (window.addGameMessage) {
          window.addGameMessage(data.message || 'Party journey launched!', 'system');
        }
        if (this.onTravelStarted) this.onTravelStarted();
      } else {
        this.showAlert(data.error || 'Failed to launch', 'error');
      }
    } catch (e) {
      console.error('Error launching:', e);
      this.showAlert('Network error', 'error');
    } finally {
      if (btn) { btn.classList.remove('loading'); btn.disabled = false; }
    }
  }

  async handleCancel() {
    try {
      const resp = await fetch('/api/journey/party/cancel', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' }
      });
      const data = await resp.json();

      if (data.success) {
        this.stopPolling();
        this.showEmpty();
        if (window.addGameMessage) {
          window.addGameMessage(data.message || 'Party cancelled.', 'system');
        }
        if (this.onClearSelection) this.onClearSelection();
      } else {
        this.showAlert(data.error || 'Failed to cancel', 'error');
      }
    } catch (e) {
      console.error('Error cancelling:', e);
      this.showAlert('Network error', 'error');
    }
  }

  // ─── Party Polling ───────────────────────────────────────────────────

  startPolling() {
    this.stopPolling();
    this.pollInterval = setInterval(() => this.refreshParty(), 3000);
  }

  stopPolling() {
    if (this.pollInterval) {
      clearInterval(this.pollInterval);
      this.pollInterval = null;
    }
  }

  async refreshParty() {
    try {
      const resp = await fetch('/api/journey/party');
      const data = await resp.json();

      if (data.success && data.party) {
        this.currentParty = data.party;
        // Preserve invite input value across re-render
        const inviteInput = this.container.querySelector('#jcp-invite-input');
        const savedValue = inviteInput ? inviteInput.value : '';
        this.renderParty();
        if (savedValue) {
          const newInput = this.container.querySelector('#jcp-invite-input');
          if (newInput) newInput.value = savedValue;
        }
      } else if (!data.party) {
        this.stopPolling();
        this.showEmpty();
        if (window.addGameMessage) {
          window.addGameMessage('Travel party is no longer active.', 'system');
        }
      }
    } catch (e) {
      console.error('Error refreshing party:', e);
    }
  }

  // ─── Helpers ─────────────────────────────────────────────────────────

  showAlert(message, type = 'info') {
    // Brief inline alert at top of panel
    const existing = this.container.querySelector('.jcp-alert');
    if (existing) existing.remove();

    const alertEl = document.createElement('div');
    alertEl.className = `jcp-alert jcp-alert-${type}`;
    alertEl.textContent = message;
    this.container.prepend(alertEl);

    setTimeout(() => alertEl.remove(), 4000);
  }

  formatTime(seconds) {
    if (!seconds || seconds <= 0) return 'instant';
    if (seconds < 60) return `${seconds}s`;
    if (seconds < 3600) return `${Math.round(seconds / 60)}m`;
    const h = Math.floor(seconds / 3600);
    const m = Math.round((seconds % 3600) / 60);
    return m > 0 ? `${h}h ${m}m` : `${h}h`;
  }

  formatMode(mode) {
    return { land: 'Land', water: 'Sea', rail: 'Rail', air: 'Air' }[mode] || mode || 'Standard';
  }

  formatFlashbackMode(mode) {
    return {
      basic: 'Flashback', return: 'Flashback Return', backloaded: 'Backloaded'
    }[mode] || mode;
  }

  escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text || '';
    return div.innerHTML;
  }
}

window.JourneyConfigPanel = JourneyConfigPanel;
