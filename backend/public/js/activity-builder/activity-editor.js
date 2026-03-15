/**
 * Activity Editor - Main controller for the activity builder
 */
class ActivityEditor {
  constructor(config) {
    this.activityId = config.activityId;
    this.isNew = config.isNew;
    this.roundTypes = config.roundTypes || [];
    this.activityTypes = config.activityTypes || [];

    this.api = new ActivityBuilderAPI(this.activityId);
    this.renderer = null;
    this.rounds = [];
    this.selectedRound = null;
    this.selectedNpcIds = [];
    this.descriptionEditors = {};
    this.universeId = null;
    this.cachedStats = [];
    this.statBlockId = null;
    this.savedLocations = [];

    this.init();
  }

  async init() {
    // Initialize SVG renderer
    const svg = document.getElementById('round-canvas');
    if (svg) {
      this.renderer = new RoundNodeRenderer(svg);
      this.renderer.setNodeClickHandler(round => this.openRoundModal(round));
      this.renderer.setNodeDeleteHandler(round => this.deleteRoundDirect(round));
      this.renderer.setPositionChangeHandler((id, x, y) => this.saveRoundPosition(id, x, y));
    }

    // Bind event handlers
    this.bindEventHandlers();

    // Initialize collapsible sections
    this.initCollapsibleSections();

    // Initialize description editor for activity description
    this.initActivityDescriptionEditor();

    // Load saved locations for room selectors
    await this.loadSavedLocations();

    // Load existing data if editing
    if (!this.isNew && this.activityId) {
      await this.loadActivity();
    }

    // Show type-specific sections based on initial selection
    this.updateTypeVisibility();
  }

  // ============================================
  // Collapsible Sections
  // ============================================

  initCollapsibleSections() {
    document.querySelectorAll('.section-header[data-section]').forEach(header => {
      const sectionId = header.dataset.section;
      const section = header.closest('.sidebar-section');
      if (!section) return;

      // Restore collapsed state from localStorage
      try {
        const stored = localStorage.getItem(`ab-section-${sectionId}`);
        if (stored === 'collapsed') {
          section.classList.add('collapsed');
        }
      } catch {
        // Ignore storage errors (e.g. private browsing)
      }

      header.addEventListener('click', () => this.toggleSection(sectionId, section));
    });
  }

  toggleSection(sectionId, section) {
    section.classList.toggle('collapsed');
    const isCollapsed = section.classList.contains('collapsed');
    try {
      localStorage.setItem(`ab-section-${sectionId}`, isCollapsed ? 'collapsed' : 'expanded');
    } catch {
      // Ignore storage errors (e.g. private browsing)
    }
  }

  // ============================================
  // Description Editor Init
  // ============================================

  initActivityDescriptionEditor() {
    const container = document.getElementById('activity-description-editor');
    if (!container || typeof DescriptionEditor === 'undefined') return;

    this.descriptionEditors.activity = new DescriptionEditor('#activity-description-editor', {
      placeholder: 'Enter activity description...',
      maxLength: 5000,
      enableGradients: true,
      onChange: (html) => {
        const hiddenInput = document.getElementById('description-html-value');
        if (hiddenInput) hiddenInput.value = html;
      }
    });

    // Set initial content
    const initial = container.dataset.initial;
    if (initial) {
      this.descriptionEditors.activity.setContent(initial);
    }
  }

  // ============================================
  // Event Handlers
  // ============================================

  bindEventHandlers() {
    // Activity type change
    const typeSelect = document.getElementById('activity-type');
    if (typeSelect) {
      typeSelect.addEventListener('change', () => this.updateTypeVisibility());
    }

    // Launch mode change
    const launchMode = document.getElementById('launch-mode');
    if (launchMode) {
      launchMode.addEventListener('change', () => this.updateTypeVisibility());
    }

    // Universe change
    const universeSelect = document.getElementById('universe-select');
    if (universeSelect) {
      universeSelect.addEventListener('change', () => {
        this.universeId = universeSelect.value || null;
        this.loadStatBlocksForUniverse();
      });
    }

    // Stat block change
    const statBlockSelect = document.getElementById('stat-block-select');
    if (statBlockSelect) {
      statBlockSelect.addEventListener('change', () => this.onStatBlockChange());
    }

    // Create/Save activity buttons
    const createBtn = document.getElementById('create-activity-btn');
    if (createBtn) {
      createBtn.addEventListener('click', () => this.createActivity());
    }

    const saveBtn = document.getElementById('save-activity-btn');
    if (saveBtn) {
      saveBtn.addEventListener('click', () => this.saveActivity());
    }

    // Round palette items
    document.querySelectorAll('.palette-item').forEach(btn => {
      btn.addEventListener('click', () => {
        const roundType = btn.dataset.roundType;
        this.addRound(roundType);
      });
    });

    // NPC selector confirm
    const confirmNpcsBtn = document.getElementById('confirm-npcs-btn');
    if (confirmNpcsBtn) {
      confirmNpcsBtn.addEventListener('click', () => this.confirmNpcSelection());
    }

    // Zoom controls
    document.getElementById('zoom-in')?.addEventListener('click', () => this.zoom(1.2));
    document.getElementById('zoom-out')?.addEventListener('click', () => this.zoom(0.8));
    document.getElementById('zoom-reset')?.addEventListener('click', () => this.resetZoom());

    // Canvas click to deselect
    const canvas = document.getElementById('canvas-container');
    if (canvas) {
      canvas.addEventListener('click', (e) => {
        if (e.target === canvas || e.target.id === 'round-canvas') {
          this.renderer.deselectAll();
        }
      });
    }

    // Round config modal events
    this.bindModalHandlers();

    // Initialize room pickers (browse toggles, cascading selects)
    this.initRoomPickers();
  }

  // ============================================
  // Room Pickers (Saved + Browse)
  // ============================================

  async loadSavedLocations() {
    if (!this.activityId) return;
    try {
      const res = await this.api.getSavedLocations();
      if (res.success) {
        this.savedLocations = res.saved_locations || [];
        this.populateAllSavedRoomSelectors();
      }
    } catch (e) {
      console.error('Failed to load saved locations:', e);
    }
  }

  populateAllSavedRoomSelectors() {
    document.querySelectorAll('.room-picker').forEach(picker => {
      const select = picker.querySelector('.saved-room-select');
      if (!select) return;
      const currentValue = picker.dataset.currentValue;
      this.populateSavedRoomSelect(select, currentValue);
    });
  }

  populateSavedRoomSelect(select, currentValue) {
    const current = currentValue || select.value;
    select.innerHTML = '<option value="">-- Saved Rooms --</option>';
    this.savedLocations.forEach(loc => {
      const opt = document.createElement('option');
      opt.value = loc.id;
      opt.textContent = loc.room_name ? `${loc.name} (${loc.room_name})` : loc.name;
      if (current && parseInt(current) === loc.id) opt.selected = true;
      select.appendChild(opt);
    });
    // Sync hidden input if a value was pre-selected
    if (current) {
      const picker = select.closest('.room-picker');
      const hidden = picker?.querySelector('input[type="hidden"]');
      if (hidden) hidden.value = current;
    }
  }

