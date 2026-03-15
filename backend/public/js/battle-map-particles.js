/**
 * BattleMapParticles — Canvas 2D particle overlay for battle maps.
 *
 * Renders falling leaves (and future effects: rain, snow, embers, fireflies)
 * on a transparent canvas that sits above the WebGL effects layer.
 * CSS scaling matches the SVG zoom level.
 *
 * Trigger: foliage_mask_url present on mapData (room has trees confirmed by SAM).
 */
(function () {
  'use strict';

  // ── Constants ──────────────────────────────────────────────────────────

  var QUALITY_OFF  = 0;
  var QUALITY_LOW  = 1;
  var QUALITY_HIGH = 2;

  var FRAME_INTERVAL = 1000 / 30; // ~30 fps

  var EFFECT_DEFAULTS = {
    leaves: {
      spawnRate:    0.15,  // particles/sec at HIGH quality
      spawnRateLow: 0.07   // particles/sec at LOW quality
    }
  };

  // ── Constructor ────────────────────────────────────────────────────────

  function BattleMapParticles(scrollContainer) {
    this.scrollContainer = scrollContainer;
    this.canvas          = null;
    this.ctx             = null;
    this.quality         = QUALITY_HIGH;
    this.running         = false;
    this.animFrameId     = null;
    this.lastFrameTime   = 0;

    this.baseWidth       = 0;
    this.baseHeight      = 0;
    this.zoom            = 1;

    this.textures        = [];   // Array of Image objects (leaf1-6)
    this.loadedCount     = 0;    // Textures successfully loaded
    this.expectedCount   = 6;    // Decremented on load error

    this.particles       = [];   // Fixed pool
    this.effects         = {};   // { type: { enabled, spawnRate, ... } }
    this._spawnAccum     = {};   // Fractional spawn accumulator per effect type

    this._foliageSpawnCDF = null; // Cumulative distribution for foliage-masked spawn
    this._foliageCDFLen   = 0;

    this._tick           = null;
    this._visHandler     = null;
  }

  // ── Prototype ──────────────────────────────────────────────────────────

  var proto = BattleMapParticles.prototype;

  /**
   * init — create Canvas 2D, allocate particle pool, load textures.
   * @param {number} svgWidth   Base width of the SVG (unzoomed pixels).
   * @param {number} svgHeight  Base height of the SVG (unzoomed pixels).
   */
  proto.init = function (svgWidth, svgHeight) {
    this.baseWidth  = svgWidth;
    this.baseHeight = svgHeight;

    // ── Create Canvas 2D overlay ────────────────────────────────────────
    var canvas = document.createElement('canvas');
    canvas.className       = 'battle-map-particles-canvas';
    canvas.width           = svgWidth;
    canvas.height          = svgHeight;
    canvas.style.position  = 'absolute';
    canvas.style.top       = '0';
    canvas.style.left      = '0';
    canvas.style.zIndex    = '3';  // Above WebGL canvas (z-index 2)
    canvas.style.pointerEvents = 'none';
    canvas.style.width     = svgWidth + 'px';
    canvas.style.height    = svgHeight + 'px';

    // Insert after the WebGL canvas
    var webglCanvas = this.scrollContainer.querySelector('.battle-map-effects-canvas');
    if (webglCanvas && webglCanvas.parentNode) {
      webglCanvas.parentNode.insertBefore(canvas, webglCanvas.nextSibling);
    } else {
      this.scrollContainer.appendChild(canvas);
    }
    this.canvas = canvas;
    this.ctx    = canvas.getContext('2d');

    // ── Particle pool (HIGH quality default: 40 slots) ──────────────────
    this._allocPool(40);

    // ── Load leaf sprites ───────────────────────────────────────────────
    this._loadTextures();

    // ── Page Visibility API ─────────────────────────────────────────────
    var self = this;
    this._visHandler = function () {
      if (document.hidden) {
        self.stop();
      } else if (self.quality !== QUALITY_OFF && self.canvas) {
        self.start();
      }
    };
    document.addEventListener('visibilitychange', this._visHandler);
  };

  proto._allocPool = function (size) {
    this.particles = [];
    for (var i = 0; i < size; i++) {
      this.particles.push({ active: false, type: null });
    }
  };

  proto._loadTextures = function () {
    var self = this;
    this.textures      = [];
    this.loadedCount   = 0;
    this.expectedCount = 6;

    for (var i = 1; i <= 6; i++) {
      (function (idx) {
        var img = new Image();
        img.onload = function () {
          self.loadedCount++;
        };
        img.onerror = function () {
          self.expectedCount = Math.max(0, self.expectedCount - 1);
          if (typeof console !== 'undefined' && console.warn) {
            console.warn('[BattleMapParticles] Failed to load leaf' + idx + '.webp');
          }
        };
        img.src = '/images/particles/leaves/leaf' + idx + '.webp';
        self.textures.push(img);
      })(i);
    }
  };

  // ── Transform sync ─────────────────────────────────────────────────────

  /**
   * updateTransform — sync canvas CSS size with SVG zoom.
   * Pixel buffer stays at base resolution; CSS scaling handles zoom.
   */
  proto.updateTransform = function (zoom) {
    this.zoom = zoom;
    if (!this.canvas) return;
    this.canvas.style.width  = (this.baseWidth  * zoom) + 'px';
    this.canvas.style.height = (this.baseHeight * zoom) + 'px';
  };

  // ── Quality ─────────────────────────────────────────────────────────────

  proto.setQuality = function (level) {
    if (typeof level === 'string') {
      switch (level) {
        case 'off':  level = QUALITY_OFF;  break;
        case 'low':  level = QUALITY_LOW;  break;
        case 'high': level = QUALITY_HIGH; break;
        default:     level = QUALITY_OFF;
      }
    }
    this.quality = level;

    if (this.canvas) {
      this.canvas.style.display = (level === QUALITY_OFF) ? 'none' : '';
    }

    if (level === QUALITY_OFF) {
      this.stop();
      this._deactivateAll();
      return;
    }

    // Resize pool for quality level
    var maxP = (level === QUALITY_HIGH) ? 40 : 20;
    if (this.particles.length !== maxP) {
      this._allocPool(maxP);
    }

    if (this.canvas) this.start();
  };

  // ── Effect registry ─────────────────────────────────────────────────────

  /**
   * enableEffect — activate a named particle effect.
   * @param {string} type     Effect name: 'leaves' (future: 'rain', 'snow', 'embers')
   * @param {object} options  Optional overrides for effect parameters
   */
  proto.enableEffect = function (type, options) {
    var defaults = EFFECT_DEFAULTS[type] || {};
    this.effects[type] = Object.assign({}, defaults, options || {}, { enabled: true });
    this._spawnAccum[type] = this._spawnAccum[type] || 0;
  };

  proto.disableEffect = function (type) {
    if (this.effects[type]) {
      this.effects[type].enabled = false;
    }
  };

  /**
   * setFoliageMask — load a foliage mask URL and build a per-column CDF so
   * leaves only spawn above areas that have tree coverage.
   * @param {string} url  Absolute or root-relative path to the mask image.
   */
  proto.setFoliageMask = function (url) {
    if (!url) return;
    var self = this;
    var img = new Image();
    img.crossOrigin = 'anonymous';
    img.onload = function () {
      var oc  = document.createElement('canvas');
      oc.width  = img.width;
      oc.height = img.height;
      var octx = oc.getContext('2d', { willReadFrequently: true }) || oc.getContext('2d');
      octx.drawImage(img, 0, 0);
      var data = octx.getImageData(0, 0, img.width, img.height).data;

      // Sum non-zero (foliage) pixels per x-column
      var weights = new Float32Array(img.width);
      for (var y = 0; y < img.height; y++) {
        for (var x = 0; x < img.width; x++) {
          if (data[(y * img.width + x) * 4] > 50) weights[x] += 1;
        }
      }

      // Build CDF; fall back to uniform if mask is blank
      var total = 0;
      for (var i = 0; i < weights.length; i++) total += weights[i];
      if (total === 0) return;

      var cdf = new Float32Array(img.width);
      var cum = 0;
      for (var i = 0; i < img.width; i++) {
        cum += weights[i] / total;
        cdf[i] = cum;
      }
      self._foliageSpawnCDF = cdf;
      self._foliageCDFLen   = img.width;
    };
    img.onerror = function () {
      if (typeof console !== 'undefined' && console.warn) {
        console.warn('[BattleMapParticles] Failed to load foliage mask for spawn weighting');
      }
    };
    img.src = url;
  };

  proto._sampleFoliageX = function () {
    var cdf = this._foliageSpawnCDF;
    if (!cdf) return Math.random();
    var r  = Math.random();
    var lo = 0, hi = this._foliageCDFLen - 1;
    while (lo < hi) {
      var mid = (lo + hi) >> 1;
      if (cdf[mid] < r) lo = mid + 1; else hi = mid;
    }
    return lo / this._foliageCDFLen;
  };

  // ── Loop ────────────────────────────────────────────────────────────────

  proto.start = function () {
    if (this.running) return;
    if (this.quality === QUALITY_OFF || !this.canvas) return;
    this.running       = true;
    this.lastFrameTime = 0;
    this._tick         = this._frame.bind(this);
    this.animFrameId   = requestAnimationFrame(this._tick);
  };

  proto.stop = function () {
    this.running = false;
    if (this.animFrameId !== null) {
      cancelAnimationFrame(this.animFrameId);
      this.animFrameId = null;
    }
  };

  proto.destroy = function () {
    this.stop();

    if (this._visHandler) {
      document.removeEventListener('visibilitychange', this._visHandler);
      this._visHandler = null;
    }

    if (this.canvas && this.canvas.parentNode) {
      this.canvas.parentNode.removeChild(this.canvas);
    }
    this.canvas    = null;
    this.ctx       = null;
    this.textures  = [];
    this.particles = [];
    this.effects   = {};
  };

  // ── Private helpers ─────────────────────────────────────────────────────

  proto._deactivateAll = function () {
    for (var i = 0; i < this.particles.length; i++) {
      this.particles[i].active = false;
    }
  };

  proto._claimSlot = function () {
    for (var i = 0; i < this.particles.length; i++) {
      if (!this.particles[i].active) return this.particles[i];
    }
    return null;
  };

  proto._spawnLeaf = function () {
    // Wait until at least one texture is ready
    if (this.loadedCount === 0) return;

    var slot = this._claimSlot();
    if (!slot) return;

    var texCount = Math.min(this.loadedCount, this.textures.length);

    slot.active   = true;
    slot.type     = 'leaf';
    slot.x        = this._sampleFoliageX();
    slot.y        = -0.03;
    slot.vx       = 0;
    slot.vy       = 0.025 + Math.random() * 0.025;  // 0.025–0.05 normalized/sec
    slot.phase    = Math.random() * Math.PI * 2;
    slot.rotation = Math.random() * Math.PI * 2;
    slot.rotSpeed = (Math.random() < 0.5 ? 1 : -1) * (1.5 + Math.random() * 2.5); // ±1.5–4.0 rad/s
    slot.alpha    = 0.9;
    slot.age      = 0;
    slot.lifetime = 8 + Math.random() * 5;           // 8–13 seconds
    slot.scale    = 0.012 + Math.random() * 0.010;   // 0.012–0.022 × canvas width
    slot.texIndex = Math.floor(Math.random() * texCount);
  };

  proto._updateLeaf = function (p, dt) {
    p.age += dt;

    // Slight gravity
    p.vy += 0.0005 * dt;

    // Organic sway
    p.vx = Math.sin(p.age * 2.0 + p.phase) * 0.0008;

    p.x += p.vx;
    p.y += p.vy * dt;
    p.rotation += p.rotSpeed * dt;

    // Alpha: linear fade, accelerated in last 15% of lifetime
    var t = p.age / p.lifetime;
    if (t < 0.85) {
      p.alpha = 0.9 * (1 - t / 0.85);
    } else {
      p.alpha = 0.9 * (1 - t) / 0.15 * 0.5;
    }

    // Deactivate when off-screen or expired
    if (p.age >= p.lifetime || p.y > 1.05) {
      p.active = false;
    }
  };

  // ── Render frame ────────────────────────────────────────────────────────

  proto._frame = function (timestamp) {
    if (!this.running) return;

    // Throttle to ~30 fps
    if (this.lastFrameTime && (timestamp - this.lastFrameTime) < FRAME_INTERVAL) {
      this.animFrameId = requestAnimationFrame(this._tick);
      return;
    }

    // Clamp dt to 100ms to avoid spiral on tab return
    var dt = this.lastFrameTime
      ? Math.min((timestamp - this.lastFrameTime) / 1000, 0.1)
      : 0.033;
    this.lastFrameTime = timestamp;

    var canvas = this.canvas;
    var ctx    = this.ctx;
    if (!canvas || !ctx) return;

    ctx.clearRect(0, 0, canvas.width, canvas.height);

    // ── Spawn ────────────────────────────────────────────────────────────
    if (this.effects.leaves && this.effects.leaves.enabled) {
      var eff       = this.effects.leaves;
      var spawnRate = (this.quality === QUALITY_HIGH) ? eff.spawnRate : eff.spawnRateLow;

      this._spawnAccum.leaves = (this._spawnAccum.leaves || 0) + spawnRate * dt;
      var toSpawn = Math.floor(this._spawnAccum.leaves);
      this._spawnAccum.leaves -= toSpawn;
      for (var s = 0; s < toSpawn; s++) this._spawnLeaf();
    }

    // ── Update ───────────────────────────────────────────────────────────
    for (var i = 0; i < this.particles.length; i++) {
      var p = this.particles[i];
      if (!p.active) continue;
      if (p.type === 'leaf') this._updateLeaf(p, dt);
    }

    // ── Render ───────────────────────────────────────────────────────────
    var textures = this.textures;
    for (var j = 0; j < this.particles.length; j++) {
      var p = this.particles[j];
      if (!p.active) continue;

      var tex = textures[p.texIndex];
      if (!tex || !tex.complete || tex.naturalWidth === 0) continue;

      var px   = p.x * canvas.width;
      var py   = p.y * canvas.height;
      var size = p.scale * canvas.width;

      if (this.quality === QUALITY_LOW) {
        // Skip rotation for performance at low quality
        ctx.globalAlpha = p.alpha;
        ctx.drawImage(tex, px - size / 2, py - size / 2, size, size);
      } else {
        ctx.save();
        ctx.globalAlpha = p.alpha;
        ctx.translate(px, py);
        ctx.rotate(p.rotation);
        ctx.drawImage(tex, -size / 2, -size / 2, size, size);
        ctx.restore();
      }
    }

    ctx.globalAlpha = 1.0;

    this.animFrameId = requestAnimationFrame(this._tick);
  };

  // ── Expose quality constants ────────────────────────────────────────────

  BattleMapParticles.QUALITY_OFF  = QUALITY_OFF;
  BattleMapParticles.QUALITY_LOW  = QUALITY_LOW;
  BattleMapParticles.QUALITY_HIGH = QUALITY_HIGH;

  // ── Export ──────────────────────────────────────────────────────────────

  window.BattleMapParticles = BattleMapParticles;

})();
