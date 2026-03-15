# frozen_string_literal: true

require_relative 'string_helper'

# Shared utilities for canvas rendering.
# Extracted from MinimapService, RoommapRenderService, AreamapService.
module CanvasHelper
  include StringHelper
  extend StringHelper
  # Direction arrows for exits
  DIRECTION_ARROWS = {
    'north' => '↑', 'south' => '↓', 'east' => '→', 'west' => '←',
    'northeast' => '↗', 'northwest' => '↖', 'southeast' => '↘', 'southwest' => '↙',
    'up' => '⇑', 'down' => '⇓', 'in' => '⊙', 'out' => '⊗',
    'n' => '↑', 's' => '↓', 'e' => '→', 'w' => '←',
    'ne' => '↗', 'nw' => '↖', 'se' => '↘', 'sw' => '↙',
    'u' => '⇑', 'd' => '⇓'
  }.freeze

  # Room type indicators for delve maps
  ROOM_INDICATORS = {
    exit: 'v',
    entrance: '^',
    monster: 'M',
    treasure: '$',
    trap: 'T',
    blocker: 'X',
    danger: '!',
    chamber: 'O',
    corridor: '#'
  }.freeze

  # Transport type emojis for area maps
  TRANSPORT_INDICATORS = {
    port: '⚓',
    train_station: '🚂',
    ferry_terminal: '⛴',
    bus_depot: '🚌',
    stable: '🐴'
  }.freeze

  DIRECTION_ALIASES = {
    'n' => 'north', 's' => 'south', 'e' => 'east', 'w' => 'west',
    'u' => 'up', 'd' => 'down',
    'ne' => 'northeast', 'nw' => 'northwest',
    'se' => 'southeast', 'sw' => 'southwest',
    'out' => 'exit', 'leave' => 'exit', 'outside' => 'exit',
    'in' => 'enter', 'inside' => 'enter'
  }.freeze

  VALID_DIRECTIONS = %w[north south east west up down northeast northwest southeast southwest exit enter].freeze

  # Opposite directions lookup - canonical source for all direction mappings.
  # Used by opposite_direction and arrival_direction methods.
  OPPOSITE_DIRECTIONS = {
    'north' => 'south', 'south' => 'north',
    'east' => 'west', 'west' => 'east',
    'northeast' => 'southwest', 'southwest' => 'northeast',
    'northwest' => 'southeast', 'southeast' => 'northwest',
    'up' => 'down', 'down' => 'up',
    'in' => 'out', 'out' => 'in',
    'enter' => 'exit', 'exit' => 'enter',
    # Abbreviations
    'n' => 'south', 's' => 'north',
    'e' => 'west', 'w' => 'east',
    'ne' => 'southwest', 'sw' => 'northeast',
    'nw' => 'southeast', 'se' => 'northwest',
    'u' => 'down', 'd' => 'up'
  }.freeze

  class << self
    # Normalize direction aliases to full direction names.
    # @param input [String, nil] Direction string or abbreviation
    # @return [String, nil] Full direction name, or nil for unknown input
    def normalize_direction(input)
      dir = input.to_s.downcase.strip
      return dir if VALID_DIRECTIONS.include?(dir)

      DIRECTION_ALIASES[dir]
    end

    # Sanitize text for canvas commands.
    # Removes HTML tags and escapes special characters that could break command format.
    # @param text [String, nil] Text to sanitize
    # @return [String] Sanitized text
    # Note: This delegates to sanitize_for_canvas from StringHelper
    def sanitize_text(text)
      sanitize_for_canvas(text)
    end

    # Truncate a name with ellipsis if too long.
    # @param name [String, nil] Name to truncate
    # @param max_length [Integer] Maximum length before truncation
    # @return [String] Truncated name
    def truncate_name(name, max_length = 15)
      return '' if name.nil?

      name.length > max_length ? "#{name[0..max_length - 4]}..." : name
    end

    # Get the direction arrow for a given direction.
    # @param direction [String] Direction name (e.g., 'north', 'n', 'up')
    # @return [String] Unicode arrow or empty string
    def direction_arrow(direction)
      return '' unless direction

      DIRECTION_ARROWS[direction.to_s.downcase] || ''
    end

    # Get the opposite direction.
    # @param direction [String] Direction name
    # @param fallback [String] Value to return if direction not found (default: original direction)
    # @return [String] Opposite direction
    def opposite_direction(direction, fallback: :direction)
      return (fallback == :direction ? direction.to_s : fallback) if direction.nil?

      result = OPPOSITE_DIRECTIONS[direction.to_s.downcase]
      return result if result

      # Return fallback - default is the original direction, nil means return nil
      fallback == :direction ? direction.to_s : fallback
    end

    # Get the arrival direction for narrative text (e.g., "arrives from the south").
    # Different from opposite_direction in that up/down become below/above.
    # @param from_direction [String] Direction the character came FROM
    # @param fallback [String] Fallback if direction not found (default: 'somewhere')
    # @return [String] Narrative arrival direction
    def arrival_direction(from_direction, fallback: 'somewhere')
      return fallback if from_direction.nil?

      opposite = opposite_direction(from_direction, fallback: nil)
      return fallback unless opposite

      # Convert up/down to narrative form for "from the X" phrasing
      case opposite
      when 'up' then 'above'
      when 'down' then 'below'
      else opposite
      end
    end

    # Calculate the position offset for a direction (as percentage or multiplier).
    # Used for placing exit rooms on minimap.
    # @param direction [String] Direction name
    # @return [Hash<Symbol, Float>] Position multipliers { x: 0.0-1.0, y: 0.0-1.0 }
    def direction_position(direction)
      case direction.to_s.downcase
      when 'north', 'n' then { x: 0.5, y: 0.15 }
      when 'south', 's' then { x: 0.5, y: 0.85 }
      when 'east', 'e' then { x: 0.85, y: 0.5 }
      when 'west', 'w' then { x: 0.15, y: 0.5 }
      when 'northeast', 'ne' then { x: 0.8, y: 0.2 }
      when 'northwest', 'nw' then { x: 0.2, y: 0.2 }
      when 'southeast', 'se' then { x: 0.8, y: 0.8 }
      when 'southwest', 'sw' then { x: 0.2, y: 0.8 }
      when 'up', 'u' then { x: 0.35, y: 0.25 }
      when 'down', 'd' then { x: 0.65, y: 0.75 }
      else { x: 0.5, y: 0.5 }
      end
    end

    # Calculate canvas coordinates for a direction-based exit.
    # @param direction [String] Direction name
    # @param canvas_width [Integer] Canvas width
    # @param canvas_height [Integer] Canvas height
    # @param element_size [Integer] Size of the element being placed
    # @param padding [Integer] Edge padding
    # @return [Array<Integer>] [x, y] canvas coordinates
    def direction_to_canvas_coords(direction, canvas_width, canvas_height, element_size: 15, padding: 20)
      pos = direction_position(direction)
      x = (canvas_width * pos[:x]).to_i
      y = (canvas_height * pos[:y]).to_i

      # Clamp to stay within bounds
      half = element_size / 2
      x = [[x, padding + half].max, canvas_width - padding - half].min
      y = [[y, padding + half].max, canvas_height - padding - half].min

      [x, y]
    end

    # Calculate bounds for a collection of elements with coordinates.
    # @param elements [Array] Elements responding to x/y or grid_x/grid_y
    # @param x_method [Symbol] Method to get x coordinate (:x, :grid_x, :hex_x)
    # @param y_method [Symbol] Method to get y coordinate (:y, :grid_y, :hex_y)
    # @return [Hash] { min_x:, max_x:, min_y:, max_y:, width:, height: }
    def calculate_bounds(elements, x_method: :x, y_method: :y)
      return { min_x: 0, max_x: 100, min_y: 0, max_y: 100, width: 100, height: 100 } if elements.empty?

      xs = elements.map { |e| e.send(x_method) }.compact
      ys = elements.map { |e| e.send(y_method) }.compact

      return { min_x: 0, max_x: 100, min_y: 0, max_y: 100, width: 100, height: 100 } if xs.empty? || ys.empty?

      min_x = xs.min
      max_x = xs.max
      min_y = ys.min
      max_y = ys.max

      {
        min_x: min_x,
        max_x: max_x,
        min_y: min_y,
        max_y: max_y,
        width: max_x - min_x,
        height: max_y - min_y
      }
    end

    # Calculate scale factors to fit content within canvas dimensions.
    # @param content_width [Numeric] Width of content area
    # @param content_height [Numeric] Height of content area
    # @param canvas_width [Integer] Available canvas width
    # @param canvas_height [Integer] Available canvas height
    # @param padding [Integer] Padding on each side
    # @return [Hash] { scale_x:, scale_y:, scale: (unified) }
    def calculate_scale(content_width, content_height, canvas_width, canvas_height, padding: 20)
      usable_width = canvas_width - (2 * padding)
      usable_height = canvas_height - (2 * padding)

      # Avoid division by zero
      content_width = 1 if content_width <= 0
      content_height = 1 if content_height <= 0

      scale_x = usable_width.to_f / content_width
      scale_y = usable_height.to_f / content_height
      unified_scale = [scale_x, scale_y].min

      {
        scale_x: scale_x,
        scale_y: scale_y,
        scale: unified_scale
      }
    end

    # Generate a hex color by blending two colors.
    # @param color1 [String] Start color (hex)
    # @param color2 [String] End color (hex)
    # @param ratio [Float] Blend ratio (0.0 = color1, 1.0 = color2)
    # @return [String] Blended hex color
    def blend_colors(color1, color2, ratio)
      r1, g1, b1 = parse_hex_color(color1)
      r2, g2, b2 = parse_hex_color(color2)

      r = ((r1 * (1 - ratio)) + (r2 * ratio)).to_i
      g = ((g1 * (1 - ratio)) + (g2 * ratio)).to_i
      b = ((b1 * (1 - ratio)) + (b2 * ratio)).to_i

      format('#%02x%02x%02x', r, g, b)
    end

    private

    def parse_hex_color(hex)
      hex = hex.gsub('#', '')
      [
        hex[0..1].to_i(16),
        hex[2..3].to_i(16),
        hex[4..5].to_i(16)
      ]
    end
  end
end