  initRoomPickers() {
    document.querySelectorAll('.room-picker').forEach(picker => {
      // Browse toggle
      const toggle = picker.querySelector('.browse-rooms-toggle');
      const panel = picker.querySelector('.browse-rooms-panel');
      if (toggle && panel) {
        toggle.addEventListener('click', () => {
          const showing = panel.style.display !== 'none';
          panel.style.display = showing ? 'none' : 'block';
          toggle.innerHTML = showing
            ? '<i class="bi bi-search mr-1"></i>or browse...'
            : '<i class="bi bi-x mr-1"></i>hide browse';
        });
      }

      // Saved room select → write to hidden input
      const savedSelect = picker.querySelector('.saved-room-select');
      const hidden = picker.querySelector('input[type="hidden"]');
      if (savedSelect && hidden) {
        savedSelect.addEventListener('change', () => {
          hidden.value = savedSelect.value;
          // Clear browse selection
          const browseRoom = picker.querySelector('.browse-room');
          if (browseRoom) browseRoom.value = '';
        });
      }

      // Browse cascading: World → Location → Room
      const worldSelect = picker.querySelector('.browse-world');
      const locSelect = picker.querySelector('.browse-location');
      const roomSelect = picker.querySelector('.browse-room');

      if (worldSelect) {
        // Load worlds on first open (lazy)
        if (worldSelect.options.length <= 1) {
          this.loadWorldsForSelect(worldSelect);
        }

        worldSelect.addEventListener('change', async () => {
          locSelect.innerHTML = '<option value="">-- Location --</option>';
          roomSelect.innerHTML = '<option value="">-- Room --</option>';
          if (!worldSelect.value) return;
          try {
            const res = await this.api.getLocations(worldSelect.value);
            if (res.success) {
              (res.locations || []).forEach(loc => {
                const opt = document.createElement('option');
                opt.value = loc.id;
                opt.textContent = loc.name;
                locSelect.appendChild(opt);
              });
            }
          } catch (e) {
            console.error('Failed to load locations:', e);
          }
        });
      }

      if (locSelect) {
        locSelect.addEventListener('change', async () => {
          roomSelect.innerHTML = '<option value="">-- Room --</option>';
          if (!locSelect.value) return;
          try {
            const res = await this.api.getRooms(locSelect.value);
            if (res.success) {
              (res.rooms || []).forEach(r => {
                const opt = document.createElement('option');
                opt.value = r.id;
                opt.textContent = r.name;
                roomSelect.appendChild(opt);
              });
            }
          } catch (e) {
            console.error('Failed to load rooms:', e);
          }
        });
      }

      if (roomSelect && hidden) {
        roomSelect.addEventListener('change', () => {
          hidden.value = roomSelect.value;
          // Clear saved room selection
          if (savedSelect) savedSelect.value = '';
        });
      }
    });
  }

  async loadWorldsForSelect(worldSelect) {
    try {
      const res = await this.api.getWorlds();
      if (res.success) {
        (res.worlds || []).forEach(w => {
          const opt = document.createElement('option');
          opt.value = w.id;
          opt.textContent = w.name;
          worldSelect.appendChild(opt);
        });
      }
    } catch (e) {
      console.error('Failed to load worlds:', e);
    }
  }

  // Set a room picker's value (saved select + hidden input)
  setRoomPickerValue(pickerId, roomId) {
    const picker = document.getElementById(pickerId);
    if (!picker) return;
    const hidden = picker.querySelector('input[type="hidden"]');
    const savedSelect = picker.querySelector('.saved-room-select');
    if (hidden) hidden.value = roomId || '';
    if (savedSelect) {
      this.populateSavedRoomSelect(savedSelect, roomId);
    }
    // Reset browse panel
    const browseRoom = picker.querySelector('.browse-room');
    if (browseRoom) browseRoom.value = '';
  }

  // Load adjacent room exits for the Room & Media tab
  async loadRoomExits(currentRoomId) {
    const select = document.getElementById('modal-room-exit-select');
    if (!select) return;

    // Use activity's location room if no custom room set
    const roomId = currentRoomId || this.activityRoomId;
    if (!roomId) {
      select.innerHTML = '<option value="">-- No activity room set --</option>';
      return;
    }

    select.innerHTML = '<option value="">Loading exits...</option>';
    try {
      const res = await this.api.request(`${this.api.baseUrl}/api/room_exits?room_id=${roomId}`);
      select.innerHTML = '<option value="">-- Choose an exit --</option>';
      if (res.exits && res.exits.length > 0) {
        res.exits.forEach(exit => {
          const opt = document.createElement('option');
          opt.value = exit.room_id;
          opt.textContent = `${exit.direction} → ${exit.room_name}`;
          if (currentRoomId && exit.room_id === currentRoomId) opt.selected = true;
          select.appendChild(opt);
        });
      } else {
        select.innerHTML = '<option value="">-- No exits found --</option>';
      }
    } catch (e) {
      select.innerHTML = '<option value="">-- Could not load exits --</option>';
    }

    // Wire exit select to set the hidden room value
    select.onchange = () => {
      const val = select.value;
      if (val) {
        const hidden = document.getElementById('modal-custom-room-value');
        if (hidden) hidden.value = val;
      }
    };
  }

  // ============================================
  // Load Activity
  // ============================================

  async loadActivity() {
    try {
      const response = await this.api.getActivity();
      if (response.success) {
        this.rounds = response.rounds || [];
        this.renderer.render(this.rounds);
        this.updateEmptyState();

        // Set universe and activity room
        const activity = response.activity;
        this.activityRoomId = activity.room_id || null;
        if (activity.universe_id) {
          this.universeId = activity.universe_id;
          const universeSelect = document.getElementById('universe-select');
          if (universeSelect) universeSelect.value = activity.universe_id;
          this.statBlockId = activity.stat_block_id ? String(activity.stat_block_id) : null;
          await this.loadStatBlocksForUniverse();
        }
      }
    } catch (err) {
      console.error('Failed to load activity:', err);
      this.showError('Failed to load activity data');
    }
  }

  // ============================================
  // Stats Loading
  // ============================================

  async loadStatsForStatBlock() {
    try {
      const res = await this.api.getStats(this.statBlockId);
      if (res.success) {
        this.cachedStats = res.stats || [];
      }
    } catch (e) {
      console.error('Failed to load stats:', e);
    }
  }

  async loadStatBlocksForUniverse() {
    const select = document.getElementById('stat-block-select');
    if (!select) return;

    if (!this.universeId) {
      select.innerHTML = '<option value="">-- Select Universe First --</option>';
      this.statBlockId = null;
      this.cachedStats = [];
      return;
    }

    try {
      const res = await this.api.getStatBlocks(this.universeId);
      if (res.success && res.stat_blocks.length > 0) {
        select.innerHTML = res.stat_blocks.map(sb => {
          const defaultTag = sb.is_default ? ' (default)' : '';
          return `<option value="${sb.id}">${sb.name} — ${sb.block_type}${defaultTag}</option>`;
        }).join('');

        // Auto-select the activity's saved stat_block_id, or the default
        const savedId = this.statBlockId;
        if (savedId && res.stat_blocks.some(sb => sb.id === parseInt(savedId))) {
          select.value = savedId;
        } else {
          const defaultBlock = res.stat_blocks.find(sb => sb.is_default) || res.stat_blocks[0];
          select.value = defaultBlock.id;
        }
        this.statBlockId = select.value;
        await this.loadStatsForStatBlock();
      } else {
        select.innerHTML = '<option value="">-- No Stat Blocks --</option>';
        this.statBlockId = null;
        this.cachedStats = [];
      }
    } catch (e) {
      console.error('Failed to load stat blocks:', e);
      select.innerHTML = '<option value="">-- Error loading --</option>';
    }
  }

  async onStatBlockChange() {
    const select = document.getElementById('stat-block-select');
    const newId = select?.value || null;

    // If rounds exist with stat selections, confirm the change
    if (this.rounds.length > 0 && this.statBlockId && newId !== this.statBlockId) {
      const hasStats = this.rounds.some(r =>
        (r.stat_set_a && r.stat_set_a.length > 0) || (r.stat_set_b && r.stat_set_b.length > 0)
      );
      if (hasStats) {
        if (!confirm('Changing the stat block will clear all stat selections on rounds and tasks. Continue?')) {
          select.value = this.statBlockId;
          return;
        }
        try {
          await this.api.clearStatSelections();
          const roundsRes = await this.api.getRounds();
          if (roundsRes.success) {
            this.rounds = roundsRes.rounds || [];
            this.renderer.render(this.rounds);
          }
        } catch (e) {
          console.error('Failed to clear stat selections:', e);
          this.showError('Failed to clear stat selections');
          return;
        }
      }
    }

    this.statBlockId = newId;
    await this.loadStatsForStatBlock();

    // Auto-save stat_block_id so it persists even if user doesn't click Save
    try {
      await this.api.updateActivity({ stat_block_id: newId });
    } catch (e) {
      console.error('Failed to save stat block selection:', e);
    }
  }

