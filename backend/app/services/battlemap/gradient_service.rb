# frozen_string_literal: true

# Service for applying color gradients to text
# Supports both RGB interpolation and CIEDE2000 perceptual interpolation in Lab color space
class GradientService
  HEX_PATTERN = /^#?([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/

  # D65 reference white for XYZ/Lab conversions
  REF_X = 95.047
  REF_Y = 100.0
  REF_Z = 108.883

  class << self
    # Parse gradient codes from string like "#ff0000,#00ff00,#0000ff"
    def parse_codes(gradient_string)
      return [] unless gradient_string

      gradient_string.split(',').map(&:strip).select { |c| valid_hex?(c) }.map { |c| normalize_hex(c) }
    end

    # Validate hex code format
    def valid_hex?(code)
      return false unless code

      code.match?(HEX_PATTERN)
    end

    # Normalize hex code (add # if missing, expand 3-char to 6-char)
    def normalize_hex(code)
      return nil unless valid_hex?(code)

      hex = code.gsub('#', '')
      hex = hex.chars.map { |c| c * 2 }.join if hex.length == 3
      "##{hex.downcase}"
    end

    # Apply gradient to text (returns HTML with span colors)
    # @param text [String] The text to colorize
    # @param colors [Array<String>] Array of hex color codes
    # @param fast [Boolean] Use sharp gradient (sections) vs smooth (interpolated)
    # @return [String] HTML string with colored spans
    def apply(text, colors, fast: false)
      return text if colors.empty? || text.nil? || text.empty?

      normalized_colors = colors.map { |c| normalize_hex(c) }.compact
      return text if normalized_colors.length < 2

      if fast
        apply_sharp(text, normalized_colors)
      else
        apply_smooth(text, normalized_colors)
      end
    end

    # Apply gradient using CIEDE2000 perceptual interpolation in Lab color space
    # @param text [String] Text to colorize
    # @param colors [Array<String>] Hex color stops
    # @param easings [Array<Integer>] Easing values for alternating stops (2nd, 4th, 6th...)
    # @return [String] HTML with colored spans
    def apply_ciede2000(text, colors, easings: [])
      return text if colors.empty? || text.nil? || text.empty?

      normalized = colors.map { |c| normalize_hex(c) }.compact
      return text if normalized.length < 2

      chars = text.chars
      visible_chars = chars.reject { |c| c.match?(/\s/) }
      return text if visible_chars.length <= 1

      # Generate gradient colors for visible characters
      gradient_colors = generate_ciede2000_colors(normalized, visible_chars.length, easings)

      color_index = 0
      chars.map do |char|
        if char.match?(/\s/)
          char
        else
          color = gradient_colors[color_index] || gradient_colors.last
          color_index += 1
          "<span style=\"color:#{color}\">#{escape_html(char)}</span>"
        end
      end.join
    end

    # Generate array of gradient colors using Lab interpolation
    # @param colors [Array<String>] Hex color stops
    # @param count [Integer] Number of colors to generate
    # @param easings [Array<Integer>] Easing values for alternating stops
    # @return [Array<String>] Array of hex colors
    def generate_ciede2000_colors(colors, count, easings = [])
      return colors if count <= colors.length

      result = []
      segments = colors.length - 1
      steps_per_segment = (count.to_f / segments).ceil

      segments.times do |seg|
        start_color = colors[seg]
        end_color = colors[seg + 1]

        # Easing applies at alternating stops (odd indices: 1, 3, 5...)
        # If end color is at odd index, apply its easing
        end_index = seg + 1
        easing = end_index.odd? ? (easings[(end_index - 1) / 2] || 100) : 100

        seg_steps = (seg == segments - 1) ? count - result.length : steps_per_segment

        seg_steps.times do |i|
          t = i.to_f / (seg_steps - 1).clamp(1, Float::INFINITY)
          eased_t = apply_easing(t, easing)
          result << interpolate_lab(start_color, end_color, eased_t)
        end
      end

      result
    end

    # Apply easing function to progress
    # @param t [Float] Linear progress 0-1
    # @param easing_value [Integer] Easing strength (100=linear, >100=ease-in-out)
    # @return [Float] Eased progress 0-1
    def apply_easing(t, easing_value)
      return t if easing_value == 100

      strength = (easing_value - 100) / 100.0

      if strength > 0
        # Ease-in-out: smoothstep
        smoothstep = t * t * (3 - 2 * t)
        smoothstep * strength + t * (1 - strength)
      else
        # Inverse easing (faster at edges)
        s = -strength
        inverse = 1 - (1 - t) * (1 - t) * (3 - 2 * (1 - t))
        inverse * s + t * (1 - s)
      end
    end

    # Interpolate two hex colors in Lab color space with LCh hue handling
    # @param hex1 [String] Start hex color
    # @param hex2 [String] End hex color
    # @param t [Float] Interpolation factor 0-1
    # @return [String] Interpolated hex color
    def interpolate_lab(hex1, hex2, t)
      lab1 = hex_to_lab(hex1)
      lab2 = hex_to_lab(hex2)

      # Convert to LCh for proper hue interpolation
      c1 = Math.sqrt(lab1[1]**2 + lab1[2]**2)
      c2 = Math.sqrt(lab2[1]**2 + lab2[2]**2)

      h1 = Math.atan2(lab1[2], lab1[1])
      h2 = Math.atan2(lab2[2], lab2[1])

      # Normalize hues to 0-2PI
      h1 += 2 * Math::PI if h1 < 0
      h2 += 2 * Math::PI if h2 < 0

      # Shortest path around hue circle
      dh = h2 - h1
      dh -= 2 * Math::PI if dh > Math::PI
      dh += 2 * Math::PI if dh < -Math::PI

      # Interpolate in LCh
      l = lab1[0] + t * (lab2[0] - lab1[0])
      c = c1 + t * (c2 - c1)
      h = h1 + t * dh

      # Convert back to Lab
      lab_to_hex(l, c * Math.cos(h), c * Math.sin(h))
    end

    # Convert hex color to Lab color space
    def hex_to_lab(hex)
      rgb = hex_to_rgb(hex)
      xyz = rgb_to_xyz(*rgb)
      xyz_to_lab(*xyz)
    end

    # Convert Lab color to hex
    def lab_to_hex(l, a, b)
      xyz = lab_to_xyz(l, a, b)
      rgb = xyz_to_rgb(*xyz)
      rgb_to_hex(*rgb)
    end

    private

    # Smooth gradient: interpolate between colors for each character
    def apply_smooth(text, colors)
      chars = text.chars
      return text if chars.length <= 1

      result = chars.each_with_index.map do |char, i|
        # Preserve spaces and newlines without coloring
        next char if char.match?(/\s/)

        position = i.to_f / (chars.length - 1)
        color = interpolate_color(colors, position)
        "<span style=\"color:#{color}\">#{escape_html(char)}</span>"
      end
      result.join
    end

    # Sharp gradient: divide text into equal sections per color
    def apply_sharp(text, colors)
      chars = text.chars
      return text if chars.empty?

      section_size = (chars.length.to_f / colors.length).ceil
      section_size = 1 if section_size < 1

      result = chars.each_with_index.map do |char, i|
        # Preserve spaces and newlines without coloring
        next char if char.match?(/\s/)

        color_index = [i / section_size, colors.length - 1].min
        "<span style=\"color:#{colors[color_index]}\">#{escape_html(char)}</span>"
      end
      result.join
    end

    # Interpolate between colors based on position (0.0 to 1.0)
    def interpolate_color(colors, position)
      return colors.first if position <= 0
      return colors.last if position >= 1

      # Find which two colors to interpolate between
      segment = position * (colors.length - 1)
      index = segment.floor
      index = [index, colors.length - 2].min

      t = segment - index
      color1 = hex_to_rgb(colors[index])
      color2 = hex_to_rgb(colors[index + 1])

      r = (color1[0] + (color2[0] - color1[0]) * t).round
      g = (color1[1] + (color2[1] - color1[1]) * t).round
      b = (color1[2] + (color2[2] - color1[2]) * t).round

      rgb_to_hex(r, g, b)
    end

    # Convert hex color to RGB array
    def hex_to_rgb(hex)
      hex = hex.gsub('#', '')
      [
        hex[0..1].to_i(16),
        hex[2..3].to_i(16),
        hex[4..5].to_i(16)
      ]
    end

    # Convert RGB values to hex string
    def rgb_to_hex(r, g, b)
      "##{r.to_s(16).rjust(2, '0')}#{g.to_s(16).rjust(2, '0')}#{b.to_s(16).rjust(2, '0')}"
    end

    # Escape HTML special characters
    def escape_html(char)
      case char
      when '<' then '&lt;'
      when '>' then '&gt;'
      when '&' then '&amp;'
      when '"' then '&quot;'
      else char
      end
    end

    # ========================================
    # Color Space Conversions (RGB ↔ XYZ ↔ Lab)
    # ========================================

    # Convert RGB [0-255] to XYZ color space (D65 illuminant)
    def rgb_to_xyz(r, g, b)
      # Normalize to 0-1 and apply gamma correction
      rn, gn, bn = [r, g, b].map do |v|
        v = v / 255.0
        v > 0.04045 ? ((v + 0.055) / 1.055)**2.4 : v / 12.92
      end

      # Scale to 0-100 range
      rn *= 100
      gn *= 100
      bn *= 100

      # RGB to XYZ matrix (D65)
      [
        rn * 0.4124564 + gn * 0.3575761 + bn * 0.1804375,
        rn * 0.2126729 + gn * 0.7151522 + bn * 0.0721750,
        rn * 0.0193339 + gn * 0.1191920 + bn * 0.9503041
      ]
    end

    # Convert XYZ to Lab color space (D65 illuminant)
    def xyz_to_lab(x, y, z)
      xr = x / REF_X
      yr = y / REF_Y
      zr = z / REF_Z

      epsilon = 0.008856
      kappa = 903.3

      f = lambda do |t|
        t > epsilon ? t**(1.0 / 3) : (kappa * t + 16) / 116
      end

      fx = f.call(xr)
      fy = f.call(yr)
      fz = f.call(zr)

      [
        116 * fy - 16,    # L*
        500 * (fx - fy),  # a*
        200 * (fy - fz)   # b*
      ]
    end

    # Convert Lab to XYZ
    def lab_to_xyz(l, a, b)
      fy = (l + 16) / 116
      fx = a / 500 + fy
      fz = fy - b / 200

      epsilon = 0.008856
      kappa = 903.3

      f_inv = lambda do |t|
        t3 = t**3
        t3 > epsilon ? t3 : (116 * t - 16) / kappa
      end

      [
        f_inv.call(fx) * REF_X,
        f_inv.call(fy) * REF_Y,
        f_inv.call(fz) * REF_Z
      ]
    end

    # Convert XYZ to RGB [0-255]
    def xyz_to_rgb(x, y, z)
      x /= 100
      y /= 100
      z /= 100

      r = x * 3.2404542 + y * -1.5371385 + z * -0.4985314
      g = x * -0.9692660 + y * 1.8760108 + z * 0.0415560
      b = x * 0.0556434 + y * -0.2040259 + z * 1.0572252

      # Inverse sRGB companding
      gamma = lambda do |v|
        v > 0.0031308 ? 1.055 * (v**(1.0 / 2.4)) - 0.055 : 12.92 * v
      end

      [
        (gamma.call(r) * 255).round.clamp(0, 255),
        (gamma.call(g) * 255).round.clamp(0, 255),
        (gamma.call(b) * 255).round.clamp(0, 255)
      ]
    end
  end
end
