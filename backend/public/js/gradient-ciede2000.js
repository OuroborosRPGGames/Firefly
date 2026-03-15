/**
 * CIEDE2000 Color Interpolation System
 * Provides perceptually uniform color transitions in Lab color space
 */

// D65 reference white
const REF_X = 95.047;
const REF_Y = 100.0;
const REF_Z = 108.883;

/**
 * Color Space Conversion Utilities
 */
class GradientColorSpace {
  /**
   * Convert hex color to RGB array [0-255]
   */
  static hexToRgb(hex) {
    const result = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(hex);
    if (!result) return [0, 0, 0];
    return [
      parseInt(result[1], 16),
      parseInt(result[2], 16),
      parseInt(result[3], 16)
    ];
  }

  /**
   * Convert RGB [0-255] to hex string
   */
  static rgbToHex(r, g, b) {
    const clamp = (v) => Math.max(0, Math.min(255, Math.round(v)));
    return '#' + [clamp(r), clamp(g), clamp(b)]
      .map(v => v.toString(16).padStart(2, '0'))
      .join('');
  }

  /**
   * Convert RGB to XYZ color space (D65 illuminant)
   */
  static rgbToXyz(r, g, b) {
    // Normalize to 0-1 and apply gamma correction
    let rn = r / 255;
    let gn = g / 255;
    let bn = b / 255;

    // sRGB companding
    rn = rn > 0.04045 ? Math.pow((rn + 0.055) / 1.055, 2.4) : rn / 12.92;
    gn = gn > 0.04045 ? Math.pow((gn + 0.055) / 1.055, 2.4) : gn / 12.92;
    bn = bn > 0.04045 ? Math.pow((bn + 0.055) / 1.055, 2.4) : bn / 12.92;

    // Scale to 0-100 range
    rn *= 100;
    gn *= 100;
    bn *= 100;

    // RGB to XYZ matrix (D65)
    return [
      rn * 0.4124564 + gn * 0.3575761 + bn * 0.1804375,
      rn * 0.2126729 + gn * 0.7151522 + bn * 0.0721750,
      rn * 0.0193339 + gn * 0.1191920 + bn * 0.9503041
    ];
  }

  /**
   * Convert XYZ to Lab color space (D65 illuminant)
   */
  static xyzToLab(x, y, z) {
    let xr = x / REF_X;
    let yr = y / REF_Y;
    let zr = z / REF_Z;

    const epsilon = 0.008856;
    const kappa = 903.3;

    const f = (t) => t > epsilon ? Math.cbrt(t) : (kappa * t + 16) / 116;

    const fx = f(xr);
    const fy = f(yr);
    const fz = f(zr);

    return [
      116 * fy - 16,        // L*
      500 * (fx - fy),      // a*
      200 * (fy - fz)       // b*
    ];
  }

  /**
   * Convert Lab to XYZ
   */
  static labToXyz(L, a, b) {
    const fy = (L + 16) / 116;
    const fx = a / 500 + fy;
    const fz = fy - b / 200;

    const epsilon = 0.008856;
    const kappa = 903.3;

    const xr = Math.pow(fx, 3) > epsilon ? Math.pow(fx, 3) : (116 * fx - 16) / kappa;
    const yr = L > kappa * epsilon ? Math.pow((L + 16) / 116, 3) : L / kappa;
    const zr = Math.pow(fz, 3) > epsilon ? Math.pow(fz, 3) : (116 * fz - 16) / kappa;

    return [xr * REF_X, yr * REF_Y, zr * REF_Z];
  }