  // ============================================
  // Type Visibility
  // ============================================

  updateTypeVisibility() {
    const type = document.getElementById('activity-type')?.value || 'mission';
    const launchMode = document.getElementById('launch-mode')?.value || 'creator';

    const isCompetition = ['competition', 'tcompetition', 'elimination'].includes(type);
    const isTeam = type === 'tcompetition';
    const isTask = type === 'task';

    const anchorSection = document.getElementById('anchor-section');
    const taskTriggerSection = document.getElementById('task-trigger-section');
    const teamsSection = document.getElementById('teams-section');

    if (anchorSection) {
      anchorSection.style.display = isCompetition && launchMode === 'anchor' ? 'block' : 'none';
    }
    if (taskTriggerSection) {
      taskTriggerSection.style.display = isTask ? 'block' : 'none';
    }
    if (teamsSection) {
      teamsSection.style.display = isTeam ? 'block' : 'none';
    }
  }

  // ============================================
  // Activity CRUD
  // ============================================

  async createActivity() {
    const form = document.getElementById('activity-form');
    if (!form) return;

    const formData = new FormData(form);
    const data = Object.fromEntries(formData.entries());
    data.description = this.descriptionEditors.activity?.getContent() || data.description || '';

    try {
      await this.api.createActivity(data);
    } catch (err) {
      console.error('Failed to create activity:', err);
      this.showError('Failed to create activity');
    }
  }

  async saveActivity() {
    const form = document.getElementById('activity-form');
    if (!form) return;

    const formData = new FormData(form);
    const data = {
      name: formData.get('name'),
      description: this.descriptionEditors.activity?.getContent() || formData.get('description'),
      type: formData.get('type'),
      launch_mode: document.getElementById('launch-mode')?.value,
      location_id: document.getElementById('location-room-value')?.value || null,
      anchor_item_pattern_id: document.getElementById('anchor-pattern')?.value || null,
      task_trigger_room_id: document.getElementById('trigger-room-value')?.value || null,
      task_auto_start: document.getElementById('task_auto_start')?.checked,
      team_name_one: document.querySelector('[name="team_name_one"]')?.value,
      team_name_two: document.querySelector('[name="team_name_two"]')?.value,
      universe_id: document.getElementById('universe-select')?.value || null,
      stat_block_id: document.getElementById('stat-block-select')?.value || null
    };

    try {
      const response = await this.api.updateActivity(data);
      if (response.success) {
        this.showSuccess('Activity saved');
      }
    } catch (err) {
      console.error('Failed to save activity:', err);
      this.showError('Failed to save activity');
    }
  }

  // ============================================
  // Round CRUD
  // ============================================

  async addRound(roundType) {
    if (!this.activityId) {
      this.showError('Please create the activity first');
      return;
    }

    const lastRound = this.rounds[this.rounds.length - 1];
    const canvasX = lastRound ? lastRound.canvas_x + 200 : 100;
    const canvasY = lastRound ? lastRound.canvas_y : 80;

    try {
      const response = await this.api.createRound({
        round_type: roundType,
        emit: '',
        canvas_x: canvasX,
        canvas_y: canvasY
      });

      if (response.success) {
        this.rounds.push(response.round);
        this.renderer.render(this.rounds);
        this.updateEmptyState();
        this.openRoundModal(response.round);
      }
    } catch (err) {
      console.error('Failed to add round:', err);
      this.showError('Failed to add round');
    }
  }

  async saveRoundPosition(roundId, x, y) {
    try {
      await this.api.updateRound(roundId, { canvas_x: x, canvas_y: y });
    } catch (err) {
      console.error('Failed to save position:', err);
    }
  }

  async deleteRound() {
    if (!this.selectedRound) return;
    if (!confirm(`Delete ${this.selectedRound.display_name}?`)) return;

    try {
      const response = await this.api.deleteRound(this.selectedRound.id);
      if (response.success) {
        this.rounds = this.rounds.filter(r => r.id !== this.selectedRound.id);
        this.renderer.render(this.rounds);
        this.selectedRound = null;
        this.updateEmptyState();
        this.closeRoundModal();
        this.showSuccess('Round deleted');
      }
    } catch (err) {
      console.error('Failed to delete round:', err);
      this.showError('Failed to delete round');
    }
  }

  async deleteRoundDirect(round) {
    const label = round.name || round.display_name || `Round ${round.round_number}`;
    if (!confirm(`Delete "${label}"?`)) return;

    try {
      const response = await this.api.deleteRound(round.id);
      if (response.success) {
        this.rounds = this.rounds.filter(r => r.id !== round.id);
        this.renderer.render(this.rounds);
        if (this.selectedRound && this.selectedRound.id === round.id) {
          this.selectedRound = null;
        }
        this.updateEmptyState();
        this.showSuccess('Round deleted');
      }
    } catch (err) {
      console.error('Failed to delete round:', err);
      this.showError('Failed to delete round');
    }
  }

  // ============================================
  // Round Config Modal
  // ============================================

  bindModalHandlers() {
    // Save round button in modal
    document.getElementById('modal-save-round-btn')?.addEventListener('click', () => this.saveRoundFromModal());
    // Delete round button in modal
    document.getElementById('modal-delete-round-btn')?.addEventListener('click', () => this.deleteRound());
    // Tab switching
    document.querySelectorAll('.round-modal-tab').forEach(tab => {
      tab.addEventListener('click', (e) => {
        e.preventDefault();
        this.switchModalTab(tab.dataset.tab);
      });
    });
    // Round type change in modal
    document.getElementById('modal-round-type')?.addEventListener('change', () => this.updateModalTypeConfig());
    // Use activity room toggle in modal
    document.getElementById('modal-use-activity-room')?.addEventListener('change', (e) => {
      const customRoom = document.getElementById('modal-custom-room-container');
      if (customRoom) customRoom.style.display = e.target.checked ? 'none' : 'block';
    });
    // Failure consequence change
    document.getElementById('modal-fail-con')?.addEventListener('change', () => this.updateFailConVisibility());
    // Select NPCs button in modal
    document.getElementById('modal-select-npcs-btn')?.addEventListener('click', () => this.openNpcSelector());
    // Add task button
    document.getElementById('modal-add-task-btn')?.addEventListener('click', () => this.addTask());
    // Add action button
    document.getElementById('modal-add-action-btn')?.addEventListener('click', () => this.addAction());
    // Action editor save button
    document.getElementById('action-editor-save-btn')?.addEventListener('click', () => this.saveActionFromEditor());
    // Add branch choice button
    document.getElementById('modal-add-branch-btn')?.addEventListener('click', () => this.addBranchChoice());
  }

  openRoundModal(round) {
    this.selectedRound = round;
    this.renderer.selectNode(round.id);

    const modal = document.getElementById('roundConfigModal');
    if (!modal) return;

    // Populate modal fields
    this.populateModal(round);

    // Show modal
    modal.showModal();
  }

  closeRoundModal() {
    const modal = document.getElementById('roundConfigModal');
    if (modal?.close) modal.close();
  }

