/**
 * Activity Builder API Client
 * Handles all REST API calls for the activity builder
 */
class ActivityBuilderAPI {
  constructor(activityId) {
    this.activityId = activityId;
    this.baseUrl = activityId ? `/admin/activity_builder/${activityId}` : '/admin/activity_builder';
  }

  // Generic fetch wrapper
  async request(url, options = {}) {
    const method = (options.method || 'GET').toUpperCase();
    const headers = {
      'Content-Type': 'application/json'
    };
    if (method !== 'GET' && method !== 'HEAD') {
      headers['X-CSRF-Token'] = getCsrfToken();
    }
    const defaultOptions = { headers };

    const response = await fetch(url, { ...defaultOptions, ...options });

    if (!response.ok) {
      const error = await response.json().catch(() => ({ error: 'Request failed' }));
      throw new Error(error.error || `HTTP ${response.status}`);
    }

    return response.json();
  }

  // ============================================
  // Activity CRUD
  // ============================================

  async createActivity(data) {
    const formData = new URLSearchParams();
    Object.entries(data).forEach(([key, value]) => {
      if (value !== null && value !== undefined) {
        formData.append(key, value);
      }
    });

    const response = await fetch('/admin/activity_builder', {
      method: 'POST',
      headers: {
        'X-CSRF-Token': getCsrfToken()
      },
      body: formData
    });

    // For form POST, we get a redirect
    if (response.redirected) {
      window.location.href = response.url;
      return { success: true };
    }

    return { success: false };
  }

  async getActivity() {
    return this.request(`${this.baseUrl}/api/activity`);
  }

  async updateActivity(data) {
    return this.request(this.baseUrl, {
      method: 'PUT',
      body: JSON.stringify(data)
    });
  }

  async deleteActivity() {
    return this.request(this.baseUrl, {
      method: 'DELETE'
    });
  }

  // ============================================
  // Rounds CRUD
  // ============================================

  async getRounds() {
    return this.request(`${this.baseUrl}/api/rounds`);
  }

  async createRound(data) {
    return this.request(`${this.baseUrl}/api/rounds`, {
      method: 'POST',
      body: JSON.stringify(data)
    });
  }

  async updateRound(roundId, data) {
    return this.request(`${this.baseUrl}/api/rounds/${roundId}`, {
      method: 'PUT',
      body: JSON.stringify(data)
    });
  }

  async deleteRound(roundId) {
    return this.request(`${this.baseUrl}/api/rounds/${roundId}`, {
      method: 'DELETE'
    });
  }

  async reorderRounds(roundIds) {
    return this.request(`${this.baseUrl}/api/rounds/reorder`, {
      method: 'POST',
      body: JSON.stringify({ round_ids: roundIds })
    });
  }

  // ============================================
  // Tasks CRUD
  // ============================================

  async getTasks(roundId) {
    return this.request(`${this.baseUrl}/api/rounds/${roundId}/tasks`);
  }

  async createTask(roundId, data) {
    return this.request(`${this.baseUrl}/api/rounds/${roundId}/tasks`, {
      method: 'POST',
      body: JSON.stringify(data)
    });
  }

  async updateTask(roundId, taskId, data) {
    return this.request(`${this.baseUrl}/api/rounds/${roundId}/tasks/${taskId}`, {
      method: 'PUT',
      body: JSON.stringify(data)
    });
  }

  async deleteTask(roundId, taskId) {
    return this.request(`${this.baseUrl}/api/rounds/${roundId}/tasks/${taskId}`, {
      method: 'DELETE'
    });
  }

  // ============================================
  // Actions CRUD
  // ============================================

  async getActions(roundId) {
    return this.request(`${this.baseUrl}/api/rounds/${roundId}/actions`);
  }

  async createAction(roundId, data) {
    return this.request(`${this.baseUrl}/api/rounds/${roundId}/actions`, {
      method: 'POST',
      body: JSON.stringify(data)
    });
  }

  async updateAction(roundId, actionId, data) {
    return this.request(`${this.baseUrl}/api/rounds/${roundId}/actions/${actionId}`, {
      method: 'PUT',
      body: JSON.stringify(data)
    });
  }

  async deleteAction(roundId, actionId) {
    return this.request(`${this.baseUrl}/api/rounds/${roundId}/actions/${actionId}`, {
      method: 'DELETE'
    });
  }

  // ============================================
  // Reference Data
  // ============================================

  async getNpcs() {
    return this.request(`${this.baseUrl}/api/npcs`);
  }

  async getSavedLocations() {
    return this.request(`${this.baseUrl}/api/saved_locations`);
  }

  async getUniverses() {
    return this.request(`${this.baseUrl}/api/universes`);
  }

  async getWorlds() {
    return this.request(`${this.baseUrl}/api/worlds`);
  }

  async getLocations(worldId) {
    return this.request(`${this.baseUrl}/api/locations?world_id=${worldId}`);
  }

  async getRooms(locationId) {
    return this.request(`${this.baseUrl}/api/rooms?location_id=${locationId}`);
  }

  async getRoomsFlat(query = '') {
    const url = query
      ? `${this.baseUrl}/api/rooms?q=${encodeURIComponent(query)}`
      : `${this.baseUrl}/api/rooms`;
    return this.request(url);
  }

  async getPatterns(query = '') {
    const url = query
      ? `${this.baseUrl}/api/patterns?q=${encodeURIComponent(query)}`
      : `${this.baseUrl}/api/patterns`;
    return this.request(url);
  }

  async getStats(statBlockId) {
    const url = statBlockId
      ? `${this.baseUrl}/api/stats?stat_block_id=${statBlockId}`
      : `${this.baseUrl}/api/stats`;
    return this.request(url);
  }

  async getStatBlocks(universeId) {
    const url = universeId
      ? `${this.baseUrl}/api/stat_blocks?universe_id=${universeId}`
      : `${this.baseUrl}/api/stat_blocks`;
    return this.request(url);
  }

  async clearStatSelections() {
    return this.request(`${this.baseUrl}/api/clear_stat_selections`, {
      method: 'PUT'
    });
  }
}

// Export for use in other modules
window.ActivityBuilderAPI = ActivityBuilderAPI;