  /**
   * Convert XYZ to RGB
   */
  static xyzToRgb(x, y, z) {
    x /= 100;
    y /= 100;
    z /= 100;

    let r = x * 3.2404542 + y * -1.5371385 + z * -0.4985314;
    let g = x * -0.9692660 + y * 1.8760108 + z * 0.0415560;
    let b = x * 0.0556434 + y * -0.2040259 + z * 1.0572252;

    // Inverse sRGB companding
    const gamma = (v) => v > 0.0031308
      ? 1.055 * Math.pow(v, 1 / 2.4) - 0.055
      : 12.92 * v;

    return [
      Math.round(gamma(r) * 255),
      Math.round(gamma(g) * 255),
      Math.round(gamma(b) * 255)
    ];
  }

  /**
   * Direct hex to Lab conversion
   */
  static hexToLab(hex) {
    const [r, g, b] = this.hexToRgb(hex);
    const [x, y, z] = this.rgbToXyz(r, g, b);
    return this.xyzToLab(x, y, z);
  }

  /**
   * Direct Lab to hex conversion
   */
  static labToHex(L, a, b) {
    const [x, y, z] = this.labToXyz(L, a, b);
    const [r, g, bb] = this.xyzToRgb(x, y, z);
    return this.rgbToHex(r, g, bb);
  }

  /**
   * Interpolate between two Lab colors using LCh for proper hue handling
   * @param {Array} lab1 - Starting Lab color [L, a, b]
   * @param {Array} lab2 - Ending Lab color [L, a, b]
   * @param {number} t - Interpolation factor 0-1
   * @returns {Array} Interpolated Lab color
   */
  static interpolateLab(lab1, lab2, t) {
    // Convert to LCh for hue interpolation
    const C1 = Math.sqrt(lab1[1] * lab1[1] + lab1[2] * lab1[2]);
    const C2 = Math.sqrt(lab2[1] * lab2[1] + lab2[2] * lab2[2]);

    let h1 = Math.atan2(lab1[2], lab1[1]);
    let h2 = Math.atan2(lab2[2], lab2[1]);

    // Normalize to 0-2PI
    if (h1 < 0) h1 += 2 * Math.PI;
    if (h2 < 0) h2 += 2 * Math.PI;

    // Choose shortest path around the hue circle
    let dh = h2 - h1;
    if (dh > Math.PI) dh -= 2 * Math.PI;
    if (dh < -Math.PI) dh += 2 * Math.PI;

    // Interpolate in LCh space
    const L = lab1[0] + t * (lab2[0] - lab1[0]);
    const C = C1 + t * (C2 - C1);
    const h = h1 + t * dh;

    // Convert back to Lab
    return [
      L,
      C * Math.cos(h),
      C * Math.sin(h)
    ];
  }

  /**
   * Interpolate between two hex colors in Lab space
   */
  static interpolateHex(hex1, hex2, t) {
    const lab1 = this.hexToLab(hex1);
    const lab2 = this.hexToLab(hex2);
    const interpolated = this.interpolateLab(lab1, lab2, t);
    return this.labToHex(interpolated[0], interpolated[1], interpolated[2]);
  }
}

/**
 * Easing functions for gradient transitions
 */
class GradientEasing {
  /**
   * Apply easing to transition parameter
   * @param {number} t - Linear progress 0-1
   * @param {number} easeValue - Easing strength (100=linear, >100=ease-in-out)
   * @returns {number} Eased progress 0-1
   */
  static apply(t, easeValue = 100) {
    if (easeValue === 100) return t;

    // Convert easing value to curve strength
    // 100 = linear, 200 = strong ease-in-out, 50 = inverse
    const strength = (easeValue - 100) / 100;

    if (strength > 0) {
      // Ease-in-out: slow at start and end, faster in middle
      // Using smoothstep-like function with adjustable strength
      const smoothstep = t * t * (3 - 2 * t);
      return smoothstep * strength + t * (1 - strength);
    } else {
      // Inverse: faster at start and end, slower in middle
      const s = -strength;
      const inverse = 1 - (1 - t) * (1 - t) * (3 - 2 * (1 - t));
      return inverse * s + t * (1 - s);
    }
  }
}

/**
 * Main gradient generator
 */