  populateModal(round) {
    const typeStyles = {
      standard: { color: '#4a90d9', icon: 'play-circle' },
      combat: { color: '#ef4444', icon: 'sword' },
      branch: { color: '#8b5cf6', icon: 'signpost-split' },
      mysterybranch: { color: '#8b5cf6', icon: 'search' },
      reflex: { color: '#f59e0b', icon: 'lightning' },
      group_check: { color: '#10b981', icon: 'people' },
      free_roll: { color: '#06b6d4', icon: 'dice-6' },
      persuade: { color: '#ec4899', icon: 'chat-heart' },
      rest: { color: '#22c55e', icon: 'cup-hot' },
      break: { color: '#9ca3af', icon: 'pause-circle' }
    };
    const style = typeStyles[round.round_type] || typeStyles.standard;

    // Header icon
    const iconEl = document.getElementById('modal-type-icon');
    if (iconEl) {
      iconEl.style.backgroundColor = style.color;
      iconEl.innerHTML = `<i class="bi bi-${style.icon}"></i>`;
    }

    // Name & Type
    document.getElementById('modal-round-name').value = round.name || '';
    document.getElementById('modal-round-type').value = round.round_type || 'standard';
    document.getElementById('modal-round-id').value = round.id;

    // Messages tab - init description editors
    this.initModalDescriptionEditors(round);

    // Type-specific config
    this.updateModalTypeConfig();
    this.populateTypeConfig(round);

    // Failure tab
    document.getElementById('modal-fail-repeat').checked = round.fail_repeat || false;
    document.getElementById('modal-knockout').checked = round.knockout || false;
    document.getElementById('modal-fail-con').value = round.failure_consequence || 'none';
    this.updateFailConVisibility();
    this.populateFailBranchDropdown(round.fail_branch_to);

    // Room & Media tab
    const useActivityRoom = document.getElementById('modal-use-activity-room');
    if (useActivityRoom) {
      useActivityRoom.checked = round.use_activity_room !== false;
      const customRoom = document.getElementById('modal-custom-room-container');
      if (customRoom) customRoom.style.display = round.use_activity_room === false ? 'block' : 'none';
    }
    // Populate modal room pickers
    this.setRoomPickerValue('modal-custom-room-picker', round.round_room_id);
    this.setRoomPickerValue('modal-battle-map-room-picker', round.battle_map_room_id);
    // Load adjacent room exits
    this.loadRoomExits(round.round_room_id);

    document.getElementById('modal-media-url').value = round.media_url || '';
    document.getElementById('modal-media-display').value = round.media_display_mode || 'thin';
    document.getElementById('modal-media-duration').value = round.media_duration_mode || 'round';

    // Show correct tabs for round type
    this.updateModalTabs(round.round_type);
    this.switchModalTab('messages');
  }

  initModalDescriptionEditors(round) {
    // Destroy existing editors
    ['modalEmit', 'modalSuccess', 'modalFailure', 'modalFreeRollContext'].forEach(key => {
      if (this.descriptionEditors[key]) {
        // Simple cleanup - just nullify
        this.descriptionEditors[key] = null;
      }
    });

    // Clear and re-init containers
    const emitContainer = document.getElementById('modal-emit-editor');
    const successContainer = document.getElementById('modal-success-editor');
    const failureContainer = document.getElementById('modal-failure-editor');
    const freeRollContainer = document.getElementById('modal-free-roll-editor');

    if (emitContainer && typeof DescriptionEditor !== 'undefined') {
      emitContainer.innerHTML = '';
      this.descriptionEditors.modalEmit = new DescriptionEditor(emitContainer, {
        placeholder: 'Transition message shown when round starts...',
        maxLength: 5000,
        enableGradients: true
      });
      if (round.emit) this.descriptionEditors.modalEmit.setContent(round.emit);
    }

    if (successContainer && typeof DescriptionEditor !== 'undefined') {
      successContainer.innerHTML = '';
      this.descriptionEditors.modalSuccess = new DescriptionEditor(successContainer, {
        placeholder: 'Message shown on success...',
        maxLength: 5000,
        enableGradients: true
      });
      if (round.success_text) this.descriptionEditors.modalSuccess.setContent(round.success_text);
    }

    if (failureContainer && typeof DescriptionEditor !== 'undefined') {
      failureContainer.innerHTML = '';
      this.descriptionEditors.modalFailure = new DescriptionEditor(failureContainer, {
        placeholder: 'Message shown on failure...',
        maxLength: 5000,
        enableGradients: true
      });
      if (round.failure_text) this.descriptionEditors.modalFailure.setContent(round.failure_text);
    }

    if (freeRollContainer && typeof DescriptionEditor !== 'undefined') {
      freeRollContainer.innerHTML = '';
      this.descriptionEditors.modalFreeRollContext = new DescriptionEditor(freeRollContainer, {
        placeholder: 'Context for the free roll GM...',
        maxLength: 5000,
        enableGradients: true
      });
      if (round.free_roll_context) this.descriptionEditors.modalFreeRollContext.setContent(round.free_roll_context);
    }
  }

  updateModalTabs(roundType) {
    const isBranch = roundType === 'branch' || roundType === 'mysterybranch';

    // Show/hide failure tab (branches don't have failure)
    const failureTab = document.querySelector('.round-modal-tab[data-tab="failure"]');
    if (failureTab) failureTab.style.display = isBranch ? 'none' : '';

    // Show/hide success/failure editors in messages tab
    const successSection = document.getElementById('modal-success-section');
    const failureSection = document.getElementById('modal-failure-section');
    if (successSection) successSection.style.display = isBranch ? 'none' : '';
    if (failureSection) failureSection.style.display = isBranch ? 'none' : '';
  }

  switchModalTab(tabName) {
    // Update tab buttons
    document.querySelectorAll('.round-modal-tab').forEach(tab => {
      tab.classList.toggle('tab-active', tab.dataset.tab === tabName);
    });

    // Update tab content
    document.querySelectorAll('.round-modal-tab-panel').forEach(panel => {
      panel.style.display = panel.dataset.tabPanel === tabName ? 'block' : 'none';
    });
  }

  updateModalTypeConfig() {
    const type = document.getElementById('modal-round-type')?.value || 'standard';

    // Hide all type configs
    document.querySelectorAll('.type-config-section').forEach(el => {
      el.style.display = 'none';
    });

    // Show the right one (mysterybranch shares branch config)
    const configType = type === 'mysterybranch' ? 'branch' : type;
    const configEl = document.getElementById(`type-config-${configType}`);
    if (configEl) configEl.style.display = 'block';

    // Update header icon
    this.updateModalTabs(type);
  }

  populateTypeConfig(round) {
    const type = round.round_type || 'standard';

    // Combat
    if (type === 'combat') {
      const slider = document.getElementById('modal-combat-difficulty');
      const diffMap = { easy: 25, normal: 50, hard: 75, deadly: 100 };
      slider.value = diffMap[round.combat_difficulty] || 50;
      this.updateDifficultyLabel(slider.value);
      document.getElementById('modal-combat-finale').checked = round.combat_is_finale || false;
      this.selectedNpcIds = round.combat_npc_ids || [];
      this.updateNpcPreview();
    }

    // Branch / Mysterybranch
    if (type === 'branch' || type === 'mysterybranch') {
      this.populateBranchChoices(round);
    }

    // Reflex
    if (type === 'reflex') {
      this.populateStatDropdown('modal-reflex-stat', round.reflex_stat_id);
      document.getElementById('modal-timeout-seconds').value = round.timeout_seconds || 120;
    }

    // Persuade
    if (type === 'persuade') {
      this.populatePersuadeStats(round);
      document.getElementById('modal-persuade-dc').value = round.persuade_base_dc || 15;
      document.getElementById('modal-persuade-npc-name').value = round.persuade_npc_name || '';
      document.getElementById('modal-persuade-personality').value = round.persuade_npc_personality || '';
      document.getElementById('modal-persuade-goal').value = round.persuade_goal || '';
    }

    // Group Check
    if (type === 'group_check') {
      document.getElementById('modal-gc-knockout').checked = round.knockout || false;
      document.getElementById('modal-gc-group-actions').checked = round.group_actions || false;
      this.populateRoundStatSets(round, 'gc-stat-set-a', 'gc-stat-set-b', 'gc-stat');
      this.loadTasks(round.id);
      this.loadActions(round.id);
    }

    // Standard
    if (type === 'standard') {
      document.getElementById('modal-std-group-actions').checked = round.group_actions || false;
      this.populateRoundStatSets(round);
      this.loadTasks(round.id);
      this.loadActions(round.id);
    }
  }

