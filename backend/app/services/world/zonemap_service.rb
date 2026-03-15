# frozen_string_literal: true

require_relative '../../lib/world_terrain_config'
require_relative '../../helpers/canvas_helper'

# Generates an SVG map of the 9x9 hex grid of terrain around the player's
# current position using SvgBuilder.
#
# Each grid cell maps to a 1-degree lat/lon cell. The DISTINCT ON SQL query
# finds the closest WorldHex to each cell center, matching the world builder's
# hex editor approach.
#
# @example
#   service = ZonemapService.new(
#     world: world,
#     center_x: 50,
#     center_y: 50,
#     current_location: location
#   )
#   svg_string = service.render
#
class ZonemapService
  TERRAIN_COLORS = WorldTerrainConfig::TERRAIN_COLORS

  # Canvas dimensions (from centralized config)
  CANVAS_SIZE = GameConfig::Rendering::AREAMAP[:canvas_size]
  GRID_SIZE = GameConfig::Rendering::AREAMAP[:grid_size]
  MARGIN = GameConfig::Rendering::AREAMAP[:margin]
  TITLE_HEIGHT = GameConfig::Rendering::AREAMAP[:title_height]
  FEATURE_WIDTH = GameConfig::Rendering::AREAMAP[:feature_width]

  # Hex grid geometry derived from canvas size and grid count
  # For a flat-top hex grid with GRID_SIZE columns:
  #   Total width = MARGIN + HEX_RADIUS + (GRID_SIZE - 1) * HORIZ_SPACING + HEX_RADIUS + MARGIN
  #   => 2*MARGIN + 2*HEX_RADIUS + (GRID_SIZE - 1) * 1.5 * HEX_RADIUS
  #   => 2*MARGIN + HEX_RADIUS * (2 + 1.5 * (GRID_SIZE - 1))
  #   Solve for HEX_RADIUS:
  HEX_RADIUS = ((CANVAS_SIZE - 2 * MARGIN) / (2.0 + 1.5 * (GRID_SIZE - 1))).floor
  HEX_HEIGHT = (Math.sqrt(3) * HEX_RADIUS).round
  HORIZ_SPACING = (HEX_RADIUS * 1.5).round
  VERT_SPACING = HEX_HEIGHT


  # Feature colors
  FEATURE_COLORS = {
    'road' => '#7f8c8d',
    'highway' => '#f39c12',
    'street' => '#95a5a6',
    'trail' => '#d7ccc8',
    'river' => '#3498db',
    'canal' => '#4a8ab5',
    'railway' => '#2c3e50'
  }.freeze

  # Colors
  BACKGROUND_COLOR = '#0e1117'
  TEXT_COLOR = '#ffffff'
  LABEL_COLOR = '#dddddd'
  GRID_BORDER_COLOR = '#ffffff26'
  CENTER_BORDER_COLOR = '#ffcc00'

  # Feature direction to flat-top hex edge midpoint offsets (x, y) from center.
  # Matches hex-editor.js getEdgePos: offsets expressed as fractions of hex dimensions.
  # These are computed at class load time from HEX_RADIUS and HEX_HEIGHT.
  FEATURE_EDGE_OFFSETS = {
    'n'  => [0,                          -(HEX_HEIGHT * 0.5)].freeze,
    's'  => [0,                           (HEX_HEIGHT * 0.5)].freeze,
    'ne' => [(HEX_RADIUS * 0.75).round,  -(HEX_HEIGHT * 0.25)].freeze,
    'nw' => [-(HEX_RADIUS * 0.75).round, -(HEX_HEIGHT * 0.25)].freeze,
    'se' => [(HEX_RADIUS * 0.75).round,   (HEX_HEIGHT * 0.25)].freeze,
    'sw' => [-(HEX_RADIUS * 0.75).round,  (HEX_HEIGHT * 0.25)].freeze
  }.freeze

  attr_reader :world, :center_x, :center_y, :current_location

  def initialize(world:, center_x:, center_y:, current_location:)
    @world = world
    @center_x = center_x
    @center_y = center_y
    @current_location = current_location
    # Grid center in integer-degree space
    @center_col = center_x.floor
    @center_row = center_y.floor
  end

  # Generate SVG XML string
  # @return [String] complete SVG document
  def render
    svg = SvgBuilder.new(CANVAS_SIZE, CANVAS_SIZE, background: BACKGROUND_COLOR)
    render_hex_cells(svg)
    render_features(svg)
    render_location_labels(svg)
    render_title(svg)
    svg.to_xml
  end

  # Generate 6 vertices of a flat-top hexagon centered at (cx, cy)
  # @return [Array<Array>] array of [x, y] pairs
  def hex_vertices(cx, cy, size)
    (0..5).map { |i|
      angle = Math::PI / 3 * i
      [(cx + size * Math.cos(angle)).round, (cy + size * Math.sin(angle)).round]
    }
  end

  # Convert grid column/row (0-based within the 9x9 grid) to pixel position
  # Matches the hex-editor.js hexToPixel logic for flat-top hexagons
  def hex_to_pixel(col, row)
    # World column determines stagger (odd columns shift down by half hex height)
    world_col = @center_col - GRID_SIZE / 2 + col

    x = MARGIN + HEX_RADIUS + col * HORIZ_SPACING
    y = MARGIN + HEX_HEIGHT / 2 + row * VERT_SPACING + (world_col.odd? ? HEX_HEIGHT / 2 : 0)

    [x, y]
  end

  private

  # Query WorldHex records using DISTINCT ON to get exactly one hex per 1-degree grid cell.
  # Returns a Hash keyed by [grid_col, grid_row] (0-based within the 9x9 grid).
  def grid_hexes
    return {} unless world

    @grid_hexes ||= begin
      half = GRID_SIZE / 2
      # The grid covers center_col-half .. center_col+half (longitude)
      # and center_row-half .. center_row+half (latitude)
      min_lon = (@center_col - half).to_f
      max_lon = (@center_col + half).to_f
      # Latitude: center_row is the center, grid row 0 = northernmost = highest lat
      max_lat = (@center_row + half).to_f
      min_lat = (@center_row - half).to_f

      # DISTINCT ON query: for each 1-degree cell, pick the closest WorldHex
      # cell_x = FLOOR(longitude - min_lon) maps lon to 0..GRID_SIZE-1
      # cell_y = FLOOR(max_lat - latitude) maps lat to 0..GRID_SIZE-1 (y=0 at top/north)
      rows = DB.fetch(
        "SELECT DISTINCT ON (cell_x, cell_y) " \
        "id, terrain_type, " \
        "feature_n, feature_ne, feature_se, feature_s, feature_sw, feature_nw, " \
        "FLOOR(longitude - ?::float8)::int AS cell_x, " \
        "FLOOR(?::float8 - latitude)::int AS cell_y " \
        "FROM world_hexes " \
        "WHERE world_id = ? AND longitude >= ? AND longitude < ? AND latitude > ? AND latitude <= ? " \
        "ORDER BY cell_x, cell_y, " \
        "((longitude - ?) - FLOOR(longitude - ?) - 0.5)^2 + " \
        "((? - latitude) - FLOOR(? - latitude) - 0.5)^2",
        min_lon, max_lat,
        world.id, min_lon - 0.5, max_lon + 1.5, min_lat - 0.5, max_lat + 0.5,
        min_lon, min_lon, max_lat, max_lat
      ).all

      result = {}
      rows.each do |row|
        cx = row[:cell_x]
        cy = row[:cell_y]
        next unless cx >= 0 && cx < GRID_SIZE && cy >= 0 && cy < GRID_SIZE

        result[[cx, cy]] = row
      end
      result
    end
  end

  # Render all hex cells: terrain fill + grid borders + center hex highlight
  def render_hex_cells(svg)
    center_grid_col = GRID_SIZE / 2
    center_grid_row = GRID_SIZE / 2
    hexes = grid_hexes

    GRID_SIZE.times do |col|
      GRID_SIZE.times do |row|
        cx, cy = hex_to_pixel(col, row)

        # Get terrain from query results, default to grassy_plains
        hex_data = hexes[[col, row]]
        terrain = hex_data ? hex_data[:terrain_type] : WorldHex::DEFAULT_TERRAIN
        color = WorldTerrainConfig::TERRAIN_COLORS[terrain] || WorldTerrainConfig::TERRAIN_COLORS[WorldHex::DEFAULT_TERRAIN]

        verts = hex_vertices(cx, cy, HEX_RADIUS)

        if col == center_grid_col && row == center_grid_row
          # Center hex: gold double-outline
          svg.polygon(verts, fill: color, stroke: CENTER_BORDER_COLOR, stroke_width: 2)
          inner = hex_vertices(cx, cy, HEX_RADIUS - 2)
          svg.polygon(inner, fill: 'none', stroke: CENTER_BORDER_COLOR, stroke_width: 1)
        else
          # Normal hex: terrain fill + subtle white border
          svg.polygon(verts, fill: color, stroke: GRID_BORDER_COLOR, stroke_width: 1)
        end
      end
    end
  end

  # Calculate feature edge point: where a feature line meets the hex border.
  # Uses simple x/y offsets matching the hex-editor.js getEdgePos function.
  def feature_edge_point(cx, cy, direction)
    offsets = FEATURE_EDGE_OFFSETS[direction.to_s.downcase]
    return [cx, cy] unless offsets

    [(cx + offsets[0]).round, (cy + offsets[1]).round]
  end

  # Render road/river/railway features as lines from hex center to edge
  def render_features(svg)
    hexes = grid_hexes

    hexes.each do |(col, row), hex_data|
      cx, cy = hex_to_pixel(col, row)

      WorldHex::DIRECTIONS.each do |dir|
        feature_type = hex_data[:"feature_#{dir}"]
        next unless feature_type

        color = FEATURE_COLORS[feature_type] || FEATURE_COLORS['road']
        ex, ey = feature_edge_point(cx, cy, dir)
        svg.line(cx, cy, ex, ey, stroke: color, stroke_width: FEATURE_WIDTH)
      end
    end
  end

  # Convert a location's lat/lon to a grid cell [col, row] within the 9x9 grid
  # Returns nil if the location falls outside the grid
  def location_to_grid(lon, lat)
    half = GRID_SIZE / 2
    min_lon = @center_col - half
    max_lat = @center_row + half

    col = (lon - min_lon).floor
    row = (max_lat - lat).floor

    return nil unless col >= 0 && col < GRID_SIZE && row >= 0 && row < GRID_SIZE

    [col, row]
  end

  # Render location names as text labels inside their hex cells
  def render_location_labels(svg)
    return unless world

    half = GRID_SIZE / 2
    min_lon = (@center_col - half).to_f
    max_lon = (@center_col + half + 1).to_f
    min_lat = (@center_row - half).to_f
    max_lat = (@center_row + half + 1).to_f

    # Capture for Sequel block
    w_id = world.id
    locations = Location.where(world_id: w_id)
                        .exclude(globe_hex_id: nil)
                        .where { (longitude >= min_lon) & (longitude < max_lon) }
                        .where { (latitude >= min_lat) & (latitude < max_lat) }
                        .all

    locations.each do |loc|
      grid_pos = location_to_grid(loc.longitude, loc.latitude)
      next unless grid_pos

      col, row = grid_pos
      cx, cy = hex_to_pixel(col, row)
      name = CanvasHelper.truncate_name(loc.name, 10)
      svg.text(cx, cy + HEX_RADIUS / 2, CanvasHelper.sanitize_text(name),
               font_size: 8, font_family: 'sans-serif',
               fill: LABEL_COLOR, text_anchor: 'middle')
    end
  end

  def render_title(svg)
    zone_name = current_location&.zone&.name || 'Unknown Zone'
    loc_name = current_location&.name
    label = loc_name ? "#{CanvasHelper.sanitize_text(loc_name)} - #{CanvasHelper.sanitize_text(zone_name)}" : CanvasHelper.sanitize_text(zone_name)

    # Dark background strip behind title
    svg.rect(0, CANVAS_SIZE - TITLE_HEIGHT - 2, CANVAS_SIZE, TITLE_HEIGHT + 2,
             fill: BACKGROUND_COLOR)
    svg.text(CANVAS_SIZE / 2, CANVAS_SIZE - TITLE_HEIGHT / 2, label,
             font_size: 14, font_family: 'sans-serif',
             fill: TEXT_COLOR, text_anchor: 'middle')
  end

end

# Alias for backward compatibility
AreamapService = ZonemapService
