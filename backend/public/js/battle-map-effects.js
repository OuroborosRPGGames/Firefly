/**
 * BattleMapEffects — WebGL ambient-effects overlay for battle maps.
 *
 * Renders water flow, torch flicker, foliage sway, etc. on a transparent
 * canvas that sits directly on top of the SVG battle map. CSS scaling
 * matches the SVG zoom level so the pixel buffer stays at base resolution.
 */
(function () {
  'use strict';

  // ── Constants ──────────────────────────────────────────────────────────

  const QUALITY_OFF  = 0;
  const QUALITY_LOW  = 1;
  const QUALITY_HIGH = 2;

  const FRAME_INTERVAL = 1000 / 30; // ~30 fps
  const MAX_LIGHTS     = 32;
  const MAX_FIRE_HEXES = 64;

  // ── Shader sources ─────────────────────────────────────────────────────

  const VERT_SRC = [
    'attribute vec2 a_position;',
    'varying vec2 v_uv;',
    'void main() {',
    '  v_uv = vec2(a_position.x * 0.5 + 0.5, 1.0 - (a_position.y * 0.5 + 0.5));',
    '  gl_Position = vec4(a_position, 0.0, 1.0);',
    '}'
  ].join('\n');

  const FRAG_SRC = [
    'precision mediump float;',
    '',
    'varying vec2 v_uv;',
    'uniform float u_time;',
    'uniform int u_quality;',
    '',
    'uniform sampler2D u_waterMask;',
    'uniform sampler2D u_foliageMask;',
    'uniform sampler2D u_fireMask;',
    'uniform sampler2D u_mapImage;',
    'uniform int u_hasWaterMask;',
    'uniform int u_hasFoliageMask;',
    'uniform int u_hasFireMask;',
    'uniform int u_hasMapImage;',
    '',
    '#define MAX_LIGHTS ' + MAX_LIGHTS,
    'uniform vec3  u_lightPositions[MAX_LIGHTS];',
    'uniform vec3  u_lightColors[MAX_LIGHTS];',
    'uniform float u_lightIntensities[MAX_LIGHTS];',
    'uniform int   u_lightTypes[MAX_LIGHTS];',  // 0=organic, 1=electric
    'uniform int   u_lightCount;',
    '',
    '#define MAX_FIRE_HEXES ' + MAX_FIRE_HEXES,
    'uniform vec3 u_fireHexes[MAX_FIRE_HEXES];',
    'uniform int  u_fireCount;',
    '',
    '// Time-of-day lighting',
    'uniform float u_timeOfDay;',     // 0.0-24.0
    'uniform vec3  u_ambientColor;',  // color temperature tint
    'uniform float u_ambientDarkness;', // 0.0 (noon) to 0.7 (midnight)
    '',
    '// Preview mode toggles',
    'uniform int u_enableLighting;',  // 0=off, 1=on
    'uniform int u_enableAnimation;', // 0=off, 1=on
    '',
    '// --- Hash-based gradient noise ---',
    'vec2 hash22(vec2 p) {',
    '  p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));',
    '  return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);',
    '}',
    '',
    'float noise2d(vec2 p) {',
    '  vec2 i = floor(p);',
    '  vec2 f = fract(p);',
    '  vec2 u = f * f * (3.0 - 2.0 * f);',
    '  return mix(mix(dot(hash22(i + vec2(0,0)), f - vec2(0,0)),',
    '                 dot(hash22(i + vec2(1,0)), f - vec2(1,0)), u.x),',
    '             mix(dot(hash22(i + vec2(0,1)), f - vec2(0,1)),',
    '                 dot(hash22(i + vec2(1,1)), f - vec2(1,1)), u.x), u.y);',
    '}',
    '',
    'float fbm(vec2 p) {',
    '  float v = 0.0;',
    '  float a = 0.5;',
    '  for (int i = 0; i < 4; i++) {',
    '    v += a * noise2d(p);',
    '    p *= 2.0;',
    '    a *= 0.5;',
    '  }',
    '  return v;',
    '}',
    '',
    '// --- Token Magic value noise (fire + organic light ripple) ---',
    'float tmRand(vec2 n) {',
    '  return fract(cos(dot(n, vec2(12.9898, 4.1414))) * 43758.5453);',
    '}',
    'float tmNoise(vec2 n) {',
    '  const vec2 d = vec2(0.0, 1.0);',
    '  vec2 b = floor(n);',
    '  vec2 f = smoothstep(vec2(0.0), vec2(1.0), fract(n));',
    '  return mix(mix(tmRand(b),        tmRand(b + d.yx), f.x),',
    '             mix(tmRand(b + d.xy), tmRand(b + d.yy), f.x), f.y);',
    '}',
    'float tmFbm(vec2 n) {',
    '  float total = 0.0, amp = 0.5;',
    '  for (int i = 0; i < 5; i++) {',
    '    total += tmNoise(n) * amp;',
    '    n += n;',
    '    amp *= 0.5;',
    '  }',
    '  return total;',
    '}',
    '',
    '// Oscillating ripple offset — slow sine/cosine wave on ~25s cycle',
    '// Adapted from TokenMagic solarRipples bornedCos/bornedSin',
    'float bornedCos(float mn, float mx) {',
    '  return (mx - mn) * (cos(6.2832 * u_time * 0.04 + 1.0) * 0.5) + mn;',
    '}',
    'float bornedSin(float mn, float mx) {',
    '  return (mx - mn) * (sin(6.2832 * u_time * 0.04 + 1.0) * 0.5) + mn;',
    '}',
    '',
    '// --- Water effect ---',
    'vec4 waterEffect(vec2 uv, float time, int quality) {',
    '  float mask = texture2D(u_waterMask, uv).r;',
    '  if (mask < 0.1) return vec4(0.0);',
    '',
    '  vec2 flowUV = uv * 8.0;',
    '  float flow;',
    '  if (quality == 2) {',
    '    // Oscillating ripple bands sweep across surface every ~25s',
    '    float rox = bornedCos(-0.15, 0.1);',
    '    float roy = bornedSin(-0.25, 0.25);',
    '    flow = fbm(flowUV + vec2(u_time * 0.3 + rox, u_time * 0.15 + roy));',
    '    flow += 0.5 * noise2d(flowUV * 2.0 - vec2(u_time * 0.2, u_time * 0.4));',
    '  } else {',
    '    flow = sin(flowUV.x * 3.0 + time * 0.5) * 0.5;',
    '    flow += sin(flowUV.y * 2.0 + time * 0.3) * 0.3;',
    '  }',
    '',
    '  float shimmer = flow * 0.5 + 0.5;',
    '',
    '  // Specular highlights: bright near-white at peaks, transparent at troughs.',
    '  // Visible on any underlying water color — simulates reflected light.',
    '  float highlight = shimmer * shimmer;',
    '  vec3 waterColor = mix(vec3(0.05, 0.15, 0.35), vec3(0.75, 0.88, 1.0), highlight);',
    '  float alpha = mask * (0.08 + 0.42 * highlight);',
    '  return vec4(waterColor * alpha, alpha);',
    '}',
    '',
    '// --- Light flicker effect ---',
    'vec4 lightEffect(vec2 uv, float time, int quality) {',
    '  vec4 result = vec4(0.0);',
    '',
    '  for (int i = 0; i < MAX_LIGHTS; i++) {',
    '    if (i >= u_lightCount) break;',
    '',
    '    vec3  lpos      = u_lightPositions[i];',
    '    vec3  lcol      = u_lightColors[i];',
    '    float intensity = u_lightIntensities[i];',
    '    int   ltype     = u_lightTypes[i];',  // 0=organic, 1=electric
    '',
    '    vec2  delta  = uv - lpos.xy;',
    '    float dist   = length(delta);',
    '    float radius = lpos.z;',
    '',
    '    if (dist > radius * 2.0) continue;',
    '',
    '    float falloff = 1.0;',
    '    float flicker = 1.0;',
    '    float phase   = float(i) * 7.13;',
    '',
    '    if (ltype == 1) {',
    '      // Electric light: crisp cubic falloff + inner bloom ring + near-zero flicker',
    '      falloff = 1.0 - smoothstep(0.0, radius * 0.9, dist);',
    '      falloff = falloff * falloff * falloff;',
    '      float bloom = smoothstep(0.0, radius * 0.2, dist)',
    '                  * (1.0 - smoothstep(radius * 0.2, radius * 0.6, dist));',
    '      falloff += bloom * 0.25;',
    '      if (quality == 2) {',
    '        flicker = 0.97 + 0.03 * noise2d(vec2(time * 8.0 + phase, float(i)));',
    '      }',
    '    } else {',
    '      // Organic light (torch, candle, gaslamp, fire, magical): FBM boundary ripple',
    '      float ripple = 0.0;',
    '      if (quality == 2) {',
    '        ripple = 0.08 * tmFbm((uv + vec2(float(i) * 0.31)) * 15.0 + time * 0.4);',
    '      }',
    '      float distorted = dist * (1.0 + ripple);',
    '      falloff = 1.0 - smoothstep(0.0, radius, distorted);',
    '      falloff *= falloff;',
    '      if (quality == 2) {',
    '        flicker = 0.85 + 0.15 * tmNoise(vec2(time * 0.8 + phase, float(i) * 1.7));',
    '        flicker *= 0.92 + 0.08 * tmNoise(vec2(time * 0.3 + phase, 0.0));',
    '      }',
    '    }',
    '',
    '    float a = falloff * intensity * flicker * 0.6;',
    '    result += vec4(lcol * a, a);',
    '  }',
    '',
    '  return result;',
    '}',
    '',
    '// --- Foliage sway effect ---',
    'vec4 foliageEffect(vec2 uv, float time, int quality) {',
    '  float mask = texture2D(u_foliageMask, uv).r;',
    '  if (mask < 0.1) return vec4(0.0);',
    '',
    '  float swayX = sin(uv.y * 12.0 + time * 1.2) * 0.003;',
    '  float swayY = cos(uv.x * 10.0 + time * 0.8) * 0.002;',
    '  swayX += noise2d(uv * 15.0 + time * 0.5) * 0.002;',
    '',
    '  float brightness = 0.5 + 0.5 * noise2d(uv * 20.0 + vec2(swayX, swayY) * 50.0 + time * 0.3);',
    '  vec3 leafTint = vec3(0.15, 0.3, 0.1) * brightness;',
    '  float alpha = mask * 0.08;',
    '  return vec4(leafTint * alpha, alpha);',
    '}',
    '',
    '// --- Fire hex effect (fallback when no mask) ---',
    'vec4 fireHexEffect(vec2 uv, float time, int quality) {',
    '  vec4 result = vec4(0.0);',
    '',
    '  // Token Magic color palette (computed once, shared across all hexes)',
    '  const vec3 c1 = vec3(0.1, 0.0, 0.0);',
    '  const vec3 c2 = vec3(0.7, 0.0, 0.0);',
    '  const vec3 c3 = vec3(0.2, 0.0, 0.0);',
    '  const vec3 c4 = vec3(1.0, 0.9, 0.0);',
    '  const vec3 c5 = vec3(0.1);',
    '  const vec3 c6 = vec3(0.9);',
    '  vec2 p = uv * 8.0;',
    '  float q = tmFbm(p - time * 0.1);',
    '  vec2 r = vec2(tmFbm(p + q + time * 0.7 - p.x - p.y),',
    '               tmFbm(p + q - time * 0.4));',
    '  vec3 fireColor = clamp(',
    '    mix(c1, c2, tmFbm(p + r)) + mix(c3, c4, r.x) - mix(c5, c6, r.y),',
    '    0.0, 1.0',
    '  );',
    '',
    '  for (int i = 0; i < MAX_FIRE_HEXES; i++) {',
    '    if (i >= u_fireCount) break;',
    '',
    '    vec3 fhex = u_fireHexes[i];',
    '    vec2 delta = uv - fhex.xy;',
    '    float dist = length(delta);',
    '    float radius = fhex.z;',
    '',
    '    if (dist > radius * 3.0) continue;',
    '',
    '    float glow = 1.0 - smoothstep(0.0, radius * 2.0, dist);',
    '    glow *= glow;',
    '',
    '    float phase = float(i) * 3.17;',
    '    float flicker;',
    '    if (quality == 2) {',
    '      flicker = 0.6 + 0.4 * tmNoise(vec2(time * 5.0 + phase, float(i) * 2.3));',
    '    } else {',
    '      flicker = 0.8 + 0.2 * sin(time * 4.0 + phase);',
    '    }',
    '',
    '    // Edge darkening toward red',
    '    vec3 edgeColor = mix(fireColor, vec3(0.8, 0.1, 0.0),',
    '                         smoothstep(radius * 0.5, radius * 2.0, dist));',
    '',
    '    float a = glow * flicker * 0.4;',
    '    result += vec4(edgeColor * a, a);',
    '  }',
    '',
    '  return result;',
    '}',
    '',
    '// --- Fire mask effect (pixel-precise from SAM) ---',
    '// Upward-rising flames within mask + tongue extension above mask edge.',
    'vec4 fireMaskEffect(vec2 uv, float time, int quality) {',
    '  float mask = texture2D(u_fireMask, uv).r;',
    '',
    '  // Tongue zone: 50% of original reach (0.035 -> 0.0175), same centre',
    '  float maskBelow = texture2D(u_fireMask, vec2(uv.x, uv.y + 0.0175)).r;',
    '  float tongue = maskBelow * (1.0 - mask);',
    '  float presence = mask + tongue * 0.6;',
    '  if (presence < 0.02) return vec4(0.0);',
    '',
    '  // Adaptive erosion: measure mask radius so small fires (torches) keep their flame.',
    '  // Sample outward in 4 directions; radius = distance until mask drops below 0.3.',
    '  float radius = 0.0;',
    '  for (float s = 0.005; s <= 0.06; s += 0.005) {',
    '    float tap = min(min(',
    '      texture2D(u_fireMask, uv + vec2( s, 0.0)).r,',
    '      texture2D(u_fireMask, uv + vec2(-s, 0.0)).r),',
    '      min(',
    '      texture2D(u_fireMask, uv + vec2(0.0,  s)).r,',
    '      texture2D(u_fireMask, uv + vec2(0.0, -s)).r));',
    '    if (tap < 0.3) break;',
    '    radius = s;',
    '  }',
    '  // Scale erosion: large fire (radius>=0.04) gets full bw=0.04,',
    '  // small fire (radius~0.01) gets bw~0.01, minimum 0.008.',
    '  float bw = clamp(radius * 0.8, 0.008, 0.04);',
    '  float interior = min(min(',
    '    texture2D(u_fireMask, uv + vec2( bw, 0.0)).r,',
    '    texture2D(u_fireMask, uv + vec2(-bw, 0.0)).r),',
    '    min(',
    '    texture2D(u_fireMask, uv + vec2(0.0,  bw)).r,',
    '    texture2D(u_fireMask, uv + vec2(0.0, -bw)).r));',
    '  interior = smoothstep(0.1, 0.7, interior);',
    '',
    '  // Upward-moving turbulence: +time in Y shifts pattern toward smaller Y = upward',
    '  vec2 p = uv * 8.0;',
    '  float q  = tmFbm(vec2(p.x * 0.9, p.y + time * 2.0));',
    '  float r1 = tmFbm(vec2(p.x + q + time * 0.5, p.y + time * 2.8));',
    '  float r2 = tmFbm(vec2(p.x - time * 0.3, p.y + q * 0.6 + time * 2.2));',
    '  float fi = clamp(tmFbm(vec2(p.x + r1 * 0.7, p.y + r2 + time * 1.5)) * 1.6 - 0.25, 0.0, 1.0);',
    '',
    '  // Color: deep red -> orange -> yellow -> white-hot core',
    '  vec3 col = mix(vec3(0.55, 0.04, 0.0), vec3(1.0, 0.38, 0.0), fi);',
    '  col = mix(col, vec3(1.0, 0.78, 0.08), pow(fi, 1.8));',
    '  col = mix(col, vec3(1.0, 0.97, 0.65), pow(fi, 5.0));',
    '',
    '  // Dual-rate flicker',
    '  float flick = 0.78 + 0.22 * tmNoise(vec2(time * 7.0, fi * 4.0 + 0.5));',
    '  flick *= 0.91 + 0.09 * tmNoise(vec2(time * 2.8 + 1.7, uv.x * 6.0));',
    '',
    '  // Tongue tendrils: narrow, noisy spires above the flame centre',
    '  if (tongue > 0.01) {',
    '    float tendrils = tmNoise(vec2(uv.x * 12.0, uv.y * 12.0 + time * 5.5));',
    '    tongue *= tendrils * tendrils;',
    '  }',
    '',
    '  // Body: eroded interior; tongues at half amplitude to match halved area',
    '  float a = clamp((mask * interior * 0.9 + tongue * 0.275) * flick * (0.4 + fi * 0.8), 0.0, 1.0);',
    '',
    '  // Embers drifting upward with slight lateral drift',
    '  if (quality == 2) {',
    '    float drift = sin(uv.x * 15.0 + time * 0.7) * 0.01;',
    '    vec2 eUV = vec2(uv.x * 28.0 + drift, uv.y * 28.0 + time * 9.0);',
    '    float ember = tmNoise(eUV);',
    '    ember = smoothstep(0.71, 0.77, ember) * interior;',
    '    col = mix(col, vec3(1.0, 0.9, 0.5), ember);',
    '    a = max(a, ember * 0.85);',
    '  }',
    '',
    '  return vec4(col * a, a);',
    '}',
    '',
    'void main() {',
    '  if (u_quality == 0) { discard; }',
    '',
    '  // Pre-compute light contribution once — reused by both image mode and overlay mode',
    '  vec4 lightContrib = vec4(0.0);',
    '  if (u_enableLighting == 1 && u_lightCount > 0) {',
    '    lightContrib = lightEffect(v_uv, u_time, u_quality);',
    '  }',
    '',
    '  // ── IMAGE MODE: color-grade the background texture ──────────────',
    '  if (u_hasMapImage == 1) {',
    '    vec4 mapSample = texture2D(u_mapImage, v_uv);',
    '    vec3 base = mapSample.rgb;',
    '',
    '    if (u_enableLighting == 1 && u_ambientDarkness > 0.01) {',
    '      float nf = u_ambientDarkness;',
    '      // 1. Exposure darkening',
    '      base *= (1.0 - nf * 0.75);',
    '      // 2. Desaturation under moonlight',
    '      float lum = dot(base, vec3(0.299, 0.587, 0.114));',
    '      base = mix(base, vec3(lum), nf * 0.30);',
    '      // 3. Cool colour temperature (u_ambientColor is (0.4,0.4,0.8) at night)',
    '      vec3 nightMul = mix(vec3(1.0), u_ambientColor * 1.8, nf * 0.5);',
    '      base = clamp(base * nightMul, 0.0, 1.0);',
    '    }',
    '',
    '    vec4 color = vec4(base, 1.0);',
    '',
    '    // Animated surface effects composited over graded image',
    '    if (u_enableAnimation == 1) {',
    '      // Water: brightness modulation (no UV displacement — avoids boulder artefacts).',
    '      // wmask is 0 on rocks inside the stream, so they are unaffected.',
    '      // Water: downward flow, brightness modulation, subtle interior-only UV distortion.',
    '      // 4-tap mask erosion keeps distortion away from boulder/shore edges.',
    '      if (u_hasWaterMask == 1) {',
    '        float wmask = texture2D(u_waterMask, v_uv).r;',
    '        if (wmask > 0.05) {',
    '          // Erode mask — 0 near any edge (stream shore or boulder outline)',
    '          float bw = 0.012;',
    '          float interior = min(min(',
    '            texture2D(u_waterMask, v_uv + vec2( bw, 0.0)).r,',
    '            texture2D(u_waterMask, v_uv + vec2(-bw, 0.0)).r),',
    '            min(',
    '            texture2D(u_waterMask, v_uv + vec2(0.0,  bw)).r,',
    '            texture2D(u_waterMask, v_uv + vec2(0.0, -bw)).r));',
    '          interior = smoothstep(0.2, 0.8, interior);',
    '          // Flow noise — negative Y offset = downward on screen',
    '          vec2 fUV = v_uv * 10.0;',
    '          float rox = bornedCos(-0.1, 0.1);',
    '          float roy = bornedSin(-0.15, 0.15);',
    '          float flow = fbm(fUV + vec2(u_time * 0.2 + rox, -(u_time * 0.6 + roy)));',
    '          flow += 0.3 * noise2d(fUV * 2.5 + vec2(u_time * 0.15, -u_time * 0.8));',
    '          float shimmer = clamp(flow * 0.5 + 0.5, 0.0, 1.0);',
    '          // Subtle UV distortion on interior pixels only (waves flow downward)',
    '          float dx = sin(v_uv.x * 22.0 + u_time * 1.4) * 0.003',
    '                   + sin(v_uv.y * 14.0 - u_time * 0.8) * 0.002;',
    '          float dy = cos(v_uv.y * 18.0 - u_time * 1.1) * 0.003',
    '                   + cos(v_uv.x * 16.0 + u_time * 0.7) * 0.002;',
    '          vec3 distorted = texture2D(u_mapImage, v_uv + interior * vec2(dx, dy)).rgb;',
    '          color.rgb = mix(color.rgb, distorted, interior * 0.55);',
    '          // Brightness modulation (darken troughs, brighten peaks)',
    '          float bmod = 0.72 + 0.50 * shimmer;',
    '          color.rgb = mix(color.rgb, color.rgb * bmod, wmask);',
    '          // Specular flash at peaks',
    '          float spec = pow(shimmer, 2.5) * 0.40;',
    '          color.rgb = clamp(color.rgb + wmask * spec * vec3(0.65, 0.82, 1.0), 0.0, 1.0);',
    '        }',
    '      }',
    '      if (u_hasFoliageMask == 1 && u_quality == 2) {',
    '        vec4 f = foliageEffect(v_uv, u_time, u_quality);',
    '        color.rgb = f.rgb + color.rgb * (1.0 - f.a);',
    '      }',
    '      if (u_hasFireMask == 1) {',
    '        vec4 fc = fireMaskEffect(v_uv, u_time, u_quality);',
    '        // Color sensitivity: full intensity on red/orange/yellow, dim on cool pixels',
    '        // Squared warmth: grey rocks (~0.1) → 1%, orange fire (~0.9) → 81%',
    '        float warmth = clamp((mapSample.r - mapSample.b) * 2.5, 0.0, 1.0);',
    '        fc.rgb *= warmth * warmth;',
    '        // Additive blend: fire emits light onto the scene (fc.rgb is premultiplied)',
    '        color.rgb = clamp(color.rgb + fc.rgb, 0.0, 1.0);',
    '      } else if (u_fireCount > 0) {',
    '        vec4 fc = fireHexEffect(v_uv, u_time, u_quality);',
    '        color.rgb = clamp(color.rgb + fc.rgb, 0.0, 1.0);',
    '      }',
    '    }',
    '',
    '    // Torch emission — warm glow added on top (brighter at night)',
    '    if (u_enableLighting == 1 && lightContrib.a > 0.0) {',
    '      float emitScale = 0.55 + u_ambientDarkness * 0.25;',
    '      color.rgb = clamp(color.rgb + lightContrib.rgb * emitScale, 0.0, 1.0);',
    '    }',
    '',
    '    // Fully opaque output — canvas IS the background',
    '    gl_FragColor = vec4(clamp(color.rgb, 0.0, 1.0), 1.0);',
    '    return;',
    '  }',
    '',
    '  // ── OVERLAY MODE: existing layers (no background texture) ────────',
    '  // === Layer 1: Ambient darkness (base dark overlay) ===',
    '  float ambAlpha = 0.0;',
    '  vec3  ambColor = vec3(0.0);',
    '  if (u_enableLighting == 1 && u_ambientDarkness > 0.01) {',
    '    // Match 2D canvas formula: ~50/255 for RG, ~80/255 for B (blue cast at night)',
    '    ambColor = vec3(u_ambientColor.r * 0.2, u_ambientColor.g * 0.2, u_ambientColor.b * 0.32);',
    '    ambAlpha = u_ambientDarkness;',
    '  }',
    '',
    '  // === Layer 2: Point lights punch through ambient darkness ===',
    '  if (u_enableLighting == 1 && u_ambientDarkness > 0.01 && u_lightCount > 0) {',
    '    // Lights reduce ambient alpha (make overlay transparent where light shines)',
    '    ambAlpha *= (1.0 - lightContrib.a * 0.85);',
    '    // Add warm light glow tint (lightContrib.rgb is premultiplied by .a)',
    '    ambColor += lightContrib.rgb * 0.5;',
    '  }',
    '',
    '  // Start with the ambient layer (premultiplied: RGB * alpha)',
    '  vec4 color = vec4(ambColor * ambAlpha, ambAlpha);',
    '',
    '  // === Layer 3: Animated effects (premultiplied "over" compositing) ===',
    '  if (u_enableAnimation == 1) {',
    '    // Water',
    '    if (u_hasWaterMask == 1) {',
    '      vec4 w = waterEffect(v_uv, u_time, u_quality);',
    '      color = vec4(w.rgb + color.rgb * (1.0 - w.a), w.a + color.a * (1.0 - w.a));',
    '    }',
    '',
    '    // Foliage (high quality only)',
    '    if (u_hasFoliageMask == 1 && u_quality == 2) {',
    '      vec4 f = foliageEffect(v_uv, u_time, u_quality);',
    '      color = vec4(f.rgb + color.rgb * (1.0 - f.a), f.a + color.a * (1.0 - f.a));',
    '    }',
    '',
    '    // Fire — mask-based (pixel-precise) or hex-based (fallback)',
    '    if (u_hasFireMask == 1) {',
    '      vec4 fc = fireMaskEffect(v_uv, u_time, u_quality);',
    '      color = vec4(fc.rgb + color.rgb * (1.0 - fc.a), fc.a + color.a * (1.0 - fc.a));',
    '    } else if (u_fireCount > 0) {',
    '      vec4 fc = fireHexEffect(v_uv, u_time, u_quality);',
    '      color = vec4(fc.rgb + color.rgb * (1.0 - fc.a), fc.a + color.a * (1.0 - fc.a));',
    '    }',
    '  }',
    '',
    '  // === Layer 4: Torch emission — glow always visible regardless of ambient darkness ===',
    '  // At noon (ambientDarkness=0) layers 1+2 produce nothing, so torches need this.',
    '  // At night, this adds a warm halo on top of the punch-through reveal.',
    '  if (u_enableLighting == 1 && u_lightCount > 0 && lightContrib.a > 0.0) {',
    '    float emitScale = 0.3;',
    '    vec4 emission = vec4(lightContrib.rgb * emitScale, lightContrib.a * emitScale);',
    '    color = vec4(emission.rgb + color.rgb * (1.0 - emission.a),',
    '                 emission.a + color.a * (1.0 - emission.a));',
    '  }',
    '',
    '  // Output straight alpha for premultipliedAlpha:false canvas',
    '  if (color.a > 0.001) {',
    '    gl_FragColor = vec4(color.rgb / color.a, color.a);',
    '  } else {',
    '    gl_FragColor = vec4(0.0);',
    '  }',
    '}'
  ].join('\n');

  // ── Shader helpers ─────────────────────────────────────────────────────

  function compileShader(gl, type, source) {
    var shader = gl.createShader(type);
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
      warn('[BattleMapEffects] Shader compile error: ' + gl.getShaderInfoLog(shader));
      gl.deleteShader(shader);
      return null;
    }
    return shader;
  }

  function linkProgram(gl, vertSrc, fragSrc) {
    var vert = compileShader(gl, gl.VERTEX_SHADER, vertSrc);
    var frag = compileShader(gl, gl.FRAGMENT_SHADER, fragSrc);
    if (!vert || !frag) return null;

    var program = gl.createProgram();
    gl.attachShader(program, vert);
    gl.attachShader(program, frag);
    gl.linkProgram(program);

    // Shaders are ref-counted; safe to delete after linking
    gl.deleteShader(vert);
    gl.deleteShader(frag);

    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      warn('[BattleMapEffects] Program link error: ' + gl.getProgramInfoLog(program));
      gl.deleteProgram(program);
      return null;
    }
    return program;
  }

  function warn(msg) {
    if (typeof console !== 'undefined' && console.warn) console.warn(msg);
  }

  // ── Texture loader ──────────────────────────────────────────────────────

  function loadTexture(gl, url, callback) {
    var texture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, texture);

    // 1x1 transparent placeholder until the image loads
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA,
                  gl.UNSIGNED_BYTE, new Uint8Array([0, 0, 0, 0]));

    var image = new Image();
    image.crossOrigin = 'anonymous';

    image.onload = function () {
      gl.bindTexture(gl.TEXTURE_2D, texture);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, image);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
      if (callback) callback();
    };

    image.onerror = function () {
      warn('[BattleMapEffects] Failed to load texture: ' + url);
    };

    image.src = url;
    return texture;
  }

  // ── Constructor ────────────────────────────────────────────────────────

  function BattleMapEffects(scrollContainer) {
    this.scrollContainer = scrollContainer;
    this.canvas          = null;  // WebGL canvas (visible overlay)
    this.gl              = null;
    this.program         = null;
    this.quality         = QUALITY_HIGH;
    this.running         = false;
    this.animFrameId     = null;
    this.lastFrameTime   = 0;
    this.startTime       = 0;

    this.baseWidth       = 0;
    this.baseHeight      = 0;
    this.viewBoxYOffset  = 0;
    this.zoom            = 1;

    this.waterMaskTex    = null;
    this.foliageMaskTex  = null;
    this.mapImageTex     = null;
    this.hasWaterMask    = false;
    this.hasFoliageMask  = false;
    this.hasFireMask     = false;
    this.hasMapImage     = false;

    this.lightSources    = [];
    this.lightCount      = 0;
    this.fireHexes       = [];
    this.fireCount       = 0;

    this.uniforms        = {};
    this.timeOfDay       = 12.0;
    this.ambientColor    = [1.0, 1.0, 1.0];
    this.ambientStrength = 1.0;
    this._baseAmbientDarkness = 0.0;
    this.ambientDarkness = 0.0;
    this.enableLighting  = true;
    this.enableAnimation = true;

    this._quadBuffer     = null;
    this._visHandler     = null;
    this._tick           = null;
  }

  // ── Prototype ──────────────────────────────────────────────────────────

  var proto = BattleMapEffects.prototype;

  /**
   * init — create canvas, obtain WebGL context, compile shaders.
   * @param {number} svgWidth        Base width of the SVG (unzoomed pixels).
   * @param {number} svgHeight       Base height of the SVG (unzoomed pixels).
   * @param {number} viewBoxYOffset  SVG viewBox Y origin (e.g. -hexHeight/2).
   * @returns {boolean} true if WebGL initialised successfully.
   */
  proto.init = function (svgWidth, svgHeight, viewBoxYOffset) {
    this.baseWidth      = svgWidth;
    this.baseHeight     = svgHeight;
    this.viewBoxYOffset = viewBoxYOffset || 0;

    // ── Create WebGL canvas as visible overlay ─────────────────────────
    var canvas = document.createElement('canvas');
    canvas.className = 'battle-map-effects-canvas';
    canvas.width  = svgWidth;
    canvas.height = svgHeight;
    canvas.style.position      = 'absolute';
    canvas.style.top           = '0';
    canvas.style.left          = '0';
    canvas.style.zIndex        = '2';
    canvas.style.pointerEvents = 'none';
    canvas.style.width         = svgWidth + 'px';
    canvas.style.height        = svgHeight + 'px';

    // Insert after the SVG inside the scroll container
    var svg = this.scrollContainer.querySelector('.battle-map-svg');
    if (svg && svg.parentNode) {
      svg.parentNode.insertBefore(canvas, svg.nextSibling);
    } else {
      this.scrollContainer.appendChild(canvas);
    }
    this.canvas = canvas;

    // ── WebGL context ────────────────────────────────────────────────
    var gl = canvas.getContext('webgl', {
      alpha: true,
      premultipliedAlpha: false,
      preserveDrawingBuffer: false,
      antialias: false
    });
    if (!gl) {
      warn('[BattleMapEffects] WebGL not available — effects disabled.');
      this.quality = QUALITY_OFF;
      return false;
    }
    this.gl = gl;

    gl.disable(gl.BLEND);

    // ── Compile & link shaders ───────────────────────────────────────
    var program = linkProgram(gl, VERT_SRC, FRAG_SRC);
    if (!program) {
      warn('[BattleMapEffects] Shader compilation failed — effects disabled.');
      this.quality = QUALITY_OFF;
      return false;
    }
    this.program = program;
    gl.useProgram(program);

    // ── Cache uniform locations ──────────────────────────────────────
    var u = {};
    u.u_time           = gl.getUniformLocation(program, 'u_time');
    u.u_quality        = gl.getUniformLocation(program, 'u_quality');
    u.u_waterMask      = gl.getUniformLocation(program, 'u_waterMask');
    u.u_foliageMask    = gl.getUniformLocation(program, 'u_foliageMask');
    u.u_fireMask       = gl.getUniformLocation(program, 'u_fireMask');
    u.u_hasWaterMask   = gl.getUniformLocation(program, 'u_hasWaterMask');
    u.u_hasFoliageMask = gl.getUniformLocation(program, 'u_hasFoliageMask');
    u.u_hasFireMask    = gl.getUniformLocation(program, 'u_hasFireMask');
    u.u_mapImage       = gl.getUniformLocation(program, 'u_mapImage');
    u.u_hasMapImage    = gl.getUniformLocation(program, 'u_hasMapImage');
    u.u_lightCount     = gl.getUniformLocation(program, 'u_lightCount');
    u.u_fireCount      = gl.getUniformLocation(program, 'u_fireCount');
    u.u_timeOfDay       = gl.getUniformLocation(program, 'u_timeOfDay');
    u.u_ambientColor    = gl.getUniformLocation(program, 'u_ambientColor');
    u.u_ambientDarkness = gl.getUniformLocation(program, 'u_ambientDarkness');
    u.u_enableLighting  = gl.getUniformLocation(program, 'u_enableLighting');
    u.u_enableAnimation = gl.getUniformLocation(program, 'u_enableAnimation');

    // Light arrays
    u.u_lightPositions  = [];
    u.u_lightColors     = [];
    u.u_lightIntensities = [];
    u.u_lightTypes       = [];
    for (var i = 0; i < MAX_LIGHTS; i++) {
      u.u_lightPositions[i]   = gl.getUniformLocation(program, 'u_lightPositions[' + i + ']');
      u.u_lightColors[i]      = gl.getUniformLocation(program, 'u_lightColors[' + i + ']');
      u.u_lightIntensities[i] = gl.getUniformLocation(program, 'u_lightIntensities[' + i + ']');
      u.u_lightTypes[i]       = gl.getUniformLocation(program, 'u_lightTypes[' + i + ']');
    }

    // Fire hex arrays
    u.u_fireHexes = [];
    for (var j = 0; j < MAX_FIRE_HEXES; j++) {
      u.u_fireHexes[j] = gl.getUniformLocation(program, 'u_fireHexes[' + j + ']');
    }

    this.uniforms = u;

    // ── Set initial uniform values ───────────────────────────────────
    gl.uniform1f(u.u_time, 0.0);
    gl.uniform1i(u.u_quality, this.quality);
    gl.uniform1i(u.u_hasWaterMask, 0);
    gl.uniform1i(u.u_hasFoliageMask, 0);
    gl.uniform1i(u.u_hasFireMask, 0);
    gl.uniform1i(u.u_lightCount, 0);
    gl.uniform1i(u.u_fireCount, 0);
    gl.uniform1f(u.u_timeOfDay, 12.0);
    gl.uniform3f(u.u_ambientColor, 1.0, 1.0, 1.0);
    gl.uniform1f(u.u_ambientDarkness, 0.0);
    gl.uniform1i(u.u_enableLighting, 1);
    gl.uniform1i(u.u_enableAnimation, 1);

    // Default all lights to organic (0)
    for (var k = 0; k < MAX_LIGHTS; k++) {
      gl.uniform1i(u.u_lightTypes[k], 0);
    }

    // Bind texture units
    gl.uniform1i(u.u_waterMask, 0);   // TEXTURE0
    gl.uniform1i(u.u_foliageMask, 1); // TEXTURE1
    gl.uniform1i(u.u_fireMask, 2);    // TEXTURE2
    gl.uniform1i(u.u_mapImage, 3);    // TEXTURE3
    gl.uniform1i(u.u_hasMapImage, 0);

    // ── Full-screen quad ─────────────────────────────────────────────
    // Two triangles covering clip space [-1,1]
    var quadVerts = new Float32Array([
      -1, -1,   1, -1,  -1,  1,
      -1,  1,   1, -1,   1,  1
    ]);
    var buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, quadVerts, gl.STATIC_DRAW);
    this._quadBuffer = buf;

    var aPos = gl.getAttribLocation(program, 'a_position');
    gl.enableVertexAttribArray(aPos);
    gl.vertexAttribPointer(aPos, 2, gl.FLOAT, false, 0, 0);


    // ── Page Visibility API ──────────────────────────────────────────
    var self = this;
    this._visHandler = function () {
      if (document.hidden) {
        self.stop();
      } else if (self.quality !== QUALITY_OFF && self.gl) {
        self.start();
      }
    };
    document.addEventListener('visibilitychange', this._visHandler);

    this.startTime = performance.now();
    return true;
  };

  /**
   * updateTransform — sync canvas CSS size with SVG zoom.
   * The pixel buffer stays at base resolution; CSS scaling handles zoom.
   */
  proto.updateTransform = function (zoom) {
    this.zoom = zoom;
    if (!this.canvas) return;
    this.canvas.style.width  = (this.baseWidth * zoom) + 'px';
    this.canvas.style.height = (this.baseHeight * zoom) + 'px';
  };

  /**
   * setQuality — change quality level.
   * @param {string|number} level  'off', 'low', 'high' or numeric constant.
   */
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
    } else if (this.gl) {
      this.start();
    }
  };

  /** start — begin the render loop. */
  proto.start = function () {
    if (this.running) return;
    if (this.quality === QUALITY_OFF || !this.gl) return;
    this.running = true;
    this.lastFrameTime = 0;
    this._tick = this._renderFrame.bind(this);
    this.animFrameId = requestAnimationFrame(this._tick);
  };

  /** stop — pause the render loop. */
  proto.stop = function () {
    this.running = false;
    if (this.animFrameId !== null) {
      cancelAnimationFrame(this.animFrameId);
      this.animFrameId = null;
    }
  };

  /**
   * destroy — tear down everything and remove the canvas from the DOM.
   */
  proto.destroy = function () {
    this.stop();

    // Remove visibility listener
    if (this._visHandler) {
      document.removeEventListener('visibilitychange', this._visHandler);
      this._visHandler = null;
    }

    var gl = this.gl;
    if (gl) {
      // Delete textures
      if (this.waterMaskTex)   gl.deleteTexture(this.waterMaskTex);
      if (this.foliageMaskTex) gl.deleteTexture(this.foliageMaskTex);
      if (this.fireMaskTex)    gl.deleteTexture(this.fireMaskTex);
      if (this.mapImageTex)    gl.deleteTexture(this.mapImageTex);
      this.waterMaskTex   = null;
      this.foliageMaskTex = null;
      this.fireMaskTex    = null;
      this.mapImageTex    = null;

      // Delete buffer
      if (this._quadBuffer) gl.deleteBuffer(this._quadBuffer);
      this._quadBuffer = null;

      // Delete program
      if (this.program) gl.deleteProgram(this.program);
      this.program = null;

      // Lose context
      var ext = gl.getExtension('WEBGL_lose_context');
      if (ext) ext.loseContext();
      this.gl = null;
    }

    // Remove canvases
    if (this.canvas && this.canvas.parentNode) {
      this.canvas.parentNode.removeChild(this.canvas);
    }
    this.canvas = null;
  };

  // ── Data setters ──────────────────────────────────────────────────

  proto.loadWaterMask = function (url) {
    if (!this.gl) return;
    var self = this;
    this.waterMaskTex = loadTexture(this.gl, url, function () {
      if (!self.gl || !self.program) return;
      self.hasWaterMask = true;
      self.gl.useProgram(self.program);
      self.gl.uniform1i(self.uniforms.u_hasWaterMask, 1);
    });
  };

  proto.loadFoliageMask = function (url) {
    if (!this.gl) return;
    var self = this;
    this.foliageMaskTex = loadTexture(this.gl, url, function () {
      if (!self.gl || !self.program) return;
      self.hasFoliageMask = true;
      self.gl.useProgram(self.program);
      self.gl.uniform1i(self.uniforms.u_hasFoliageMask, 1);
    });
  };

  proto.loadFireMask = function (url) {
    if (!this.gl) return;
    var self = this;
    this.fireMaskTex = loadTexture(this.gl, url, function () {
      if (!self.gl || !self.program) return;
      self.hasFireMask = true;
      self.gl.useProgram(self.program);
      self.gl.uniform1i(self.uniforms.u_hasFireMask, 1);
    });
  };

  /**
   * loadMapImage — load the battle map background as TEXTURE3 for WebGL color grading.
   * Switches canvas to image mode: renders the graded background instead of a transparent overlay.
   * Also repositions the canvas behind the SVG so hex outlines and tokens remain on top.
   */
  proto.loadMapImage = function (url) {
    if (!this.gl) return;
    if (this.mapImageTex) {
      this.gl.deleteTexture(this.mapImageTex);
      this.mapImageTex = null;
    }
    this.hasMapImage = false;
    if (this.program && this.uniforms.u_hasMapImage) {
      this.gl.useProgram(this.program);
      this.gl.uniform1i(this.uniforms.u_hasMapImage, 0);
    }

    var self = this;
    this.mapImageTex = loadTexture(this.gl, url, function () {
      if (!self.gl || !self.program) return;
      self.hasMapImage = true;
      self.gl.useProgram(self.program);
      self.gl.uniform1i(self.uniforms.u_hasMapImage, 1);

      // Remove SVG background element if present (editor: bgImage tagged with class)
      if (self.scrollContainer) {
        var bgEl = self.scrollContainer.querySelector('.battle-map-bg-image');
        if (bgEl && bgEl.parentNode) bgEl.parentNode.removeChild(bgEl);
      }

      // Canvas drops behind SVG — SVG (with transparent hex fills) renders on top
      if (self.canvas) {
        self.canvas.style.zIndex = '0';
      }
      var svg = self.scrollContainer && self.scrollContainer.querySelector('.battle-map-svg');
      if (svg) {
        svg.style.position = 'relative';
        svg.style.zIndex   = '1';
      }
    });
  };

  proto.setLightSources = function (sources) {
    if (!this.gl || !this.program) return;
    var gl = this.gl;
    gl.useProgram(this.program);
    this.lightCount = Math.min(sources.length, MAX_LIGHTS);
    gl.uniform1i(this.uniforms.u_lightCount, this.lightCount);

    for (var i = 0; i < this.lightCount; i++) {
      var s = sources[i];
      // Light source coords arrive pre-normalized to 0-1 UV from the server
      var u = s.center_x;
      var v = s.center_y;
      var r = Math.min(s.radius_px || (50 / Math.max(this.baseWidth, this.baseHeight)), 0.3);
      gl.uniform3f(this.uniforms.u_lightPositions[i], u, v, r);

      var cr = (s.color && s.color[0] != null) ? s.color[0] : 1.0;
      var cg = (s.color && s.color[1] != null) ? s.color[1] : 0.7;
      var cb = (s.color && s.color[2] != null) ? s.color[2] : 0.3;
      gl.uniform3f(this.uniforms.u_lightColors[i], cr, cg, cb);
      gl.uniform1f(this.uniforms.u_lightIntensities[i], s.intensity || 0.7);

      // Map light type string to int: 1=electric, 0=organic (everything else)
      var isElectric = (s.type === 'electric_light') ? 1 : 0;
      gl.uniform1i(this.uniforms.u_lightTypes[i], isElectric);
    }
    this.lightSources = sources;
  };

  proto.setFireHexes = function (hexes) {
    if (!this.gl || !this.program) return;
    var gl = this.gl;
    gl.useProgram(this.program);
    this.fireCount = Math.min(hexes.length, MAX_FIRE_HEXES);
    gl.uniform1i(this.uniforms.u_fireCount, this.fireCount);

    for (var i = 0; i < this.fireCount; i++) {
      var h = hexes[i];
      // Use BattleMapRenderer.hexToPixel if available, otherwise estimate
      var pos;
      if (window.BattleMapRenderer && window.BattleMapRenderer.hexToPixel) {
        pos = window.BattleMapRenderer.hexToPixel(h.x, h.y, this._hexSize, this._hexHeight, this._totalRows);
      } else {
        pos = { px: h.x * this._hexSize * 1.5, py: h.y * this._hexHeight / 4 };
      }
      var u = pos.px / this.baseWidth;
      var v = pos.py / this.baseHeight;
      var r = (this._hexSize || 30) / Math.max(this.baseWidth, this.baseHeight);
      gl.uniform3f(this.uniforms.u_fireHexes[i], u, v, r);
    }
    this.fireHexes = hexes;
  };

  proto.setHexParams = function (hexSize, hexHeight, totalRows) {
    this._hexSize = hexSize;
    this._hexHeight = hexHeight;
    this._totalRows = totalRows;
  };

  /**
   * setAmbientStrength — scale time-of-day ambient lighting contribution.
   * 1.0 = full client ambient, 0.0 = disabled (for pre-lit server images).
   */
  proto.setAmbientStrength = function (strength) {
    var clamped = Number(strength);
    if (!Number.isFinite(clamped)) clamped = 1.0;
    clamped = Math.max(0.0, Math.min(1.0, clamped));
    this.ambientStrength = clamped;
    this.ambientDarkness = this._baseAmbientDarkness * this.ambientStrength;

    if (this.gl && this.program) {
      this.gl.useProgram(this.program);
      this.gl.uniform1f(this.uniforms.u_ambientDarkness, this.ambientDarkness);
    }
  };

  /**
   * setEnableLighting — toggle lighting effects (point lights, ambient, color temperature).
   */
  proto.setEnableLighting = function (enabled) {
    this.enableLighting = !!enabled;
    if (this.gl && this.program) {
      this.gl.useProgram(this.program);
      this.gl.uniform1i(this.uniforms.u_enableLighting, this.enableLighting ? 1 : 0);
    }
  };

  /**
   * setEnableAnimation — toggle animated effects (water, foliage, fire).
   */
  proto.setEnableAnimation = function (enabled) {
    this.enableAnimation = !!enabled;
    if (this.gl && this.program) {
      this.gl.useProgram(this.program);
      this.gl.uniform1i(this.uniforms.u_enableAnimation, this.enableAnimation ? 1 : 0);
    }
  };

  /**
   * setTimeOfDay — adjust ambient lighting for time-of-day simulation.
   * @param {number} hour  0.0 to 24.0 (12.0 = noon, 0.0 = midnight)
   * @param {boolean} isOutdoor  true for outdoor rooms (full effect), false for indoor (reduced)
   */
  proto.setTimeOfDay = function (hour, isOutdoor) {
    this.timeOfDay = hour;

    // Ambient darkness: cosine curve peaking at midnight (hour 0/24), zero at noon (12)
    // Map hour to radians: noon=0, midnight=PI
    var t = (hour - 12.0) / 12.0 * Math.PI;
    var darkness = (1.0 - Math.cos(t)) * 0.5; // 0 at noon, 1 at midnight
    darkness = darkness * darkness; // Square for sharper falloff near noon
    // Indoor rooms get reduced darkness (interior lighting) and color shift
    var maxDarkness = isOutdoor ? 0.85 : 0.7;
    this._baseAmbientDarkness = darkness * maxDarkness;

    // Color temperature by time period
    var r = 1.0, g = 1.0, b = 1.0;
    if (hour >= 5 && hour < 7) {
      // Dawn: warm orange
      var f = (hour - 5) / 2.0;
      r = 1.0; g = 0.75 + 0.2 * f; b = 0.5 + 0.35 * f;
    } else if (hour >= 7 && hour < 10) {
      // Morning: warm white
      r = 1.0; g = 0.95; b = 0.85;
    } else if (hour >= 10 && hour < 14) {
      // Noon: neutral
      r = 1.0; g = 1.0; b = 1.0;
    } else if (hour >= 14 && hour < 17) {
      // Afternoon: slightly warm
      r = 1.0; g = 0.95; b = 0.9;
    } else if (hour >= 17 && hour < 19) {
      // Dusk: deep orange
      var f = (hour - 17) / 2.0;
      r = 1.0; g = 0.85 - 0.1 * f; b = 0.7 - 0.2 * f;
    } else {
      // Night (19-5): deep blue-purple
      r = 0.4; g = 0.4; b = 0.8;
    }
    // Indoor rooms blend color toward warm neutral (interior lighting, not moonlight)
    if (!isOutdoor) {
      r = r * 0.3 + 0.7;  // Blend 70% toward 1.0 (neutral warm)
      g = g * 0.3 + 0.7;
      b = b * 0.3 + 0.7;
    }
    this.ambientColor = [r, g, b];
    this.ambientDarkness = this._baseAmbientDarkness * this.ambientStrength;

    // Update uniforms if GL is active
    if (this.gl && this.program) {
      var gl = this.gl;
      gl.useProgram(this.program);
      gl.uniform1f(this.uniforms.u_timeOfDay, hour);
      gl.uniform3f(this.uniforms.u_ambientColor, r, g, b);
      gl.uniform1f(this.uniforms.u_ambientDarkness, this.ambientDarkness);
    }
  };

  // ── Render loop (private) ──────────────────────────────────────────

  proto._renderFrame = function (timestamp) {
    if (!this.running) return;

    // Throttle to ~30 fps
    if (this.lastFrameTime && (timestamp - this.lastFrameTime) < FRAME_INTERVAL) {
      this.animFrameId = requestAnimationFrame(this._tick);
      return;
    }
    this.lastFrameTime = timestamp;

    var gl = this.gl;
    var u  = this.uniforms;

    gl.viewport(0, 0, gl.drawingBufferWidth, gl.drawingBufferHeight);
    gl.clear(gl.COLOR_BUFFER_BIT);

    gl.useProgram(this.program);

    // Time in seconds since init
    gl.uniform1f(u.u_time, (timestamp - this.startTime) / 1000.0);
    gl.uniform1i(u.u_quality, this.quality);

    // Bind water mask texture
    if (this.hasWaterMask && this.waterMaskTex) {
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, this.waterMaskTex);
    }

    // Bind foliage mask texture
    if (this.hasFoliageMask && this.foliageMaskTex) {
      gl.activeTexture(gl.TEXTURE1);
      gl.bindTexture(gl.TEXTURE_2D, this.foliageMaskTex);
    }

    // Bind fire mask texture
    if (this.hasFireMask && this.fireMaskTex) {
      gl.activeTexture(gl.TEXTURE2);
      gl.bindTexture(gl.TEXTURE_2D, this.fireMaskTex);
    }

    // Bind map image texture (image mode)
    if (this.hasMapImage && this.mapImageTex) {
      gl.activeTexture(gl.TEXTURE3);
      gl.bindTexture(gl.TEXTURE_2D, this.mapImageTex);
    }

    // Draw full-screen quad (6 vertices, 2 triangles)
    gl.bindBuffer(gl.ARRAY_BUFFER, this._quadBuffer);
    gl.drawArrays(gl.TRIANGLES, 0, 6);

    // Schedule next frame
    this.animFrameId = requestAnimationFrame(this._tick);
  };

  // ── Expose quality constants on constructor ────────────────────────

  BattleMapEffects.QUALITY_OFF  = QUALITY_OFF;
  BattleMapEffects.QUALITY_LOW  = QUALITY_LOW;
  BattleMapEffects.QUALITY_HIGH = QUALITY_HIGH;

  // ── Export ─────────────────────────────────────────────────────────

  window.BattleMapEffects = BattleMapEffects;

})();