  populateRoundStatSets(round, idA = 'round-stat-set-a', idB = 'round-stat-set-b', namePrefix = 'round-stat') {
    const containerA = document.getElementById(idA);
    const containerB = document.getElementById(idB);
    if (!containerA || !containerB) return;

    const setA = round.stat_set_a || [];
    const setB = round.stat_set_b || [];

    containerA.innerHTML = '';
    containerB.innerHTML = '';

    this.cachedStats.forEach(stat => {
      containerA.appendChild(this.createStatChip(stat, setA.includes(stat.id), `${namePrefix}-a`));
      containerB.appendChild(this.createStatChip(stat, setB.includes(stat.id), `${namePrefix}-b`));
    });

    if (this.cachedStats.length === 0) {
      containerA.innerHTML = '<span class="text-xs opacity-40">No stats loaded</span>';
      containerB.innerHTML = '<span class="text-xs opacity-40">No stats loaded</span>';
    }
  }

  createStatChip(stat, selected, group) {
    const label = document.createElement('label');
    label.className = `btn btn-xs ${selected ? 'btn-primary' : 'btn-outline btn-ghost'} stat-chip`;
    label.title = stat.name;
    label.innerHTML = `<input type="checkbox" class="hidden" name="${group}" value="${stat.id}" ${selected ? 'checked' : ''}>${stat.abbreviation}`;
    label.querySelector('input').addEventListener('change', (e) => {
      label.className = `btn btn-xs ${e.target.checked ? 'btn-primary' : 'btn-outline btn-ghost'} stat-chip`;
    });
    return label;
  }

  updateDifficultyLabel(value) {
    const label = document.getElementById('modal-combat-difficulty-label');
    if (!label) return;
    const pct = parseInt(value) || 50;
    let text, cls;
    if (pct <= 25) { text = 'Easy'; cls = 'text-success'; }
    else if (pct <= 50) { text = 'Normal'; cls = 'text-info'; }
    else if (pct <= 75) { text = 'Hard'; cls = 'text-warning'; }
    else { text = 'Deadly'; cls = 'text-error'; }
    label.textContent = text;
    label.className = `font-semibold text-sm ${cls}`;
  }

  populatePersuadeStats(round) {
    const container = document.getElementById('persuade-stat-chips');
    if (!container) return;
    const selected = round.persuade_stat_ids || (round.persuade_stat_id ? [round.persuade_stat_id] : []);
    container.innerHTML = '';
    this.cachedStats.forEach(stat => {
      container.appendChild(this.createStatChip(stat, selected.includes(stat.id), 'persuade-stat'));
    });
    if (this.cachedStats.length === 0) {
      container.innerHTML = '<span class="text-xs opacity-40">No stats loaded</span>';
    }
  }

  populateStatDropdown(selectId, currentValue) {
    const select = document.getElementById(selectId);
    if (!select) return;

    select.innerHTML = '<option value="">-- Select Stat --</option>';
    this.cachedStats.forEach(stat => {
      const opt = document.createElement('option');
      opt.value = stat.id;
      opt.textContent = `${stat.name} (${stat.abbreviation})`;
      if (currentValue && stat.id === currentValue) opt.selected = true;
      select.appendChild(opt);
    });
  }

  populateFailBranchDropdown(currentValue) {
    const select = document.getElementById('modal-fail-branch-to');
    if (!select) return;

    select.innerHTML = '<option value="">-- Select Round --</option>';
    this.rounds.forEach(r => {
      const opt = document.createElement('option');
      opt.value = r.id;
      opt.textContent = r.name || r.display_name || `Round ${r.round_number}`;
      if (currentValue && r.id === currentValue) opt.selected = true;
      select.appendChild(opt);
    });
  }

  updateFailConVisibility() {
    const failCon = document.getElementById('modal-fail-con')?.value;
    const branchContainer = document.getElementById('modal-fail-branch-container');
    if (branchContainer) {
      branchContainer.style.display = failCon === 'branch' ? 'block' : 'none';
    }
  }

  // ============================================
  // Branch Choices
  // ============================================

  populateBranchChoices(round) {
    // Cleanup old branch choice editors
    this.cleanupEditorsByPrefix('branchChoice_');
    const container = document.getElementById('branch-choices-list');
    if (!container) return;
    container.innerHTML = '';

    let choices = round.branch_choices || [];
    // Backwards compat: if no branch_choices JSONB, build from legacy columns
    if (choices.length === 0 && (round.branch_choice_one || round.branch_choice_two)) {
      choices = [];
      if (round.branch_choice_one) choices.push({ text: round.branch_choice_one, branch_to_round_id: round.branch_to });
      if (round.branch_choice_two) choices.push({ text: round.branch_choice_two, branch_to_round_id: null });
    }
    // Ensure at least 2 choices
    while (choices.length < 2) choices.push({ text: '', branch_to_round_id: null });

    choices.forEach((choice, idx) => this.addBranchChoiceRow(container, choice, idx));
  }

  addBranchChoice() {
    const container = document.getElementById('branch-choices-list');
    if (!container) return;
    const idx = container.children.length;
    this.addBranchChoiceRow(container, { text: '', branch_to_round_id: null }, idx);
  }

  addBranchChoiceRow(container, choice, idx) {
    const div = document.createElement('div');
    div.className = 'branch-choice-item';
    const editorId = `branch-choice-editor-${Date.now()}-${idx}`;
    div.innerHTML = `
      <div class="flex items-start gap-2 mb-1">
        <span class="choice-number mt-1">${idx + 1}.</span>
        <div class="flex-1">
          <div id="${editorId}" class="mb-1"></div>
          <select class="select select-bordered select-xs w-full branch-choice-target">
            <option value="">-- Target Round --</option>
            ${this.rounds.map(r => `<option value="${r.id}" ${choice.branch_to_round_id === r.id ? 'selected' : ''}>${r.name || r.display_name || 'Round ' + r.round_number}</option>`).join('')}
          </select>
        </div>
        <button type="button" class="btn btn-xs btn-ghost btn-circle text-error mt-1 branch-choice-remove">
          <i class="bi bi-x-lg"></i>
        </button>
      </div>
    `;
    container.appendChild(div);

    // Init DescriptionEditor for choice text
    const editorKey = `branchChoice_${editorId}`;
    if (typeof DescriptionEditor !== 'undefined') {
      this.descriptionEditors[editorKey] = new DescriptionEditor(`#${editorId}`, {
        placeholder: 'Choice text shown to players...',
        onChange: () => {}
      });
      if (choice.text) this.descriptionEditors[editorKey].setContent(choice.text);
    }
    div.dataset.editorKey = editorKey;

    // Remove handler
    div.querySelector('.branch-choice-remove').addEventListener('click', () => {
      this.descriptionEditors[editorKey]?.destroy?.();
      delete this.descriptionEditors[editorKey];
      div.remove();
    });
  }

  getBranchChoicesFromModal() {
    const items = document.querySelectorAll('#branch-choices-list .branch-choice-item');
    const choices = [];
    items.forEach(item => {
      const editorKey = item.dataset.editorKey;
      const text = this.descriptionEditors[editorKey]?.getContent() || '';
      const target = item.querySelector('.branch-choice-target')?.value || null;
      if (text.trim()) {
        choices.push({ text, branch_to_round_id: target ? parseInt(target) : null });
      }
    });
    return choices;
  }

  // ============================================
  // Actions CRUD
  // ============================================

  async loadActions(roundId) {
    this._actionsLoadingForRound = roundId;
    const isGc = this.selectedRound?.round_type === 'group_check';
    const container = document.getElementById(isGc ? 'gc-actions-list' : 'actions-list');
    if (!container) return;
    container.innerHTML = '<p class="text-sm opacity-60">Loading...</p>';

    try {
      const res = await this.api.getActions(roundId);
      // Ignore stale response if user switched to a different round
      if (this._actionsLoadingForRound !== roundId) return;
      if (res.success) {
        this.currentRoundActions = res.actions || [];
        container.innerHTML = '';
        if (this.currentRoundActions.length === 0) {
          container.innerHTML = '<p class="text-sm opacity-60" id="no-actions-msg">No actions yet</p>';
        } else {
          this.currentRoundActions.forEach(action => this.addActionCard(container, action));
        }
      }
    } catch (e) {
      if (this._actionsLoadingForRound !== roundId) return;
      container.innerHTML = '<p class="text-sm text-error">Failed to load actions</p>';
    }
  }

