/**
 * GlobeView - 3D globe renderer using Globe.gl with texture-based terrain
 *
 * Uses a pre-rendered equirectangular PNG texture for terrain instead of
 * individual hex polygons, dramatically improving GPU performance.
 *
 * Key features:
 * - Single texture draw call instead of ~20,000 polygon draw calls
 * - Click detection via lat/lng coordinate calculation
 * - Optional invisible polygon overlay for precise hex selection
 * - City markers and zone overlays
 */
class GlobeView {
  constructor(containerId, options = {}) {
    this.containerId = containerId;
    this.container = document.getElementById(containerId);
    this.globe = null;
    this.hexData = []; // Cached hex data for click detection
    this.cities = [];
    this.zones = [];
    this.onHexClick = options.onHexClick || (() => {});
    this.initialLat = options.initialLat ?? 20;
    this.initialLng = options.initialLng ?? 0;
    this.highlightedHexId = null;
    this.isLoading = false;
    this.useTextureRendering = true; // Enable texture-based rendering

    this.terrainColors = {
      ocean: '#2d5f8a',
      lake: '#4a8ab5',
      coast: '#8a9a8d',
      plain: '#a8b878',
      field: '#c4ba8a',
      forest: '#3a6632',
      hill: '#96a07a',
      mountain: '#8a7d6b',
      desert: '#c8b48a',
      swamp: '#5a6b48',
      urban: '#7a7a7a',
      ice: '#d8e0e4',
      unknown: '#4a4a4a'
    };

    this.init();
  }

  init() {
    if (!this.container) {
      console.error('GlobeView: Container not found:', this.containerId);
      return;
    }

    // Create globe instance with texture-based terrain
    if (typeof Globe === 'undefined') {
      console.error('GlobeView: Globe.gl not loaded — CDN may be unreachable');
      return;
    }
    this.globe = Globe()
      .backgroundColor('#000011')
      .atmosphereColor('#3a7ecf')
      .atmosphereAltitude(0.15)
      .showAtmosphere(true)
      .width(this.container.clientWidth)
      .height(this.container.clientHeight);

    // Use texture for terrain rendering (much faster than polygons)
    if (this.useTextureRendering) {
      const textureUrl = `${window.API_BASE || ''}/terrain_texture.png?t=${Date.now()}`;
      this.globe.globeImageUrl(textureUrl);
      console.log('GlobeView: Using texture-based rendering:', textureUrl);
    } else {
      this.globe.globeImageUrl(null);
    }

    // Configure click detection layer (invisible, just for interaction)
    // We use onGlobeClick instead of polygons for better performance
    this.globe.onGlobeClick((coords) => {
      if (coords && coords.lat !== undefined && coords.lng !== undefined) {
        this.handleGlobeClick(coords.lat, coords.lng);
      }
    });

    // Mount to container
    this.globe(this.container);

    // Handle window resize
    this.resizeHandler = () => {
      if (this.container.classList.contains('globe-thumbnail')) {
        this.globe.width(180).height(180);
      } else {
        this.globe.width(this.container.clientWidth).height(this.container.clientHeight);
      }
    };
    window.addEventListener('resize', this.resizeHandler);

    // Set initial camera position
    this.globe.pointOfView({
      lat: this.initialLat,
      lng: this.initialLng,
      altitude: 2.5
    });

    // Change cursor on globe hover
    this.container.style.cursor = 'grab';

    console.log('GlobeView: Globe.gl initialized with texture rendering');
  }

