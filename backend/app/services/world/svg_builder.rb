# frozen_string_literal: true

require_relative '../../lib/world_terrain_config'

# SvgBuilder provides a fluent DSL for constructing SVG documents.
#
# Generates SVG XML without external dependencies.
#
# @example Basic usage
#   svg = SvgBuilder.new(800, 600)
#   svg.rect(10, 10, 100, 50, fill: '#ff0000')
#   svg.circle(200, 200, 30, fill: '#00ff00', stroke: '#000')
#   svg.text(50, 50, 'Hello', font_size: 14)
#   svg.to_xml
#
class SvgBuilder
  TERRAIN_COLORS = WorldTerrainConfig::TERRAIN_COLORS


  # Building type colors
  BUILDING_COLORS = {
    apartment_tower: '#6a6a6a',
    brownstone: '#8b4513',
    house: '#daa520',
    shop: '#4682b4',
    cafe: '#cd853f',
    bar: '#800020',
    restaurant: '#dc143c',
    mall: '#4169e1',
    church: '#f0e68c',
    hospital: '#ff6347',
    police_station: '#1e90ff',
    park: '#32cd32',
    intersection: '#404040',
    street: '#555555',
    avenue: '#555555'
  }.freeze

  # Room type colors
  ROOM_COLORS = {
    standard: '#2d3748',
    exterior: '#4a5568',
    vehicle: '#718096',
    water: '#3182ce',
    sky: '#90cdf4',
    underground: '#1a202c'
  }.freeze

  def initialize(width, height, background: '#0d1117')
    @width = width
    @height = height
    @background = background
    @elements = []
    @defs = []
  end

  # Add a rectangle
  # @param x [Numeric] top-left x
  # @param y [Numeric] top-left y
  # @param width [Numeric] width
  # @param height [Numeric] height
  # @param options [Hash] SVG attributes (fill, stroke, stroke_width, rx, ry, opacity, transform)
  def rect(x, y, width, height, **options)
    attrs = { x: x, y: y, width: width, height: height }.merge(normalize_options(options))
    @elements << element('rect', attrs)
    self
  end

  # Add a circle
  # @param cx [Numeric] center x
  # @param cy [Numeric] center y
  # @param r [Numeric] radius
  # @param options [Hash] SVG attributes
  def circle(cx, cy, r, **options)
    attrs = { cx: cx, cy: cy, r: r }.merge(normalize_options(options))
    @elements << element('circle', attrs)
    self
  end

  # Add an ellipse
  # @param cx [Numeric] center x
  # @param cy [Numeric] center y
  # @param rx [Numeric] x radius
  # @param ry [Numeric] y radius
  # @param options [Hash] SVG attributes
  def ellipse(cx, cy, rx, ry, **options)
    attrs = { cx: cx, cy: cy, rx: rx, ry: ry }.merge(normalize_options(options))
    @elements << element('ellipse', attrs)
    self
  end

  # Add a line
  # @param x1 [Numeric] start x
  # @param y1 [Numeric] start y
  # @param x2 [Numeric] end x
  # @param y2 [Numeric] end y
  # @param options [Hash] SVG attributes
  def line(x1, y1, x2, y2, **options)
    attrs = { x1: x1, y1: y1, x2: x2, y2: y2 }.merge(normalize_options(options))
    @elements << element('line', attrs)
    self
  end

  # Add a polyline
  # @param points [Array<Array>] array of [x, y] pairs
  # @param options [Hash] SVG attributes
  def polyline(points, **options)
    points_str = points.map { |p| p.join(',') }.join(' ')
    attrs = { points: points_str }.merge(normalize_options(options))
    @elements << element('polyline', attrs)
    self
  end

  # Add a polygon
  # @param points [Array<Array>] array of [x, y] pairs
  # @param options [Hash] SVG attributes
  def polygon(points, **options)
    points_str = points.map { |p| p.join(',') }.join(' ')
    attrs = { points: points_str }.merge(normalize_options(options))
    @elements << element('polygon', attrs)
    self
  end

  # Add a path
  # @param d [String] path data
  # @param options [Hash] SVG attributes
  def path(d, **options)
    attrs = { d: d }.merge(normalize_options(options))
    @elements << element('path', attrs)
    self
  end

  # Add text
  # @param x [Numeric] x position
  # @param y [Numeric] y position
  # @param content [String] text content
  # @param options [Hash] SVG attributes (font_size, font_family, text_anchor, fill)
  def text(x, y, content, **options)
    attrs = { x: x, y: y }.merge(normalize_options(options))
    @elements << element('text', attrs, escape_html(content))
    self
  end

  # Add a group with optional transform
  # @param options [Hash] group attributes (transform, id, class)
  # @yield block to add elements to group
  def group(**options, &block)
    saved_elements = @elements
    @elements = []
    yield
    children = @elements.join("\n")
    @elements = saved_elements
    attrs = normalize_options(options)
    @elements << "<g#{attrs_to_str(attrs)}>\n#{children}\n</g>"
    self
  end

  # Add raw SVG markup (for pre-built elements like tspan-based text)
  # @param xml_string [String] raw SVG XML to insert
  def raw(xml_string)
    @elements << xml_string
    self
  end

  # Add a hexagon (flat-top orientation)
  # @param cx [Numeric] center x
  # @param cy [Numeric] center y
  # @param size [Numeric] distance from center to corner
  # @param options [Hash] SVG attributes
  def hexagon(cx, cy, size, **options)
    # Flat-top hexagon vertices
    points = (0..5).map do |i|
      angle = (60 * i - 30) * Math::PI / 180
      [cx + size * Math.cos(angle), cy + size * Math.sin(angle)]
    end
    polygon(points, **options)
  end

  # Add a world hex at grid position
  # @param hex [WorldHex] the world hex record
  # @param offset_x [Numeric] pixel offset x
  # @param offset_y [Numeric] pixel offset y
  # @param hex_size [Numeric] hex size in pixels
  def add_world_hex(hex, offset_x: 0, offset_y: 0, hex_size: 20)
    # Calculate pixel position from hex coords (flat-top)
    px = offset_x + hex_size * 1.5 * hex.hex_x
    py = offset_y + hex_size * Math.sqrt(3) * (hex.hex_y + (hex.hex_x.odd? ? 0.5 : 0))

    color = WorldTerrainConfig::TERRAIN_COLORS[hex.terrain_type] || WorldTerrainConfig::TERRAIN_COLORS['unknown']
    hexagon(px, py, hex_size, fill: color, stroke: '#1a1a1a', stroke_width: 0.5)

    # Add feature icons
    if hex.features.is_a?(Array) && hex.features.any?
      feature_text = hex.features.first.to_s[0..1].upcase
      text(px, py + 4, feature_text, font_size: 8, fill: '#fff', text_anchor: 'middle')
    end

    self
  end

  # Add a city grid building
  # @param room [Room] room record
  # @param scale [Numeric] pixels per foot
  # @param offset_x [Numeric] pixel offset
  # @param offset_y [Numeric] pixel offset
  def add_building(room, scale: 1.0, offset_x: 0, offset_y: 0)
    return self unless room.min_x && room.min_y

    x = offset_x + room.min_x * scale
    y = offset_y + room.min_y * scale
    w = (room.max_x - room.min_x) * scale
    h = (room.max_y - room.min_y) * scale

    building_type = room.room_type&.to_sym
    color = BUILDING_COLORS[building_type] || '#4a4a4a'

    rect(x, y, w, h, fill: color, stroke: '#2d3748', stroke_width: 1)

    # Add label if space allows
    if w > 30 && h > 15
      label = room.name&.slice(0, 10) || ''
      text(x + w / 2, y + h / 2 + 4, label, font_size: 9, fill: '#fff', text_anchor: 'middle')
    end

    self
  end

  # Add a room interior element
  # @param room [Room] room record
  # @param width [Numeric] viewport width
  # @param height [Numeric] viewport height
  def add_room_bounds(room, width:, height:)
    # Calculate scale to fit room in viewport
    room_w = (room.max_x || 100) - (room.min_x || 0)
    room_h = (room.max_y || 100) - (room.min_y || 0)

    padding = 20
    scale_x = (width - padding * 2) / room_w.to_f
    scale_y = (height - padding * 2) / room_h.to_f
    scale = [scale_x, scale_y].min

    @room_scale = scale
    @room_offset_x = padding - (room.min_x || 0) * scale
    @room_offset_y = padding - (room.min_y || 0) * scale

    room_color = ROOM_COLORS[room.room_type&.to_sym] || ROOM_COLORS[:standard]
    rect(padding, padding, room_w * scale, room_h * scale,
         fill: room_color, stroke: '#4a5568', stroke_width: 2)

    # Add polygon if custom
    if room.has_custom_polygon?
      polygon_points = room.room_polygon.map do |pt|
        [
          @room_offset_x + pt[0] * scale,
          @room_offset_y + pt[1] * scale
        ]
      end
      polygon(polygon_points, fill: 'none', stroke: '#10b981', stroke_width: 2, stroke_dasharray: '4,4')
    end

    self
  end

  # Add furniture/place to room
  # @param place [Place] place record
  def add_furniture(place)
    return self unless @room_scale

    x = @room_offset_x + place.x * @room_scale
    y = @room_offset_y + place.y * @room_scale
    size = 10 * @room_scale

    rect(x - size / 2, y - size / 2, size, size,
         fill: '#4a5568', stroke: '#718096', stroke_width: 1, rx: 2)

    text(x, y + 3, place.name&.slice(0, 3)&.upcase || 'FRN',
         font_size: 7, fill: '#fff', text_anchor: 'middle')

    self
  end

  # Add exit arrow to room
  # @param exit_data [Hash] spatial exit data with :direction and :room keys
  # @param x [Float] optional x position override
  # @param y [Float] optional y position override
  def add_exit(exit_data, x: nil, y: nil)
    return self unless @room_scale

    direction = exit_data.is_a?(Hash) ? exit_data[:direction].to_s : exit_data.direction.to_s
    x ||= 50
    y ||= 50
    px = @room_offset_x + x * @room_scale
    py = @room_offset_y + y * @room_scale

    # Draw directional arrow
    arrow_size = 8
    direction_angles = {
      'north' => -90, 'south' => 90, 'east' => 0, 'west' => 180,
      'northeast' => -45, 'northwest' => -135, 'southeast' => 45, 'southwest' => 135,
      'up' => -90, 'down' => 90
    }
    angle = direction_angles[direction] || 0

    group(transform: "translate(#{px},#{py}) rotate(#{angle})") do
      # Arrow shape pointing right
      path('M -4 -4 L 4 0 L -4 4 Z', fill: '#ef4444')
    end

    self
  end

  # Add city grid
  # @param location [Location] city location
  # @param scale [Numeric] pixels per cell
  def add_city_grid(location, scale: 5.0)
    streets = location.horizontal_streets || 10
    avenues = location.vertical_streets || 10

    cell_size = GridCalculationService::GRID_CELL_SIZE * scale
    street_width = GridCalculationService::STREET_WIDTH * scale

    # Draw street grid
    (0..streets).each do |y|
      py = y * cell_size
      rect(0, py - street_width / 2, avenues * cell_size, street_width,
           fill: '#404040', stroke: 'none')
    end

    (0..avenues).each do |x|
      px = x * cell_size
      rect(px - street_width / 2, 0, street_width, streets * cell_size,
           fill: '#404040', stroke: 'none')
    end

    self
  end

  # Generate final SVG XML
  # @return [String] complete SVG document
  def to_xml
    defs_section = @defs.any? ? "<defs>\n#{@defs.join("\n")}\n</defs>" : ''

    <<~SVG
      <?xml version="1.0" encoding="UTF-8"?>
      <svg xmlns="http://www.w3.org/2000/svg" width="#{@width}" height="#{@height}" viewBox="0 0 #{@width} #{@height}">
        <rect width="100%" height="100%" fill="#{@background}"/>
        #{defs_section}
        #{@elements.join("\n")}
      </svg>
    SVG
  end

  private

  def element(tag, attrs, content = nil)
    if content
      "<#{tag}#{attrs_to_str(attrs)}>#{content}</#{tag}>"
    else
      "<#{tag}#{attrs_to_str(attrs)}/>"
    end
  end

  def attrs_to_str(attrs)
    return '' if attrs.empty?

    ' ' + attrs.map { |k, v| "#{k}=\"#{v}\"" }.join(' ')
  end

  def normalize_options(options)
    # Convert Ruby-style keys to SVG attributes
    options.transform_keys do |key|
      case key
      when :stroke_width then 'stroke-width'
      when :stroke_dasharray then 'stroke-dasharray'
      when :font_size then 'font-size'
      when :font_family then 'font-family'
      when :text_anchor then 'text-anchor'
      else key.to_s.tr('_', '-')
      end
    end
  end

  def escape_html(str)
    str.to_s
       .gsub('&', '&amp;')
       .gsub('<', '&lt;')
       .gsub('>', '&gt;')
       .gsub('"', '&quot;')
  end
end