  async addAction() {
    if (!this.selectedRound) return;
    try {
      const res = await this.api.createAction(this.selectedRound.id, {
        choice_string: 'New Action',
        output_string: '',
        fail_string: ''
      });
      if (res.success) {
        await this.loadActions(this.selectedRound.id);
        // Open the editor for the newly created action
        if (res.action) {
          this.openActionEditor(res.action);
        }
      }
    } catch (e) {
      this.showError('Failed to add action');
    }
  }

  addActionCard(container, action) {
    const div = document.createElement('div');
    div.className = 'flex items-center gap-2 p-2 bg-base-100 rounded mb-1';
    div.dataset.actionId = action.id;

    const taskLabel = action.task_id
      ? `T${(this.currentRoundTasks || []).find(t => t.id === action.task_id)?.task_number || '?'}`
      : '';
    const riskLabel = action.risk_sides ? `d${action.risk_sides}` : '';
    const meta = [taskLabel, action.stat_set_label?.toUpperCase(), riskLabel, action.allowed_roles]
      .filter(Boolean).join(' | ');

    div.innerHTML = `
      <div class="flex-1 min-w-0">
        <div class="text-sm font-medium truncate">${action.choice_string || '<em class="opacity-50">No choice text</em>'}</div>
        ${meta ? `<div class="text-xs opacity-60">${escapeHtml(meta)}</div>` : ''}
      </div>
      <button type="button" class="btn btn-xs btn-ghost action-edit-btn" title="Edit">
        <i class="bi bi-pencil"></i>
      </button>
      <button type="button" class="btn btn-xs btn-ghost action-delete-btn" title="Delete">
        <i class="bi bi-trash text-error"></i>
      </button>
    `;

    div.querySelector('.action-edit-btn').addEventListener('click', () => this.openActionEditor(action));
    div.querySelector('.action-delete-btn').addEventListener('click', async () => {
      if (!confirm('Delete this action?')) return;
      try {
        await this.api.deleteAction(this.selectedRound.id, action.id);
        div.remove();
        if (container.children.length === 0) {
          container.innerHTML = '<p class="text-sm opacity-60">No actions yet</p>';
        }
        this.showSuccess('Action deleted');
      } catch (e) {
        this.showError('Failed to delete action');
      }
    });

    container.appendChild(div);
  }

  // ============================================
  // Action Editor Modal
  // ============================================

  openActionEditor(action) {
    this.editingAction = action;
    document.getElementById('action-editor-id').value = action.id;

    // Initialize or update DescriptionEditors for action fields
    this.initActionEditors(action);

    // Populate task dropdown with description preview
    const taskSelect = document.getElementById('action-editor-task');
    taskSelect.innerHTML = '<option value="">--</option>';
    (this.currentRoundTasks || []).forEach(t => {
      const opt = document.createElement('option');
      opt.value = t.id;
      const stripped = (t.description || '').replace(/<[^>]*>/g, '').trim();
      const preview = stripped.length > 30 ? stripped.substring(0, 30) + '…' : stripped;
      opt.textContent = `Task ${t.task_number}${preview ? ': ' + preview : ''}`;
      if (action.task_id === t.id) opt.selected = true;
      taskSelect.appendChild(opt);
    });

    // Populate stat set dropdown from selected task (or round fallback)
    const statSetSelect = document.getElementById('action-editor-stat-set');
    this.updateActionStatSets(action.task_id, action.stat_set_label || 'a');

    // Update stat sets when task selection changes
    taskSelect.addEventListener('change', () => {
      const selectedTaskId = taskSelect.value ? parseInt(taskSelect.value) : null;
      this.updateActionStatSets(selectedTaskId, statSetSelect.value);
    });
    document.getElementById('action-editor-risk-sides').value = action.risk_sides || '';
    document.getElementById('action-editor-roles').value = action.allowed_roles || '';

    document.getElementById('actionEditorModal').showModal();
  }

  updateActionStatSets(taskId, currentValue) {
    const statSetSelect = document.getElementById('action-editor-stat-set');
    // Find the task to get its stat sets
    const task = taskId ? (this.currentRoundTasks || []).find(t => t.id === taskId) : null;
    // Use task stat sets if available, otherwise fall back to round stat sets
    const source = task || this.selectedRound || {};
    const setANames = (source.stat_set_a || []).map(id => this.cachedStats.find(s => s.id === id)?.abbreviation).filter(Boolean).join(', ');
    const setBNames = (source.stat_set_b || []).map(id => this.cachedStats.find(s => s.id === id)?.abbreviation).filter(Boolean).join(', ');
    statSetSelect.innerHTML = '';
    statSetSelect.appendChild(Object.assign(document.createElement('option'), { value: 'a', textContent: `A${setANames ? ' (' + setANames + ')' : ''}` }));
    statSetSelect.appendChild(Object.assign(document.createElement('option'), { value: 'b', textContent: `B${setBNames ? ' (' + setBNames + ')' : ''}` }));
    statSetSelect.value = currentValue || 'a';
  }

  initActionEditors(action) {
    // Destroy previous instances
    ['actionChoice', 'actionSuccess', 'actionFailure'].forEach(key => {
      if (this.descriptionEditors[key]) {
        this.descriptionEditors[key].destroy?.();
        delete this.descriptionEditors[key];
      }
    });

    // Clear containers
    ['action-editor-choice', 'action-editor-success', 'action-editor-failure'].forEach(id => {
      document.getElementById(id).innerHTML = '';
    });

    // Create new editors (use setContent after construction — DescriptionEditor doesn't support initialContent)
    if (typeof DescriptionEditor !== 'undefined') {
      this.descriptionEditors.actionChoice = new DescriptionEditor('#action-editor-choice', {
        placeholder: 'What players see when choosing this action...',
        onChange: () => {}
      });
      if (action.choice_string) this.descriptionEditors.actionChoice.setContent(action.choice_string);

      this.descriptionEditors.actionSuccess = new DescriptionEditor('#action-editor-success', {
        placeholder: 'Message shown on success...',
        onChange: () => {}
      });
      if (action.output_string) this.descriptionEditors.actionSuccess.setContent(action.output_string);

      this.descriptionEditors.actionFailure = new DescriptionEditor('#action-editor-failure', {
        placeholder: 'Message shown on failure...',
        onChange: () => {}
      });
      if (action.fail_string) this.descriptionEditors.actionFailure.setContent(action.fail_string);
    }
  }

  async saveActionFromEditor() {
    if (!this.editingAction || !this.selectedRound) return;

    const taskIdVal = document.getElementById('action-editor-task').value;
    const riskVal = document.getElementById('action-editor-risk-sides').value;

    const data = {
      choice_string: this.descriptionEditors.actionChoice?.getContent() || '',
      output_string: this.descriptionEditors.actionSuccess?.getContent() || '',
      fail_string: this.descriptionEditors.actionFailure?.getContent() || '',
      task_id: taskIdVal ? parseInt(taskIdVal) : null,
      stat_set_label: document.getElementById('action-editor-stat-set').value,
      risk_sides: riskVal ? parseInt(riskVal) : null,
      allowed_roles: document.getElementById('action-editor-roles').value || null
    };

    try {
      await this.api.updateAction(this.selectedRound.id, this.editingAction.id, data);
      this.showSuccess('Action saved');
      document.getElementById('actionEditorModal').close();
      // Reload action list to reflect changes
      this.loadActions(this.selectedRound.id);
    } catch (e) {
      this.showError('Failed to save action');
    }
  }

  // ============================================
  // Tasks CRUD
  // ============================================

