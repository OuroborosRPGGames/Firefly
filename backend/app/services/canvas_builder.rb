# frozen_string_literal: true

# Fluent DSL for building canvas commands.
# Replaces manual string concatenation with a cleaner API.
#
# @example Basic usage
#   canvas = CanvasBuilder.new(width: 200, height: 176)
#   canvas.filled_rect(x: 0, y: 0, width: 200, height: 176, color: '#0a0a0a')
#   canvas.circle(cx: 100, cy: 88, radius: 10, color: '#00bcd4', filled: true)
#   canvas.text(x: 100, y: 88, text: 'Center', font: 'sans-serif')
#   canvas.render  # => "200|||176|||frect::#0a0a0a,0,0,200,176;;;fcircle::#00bcd4,100,88,10;;;..."
#
# @example With palettes and layers
#   canvas = CanvasBuilder.new(width: 200, height: 176)
#   canvas.use_palette(:minimap)
#   canvas.layer(:background) { |c| c.filled_rect(x: 0, y: 0, width: 200, height: 176, color: :background) }
#   canvas.layer(:entities) { |c| c.circle(cx: 100, cy: 88, radius: 10, color: :current_room) }
#   canvas.render
#
# @example With interactivity
#   canvas.circle(cx: 50, cy: 50, radius: 20, color: '#00bcd4', filled: true,
#                 id: 'exit_north', data: { tooltip: 'Market Street', action: 'navigate', command: 'north' })
#   canvas.render  # Returns commands + hit regions for click handling
#
class CanvasBuilder
  # Predefined color palettes from existing services
  PALETTES = {
    minimap: {
      background: '#0a0a0a',
      current_room: '#00bcd4',
      exit_room: '#2a2a2a',
      door: '#666666',
      text: '#ffffff',
      exit_text: '#aaaaaa',
      arrow: '#666666'
    },
    roommap: {
      background: '#1a1a1a',
      wall: '#444444',
      floor: '#2a2a2a',
      place: '#663300',
      place_text: '#ccaa77',
      exit: '#336633',
      exit_text: '#88cc88',
      character: '#22cc22',
      npc: '#888888',
      self_color: '#ff4444',
      self_text: '#ffffff',
      label: '#aaaaaa'
    },
    areamap: {
      background: '#1a1a1a',
      building: '#d5d8dc',
      current_building: '#f1948a',
      landmark: '#e74c3c',
      character: '#ff0000',
      text: '#ffffff',
      feature_text: '#aaaaaa',
      # Terrain colors - natural earth tones
      ocean: '#2d5f8a',
      lake: '#4a8ab5',
      coast: '#8a9a8d',
      plain: '#a8b878',
      field: '#c4ba8a',
      urban: '#7a7a7a',
      forest: '#3a6632',
      swamp: '#5a6b48',
      mountain: '#8a7d6b',
      hill: '#96a07a',
      desert: '#c8b48a',
      ice: '#d8e0e4',
      # Feature colors
      road: '#7f8c8d',
      highway: '#f39c12',
      street: '#95a5a6',
      trail: '#d7ccc8',
      river: '#3498db',
      canal: '#4a8ab5',
      railway: '#2c3e50'
    },
    delve: {
      corridor: '#666666',
      chamber: '#888888',
      treasure: '#FFD700',
      monster: '#FF4444',
      trap: '#FF8800',
      puzzle: '#8844FF',
      boss: '#FF0000',
      exit: '#00FF00',
      player: '#00AAFF',
      fog: '#222222',
      unexplored: '#111111',
      danger_hint: '#AA4444',
      exit_marker: '#44FF44',
      connection: '#444444'
    }
  }.freeze

  # Layer ordering (lower = rendered first/behind)
  LAYER_ORDER = %i[background terrain features entities ui overlay].freeze

  attr_reader :width, :height, :commands, :hit_regions, :palette

  def initialize(width:, height:)
    @width = width
    @height = height
    @commands = []
    @layers = Hash.new { |h, k| h[k] = [] }
    @hit_regions = []
    @palette = {}
    @transform = :none
    @transform_context = {}
  end

  # Set the color palette for symbol-based colors
  # @param name [Symbol] Palette name (:minimap, :roommap, :areamap, :delve)
  # @return [self]
  def use_palette(name)
    @palette = PALETTES[name] || {}
    self
  end

  # Set coordinate transformation mode
  # @param type [Symbol] Transform type (:none, :invert_y, :room_to_canvas)
  # @param context [Hash] Additional context for transforms (min_x, max_x, min_y, max_y, padding, etc.)
  # @return [self]
  def set_transform(type, **context)
    @transform = type
    @transform_context = context
    self
  end

  # Add commands to a named layer
  # @param name [Symbol] Layer name (:background, :terrain, :features, :entities, :ui, :overlay)
  # @yield [CanvasBuilder] Builder scoped to this layer
  # @return [self]
  def layer(name, &block)
    layer_builder = LayerBuilder.new(self)
    block.call(layer_builder)
    @layers[name].concat(layer_builder.commands)
    @hit_regions.concat(layer_builder.hit_regions)
    self
  end

  # Draw a line
  # @param x1 [Numeric] Start x
  # @param y1 [Numeric] Start y
  # @param x2 [Numeric] End x
  # @param y2 [Numeric] End y
  # @param color [String, Symbol] Color (hex string or palette key)
  # @return [self]
  def line(x1:, y1:, x2:, y2:, color:)
    tx1, ty1 = transform_point(x1, y1)
    tx2, ty2 = transform_point(x2, y2)
    @commands << "line::#{resolve_color(color)},#{tx1.to_i},#{ty1.to_i},#{tx2.to_i},#{ty2.to_i}"
    self
  end

  # Draw a dashed line
  # @param x1 [Numeric] Start x
  # @param y1 [Numeric] Start y
  # @param x2 [Numeric] End x
  # @param y2 [Numeric] End y
  # @param color [String, Symbol] Color
  # @param dash_length [Integer] Length of each dash
  # @param gap_length [Integer] Length of gap between dashes
  # @return [self]
  def dashed_line(x1:, y1:, x2:, y2:, color:, dash_length: 5, gap_length: 3)
    tx1, ty1 = transform_point(x1, y1)
    tx2, ty2 = transform_point(x2, y2)
    @commands << "dashed::#{resolve_color(color)},#{tx1.to_i},#{ty1.to_i},#{tx2.to_i},#{ty2.to_i},#{dash_length},#{gap_length}"
    self
  end

  # Draw a rectangle (outline only)
  # @param x [Numeric] Top-left x
  # @param y [Numeric] Top-left y
  # @param width [Numeric] Width
  # @param height [Numeric] Height
  # @param color [String, Symbol] Color
  # @return [self]
  def rect(x:, y:, width:, height:, color:)
    tx, ty = transform_point(x, y)
    @commands << "rect::#{resolve_color(color)},#{tx.to_i},#{ty.to_i},#{(tx + width).to_i},#{(ty + height).to_i}"
    self
  end

  # Draw a filled rectangle
  # @param x [Numeric] Top-left x
  # @param y [Numeric] Top-left y
  # @param width [Numeric] Width
  # @param height [Numeric] Height
  # @param color [String, Symbol] Color
  # @param id [String] Optional ID for hit detection
  # @param data [Hash] Optional data for interactivity (tooltip, action, command)
  # @return [self]
  def filled_rect(x:, y:, width:, height:, color:, id: nil, data: nil)
    tx, ty = transform_point(x, y)
    x1 = tx.to_i
    y1 = ty.to_i
    x2 = (tx + width).to_i
    y2 = (ty + height).to_i
    @commands << "frect::#{resolve_color(color)},#{x1},#{y1},#{x2},#{y2}"
    add_hit_region(id: id, shape: :rect, x: x1, y: y1, width: width.to_i, height: height.to_i, data: data) if id
    self
  end

  # Draw a rounded rectangle (outline only)
  # @param x [Numeric] Top-left x
  # @param y [Numeric] Top-left y
  # @param width [Numeric] Width
  # @param height [Numeric] Height
  # @param radius [Numeric] Corner radius
  # @param color [String, Symbol] Color
  # @return [self]
  def rounded_rect(x:, y:, width:, height:, radius:, color:)
    tx, ty = transform_point(x, y)
    @commands << "roundrect::#{resolve_color(color)},#{tx.to_i},#{ty.to_i},#{(tx + width).to_i},#{(ty + height).to_i},#{radius.to_i}"
    self
  end

  # Draw a filled rounded rectangle
  # @param x [Numeric] Top-left x
  # @param y [Numeric] Top-left y
  # @param width [Numeric] Width
  # @param height [Numeric] Height
  # @param radius [Numeric] Corner radius
  # @param color [String, Symbol] Color
  # @param id [String] Optional ID for hit detection
  # @param data [Hash] Optional data for interactivity
  # @return [self]
  def filled_rounded_rect(x:, y:, width:, height:, radius:, color:, id: nil, data: nil)
    tx, ty = transform_point(x, y)
    x1 = tx.to_i
    y1 = ty.to_i
    x2 = (tx + width).to_i
    y2 = (ty + height).to_i
    @commands << "froundrect::#{resolve_color(color)},#{x1},#{y1},#{x2},#{y2},#{radius.to_i}"
    add_hit_region(id: id, shape: :rect, x: x1, y: y1, width: width.to_i, height: height.to_i, data: data) if id
    self
  end

  # Draw a circle (outline only)
  # @param cx [Numeric] Center x
  # @param cy [Numeric] Center y
  # @param radius [Numeric] Radius
  # @param color [String, Symbol] Color
  # @return [self]
  def circle(cx:, cy:, radius:, color:)
    tcx, tcy = transform_point(cx, cy)
    @commands << "circle::#{resolve_color(color)},#{tcx.to_i},#{tcy.to_i},#{radius.to_i}"
    self
  end

  # Draw a filled circle
  # @param cx [Numeric] Center x
  # @param cy [Numeric] Center y
  # @param radius [Numeric] Radius
  # @param color [String, Symbol] Color
  # @param id [String] Optional ID for hit detection
  # @param data [Hash] Optional data for interactivity
  # @return [self]
  def filled_circle(cx:, cy:, radius:, color:, id: nil, data: nil)
    tcx, tcy = transform_point(cx, cy)
    @commands << "fcircle::#{resolve_color(color)},#{tcx.to_i},#{tcy.to_i},#{radius.to_i}"
    add_hit_region(id: id, shape: :circle, cx: tcx.to_i, cy: tcy.to_i, radius: radius.to_i, data: data) if id
    self
  end

  # Draw an arc (partial circle outline)
  # @param cx [Numeric] Center x
  # @param cy [Numeric] Center y
  # @param radius [Numeric] Radius
  # @param start_angle [Numeric] Start angle in degrees
  # @param end_angle [Numeric] End angle in degrees
  # @param color [String, Symbol] Color
  # @return [self]
  def arc(cx:, cy:, radius:, start_angle:, end_angle:, color:)
    tcx, tcy = transform_point(cx, cy)
    @commands << "arc::#{resolve_color(color)},#{tcx.to_i},#{tcy.to_i},#{radius.to_i},#{start_angle},#{end_angle}"
    self
  end

  # Draw a polygon (outline only)
  # @param points [Array<Array<Numeric>>] Array of [x, y] coordinate pairs
  # @param color [String, Symbol] Color
  # @return [self]
  def polygon(points:, color:)
    transformed = points.map { |x, y| transform_point(x, y).map(&:to_i) }
    coords = transformed.flatten.join(',')
    @commands << "poly::#{resolve_color(color)},#{coords}"
    self
  end

  # Draw a filled polygon
  # @param points [Array<Array<Numeric>>] Array of [x, y] coordinate pairs
  # @param color [String, Symbol] Color
  # @param id [String] Optional ID for hit detection
  # @param data [Hash] Optional data for interactivity
  # @return [self]
  def filled_polygon(points:, color:, id: nil, data: nil)
    transformed = points.map { |x, y| transform_point(x, y).map(&:to_i) }
    coords = transformed.flatten.join(',')
    @commands << "fpoly::#{resolve_color(color)},#{coords}"
    add_hit_region(id: id, shape: :polygon, points: transformed, data: data) if id
    self
  end

  # Draw a gradient-filled rectangle
  # @param x [Numeric] Top-left x
  # @param y [Numeric] Top-left y
  # @param width [Numeric] Width
  # @param height [Numeric] Height
  # @param color1 [String, Symbol] Start color
  # @param color2 [String, Symbol] End color
  # @param direction [Symbol] Gradient direction (:vertical, :horizontal, :diagonal)
  # @return [self]
  def gradient_rect(x:, y:, width:, height:, color1:, color2:, direction: :vertical)
    tx, ty = transform_point(x, y)
    dir_char = case direction
               when :horizontal then 'h'
               when :diagonal then 'd'
               else 'v'
               end
    @commands << "gradient::#{resolve_color(color1)},#{resolve_color(color2)},#{dir_char},#{tx.to_i},#{ty.to_i},#{(tx + width).to_i},#{(ty + height).to_i}"
    self
  end

  # Draw text at a position
  # @param x [Numeric] x position
  # @param y [Numeric] y position
  # @param text [String] Text to draw
  # @param font [String] Font family
  # @param color [String, Symbol] Optional color (nil = default)
  # @return [self]
  def text(x:, y:, text:, font: 'sans-serif', color: nil)
    tx, ty = transform_point(x, y)
    sanitized = CanvasHelper.sanitize_text(text)
    if color
      @commands << "coltext::#{resolve_color(color)},#{tx.to_i},#{ty.to_i}||#{font}||#{sanitized}"
    else
      @commands << "text::#{tx.to_i},#{ty.to_i}||#{font}||#{sanitized}"
    end
    self
  end

  # Draw text that auto-fits within a rectangle
  # @param x1 [Numeric] Top-left x
  # @param y1 [Numeric] Top-left y
  # @param x2 [Numeric] Bottom-right x
  # @param y2 [Numeric] Bottom-right y
  # @param text [String] Text to draw
  # @param font [String] Font family
  # @return [self]
  def text_in_rect(x1:, y1:, x2:, y2:, text:, font: 'sans-serif')
    tx1, ty1 = transform_point(x1, y1)
    tx2, ty2 = transform_point(x2, y2)
    sanitized = CanvasHelper.sanitize_text(text)
    @commands << "textrect::#{tx1.to_i},#{ty1.to_i},#{tx2.to_i},#{ty2.to_i}||#{font}||#{sanitized}"
    self
  end

  # Draw rotated text
  # @param x [Numeric] x position
  # @param y [Numeric] y position
  # @param text [String] Text to draw
  # @param angle [Numeric] Rotation angle in degrees
  # @param font [String] Font family
  # @param color [String, Symbol] Color
  # @return [self]
  def rotated_text(x:, y:, text:, angle:, font: 'sans-serif', color:)
    tx, ty = transform_point(x, y)
    sanitized = CanvasHelper.sanitize_text(text)
    @commands << "vtext::#{resolve_color(color)},#{tx.to_i},#{ty.to_i},#{angle}||#{font}||#{sanitized}"
    self
  end

  # Draw an image
  # @param url [String] Image URL
  # @param x [Numeric] Top-left x
  # @param y [Numeric] Top-left y
  # @param width [Numeric] Width
  # @param height [Numeric] Height
  # @return [self]
  def image(url:, x:, y:, width:, height:)
    tx, ty = transform_point(x, y)
    @commands << "img::#{url},#{tx.to_i},#{ty.to_i},#{width.to_i},#{height.to_i}"
    self
  end

  # Generate the final canvas command string
  # @param include_hit_regions [Boolean] Whether to include hit regions for interactivity
  # @return [String] Canvas format: width|||height|||commands or width|||height|||commands|||hitRegions
  def render(include_hit_regions: false)
    # Collect commands from layers in order, then add non-layered commands
    final_commands = []
    LAYER_ORDER.each do |layer_name|
      final_commands.concat(@layers[layer_name]) if @layers.key?(layer_name)
    end
    final_commands.concat(@commands)

    base = "#{width}|||#{height}|||#{final_commands.join(';;;')}"

    if include_hit_regions && !@hit_regions.empty?
      require 'base64'
      require 'json'
      encoded_regions = Base64.strict_encode64(@hit_regions.to_json)
      "#{base}|||#{encoded_regions}"
    else
      base
    end
  end

  private

  def resolve_color(color)
    return color if color.is_a?(String) && color.start_with?('#')
    return @palette[color] || '#ffffff' if color.is_a?(Symbol)

    color.to_s
  end

  def transform_point(x, y)
    case @transform
    when :invert_y
      # Canvas Y is inverted (0 at top)
      max_y = @transform_context[:max_y] || height
      [x, max_y - y]
    when :room_to_canvas
      # Full room-to-canvas transformation
      padding = @transform_context[:padding] || 0
      min_x = @transform_context[:min_x] || 0
      max_y = @transform_context[:max_y] || 100
      scale_x = @transform_context[:scale_x] || 1
      scale_y = @transform_context[:scale_y] || 1
      cx = padding + ((x - min_x) * scale_x)
      cy = padding + ((max_y - y) * scale_y)
      [cx, cy]
    else
      [x, y]
    end
  end

  def add_hit_region(id:, shape:, data:, **geometry)
    return unless id

    region = { id: id, shape: shape.to_s, data: data || {} }
    region.merge!(geometry)
    @hit_regions << region
  end

  # Internal builder for layer blocks
  class LayerBuilder
    attr_reader :commands, :hit_regions

    def initialize(parent)
      @parent = parent
      @commands = []
      @hit_regions = []
    end

    # Delegate all drawing methods to parent but capture commands
    %i[line dashed_line rect filled_rect rounded_rect filled_rounded_rect
       circle filled_circle arc polygon filled_polygon gradient_rect
       text text_in_rect rotated_text image].each do |method_name|
      define_method(method_name) do |**args|
        # Create temporary parent copy for this call
        temp_parent = @parent.dup
        temp_parent.instance_variable_set(:@commands, [])
        temp_parent.instance_variable_set(:@hit_regions, [])
        temp_parent.send(method_name, **args)
        @commands.concat(temp_parent.commands)
        @hit_regions.concat(temp_parent.hit_regions)
        self
      end
    end
  end
end
