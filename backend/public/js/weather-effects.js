/**
 * WeatherGL — WebGL weather effects for the Firefly webclient.
 *
 * Rain/snow shaders from Map-Shine (RainShaderAdvanced, SnowShaderAdvanced).
 * Fog shader from Map-Shine FogShader. Underwater caustics (UnderwaterGL)
 * using dual-Voronoi interference. All adapted for standalone WebGL.
 *
 * Rain  : 5-layer Voronoi parallax, per-drop lifecycle, curtains, splashes
 * Snow  : 20-layer procedural flakes with wind drift and wobble
 * Fog   : Dual-layer FBM animated mist (Map-Shine FogShader port)
 * Caustics: Dual-Voronoi interference for underwater light patterns
 *
 * Exports: WeatherGL, UnderwaterGL
 */
(function (global) {
  'use strict';

  // ── Vertex shader (shared) ─────────────────────────────────────────────────
  // Full-screen quad; passes normalized [0,1] UVs to fragment shader.
  const VERT_SRC = `
    attribute vec2 aPos;
    varying vec2 vUvs;
    void main() {
      vUvs = aPos * 0.5 + 0.5;
      gl_Position = vec4(aPos, 0.0, 1.0);
    }
  `;

  // ── Shared GLSL utility chunks (from WeatherShaderBase) ───────────────────
  const GLSL_CONSTANTS = `
    const float PI     = 3.141592653589793;
    const float TWOPI  = 6.283185307179586;
    const vec3  BT709  = vec3(0.2126, 0.7152, 0.0722);
  `;

  // Scalar pseudo-random from WeatherShaderBase
  const GLSL_PRNG = `
    float random(in vec2 uv) {
      uv = mod(uv, 1000.0);
      return fract(dot(uv, vec2(5.23, 2.89)
        * fract((2.41 * uv.x + 2.27 * uv.y) * 251.19)) * 551.83);
    }
  `;

  const GLSL_ROTATION = `
    mat2 rot(in float a) {
      float s = sin(a); float c = cos(a);
      return mat2(c, -s, s, c);
    }
  `;

  const GLSL_BRIGHTNESS = `
    float perceivedBrightness(in vec3 c) { return sqrt(dot(BT709, c * c)); }
  `;

  // Voronoi noise — rewritten with nested int loops (no dynamic array indexing)
  // so it compiles cleanly under WebGL1 / GLSL ES 1.00.
  const GLSL_VORONOI = `
    vec3 voronoi(in vec2 uv, in float t, in float zd) {
      vec2 uvi = floor(uv); vec2 uvf = fract(uv);
      vec3 vor = vec3(0.0, 0.0, zd);
      float bestDist2 = zd * zd;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          vec2 uvn = vec2(float(dx), float(dy));
          float rnd = random(uvi + uvn);
          float r1 = 0.5 * sin(TWOPI * rnd + t) + 0.5;
          float r2 = 0.5 * sin(TWOPI * r1  + t) + 0.5;
          vec2 uvr = vec2(r2, r2);
          vec2 diff = uvn + uvr - uvf;
          float dist2 = dot(diff, diff);
          if (dist2 < bestDist2) {
            vor.xy = uvr; vor.z = sqrt(dist2); bestDist2 = dist2;
          }
        }
      }
      return vor;
    }
    vec3 voronoi(in vec3 vuv, in float zd) { return voronoi(vuv.xy, vuv.z, zd); }
  `;

  // ── Rain fragment shader ───────────────────────────────────────────────────
  // Adapted from RainShaderAdvanced (Map-Shine).
  // Perspective note: windDir=[1,0] produces vertical streaks (side-on view).
  // Rain appears to fall from above and streak across the screen at wind angle.
  const RAIN_FRAG = `
    precision mediump float;
    varying vec2  vUvs;
    uniform float time;
    uniform float opacity;
    uniform float intensity;
    uniform float strength;
    uniform vec2  windDir;
    uniform float windStrength;
    uniform float rainDensity;
    uniform float baseResolution;
    uniform float streakLength;
    uniform float splashIntensity;
    uniform float waveMaskIntensity;
    uniform float curtainIntensity;
    uniform vec3  tint;
    uniform float alpha;

    ${GLSL_CONSTANTS}
    ${GLSL_PRNG}
    ${GLSL_ROTATION}
    ${GLSL_BRIGHTNESS}
    ${GLSL_VORONOI}

    // Smooth value noise helper
    float smoothNoise(in vec2 coords) {
      vec2 i = floor(coords); vec2 f = fract(coords);
      float a = random(i);
      float b = random(i + vec2(1.0, 0.0));
      float c = random(i + vec2(0.0, 1.0));
      float d = random(i + vec2(1.0, 1.0));
      vec2 cb = f * f * (3.0 - 2.0 * f);
      return mix(a, b, cb.x) + (c - a) * cb.y * (1.0 - cb.x) + (d - b) * cb.x * cb.y;
    }

    // Worley (cellular) noise for splash/mask patterns
    vec2 random2(in vec2 uv) {
      vec2 uvf = fract(uv * vec2(0.1031, 0.1030));
      uvf += dot(uvf, uvf.yx + 19.19);
      return fract((uvf.x + uvf.y) * uvf);
    }
    float worleyNoise(in vec2 uv, in float scale) {
      vec2 id = floor(uv * scale); vec2 p = fract(uv * scale);
      float minDist = 1.0;
      for (float wy = -1.0; wy <= 1.0; wy++) {
        for (float wx = -1.0; wx <= 1.0; wx++) {
          vec2 nb = vec2(wx, wy);
          float dist = length(nb + random2(id + nb) - p);
          minDist = min(minDist, dist);
        }
      }
      return minDist;
    }

    // Large-scale sweeping rain curtain sheets
    float rainCurtain(in vec2 uv) {
      vec2 cuv = uv * 0.8 - windDir * time * 0.15;
      vec3 cv = voronoi(cuv, time * 0.3, 20.0);
      float cp = 1.0 - smoothstep(0.2, 0.8, cv.z);
      float cvar = random(floor(cuv)) * 0.3 + 0.7;
      float cs = windStrength * windStrength;
      return 1.0 + (cp * cvar * sqrt(cs) * curtainIntensity * 2.0);
    }

    // Softens rain near screen edges for natural falloff
    float atmosphericFade(in vec2 uv) {
      return 1.0 - smoothstep(0.3, 0.7, length(uv - 0.5)) * 0.4;
    }

    // Worley-intersection ground splash particles
    float computeSplashes(in vec2 uv) {
      vec2 s1 = uv * 3.0 - windDir * time * 0.3;
      s1.x += smoothNoise(uv * 1.5 + time * 1.2) * 0.4
             + smoothNoise(uv * 4.0 - time * 1.8) * 0.25;
      s1.y += smoothNoise(uv * 8.0 + time * 2.5) * 0.15
             + sin(uv.x * 8.0 + time * 3.0) * 0.25;
      s1 += vec2(cos(time * 1.5), sin(time * 1.7)) * 0.1;
      float w1 = smoothstep(0.3, 0.8, worleyNoise(s1, 4.0));

      vec2 s2 = uv * 3.2 - windDir * time * 0.26 + vec2(137.5, 249.8);
      s2.x += smoothNoise(uv * 2.0 - time * 1.5) * 0.35
             + smoothNoise(uv * 5.0 + time * 2.0) * 0.2;
      s2.y += smoothNoise(uv * 10.0 - time * 2.8) * 0.12
             + cos(uv.y * 7.0 - time * 2.5) * 0.2;
      s2 += vec2(sin(time * 1.8), cos(time * 1.4)) * 0.15;
      float w2 = smoothstep(0.25, 0.75, worleyNoise(s2, 3.5));

      float splash = w1 * w2;
      splash *= 0.7 + smoothNoise(uv * 20.0 + time * 4.0) * 0.3;

      vec2 muv = uv * 2.5 - windDir * time * 0.16 + vec2(500.0, 500.0);
      float vm = smoothNoise(muv + time * 0.5)
               + smoothNoise(muv * 2.0 - time * 0.7) * 0.5;
      splash *= smoothstep(0.3, 0.7, vm);
      return splash * 0.8;
    }

    // Wavy gaps between curtains for natural variation
    float waveMask(in vec2 uv) {
      vec2 muv = uv * 1.2 - windDir * time * 0.05 + vec2(100.0, 100.0);
      muv.x += smoothNoise(uv * 0.8 + time * 0.3) * 0.3;
      muv.y += smoothNoise(uv * 2.0 - time * 0.5) * 0.15;
      float mp = 1.0 - worleyNoise(muv, 2.5);
      mp = smoothstep(0.2, 0.7, mp);
      return 0.3 + mp * 0.7;
    }

    // One parallax rain layer — Voronoi streaks with per-drop lifecycle.
    // layerDepth: 0=far/high-altitude, 1=near/ground.
    float rainLayer(in vec2 baseUV, in float layerDepth, in float layerOffset) {
      if (rainDensity <= 0.0) return 0.0;

      // Streak angle perpendicular to wind; windDir=[1,0] → vertical streaks.
      float windAngle  = atan(-windDir.y, windDir.x);
      float streakAngle = windAngle + 1.5707963;
      mat2  rm = rot(streakAngle);

      float speed = 0.5 + layerDepth * 1.0;
      vec2 uv = baseUV - windDir * time * 0.4 * speed + windDir * layerOffset;
      vec2 ruv = uv * rm;

      float szScale = 0.7 + layerDepth * 0.6;
      vec2 res = vec2(baseResolution * szScale, (8000.0 / streakLength) * szScale);
      vec2 st = ruv * res;

      // Sparse spawn check per Voronoi cell
      float threshold = clamp(rainDensity * 0.00000055, 0.0, 0.95);
      vec2  cellID  = floor(st);
      float cellRnd = random(cellID + vec2(layerOffset, layerDepth));
      if (cellRnd > threshold) return 0.0;

      vec3  vr      = voronoi(vec3(st, time * 0.5 + layerOffset), 10.0);
      float dropSeed = vr.x + vr.y;
      float szVar    = 0.5 + random(vec2(dropSeed, layerDepth)) * 0.5;

      // Per-drop lifetime with layer-depth variation
      float baseLife = 4.0 - layerDepth * 3.0;
      float lifeVar  = 0.7 + random(cellID + vec2(dropSeed, 0.0)) * 0.6;
      float dropLife = baseLife * lifeVar;
      float tOff     = random(cellID) * dropLife;
      float dropAge  = mod(time * 0.5 + layerOffset + tOff, dropLife) / dropLife;

      // 4-stage lifecycle: fade-in → visible → impact-flash → fade-out
      float lifeAlpha  = smoothstep(0.0, 0.20, dropAge)
                       * (1.0 - smoothstep(0.90, 1.0, dropAge));
      float impactFlash = smoothstep(0.80, 0.85, dropAge)
                        * smoothstep(0.90, 0.85, dropAge) * 0.2;

      float df = perceivedBrightness(vr);
      float ls = strength * (0.7 + layerDepth * 0.3) * szVar;

      // Per-drop edge variation for organic streak tips
      float eSeed  = dropSeed * 1.337;
      float eSharp = 0.25 + random(vec2(eSeed,       layerOffset)) * 0.10;
      float eFall  = 0.85 + random(vec2(eSeed + 1.0, layerDepth))  * 0.30;

      float rain = (1.0 - smoothstep(-df * ls, df * ls + 0.001,
                   1.0 - smoothstep(eSharp, eFall, vr.z))) * intensity;
      float layerAlpha = (0.5 + layerDepth * 1.0) * szVar * lifeAlpha;
      return (rain + impactFlash * intensity) * layerAlpha;
    }

    void main() {
      // 5-layer parallax accumulation
      float totalRain = 0.0;
      totalRain += rainLayer(vUvs, 0.0,  0.0);
      totalRain += rainLayer(vUvs, 0.25, 0.8);
      totalRain += rainLayer(vUvs, 0.5,  1.6);
      totalRain += rainLayer(vUvs, 0.75, 2.4);
      totalRain += rainLayer(vUvs, 1.0,  3.2);
      totalRain /= 5.0;

      // Apply curtain and gap effects
      totalRain *= rainCurtain(vUvs);
      totalRain *= mix(1.0, waveMask(vUvs), clamp(waveMaskIntensity, 0.0, 1.0));

      // Ground splashes (additive)
      totalRain += computeSplashes(vUvs) * splashIntensity;

      // Edge fade
      totalRain *= atmosphericFade(vUvs);

      // Output: tint color with rain-density alpha.
      // Non-rain pixels (totalRain≈0) are fully transparent — no darkening.
      float rainAlpha = clamp(totalRain * 2.5, 0.0, 1.0) * alpha * opacity;
      gl_FragColor = vec4(tint, rainAlpha);
    }
  `;

  // ── Snow fragment shader ───────────────────────────────────────────────────
  // Adapted from SnowShaderAdvanced (Map-Shine).
  // 20 depth layers of procedural snowflakes with wind-drift parallax.
  const SNOW_FRAG = `
    precision mediump float;
    varying vec2  vUvs;
    uniform float time;
    uniform float opacity;
    uniform vec2  windDir;
    uniform float windStrength;
    uniform float snowDensity;
    uniform float driftAmount;
    uniform vec3  tint;
    uniform float alpha;

    ${GLSL_CONSTANTS}

    const mat3 prng = mat3(
      13.323122, 23.5112,  21.71123,
      21.1212,   28.7312,  11.9312,
      21.8112,   14.7212,  61.3934
    );

    // Snowflake density function (from SnowShaderAdvanced)
    float snowFlake(in vec2 uv, in float layer) {
      vec3 sb = vec3(floor(uv), 31.189 + layer);
      vec3 m  = floor(sb) / 10000.0 + fract(sb);
      vec3 mp = (31415.9 + m) / fract(prng * m);
      vec3 r  = fract(mp);
      vec2 s  = abs(fract(uv) + 0.9 * r.xy - 0.95)
              + 0.01 * abs(2.0 * fract(10.0 * uv.yx) - 1.0);
      float d = 0.6 * (s.x + s.y) + max(s.x, s.y) - 0.01;
      float e = 0.005 + 0.05 * min(0.5 * abs(layer - 5.0 - sin(time * 0.1)), 1.0);
      return smoothstep(e * 2.0, -e * 2.0, d) * r.x / (0.5 + layer * 0.015);
    }

    void main() {
      float acc = 0.0;
      for (int i = 5; i < 25; i++) {
        float f = float(i);
        float depthFactor = (f - 5.0) / 20.0;
        vec2 suv = vUvs * (1.0 + f * 1.5);

        // Wind drift — closer layers move faster (parallax)
        suv += windDir * time * driftAmount * (0.5 + depthFactor * 0.5) * 0.8;

        // Turbulent wobble (intensity scales with windStrength)
        suv.x += sin(time * 1.5 + f * 0.5 + suv.y * 3.0) * windStrength * 0.02;
        suv.y += cos(time * 1.2 + f * 0.7 + suv.x * 2.5) * windStrength * 0.015;

        acc += snowFlake(suv, f) * snowDensity;
      }

      // Transparent background — only snowflake pixels contribute alpha.
      float snowAlpha = clamp(acc * 2.0, 0.0, 1.0) * alpha * opacity;
      gl_FragColor = vec4(tint, snowAlpha);
    }
  `;

  // ── Fog fragment shader ────────────────────────────────────────────────────
  // Ported from Map-Shine FogShader (medium-quality dual-layer FBM).
  // Outputs animated swirling mist as a transparent overlay — only foggy
  // regions are opaque, leaving clear patches fully transparent.
  const FOG_FRAG = `
    precision mediump float;
    varying vec2  vUvs;
    uniform float time;
    uniform float opacity;
    uniform float intensity;
    uniform vec3  tint;
    uniform float alpha;

    // Value noise (same PRNG as WeatherShaderBase)
    float random(in vec2 uv) {
      uv = mod(uv, 1000.0);
      return fract(dot(uv, vec2(5.23, 2.89)
        * fract((2.41 * uv.x + 2.27 * uv.y) * 251.19)) * 551.83);
    }
    float fnoise(in vec2 c) {
      vec2 i = floor(c); vec2 f = fract(c);
      float a = random(i);
      float b = random(i + vec2(1.0, 0.0));
      float d = random(i + vec2(0.0, 1.0));
      float e = random(i + vec2(1.0, 1.0));
      vec2 u = f * f * (3.0 - 2.0 * f);
      return mix(a, b, u.x) + (d - a)*u.y*(1.0 - u.x) + (e - b)*u.x*u.y;
    }
    float fbm(in vec2 uv) {
      float r = 0.0; float scale = 1.0;
      uv += time * 0.03; uv *= 2.0;
      for (int i = 0; i < 4; i++) {
        r += fnoise(uv + time * 0.03) * scale;
        uv *= 3.0; scale *= 0.3;
      }
      return r;
    }

    void main() {
      // Map [0,1] UV to [-1,1] for centered noise patterns
      vec2 uv = vUvs * 2.0 - 1.0;

      // Dual-layer FBM mist (Map-Shine FogShader "medium" mode)
      float mist = 0.0;
      for (int i = 0; i < 2; i++) {
        vec2 mv = vec2(fbm(uv * 4.5 + time * 0.115 + vec2(float(i) * 250.0))) * 0.5;
        mist += fbm(uv * 4.5 + mv - time * 0.0275) * 0.5;
      }

      // Perceived brightness threshold (Map-Shine FogShader pattern)
      const float slope = 0.25;
      vec3 mistColor = vec3(0.9, 0.85, 1.0) * mist * 1.33;
      float pb = sqrt(dot(vec3(0.2126, 0.7152, 0.0722), mistColor * mistColor));
      pb = smoothstep(slope * 0.5, slope + 0.001, pb);

      // Output: transparent where no mist, fog-colored where dense.
      vec3 fogRGB = mix(vec3(0.05, 0.05, 0.08),
                        mistColor * clamp(slope, 1.0, 2.0), pb) * tint;
      float fogAlpha = pb * opacity * intensity * alpha;
      gl_FragColor = vec4(fogRGB, fogAlpha);
    }
  `;

  // ── Underwater caustic fragment shader ────────────────────────────────────
  // Dual-Voronoi interference pattern that mimics sunlight refracted through
  // a wavy water surface. Bright lines appear where the two animated cell
  // patterns have equal distance (constructive interference).
  const UNDERWATER_FRAG = `
    precision mediump float;
    varying vec2  vUvs;
    uniform float time;
    uniform float opacity;
    uniform vec3  tint;
    uniform float alpha;
    // waterLine: 0.0 = full-screen underwater; 0.667 = in-water (bottom third only).
    // Effect fades in below this Y coordinate with a soft 5% feather.
    uniform float waterLine;

    // Gradient-noise hash for animated Voronoi cell centres
    vec2 hash22(in vec2 p) {
      p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
      return -1.0 + 2.0 * fract(sin(p) * 43758.5453);
    }

    // Minimum distance to animated Voronoi cells
    float voronoiDist(in vec2 uv, in float t) {
      vec2 n = floor(uv);
      vec2 f = fract(uv);
      float d = 8.0;
      for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
          vec2 g = vec2(float(i), float(j));
          vec2 o = hash22(n + g);
          // Cells drift gently with time (wave simulation)
          o = 0.5 + 0.5 * sin(t + 6.2831 * o);
          d = min(d, length(g + o - f));
        }
      }
      return d;
    }

    void main() {
      // Two Voronoi layers at the same scale but offset position.
      // Bright caustic lines appear where abs(d1-d2) ≈ 0.
      float d1 = voronoiDist(vUvs * 3.0,                    time * 0.5);
      float d2 = voronoiDist(vUvs * 3.0 + vec2(0.47, 0.31), time * 0.5 + 0.7);
      float caustic = 1.0 - smoothstep(0.0, 0.25, abs(d1 - d2));
      caustic = pow(caustic, 1.5);  // narrow the bright lines

      // Ray brightness peaks at the water surface and dims with depth.
      // In in-water mode (waterLine > 0) the surface is at waterLine, not the top.
      float rayStart = mix(0.0, waterLine, step(0.01, waterLine));
      float rayFade  = mix(1.0, 0.35,
                           clamp((vUvs.y - rayStart) / max(1.0 - rayStart, 0.001), 0.0, 1.0));

      // Soft mask: transparent above waterLine, fades in over 5% of screen height.
      // When waterLine = 0 the mask is always 1 (full-screen mode).
      float mask = mix(1.0, smoothstep(waterLine - 0.05, waterLine + 0.05, vUvs.y),
                       step(0.01, waterLine));

      float causticAlpha = caustic * rayFade * mask * opacity * alpha;
      gl_FragColor = vec4(tint, causticAlpha);
    }
  `;

  // ── WeatherGL class ────────────────────────────────────────────────────────

  class WeatherGL {
    constructor(canvas) {
      this.canvas = canvas;
      this.gl = null;
      this.programs = {};
      this.animFrame = null;
      this.startTime = null;
      this._buf = null;
      this._activeProg = null;
      this._activeUniforms = null;
      this._init();
    }

    // ── Setup ──────────────────────────────────────────────────────────────

    _init() {
      const opts = { alpha: true, premultipliedAlpha: false, depth: false, stencil: false };
      const gl = this.canvas.getContext('webgl', opts);
      if (!gl) { console.warn('[WeatherGL] WebGL not available'); return; }
      this.gl = gl;

      gl.enable(gl.BLEND);
      gl.blendFuncSeparate(
        gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA,
        gl.ONE,       gl.ONE_MINUS_SRC_ALPHA
      );

      // Full-screen triangle-strip quad
      const verts = new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]);
      this._buf = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, this._buf);
      gl.bufferData(gl.ARRAY_BUFFER, verts, gl.STATIC_DRAW);

      this.programs.rain = this._compile(VERT_SRC, RAIN_FRAG);
      this.programs.snow = this._compile(VERT_SRC, SNOW_FRAG);
      this.programs.fog  = this._compile(VERT_SRC, FOG_FRAG);
    }

    _compile(vertSrc, fragSrc) {
      const gl = this.gl;
      const vs = this._shader(gl.VERTEX_SHADER,   vertSrc);
      const fs = this._shader(gl.FRAGMENT_SHADER, fragSrc);
      if (!vs || !fs) return null;

      const prog = gl.createProgram();
      gl.attachShader(prog, vs);
      gl.attachShader(prog, fs);
      gl.linkProgram(prog);
      if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
        console.error('[WeatherGL] Link error:', gl.getProgramInfoLog(prog));
        return null;
      }
      gl.deleteShader(vs);
      gl.deleteShader(fs);

      const info = { prog, locs: {}, aPos: gl.getAttribLocation(prog, 'aPos') };
      const n = gl.getProgramParameter(prog, gl.ACTIVE_UNIFORMS);
      for (let i = 0; i < n; i++) {
        const u = gl.getActiveUniform(prog, i);
        info.locs[u.name] = gl.getUniformLocation(prog, u.name);
      }
      return info;
    }

    _shader(type, src) {
      const gl = this.gl;
      const s = gl.createShader(type);
      gl.shaderSource(s, src);
      gl.compileShader(s);
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
        console.error('[WeatherGL] Shader compile error:', gl.getShaderInfoLog(s));
        gl.deleteShader(s);
        return null;
      }
      return s;
    }

    // ── Rendering ──────────────────────────────────────────────────────────

    _resize() {
      const { canvas, gl } = this;
      const w = window.innerWidth, h = window.innerHeight;
      if (canvas.width !== w || canvas.height !== h) {
        canvas.width  = w;
        canvas.height = h;
      }
      gl.viewport(0, 0, w, h);
    }

    _applyUniforms(progInfo, uniforms) {
      const { gl } = this;
      const locs = progInfo.locs;
      // Inject current time
      uniforms.time = (performance.now() - this.startTime) / 1000;
      for (const [k, v] of Object.entries(uniforms)) {
        const loc = locs[k];
        if (loc == null) continue;
        if (typeof v === 'number')    gl.uniform1f(loc, v);
        else if (v.length === 2)      gl.uniform2fv(loc, v);
        else if (v.length === 3)      gl.uniform3fv(loc, v);
      }
    }

    _drawFrame() {
      const { gl } = this;
      if (!gl || !this._activeProg) return;
      this._resize();
      gl.clearColor(0, 0, 0, 0);
      gl.clear(gl.COLOR_BUFFER_BIT);
      gl.useProgram(this._activeProg.prog);
      gl.bindBuffer(gl.ARRAY_BUFFER, this._buf);
      gl.enableVertexAttribArray(this._activeProg.aPos);
      gl.vertexAttribPointer(this._activeProg.aPos, 2, gl.FLOAT, false, 0, 0);
      this._applyUniforms(this._activeProg, this._activeUniforms);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    }

    _startLoop() {
      const tick = () => {
        this._drawFrame();
        this.animFrame = requestAnimationFrame(tick);
      };
      this.animFrame = requestAnimationFrame(tick);
    }

    // ── Public API ─────────────────────────────────────────────────────────

    /**
     * Start rain effect.
     * @param {object} opts
     * @param {string}  opts.intensity   'light'|'moderate'|'heavy'|'extreme'
     * @param {boolean} opts.windEnabled  true = angled storm rain
     * @param {number[]} opts.windDir    override [x,y] wind vector
     */
    startRain(opts = {}) {
      if (!this.gl) return;
      const intensity = opts.intensity || 'moderate';

      // windDir x-component controls streak angle in side-on view.
      // [1,0] → vertical streaks; larger x → more diagonal.
      const windX  = opts.windEnabled ? 0.65 : 0.3;
      const windDir = opts.windDir || [windX, 0.0];

      const densityMap = { light: 800, moderate: 2800, heavy: 7500, extreme: 20000 };
      const opacityMap = { light: 0.40, moderate: 0.60, heavy: 0.80, extreme: 1.0 };

      this.stop();
      this.startTime = performance.now();
      this._activeProg = this.programs.rain;
      this._activeUniforms = {
        time:              0,
        opacity:           opacityMap[intensity] ?? 0.60,
        intensity:         1.2,
        strength:          0.8,
        windDir:           windDir,
        windStrength:      Math.hypot(windDir[0], windDir[1]),
        rainDensity:       densityMap[intensity] ?? 2800,
        baseResolution:    3200,
        streakLength:      80,
        splashIntensity:   intensity === 'light' ? 0.15 : 0.45,
        waveMaskIntensity: 0.7,
        curtainIntensity:  intensity === 'extreme' ? 0.8 : intensity === 'heavy' ? 0.6 : 0.4,
        tint:              [0.72, 0.82, 1.0],
        alpha:             1.0,
      };
      this._startLoop();
    }

    /**
     * Start snow effect.
     * @param {object} opts
     * @param {string}  opts.intensity 'light'|'moderate'|'heavy'|'extreme'
     */
    startSnow(opts = {}) {
      if (!this.gl) return;
      const intensity = opts.intensity || 'moderate';
      const windDir   = opts.windDir || [0.3, 0.1];

      const densityMap = { light: 0.35, moderate: 0.75, heavy: 1.4, extreme: 2.4 };
      const opacityMap = { light: 0.45, moderate: 0.65, heavy: 0.82, extreme: 1.0 };

      this.stop();
      this.startTime = performance.now();
      this._activeProg = this.programs.snow;
      this._activeUniforms = {
        time:        0,
        opacity:     opacityMap[intensity] ?? 0.65,
        windDir:     windDir,
        windStrength: Math.hypot(windDir[0], windDir[1]),
        snowDensity: densityMap[intensity] ?? 0.75,
        driftAmount: 1.0,
        tint:        [1.0, 1.0, 1.0],
        alpha:       1.0,
      };
      this._startLoop();
    }

    /**
     * Toggle wind on the currently active rain effect (updates windDir live).
     * @param {boolean} windEnabled
     */
    setWind(windEnabled) {
      if (!this._activeUniforms || this._activeProg !== this.programs.rain) return;
      const windX = windEnabled ? 0.65 : 0.3;
      this._activeUniforms.windDir     = [windX, 0.0];
      this._activeUniforms.windStrength = Math.abs(windX);
    }

    /**
     * Update intensity on the currently active effect without restarting.
     * @param {string} intensity 'light'|'moderate'|'heavy'|'extreme'
     */
    setIntensity(intensity) {
      if (!this._activeUniforms) return;
      const opacityMap = { light: 0.40, moderate: 0.60, heavy: 0.80, extreme: 1.0 };
      this._activeUniforms.opacity = opacityMap[intensity] ?? 0.60;
      if (this._activeProg === this.programs.rain) {
        const densityMap = { light: 800, moderate: 2800, heavy: 7500, extreme: 20000 };
        this._activeUniforms.rainDensity    = densityMap[intensity] ?? 2800;
        this._activeUniforms.curtainIntensity =
          intensity === 'extreme' ? 0.8 : intensity === 'heavy' ? 0.6 : 0.4;
      } else if (this._activeProg === this.programs.snow) {
        const densityMap = { light: 0.35, moderate: 0.75, heavy: 1.4, extreme: 2.4 };
        this._activeUniforms.snowDensity = densityMap[intensity] ?? 0.75;
      }
    }

    /**
     * Start animated FBM fog overlay (Map-Shine FogShader port).
     * @param {object} opts
     * @param {string} opts.intensity 'light'|'moderate'|'heavy'|'extreme'
     * @param {string} opts.color     'grey'|'blue'|'green' (tint preset)
     */
    startFog(opts = {}) {
      if (!this.gl) return;
      const intensity = opts.intensity || 'moderate';
      const opacityMap = { light: 0.25, moderate: 0.40, heavy: 0.58, extreme: 0.70 };
      const tintMap = {
        grey:  [0.85, 0.85, 0.90],
        blue:  [0.80, 0.88, 1.00],
        green: [0.80, 0.95, 0.85],
      };
      const tint = tintMap[opts.color] || tintMap.grey;

      this.stop();
      this.startTime = performance.now();
      this._activeProg = this.programs.fog;
      this._activeUniforms = {
        time:      0,
        opacity:   opacityMap[intensity] ?? 0.45,
        intensity: 1.0,
        tint,
        alpha:     1.0,
      };
      this._startLoop();
    }

    /** Stop the current effect and clear the canvas. */
    stop() {
      if (this.animFrame) {
        cancelAnimationFrame(this.animFrame);
        this.animFrame = null;
      }
      this._activeProg     = null;
      this._activeUniforms = null;
      if (this.gl) {
        this.gl.clearColor(0, 0, 0, 0);
        this.gl.clear(this.gl.COLOR_BUFFER_BIT);
      }
    }

    /** Called on window resize. */
    resize() { this._resize(); }
  }

  // ── UnderwaterGL ───────────────────────────────────────────────────────────
  // Standalone WebGL caustic-light renderer for the underwater canvas.
  // Replaces UnderwaterCanvas; keeps the same start/stop/resize API.

  class UnderwaterGL {
    constructor(canvas) {
      this.canvas = canvas;
      this.gl = null;
      this._prog = null;
      this._buf  = null;
      this.animFrame  = null;
      this.startTime  = null;
      this._uniforms  = null;
      this._init();
    }

    _init() {
      const opts = { alpha: true, premultipliedAlpha: false, depth: false, stencil: false };
      const gl = this.canvas.getContext('webgl', opts);
      if (!gl) { console.warn('[UnderwaterGL] WebGL not available'); return; }
      this.gl = gl;
      gl.enable(gl.BLEND);
      gl.blendFuncSeparate(
        gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA,
        gl.ONE,       gl.ONE_MINUS_SRC_ALPHA
      );
      const verts = new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]);
      this._buf = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, this._buf);
      gl.bufferData(gl.ARRAY_BUFFER, verts, gl.STATIC_DRAW);
      this._prog = this._compile(VERT_SRC, UNDERWATER_FRAG);
    }

    _compile(vertSrc, fragSrc) {
      const gl = this.gl;
      const mk = (type, src) => {
        const s = gl.createShader(type);
        gl.shaderSource(s, src); gl.compileShader(s);
        if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
          console.error('[UnderwaterGL] Shader error:', gl.getShaderInfoLog(s));
          gl.deleteShader(s); return null;
        }
        return s;
      };
      const vs = mk(gl.VERTEX_SHADER, vertSrc);
      const fs = mk(gl.FRAGMENT_SHADER, fragSrc);
      if (!vs || !fs) return null;
      const prog = gl.createProgram();
      gl.attachShader(prog, vs); gl.attachShader(prog, fs);
      gl.linkProgram(prog);
      if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
        console.error('[UnderwaterGL] Link error:', gl.getProgramInfoLog(prog));
        return null;
      }
      gl.deleteShader(vs); gl.deleteShader(fs);
      const info = { prog, locs: {}, aPos: gl.getAttribLocation(prog, 'aPos') };
      const n = gl.getProgramParameter(prog, gl.ACTIVE_UNIFORMS);
      for (let i = 0; i < n; i++) {
        const u = gl.getActiveUniform(prog, i);
        info.locs[u.name] = gl.getUniformLocation(prog, u.name);
      }
      return info;
    }

    _resize() {
      const w = window.innerWidth, h = window.innerHeight;
      if (this.canvas.width !== w || this.canvas.height !== h) {
        this.canvas.width = w; this.canvas.height = h;
      }
      this.gl.viewport(0, 0, w, h);
    }

    _draw() {
      const { gl, _prog: p } = this;
      if (!gl || !p) return;
      this._resize();
      gl.clearColor(0, 0, 0, 0);
      gl.clear(gl.COLOR_BUFFER_BIT);
      gl.useProgram(p.prog);
      gl.bindBuffer(gl.ARRAY_BUFFER, this._buf);
      gl.enableVertexAttribArray(p.aPos);
      gl.vertexAttribPointer(p.aPos, 2, gl.FLOAT, false, 0, 0);
      const t = (performance.now() - this.startTime) / 1000;
      const u = this._uniforms;
      const L = p.locs;
      gl.uniform1f(L.time,      t);
      gl.uniform1f(L.opacity,   u.opacity);
      gl.uniform1f(L.alpha,     u.alpha);
      gl.uniform1f(L.waterLine, u.waterLine ?? 0.0);
      gl.uniform3fv(L.tint,     u.tint);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    }

    /** Start full-screen caustic animation (fully submerged). */
    start(intensity = 'moderate') {
      this._startCaustics(intensity, 0.0);
    }

    /**
     * Start in-water caustics — bottom third of screen only, soft fade at the
     * waterline. Use for swimming, bathing, wading rather than full submersion.
     */
    startInWater(intensity = 'moderate') {
      this._startCaustics(intensity, 0.667);
    }

    _startCaustics(intensity, waterLine) {
      if (!this.gl) return;
      const opacityMap = { light: 0.15, moderate: 0.28, heavy: 0.42, extreme: 0.55 };
      this.stop();
      this._resize();
      this.startTime = performance.now();
      this._uniforms = {
        opacity:   opacityMap[intensity] ?? 0.28,
        tint:      [0.40, 0.85, 1.0],   // cyan-blue caustic colour
        alpha:     1.0,
        waterLine,
      };
      const tick = () => {
        this._draw();
        this.animFrame = requestAnimationFrame(tick);
      };
      this.animFrame = requestAnimationFrame(tick);
    }

    /** Stop and clear the canvas. */
    stop() {
      if (this.animFrame) { cancelAnimationFrame(this.animFrame); this.animFrame = null; }
      this._uniforms = null;
      if (this.gl) { this.gl.clearColor(0, 0, 0, 0); this.gl.clear(this.gl.COLOR_BUFFER_BIT); }
    }

    /** Call on window resize. */
    resize() { this._resize(); }

    /** Legacy compatibility — same as stop(). */
    get running() { return this.animFrame !== null; }
  }

  global.WeatherGL    = WeatherGL;
  global.UnderwaterGL = UnderwaterGL;
})(window);