  async loadTasks(roundId, retries = 1) {
    // Cleanup old task description editors
    this.cleanupEditorsByPrefix('taskDesc');
    this.currentRoundTasks = [];
    this._tasksLoading = true;
    this._tasksLoadingForRound = roundId;
    const isGc = this.selectedRound?.round_type === 'group_check';
    const container = document.getElementById(isGc ? 'gc-tasks-container' : 'tasks-container');
    if (!container) { this._tasksLoading = false; return; }

    try {
      const res = await this.api.getTasks(roundId);
      // Ignore stale response if user switched to a different round
      if (this._tasksLoadingForRound !== roundId) return;
      if (res.success) {
        this.currentRoundTasks = res.tasks || [];
        container.innerHTML = '';
        if (this.currentRoundTasks.length === 0) {
          container.innerHTML = '<p class="text-sm opacity-60" id="no-tasks-msg">No tasks (actions use legacy stats)</p>';
        } else {
          this.currentRoundTasks.forEach(task => this.addTaskCard(container, task));
        }
      }
    } catch (e) {
      if (this._tasksLoadingForRound !== roundId) return;
      if (retries > 0) {
        await new Promise(r => setTimeout(r, 300));
        return this.loadTasks(roundId, retries - 1);
      }
      container.innerHTML = '<p class="text-sm text-error">Failed to load tasks</p>';
    } finally {
      if (this._tasksLoadingForRound === roundId) this._tasksLoading = false;
    }
  }

  async addTask() {
    if (!this.selectedRound) return;
    // Wait for tasks to finish loading if still in progress
    if (this._tasksLoading) {
      await new Promise(r => setTimeout(r, 500));
      if (this._tasksLoading) {
        this.showError('Tasks still loading, please try again');
        return;
      }
    }
    const existing = this.currentRoundTasks || [];
    if (existing.length >= 2) {
      this.showError('Maximum 2 tasks per round');
      return;
    }

    const taskNumber = existing.length + 1;
    try {
      const res = await this.api.createTask(this.selectedRound.id, {
        task_number: taskNumber,
        description: taskNumber === 1 ? 'Primary objective' : 'Secondary objective',
        dc_reduction: 3,
        min_participants: taskNumber === 2 ? 3 : 1,
        stat_set_a: [],
        stat_set_b: []
      });
      if (res.success) {
        await this.loadTasks(this.selectedRound.id);
        this.showSuccess('Task added');
      }
    } catch (e) {
      this.showError(e.message || 'Failed to add task');
    }
  }

  addTaskCard(container, task) {
    const card = document.createElement('div');
    card.className = 'card bg-base-100 shadow-sm mb-2 p-3';
    card.dataset.taskId = task.id;

    // Build stat set pickers
    const statOptionsA = this.buildStatCheckboxes(`task-${task.id}-a`, task.stat_set_a || []);
    const statOptionsB = this.buildStatCheckboxes(`task-${task.id}-b`, task.stat_set_b || []);
    const descEditorId = `task-desc-editor-${task.id}`;

    card.innerHTML = `
      <div class="flex justify-between items-center mb-2">
        <span class="badge badge-sm ${task.task_number === 1 ? 'badge-primary' : 'badge-secondary'}">
          Task ${task.task_number}${task.min_participants > 1 ? ' (min ' + task.min_participants + ' players)' : ''}
        </span>
        <div class="flex gap-1">
          <button type="button" class="btn btn-xs btn-ghost task-save-btn" title="Save"><i class="bi bi-check-lg text-success"></i></button>
          <button type="button" class="btn btn-xs btn-ghost task-delete-btn" title="Delete"><i class="bi bi-trash text-error"></i></button>
        </div>
      </div>
      <div class="form-control mb-2">
        <label class="label py-0"><span class="label-text text-xs">Description</span></label>
        <div id="${descEditorId}"></div>
      </div>
      <div class="grid grid-cols-2 gap-2 mb-2">
        <div>
          <label class="label py-0"><span class="label-text text-xs">Stat Set A</span></label>
          <div class="flex flex-wrap gap-1 task-stats-a">${statOptionsA}</div>
        </div>
        <div>
          <label class="label py-0"><span class="label-text text-xs">Stat Set B (optional)</span></label>
          <div class="flex flex-wrap gap-1 task-stats-b">${statOptionsB}</div>
        </div>
      </div>
      <div class="grid grid-cols-2 gap-2">
        <div class="form-control">
          <label class="label py-0"><span class="label-text text-xs">DC Reduction</span></label>
          <input type="number" class="input input-bordered input-xs w-full task-dc-reduction"
                 value="${task.dc_reduction || 3}" min="0" max="20">
        </div>
        <div class="form-control">
          <label class="label py-0"><span class="label-text text-xs">Min Players</span></label>
          <input type="number" class="input input-bordered input-xs w-full task-min-participants"
                 value="${task.min_participants || 1}" min="1" max="20">
        </div>
      </div>
    `;

    // Append card to DOM first so DescriptionEditor can find its container
    container.appendChild(card);

    // Init DescriptionEditor for task description
    const editorKey = `taskDesc${task.id}`;
    if (typeof DescriptionEditor !== 'undefined') {
      this.descriptionEditors[editorKey] = new DescriptionEditor(`#${descEditorId}`, {
        placeholder: 'Task description shown to players...',
        onChange: () => {}
      });
      if (task.description) this.descriptionEditors[editorKey].setContent(task.description);
    }

    // Save handler
    card.querySelector('.task-save-btn').addEventListener('click', async () => {
      const statsA = this.getCheckedStatIds(card.querySelector('.task-stats-a'));
      const statsB = this.getCheckedStatIds(card.querySelector('.task-stats-b'));
      const desc = this.descriptionEditors[editorKey]?.getContent() || '';
      try {
        await this.api.updateTask(this.selectedRound.id, task.id, {
          description: desc,
          stat_set_a: statsA,
          stat_set_b: statsB.length > 0 ? statsB : null,
          dc_reduction: parseInt(card.querySelector('.task-dc-reduction').value) || 3,
          min_participants: parseInt(card.querySelector('.task-min-participants').value) || 1
        });
        this.showSuccess('Task saved');
      } catch (e) {
        this.showError('Failed to save task');
      }
    });

    // Delete handler
    card.querySelector('.task-delete-btn').addEventListener('click', async () => {
      if (!confirm('Delete this task?')) return;
      // Cleanup editor
      this.descriptionEditors[editorKey]?.destroy?.();
      delete this.descriptionEditors[editorKey];
      try {
        await this.api.deleteTask(this.selectedRound.id, task.id);
        await this.loadTasks(this.selectedRound.id);
        this.showSuccess('Task deleted');
      } catch (e) {
        this.showError('Failed to delete task');
      }
    });
  }

  buildStatCheckboxes(prefix, selectedIds) {
    if (!this.cachedStats || this.cachedStats.length === 0) {
      return '<span class="text-xs opacity-60">Load universe first</span>';
    }
    return this.cachedStats.map(stat => {
      const checked = selectedIds.includes(stat.id) ? 'checked' : '';
      return `<label class="label cursor-pointer gap-1 p-0">
        <input type="checkbox" class="checkbox checkbox-xs stat-checkbox" value="${stat.id}" ${checked}>
        <span class="label-text text-xs">${stat.abbreviation}</span>
      </label>`;
    }).join('');
  }

  getCheckedStatIds(container) {
    if (!container) return [];
    return Array.from(container.querySelectorAll('.stat-checkbox:checked'))
      .map(cb => parseInt(cb.value));
  }

  // ============================================
  // Save Round from Modal
  // ============================================