  /**
   * Handle click on the globe surface
   * Looks up the nearest hex via server API
   */
  async handleGlobeClick(lat, lng) {
    console.log('Globe clicked at:', lat.toFixed(2), lng.toFixed(2));

    try {
      const response = await fetch(`${window.API_BASE || ''}/nearest_hex?lat=${lat}&lng=${lng}`);
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = await response.json();

      if (data.success && data.hex) {
        console.log('Found hex:', data.hex.id, 'terrain:', data.hex.terrain);
        this.onHexClick(data.hex);
      } else {
        // No hex found - use synthetic
        const syntheticHex = {
          id: `synthetic-${lat.toFixed(2)}-${lng.toFixed(2)}`,
          lat: lat,
          lng: lng,
          terrain: 'ocean',
          faceIndex: 0,
          ico_face: 0,
          ico_x: Math.floor(lng + 180),
          ico_y: Math.floor(90 - lat)
        };
        console.log('No hex found, using synthetic:', syntheticHex.id);
        this.onHexClick(syntheticHex);
      }
    } catch (error) {
      console.error('GlobeView: Failed to look up hex:', error);
      // Fall back to synthetic hex on error
      this.onHexClick({
        id: `synthetic-${lat.toFixed(2)}-${lng.toFixed(2)}`,
        lat: lat,
        lng: lng,
        terrain: 'ocean'
      });
    }
  }


  /**
   * Refresh the terrain texture (call after terrain changes)
   */
  async refreshData() {
    if (this.isLoading) return;
    this.isLoading = true;

    try {
      this.showLoading('Refreshing terrain...');

      // Update texture URL with cache-busting timestamp
      if (this.useTextureRendering) {
        const textureUrl = `${window.API_BASE || ''}/terrain_texture.png?t=${Date.now()}`;
        this.globe.globeImageUrl(textureUrl);
        console.log('GlobeView: Texture URL updated:', textureUrl);
      }

      // Reload city markers
      try {
        const citiesRes = await fetch(`${window.API_BASE || ''}/cities`);
        const citiesData = await citiesRes.json();
        if (citiesData.success && citiesData.cities) {
          this.setCities(citiesData.cities);
        }
      } catch (e) {
        console.warn('GlobeView: Failed to refresh cities:', e);
      }
    } catch (error) {
      console.error('GlobeView: Failed to refresh data:', error);
    } finally {
      this.hideLoading();
      this.isLoading = false;
    }
  }

  /**
   * Set hex data (legacy method for compatibility)
   * With texture rendering, this only updates click detection data
   */
  setHexData(hexDataArray) {
    if (!hexDataArray || hexDataArray.length === 0) {
      console.log('GlobeView: No hex data provided');
      return;
    }

    this.hexData = hexDataArray;
    console.log(`GlobeView: Set ${hexDataArray.length} hexes for click detection`);

    // If using polygon mode (fallback), render them
    if (!this.useTextureRendering) {
      this.renderPolygons(hexDataArray);
    }
  }

  /**
   * Fallback: Render hexes as polygons (for comparison/debugging)
   * This is the old slow method - kept for reference
   */
  renderPolygons(hexDataArray) {
    const hexRadius = Math.max(0.8, Math.min(3, 180 / Math.sqrt(hexDataArray.length) * 0.8));

    const polygons = hexDataArray
      .map(hex => this.dbHexToGeoJson(hex, hexRadius))
      .filter(p => p !== null);

    this.globe
      .polygonsData(polygons)
      .polygonGeoJsonGeometry('geometry')
      .polygonCapColor(d => this.getHexColor(d))
      .polygonSideColor(() => 'rgba(0, 0, 0, 0.15)')
      .polygonStrokeColor(() => 'rgba(0, 0, 0, 0.3)')
      .polygonAltitude(0.002)
      .polygonCapCurvatureResolution(3)
      .onPolygonClick((polygon, event, coords) => {
        if (polygon) this.onHexClick(polygon);
      })
      .onPolygonHover(polygon => {
        this.container.style.cursor = polygon ? 'pointer' : 'grab';
      });
  }

