/**
 * BattleMapCompositor - Shared battle map visual composition for editor + webclient.
 *
 * Composes:
 * - WebGL effects (BattleMapEffects)
 * - Optional particle overlay (BattleMapParticles)
 *
 * It also enforces lighting policy:
 * - client_full: client applies ambient/time-of-day + dynamic effects
 * - server_prelit: server pre-bakes ambient/time-of-day; client adds only animated overlays
 */
(function () {
  'use strict';

  var MODE_CLIENT_FULL = 'client_full';
  var MODE_SERVER_PRELIT = 'server_prelit';

  function toNumber(value, fallback) {
    var n = Number(value);
    return Number.isFinite(n) ? n : fallback;
  }

  function resolveLightingPolicy(mapData) {
    var mode = mapData && (mapData.lighting_mode || mapData.lightingMode);
    var applyClientAmbient;

    if (mapData && typeof mapData.apply_client_ambient === 'boolean') {
      applyClientAmbient = mapData.apply_client_ambient;
    } else if (mapData && typeof mapData.applyClientAmbient === 'boolean') {
      applyClientAmbient = mapData.applyClientAmbient;
    } else {
      applyClientAmbient = mode !== MODE_SERVER_PRELIT;
    }

    return {
      mode: mode || (applyClientAmbient ? MODE_CLIENT_FULL : MODE_SERVER_PRELIT),
      applyClientAmbient: applyClientAmbient
    };
  }

  function normalizeMapData(raw) {
    var data = raw || {};
    var policy = resolveLightingPolicy(data);

    return {
      backgroundUrl: data.background_url || data.backgroundUrl || null,
      waterMaskUrl: data.water_mask_url || data.waterMaskUrl || null,
      foliageMaskUrl: data.foliage_mask_url || data.foliageMaskUrl || null,
      fireMaskUrl: data.fire_mask_url || data.fireMaskUrl || null,
      lightSources: Array.isArray(data.light_sources) ? data.light_sources : (Array.isArray(data.lightSources) ? data.lightSources : []),
      hexes: Array.isArray(data.hexes) ? data.hexes : [],
      timeOfDayHour: data.time_of_day_hour != null ? toNumber(data.time_of_day_hour, null) : (data.timeOfDayHour != null ? toNumber(data.timeOfDayHour, null) : null),
      isOutdoor: !!(data.is_outdoor != null ? data.is_outdoor : data.isOutdoor),
      arenaHeight: toNumber(data.arena_height != null ? data.arena_height : data.arenaHeight, null),
      hexScale: toNumber(data.hex_scale != null ? data.hex_scale : data.hexScale, null),
      lightingMode: policy.mode,
      applyClientAmbient: policy.applyClientAmbient
    };
  }

  function buildFireHexes(hexes) {
    if (!Array.isArray(hexes)) return [];

    return hexes.filter(function (h) {
      var t = h.type || h.hex_type;
      return t === 'fire';
    }).map(function (h) {
      return {
        x: h.x != null ? h.x : h.hex_x,
        y: h.y != null ? h.y : h.hex_y
      };
    }).filter(function (h) {
      return Number.isFinite(Number(h.x)) && Number.isFinite(Number(h.y));
    });
  }

  function BattleMapCompositor(scrollContainer, options) {
    this.scrollContainer = scrollContainer;
    this.options = options || {};

    this.effects = null;
    this.particles = null;
    this.mapData = normalizeMapData({});
    this.quality = this.options.quality || 'high';
  }

  var proto = BattleMapCompositor.prototype;

  /**
   * init - build effects/particles from one map config.
   * @param {Object} config
   * @returns {boolean}
   */
  proto.init = function (config) {
    config = config || {};
    this.destroy();

    this.mapData = normalizeMapData(config.mapData || {});
    this.quality = config.quality || this.quality || 'high';

    if (!window.BattleMapEffects) return false;

    var svgWidth = toNumber(config.svgWidth, 0);
    var svgHeight = toNumber(config.svgHeight, 0);
    var viewBoxYOffset = toNumber(config.viewBoxYOffset, 0);

    var effects = new window.BattleMapEffects(this.scrollContainer);
    var ready = effects.init(svgWidth, svgHeight, viewBoxYOffset);
    if (!ready) {
      effects.destroy();
      return false;
    }

    effects.setQuality(this.quality);

    var hexSize = toNumber(config.hexSize, null);
    if (hexSize == null && this.mapData.hexScale != null) {
      hexSize = this.mapData.hexScale / 2;
    }

    var hexHeight = toNumber(config.hexHeight, null);
    if (hexHeight == null && hexSize != null) {
      hexHeight = hexSize * Math.sqrt(3);
    }

    var totalRows = toNumber(config.totalRows, this.mapData.arenaHeight);
    if (hexSize != null && hexHeight != null && totalRows != null) {
      effects.setHexParams(hexSize, hexHeight, totalRows);
    }

    if (this.mapData.waterMaskUrl) effects.loadWaterMask(this.mapData.waterMaskUrl);
    if (this.mapData.foliageMaskUrl) effects.loadFoliageMask(this.mapData.foliageMaskUrl);
    if (this.mapData.fireMaskUrl) effects.loadFireMask(this.mapData.fireMaskUrl);
    if (this.mapData.backgroundUrl) effects.loadMapImage(this.mapData.backgroundUrl);

    if (this.mapData.lightSources.length > 0) {
      effects.setLightSources(this.mapData.lightSources);
    }

    var fireHexes = buildFireHexes(this.mapData.hexes);
    if (fireHexes.length > 0) {
      effects.setFireHexes(fireHexes);
    }

    effects.setAmbientStrength(this.mapData.applyClientAmbient ? 1.0 : 0.0);

    if (this.mapData.timeOfDayHour != null) {
      effects.setTimeOfDay(this.mapData.timeOfDayHour, this.mapData.isOutdoor);
    }

    if (typeof this.options.enableLighting === 'boolean') {
      effects.setEnableLighting(this.options.enableLighting);
    }
    if (typeof this.options.enableAnimation === 'boolean') {
      effects.setEnableAnimation(this.options.enableAnimation);
    }

    effects.start();
    this.effects = effects;

    if (window.BattleMapParticles) {
      var particles = new window.BattleMapParticles(this.scrollContainer);
      particles.init(svgWidth, svgHeight);
      particles.setQuality(this.quality);

      if (this.mapData.foliageMaskUrl) {
        particles.enableEffect('leaves');
        particles.setFoliageMask(this.mapData.foliageMaskUrl);
      }

      particles.start();
      this.particles = particles;
    }

    return true;
  };

  proto.setQuality = function (quality) {
    this.quality = quality || this.quality;
    if (this.effects) this.effects.setQuality(this.quality);
    if (this.particles) this.particles.setQuality(this.quality);
  };

  proto.setLightingEnabled = function (enabled) {
    if (this.effects) this.effects.setEnableLighting(enabled);
  };

  proto.setAnimationEnabled = function (enabled) {
    if (this.effects) this.effects.setEnableAnimation(enabled);
  };

  proto.setAmbientPolicy = function (applyClientAmbient) {
    this.mapData.applyClientAmbient = !!applyClientAmbient;
    if (!this.effects) return;

    this.effects.setAmbientStrength(this.mapData.applyClientAmbient ? 1.0 : 0.0);

    if (this.mapData.timeOfDayHour != null) {
      this.effects.setTimeOfDay(this.mapData.timeOfDayHour, this.mapData.isOutdoor);
    }
  };

  proto.setTimeOfDay = function (hour, isOutdoor) {
    this.mapData.timeOfDayHour = toNumber(hour, this.mapData.timeOfDayHour);
    this.mapData.isOutdoor = !!isOutdoor;

    if (!this.effects || this.mapData.timeOfDayHour == null) return;

    this.effects.setAmbientStrength(this.mapData.applyClientAmbient ? 1.0 : 0.0);
    this.effects.setTimeOfDay(this.mapData.timeOfDayHour, this.mapData.isOutdoor);
  };

  proto.setMapImage = function (url) {
    this.mapData.backgroundUrl = url;
    if (this.effects && url) {
      this.effects.loadMapImage(url);
    }
  };

  proto.setLightSources = function (sources) {
    this.mapData.lightSources = Array.isArray(sources) ? sources : [];
    if (this.effects) {
      this.effects.setLightSources(this.mapData.lightSources);
    }
  };

  proto.updateTransform = function (zoom) {
    if (this.effects) this.effects.updateTransform(zoom);
    if (this.particles) this.particles.updateTransform(zoom);
  };

  proto.destroy = function () {
    if (this.effects) {
      this.effects.destroy();
      this.effects = null;
    }

    if (this.particles) {
      this.particles.destroy();
      this.particles = null;
    }
  };

  BattleMapCompositor.LIGHTING_MODE_CLIENT_FULL = MODE_CLIENT_FULL;
  BattleMapCompositor.LIGHTING_MODE_SERVER_PRELIT = MODE_SERVER_PRELIT;
  BattleMapCompositor.resolveLightingPolicy = resolveLightingPolicy;

  window.BattleMapCompositor = BattleMapCompositor;
})();