  async saveRoundFromModal() {
    if (!this.selectedRound) return;

    const roundType = document.getElementById('modal-round-type')?.value || 'standard';

    const data = {
      name: document.getElementById('modal-round-name')?.value || null,
      round_type: roundType,
      emit: this.descriptionEditors.modalEmit?.getContent() || '',
      success_text: this.descriptionEditors.modalSuccess?.getContent() || '',
      failure_text: this.descriptionEditors.modalFailure?.getContent() || '',

      // Room & Media
      use_activity_room: document.getElementById('modal-use-activity-room')?.checked,
      round_room_id: document.getElementById('modal-custom-room-value')?.value || null,
      media_url: document.getElementById('modal-media-url')?.value || null,
      media_display_mode: document.getElementById('modal-media-display')?.value,
      media_duration_mode: document.getElementById('modal-media-duration')?.value,

      // Failure
      fail_repeat: document.getElementById('modal-fail-repeat')?.checked,
      knockout: document.getElementById('modal-knockout')?.checked,
      failure_consequence: document.getElementById('modal-fail-con')?.value || 'none',
      fail_branch_to: document.getElementById('modal-fail-branch-to')?.value || null
    };

    // Type-specific fields
    if (roundType === 'combat') {
      const pct = parseInt(document.getElementById('modal-combat-difficulty')?.value) || 50;
      data.combat_difficulty = pct <= 25 ? 'easy' : pct <= 50 ? 'normal' : pct <= 75 ? 'hard' : 'deadly';
      data.combat_is_finale = document.getElementById('modal-combat-finale')?.checked;
      data.combat_npc_ids = this.selectedNpcIds;
      data.battle_map_room_id = document.getElementById('modal-battle-map-room-value')?.value || null;
    }

    if (roundType === 'branch' || roundType === 'mysterybranch') {
      const choices = this.getBranchChoicesFromModal();
      data.branch_choices = choices;
      // Backwards compat
      data.branch_choice_one = choices[0]?.text || '';
      data.branch_choice_two = choices[1]?.text || '';
      data.branch_to = choices[0]?.branch_to_round_id || null;
    }

    if (roundType === 'reflex') {
      data.reflex_stat_id = document.getElementById('modal-reflex-stat')?.value || null;
      data.timeout_seconds = parseInt(document.getElementById('modal-timeout-seconds')?.value) || 120;
    }

    if (roundType === 'persuade') {
      data.persuade_stat_ids = [...document.querySelectorAll('input[name="persuade-stat"]:checked')].map(c => parseInt(c.value));
      data.persuade_base_dc = parseInt(document.getElementById('modal-persuade-dc')?.value) || 15;
      data.persuade_npc_name = document.getElementById('modal-persuade-npc-name')?.value || '';
      data.persuade_npc_personality = document.getElementById('modal-persuade-personality')?.value || '';
      data.persuade_goal = document.getElementById('modal-persuade-goal')?.value || '';
    }

    if (roundType === 'free_roll') {
      data.free_roll_context = this.descriptionEditors.modalFreeRollContext?.getContent() || '';
    }

    if (roundType === 'group_check') {
      data.knockout = document.getElementById('modal-gc-knockout')?.checked;
      data.group_actions = document.getElementById('modal-gc-group-actions')?.checked;
      data.single_solution = !data.group_actions;
      data.stat_set_a = [...document.querySelectorAll('input[name="gc-stat-a"]:checked')].map(c => parseInt(c.value));
      data.stat_set_b = [...document.querySelectorAll('input[name="gc-stat-b"]:checked')].map(c => parseInt(c.value));
    }

    if (roundType === 'standard') {
      data.group_actions = document.getElementById('modal-std-group-actions')?.checked;
      data.single_solution = !data.group_actions;
      // Collect stat sets from chips
      data.stat_set_a = [...document.querySelectorAll('input[name="round-stat-a"]:checked')].map(c => parseInt(c.value));
      data.stat_set_b = [...document.querySelectorAll('input[name="round-stat-b"]:checked')].map(c => parseInt(c.value));
    }

    try {
      const response = await this.api.updateRound(this.selectedRound.id, data);
      if (response.success) {
        const idx = this.rounds.findIndex(r => r.id === this.selectedRound.id);
        if (idx >= 0) {
          this.rounds[idx] = response.round;
        }
        this.selectedRound = response.round;
        this.renderer.render(this.rounds);
        this.showSuccess('Round saved');
      }
    } catch (err) {
      console.error('Failed to save round:', err);
      this.showError('Failed to save round');
    }
  }

  // ============================================
  // NPC Selector
  // ============================================

  openNpcSelector() {
    document.querySelectorAll('.npc-checkbox').forEach(cb => {
      cb.checked = this.selectedNpcIds.includes(parseInt(cb.value));
    });

    const modal = document.getElementById('npcModal');
    if (modal?.showModal) modal.showModal();
  }

  confirmNpcSelection() {
    this.selectedNpcIds = [];
    document.querySelectorAll('.npc-checkbox:checked').forEach(cb => {
      this.selectedNpcIds.push(parseInt(cb.value));
    });

    this.updateNpcPreview();
    const modal = document.getElementById('npcModal');
    if (modal?.close) modal.close();
  }

  updateNpcPreview() {
    const preview = document.getElementById('modal-npc-preview');
    if (!preview) return;

    if (this.selectedNpcIds.length === 0) {
      preview.innerHTML = '<small class="text-base-content/60">No enemies selected</small>';
    } else {
      const count = this.selectedNpcIds.length;
      preview.innerHTML = `<span class="badge badge-error">${count} enem${count === 1 ? 'y' : 'ies'} selected</span>`;
    }
  }

  // ============================================
  // Utility
  // ============================================

  updateEmptyState() {
    const emptyEl = document.getElementById('canvas-empty');
    if (emptyEl) {
      emptyEl.style.display = this.rounds.length === 0 ? 'flex' : 'none';
    }
  }

  zoom(factor) {
    const svg = document.getElementById('round-canvas');
    if (!svg) return;

    const viewBox = svg.getAttribute('viewBox');
    if (!viewBox) {
      const rect = svg.getBoundingClientRect();
      svg.setAttribute('viewBox', `0 0 ${rect.width} ${rect.height}`);
      return this.zoom(factor);
    }

    const [x, y, w, h] = viewBox.split(' ').map(Number);
    const newW = w / factor;
    const newH = h / factor;
    const newX = x + (w - newW) / 2;
    const newY = y + (h - newH) / 2;

    svg.setAttribute('viewBox', `${newX} ${newY} ${newW} ${newH}`);
  }

  resetZoom() {
    const svg = document.getElementById('round-canvas');
    if (!svg) return;
    const rect = svg.getBoundingClientRect();
    svg.setAttribute('viewBox', `0 0 ${rect.width} ${rect.height}`);
  }

  cleanupEditorsByPrefix(prefix) {
    Object.keys(this.descriptionEditors).forEach(key => {
      if (key.startsWith(prefix)) {
        this.descriptionEditors[key]?.destroy?.();
        delete this.descriptionEditors[key];
      }
    });
  }


  // Toast notifications
  showSuccess(message) { this.showToast(message, 'success'); }
  showError(message) { this.showToast(message, 'error'); }

  showToast(message, type = 'info') {
    const alertClass = {
      success: 'alert-success',
      error: 'alert-error',
      warning: 'alert-warning',
      info: 'alert-info'
    }[type] || 'alert-info';

    const toast = document.createElement('div');
    toast.className = 'alert ' + alertClass + ' shadow-lg';
    toast.innerHTML = `
      <span>${message}</span>
      <button type="button" class="btn btn-sm btn-circle btn-ghost" aria-label="Close">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
        </svg>
      </button>
    `;

    const closeBtn = toast.querySelector('button');
    closeBtn.addEventListener('click', () => {
      toast.classList.add('opacity-0', 'transition-opacity', 'duration-300');
      setTimeout(() => toast.remove(), 300);
    });

    let container = document.querySelector('.toast-container');
    if (!container) {
      container = document.createElement('div');
      container.className = 'toast-container toast toast-end toast-bottom';
      document.body.appendChild(container);
    }

    container.appendChild(toast);

    setTimeout(() => {
      if (toast.parentNode) {
        toast.classList.add('opacity-0', 'transition-opacity', 'duration-300');
        setTimeout(() => toast.remove(), 300);
      }
    }, 5000);
  }
}

// Initialize on page load
document.addEventListener('DOMContentLoaded', () => {
  if (window.activityBuilderConfig) {
    window.activityEditor = new ActivityEditor(window.activityBuilderConfig);
  }
});
