/**
 * API Client for Room Builder
 * Handles all communication with the backend API
 */
class RoomBuilderAPI {
  constructor(roomId) {
    this.roomId = roomId;
    this.baseUrl = `/admin/room_builder/${roomId}/api`;
  }

  async request(method, endpoint, data = null) {
    const options = {
      method,
      headers: {
        'Content-Type': 'application/json',
      },
    };

    if (data) {
      options.body = JSON.stringify(data);
    }

    const response = await fetch(`${this.baseUrl}${endpoint}`, options);
    const result = await response.json();

    if (!result.success) {
      throw new Error(result.error || 'API request failed');
    }

    return result;
  }

  // Room
  async getRoom() {
    return this.request('GET', '/room');
  }

  async updateRoom(data) {
    return this.request('PUT', '/room', data);
  }

  // Places (Furniture)
  async getPlaces() {
    return this.request('GET', '/places');
  }

  async createPlace(data) {
    return this.request('POST', '/places', data);
  }

  async updatePlace(id, data) {
    return this.request('PUT', `/places/${id}`, data);
  }

  async deletePlace(id) {
    return this.request('DELETE', `/places/${id}`);
  }

  // Decorations
  async getDecorations() {
    return this.request('GET', '/decorations');
  }

  async createDecoration(data) {
    return this.request('POST', '/decorations', data);
  }

  async updateDecoration(id, data) {
    return this.request('PUT', `/decorations/${id}`, data);
  }

  async deleteDecoration(id) {
    return this.request('DELETE', `/decorations/${id}`);
  }

  // Features (Doors/Windows)
  async getFeatures() {
    return this.request('GET', '/features');
  }

  async createFeature(data) {
    return this.request('POST', '/features', data);
  }

  async updateFeature(id, data) {
    return this.request('PUT', `/features/${id}`, data);
  }

  async deleteFeature(id) {
    return this.request('DELETE', `/features/${id}`);
  }

  // Exits
  async getExits() {
    return this.request('GET', '/exits');
  }

  async createExit(data) {
    return this.request('POST', '/exits', data);
  }

  async updateExit(id, data) {
    return this.request('PUT', `/exits/${id}`, data);
  }

  async deleteExit(id) {
    return this.request('DELETE', `/exits/${id}`);
  }

  // Sub-rooms
  async getSubrooms() {
    return this.request('GET', '/subrooms');
  }

  async createSubroom(data) {
    return this.request('POST', '/subrooms', data);
  }

  async deleteSubroom(id) {
    return this.request('DELETE', `/subrooms/${id}`);
  }

  // Catalog
  async getFurnitureCatalog() {
    const response = await fetch('/admin/room_builder/api/catalog/furniture');
    return response.json();
  }
}

// Global instance
window.roomAPI = null;

document.addEventListener('DOMContentLoaded', () => {
  if (window.ROOM_ID) {
    window.roomAPI = new RoomBuilderAPI(window.ROOM_ID);
  }
});