class GradientGenerator {
  /**
   * Generate array of colors for a gradient
   * @param {Array<string>} colors - Array of hex color stops
   * @param {Array<number>} easings - Array of easing values for alternating stops (2nd, 4th, 6th...)
   * @param {number} steps - Total number of output colors
   * @returns {Array<string>} Array of hex colors
   */
  static generate(colors, easings = [], steps = 100) {
    if (!colors || colors.length === 0) return [];
    if (colors.length === 1) return new Array(steps).fill(colors[0]);

    const result = [];
    const segments = colors.length - 1;
    const stepsPerSegment = Math.ceil(steps / segments);

    for (let seg = 0; seg < segments; seg++) {
      const startColor = colors[seg];
      const endColor = colors[seg + 1];

      // Easing applies at alternating stops (odd indices: 1, 3, 5...)
      // If end color is at odd index, apply its easing
      const endIndex = seg + 1;
      const easing = endIndex % 2 === 1 ? (easings[Math.floor((endIndex - 1) / 2)] || 100) : 100;

      const segSteps = (seg === segments - 1)
        ? steps - result.length
        : stepsPerSegment;

      for (let i = 0; i < segSteps; i++) {
        const t = i / (segSteps - 1 || 1);
        const easedT = GradientEasing.apply(t, easing);
        const color = GradientColorSpace.interpolateHex(startColor, endColor, easedT);
        result.push(color);
      }
    }

    return result;
  }

  /**
   * Apply gradient to text, creating span-per-character HTML
   * @param {string} text - Text to colorize
   * @param {Array<string>} colors - Gradient color stops
   * @param {Array<number>} easings - Easing values for alternating stops
   * @returns {string} HTML with colored spans
   */
  static applyToText(text, colors, easings = []) {
    if (!text || !colors || colors.length < 2) return text;

    // Count non-whitespace characters for gradient distribution
    const chars = text.split('');
    const nonWhitespaceCount = chars.filter(c => !/\s/.test(c)).length;

    if (nonWhitespaceCount === 0) return text;

    // Generate gradient colors for visible characters
    const gradientColors = this.generate(colors, easings, nonWhitespaceCount);

    let colorIndex = 0;
    return chars.map(char => {
      if (/\s/.test(char)) {
        return char; // Preserve whitespace
      }

      const color = gradientColors[colorIndex] || gradientColors[gradientColors.length - 1];
      colorIndex++;

      // Escape HTML
      const escaped = char
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');

      return `<span style="color:${color}">${escaped}</span>`;
    }).join('');
  }

  /**
   * Generate a CSS linear-gradient preview
   */
  static toCssGradient(colors, easings = []) {
    if (!colors || colors.length < 2) return 'transparent';

    // Generate intermediate stops for smooth preview
    const stops = this.generate(colors, easings, Math.min(colors.length * 10, 50));
    const step = 100 / (stops.length - 1);

    const cssStops = stops.map((color, i) => `${color} ${(i * step).toFixed(1)}%`);
    return `linear-gradient(90deg, ${cssStops.join(', ')})`;
  }

  /**
   * Normalize a hex color code
   */
  static normalizeHex(hex) {
    if (!hex) return null;
    let h = hex.replace('#', '');
    if (h.length === 3) {
      h = h.split('').map(c => c + c).join('');
    }
    if (!/^[0-9a-f]{6}$/i.test(h)) return null;
    return '#' + h.toLowerCase();
  }

  /**
   * Validate a hex color code
   */
  static isValidHex(hex) {
    if (!hex) return false;
    return /^#?([0-9a-f]{3}|[0-9a-f]{6})$/i.test(hex);
  }
}

// Export for module systems
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { GradientColorSpace, GradientEasing, GradientGenerator };
}

// Global export for browser
if (typeof window !== 'undefined') {
  window.GradientColorSpace = GradientColorSpace;
  window.GradientEasing = GradientEasing;
  window.GradientGenerator = GradientGenerator;
}