  /**
   * Convert a database hex to a GeoJSON polygon (for fallback polygon rendering)
   */
  dbHexToGeoJson(hex, hexRadius = 1.5) {
    const lat = hex.lat;
    const lng = hex.lng;

    if (lat == null || lng == null) return null;

    const vertices = [];
    for (let i = 0; i < 6; i++) {
      const angle = (Math.PI / 3) * i - Math.PI / 6;
      const vLng = lng + hexRadius * Math.cos(angle) / Math.cos(lat * Math.PI / 180);
      const vLat = lat + hexRadius * Math.sin(angle);
      vertices.push([vLng, vLat]);
    }
    vertices.push(vertices[0]);

    return {
      id: hex.id,
      lat: lat,
      lng: lng,
      terrain: hex.terrain || 'ocean',
      geometry: {
        type: 'Polygon',
        coordinates: [vertices]
      }
    };
  }

  getHexColor(hex) {
    if (!hex) return this.terrainColors.ocean;
    const terrain = hex.terrain || 'ocean';
    if (this.highlightedHexId === hex.id) {
      return '#ffcc00';
    }
    return this.terrainColors[terrain] || this.terrainColors.unknown;
  }

  setCities(cities) {
    this.cities = cities;
    this.renderCities();
  }

  setZones(zones) {
    this.zones = zones;
    this.renderZones();
  }

  render() {
    // For texture rendering, just refresh the texture
    if (this.useTextureRendering) {
      const textureUrl = `${window.API_BASE || ''}/terrain_texture.png?t=${Date.now()}`;
      this.globe.globeImageUrl(textureUrl);
    }
  }

  renderCities() {
    this.globe
      .pointsData(this.cities)
      .pointLat(d => d.lat)
      .pointLng(d => d.lng)
      .pointColor(() => '#ff6b6b')
      .pointAltitude(0.02)
      .pointRadius(0.5)
      .pointLabel(d => d.name)
      .onPointClick(d => {
        if (d.location_id) {
          window.location.href = `/admin/city_builder/${d.location_id}`;
        } else {
          alert(`City: ${d.name}\nNo city grid has been built yet.`);
        }
      });
  }

  renderZones() {
    // Zone rendering as polygon outlines (not filled, so texture shows through)
    if (this.zones.length > 0) {
      this.globe
        .pathsData(this.zones)
        .pathPoints(d => d.points || [])
        .pathPointLat(p => p.lat)
        .pathPointLng(p => p.lng)
        .pathColor(() => 'rgba(255, 100, 100, 0.6)')
        .pathStroke(2)
        .pathDashLength(0.01)
        .pathDashGap(0.01);
    }
  }

  shrinkToThumbnail() {
    this.container.classList.add('globe-thumbnail');
    this.globe.width(180).height(180);
    this.globe.controls().enabled = false;
    this.globe.showAtmosphere(false);
  }

  expandToFull() {
    this.container.classList.remove('globe-thumbnail');
    this.globe.width(this.container.clientWidth).height(this.container.clientHeight);
    this.globe.controls().enabled = true;
    this.globe.showAtmosphere(true);
  }

  highlightHex(hexId) {
    this.highlightedHexId = hexId;
    // With texture rendering, we'd need to re-render the texture to show highlights
    // For now, this is a no-op with texture mode
  }

  /**
   * Set granularity level (no-op with texture rendering)
   * Kept for API compatibility with hex-editor.js
   */
  setGranularity(level) {
    // Texture rendering doesn't use granularity levels
    console.log('GlobeView: Granularity level ignored in texture mode:', level);
  }

  showLoading(message = 'Loading...') {
    const el = document.getElementById('globe-loading');
    if (el) {
      const textEl = el.querySelector('div:last-child');
      if (textEl) {
        textEl.textContent = message;
      }
      el.classList.remove('hidden');
    }
  }

  hideLoading() {
    const el = document.getElementById('globe-loading');
    if (el) {
      el.classList.add('hidden');
    }
  }

  destroy() {
    window.removeEventListener('resize', this.resizeHandler);
    this.globe = null;
    this.hexData = [];
    this.container.innerHTML = '';
  }
}
