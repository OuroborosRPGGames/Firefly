# frozen_string_literal: true

require_relative '../../lib/world_terrain_config'

module WorldGeneration
  # Renders 2D map projections of globe hex grids for visual verification.
  #
  # This service creates map images from globe hex data, allowing automated
  # verification of world generation quality without needing WebGL.
  #
  # Supported projections:
  # - :orthographic - Single-hemisphere view (like looking at a globe)
  # - :equirectangular - Full world map (lat/lon grid, Mercator-like)
  #
  # @example Generate an orthographic PNG
  #   service = WorldGeneration::GlobeSnapshotService.new(world)
  #   service.render_png('/tmp/world_snapshot.png', projection: :orthographic)
  #
  # @example Generate an equirectangular SVG
  #   service = WorldGeneration::GlobeSnapshotService.new(world)
  #   svg_content = service.render_svg(projection: :equirectangular)
  #
  class GlobeSnapshotService

    DEFAULT_WIDTH = 800
    DEFAULT_HEIGHT = 400
    HEX_RADIUS = 3 # Default hex radius in pixels
    TERRAIN_COLORS = WorldTerrainConfig::TERRAIN_COLORS

    attr_reader :world, :hexes

    # Initialize the snapshot service.
    #
    # @param world [World] The world to render
    # @param hexes [Array<WorldHex>] Optional preloaded hexes (loads from DB if not provided)
    def initialize(world, hexes: nil)
      @world = world
      @hexes = hexes || WorldHex.where(world_id: world.id).all
    end

    # Render the world to an SVG string.
    #
    # @param projection [Symbol] :orthographic or :equirectangular
    # @param width [Integer] Image width in pixels
    # @param height [Integer] Image height in pixels
    # @param center_lon [Float] Center longitude for orthographic projection (degrees)
    # @param center_lat [Float] Center latitude for orthographic projection (degrees)
    # @return [String] SVG content
    def render_svg(projection: :equirectangular, width: DEFAULT_WIDTH, height: DEFAULT_HEIGHT,
                   center_lon: 0.0, center_lat: 0.0)
      case projection
      when :orthographic
        render_orthographic_svg(width, height, center_lon, center_lat)
      when :equirectangular
        render_equirectangular_svg(width, height)
      else
        raise ArgumentError, "Unknown projection: #{projection}"
      end
    end

    # Render the world to a PNG file.
    # Requires the 'mini_magick' gem for SVG to PNG conversion.
    #
    # @param output_path [String] Path to write the PNG file
    # @param projection [Symbol] :orthographic or :equirectangular
    # @param width [Integer] Image width in pixels
    # @param height [Integer] Image height in pixels
    # @param center_lon [Float] Center longitude for orthographic projection (degrees)
    # @param center_lat [Float] Center latitude for orthographic projection (degrees)
    # @return [String] The output path
    def render_png(output_path, projection: :equirectangular, width: DEFAULT_WIDTH, height: DEFAULT_HEIGHT,
                   center_lon: 0.0, center_lat: 0.0)
      svg_content = render_svg(
        projection: projection,
        width: width,
        height: height,
        center_lon: center_lon,
        center_lat: center_lat
      )

      # Write SVG to temp file
      svg_path = output_path.sub(/\.png$/i, '.svg')
      File.write(svg_path, svg_content)

      # Try to convert to PNG using rsvg-convert or ImageMagick
      if system('which rsvg-convert > /dev/null 2>&1')
        system("rsvg-convert -w #{width} -h #{height} '#{svg_path}' -o '#{output_path}'")
      elsif system('which convert > /dev/null 2>&1')
        system("convert '#{svg_path}' -resize #{width}x#{height} '#{output_path}'")
      else
        warn '[GlobeSnapshotService] No PNG converter available (rsvg-convert or ImageMagick)'
        # Just leave the SVG
        return svg_path
      end

      output_path
    end

    # Render an SVG file directly.
    #
    # @param output_path [String] Path to write the SVG file
    # @param projection [Symbol] :orthographic or :equirectangular
    # @param width [Integer] Image width in pixels
    # @param height [Integer] Image height in pixels
    # @param center_lon [Float] Center longitude for orthographic projection (degrees)
    # @param center_lat [Float] Center latitude for orthographic projection (degrees)
    # @return [String] The output path
    def render_svg_file(output_path, projection: :equirectangular, width: DEFAULT_WIDTH, height: DEFAULT_HEIGHT,
                        center_lon: 0.0, center_lat: 0.0)
      svg_content = render_svg(
        projection: projection,
        width: width,
        height: height,
        center_lon: center_lon,
        center_lat: center_lat
      )
      File.write(output_path, svg_content)
      output_path
    end

    private

    # Render equirectangular projection (full world map).
    # Maps latitude to Y, longitude to X linearly.
    def render_equirectangular_svg(width, height)
      svg_parts = [svg_header(width, height)]

      # Add background (ocean color)
      svg_parts << %(<rect x="0" y="0" width="#{width}" height="#{height}" fill="#{WorldTerrainConfig::TERRAIN_COLORS['ocean']}"/>)

      # Calculate hex radius based on hex count for reasonable coverage
      hex_radius = calculate_hex_radius(width, height)

      @hexes.each do |hex|
        next unless hex.latitude && hex.longitude

        # Convert lat/lon to pixel coordinates
        # Longitude: -180 to 180 -> 0 to width
        # Latitude: 90 to -90 -> 0 to height (north at top)
        x = ((hex.longitude + 180.0) / 360.0 * width).round(2)
        y = ((90.0 - hex.latitude) / 180.0 * height).round(2)

        color = terrain_color(hex.terrain_type)
        svg_parts << render_hex_svg(x, y, hex_radius, color)
      end

      # Add grid lines for reference
      svg_parts << render_grid_lines(width, height)

      svg_parts << '</svg>'
      svg_parts.join("\n")
    end

    # Render orthographic projection (single hemisphere view).
    # Shows the globe as seen from space at a given center point.
    def render_orthographic_svg(width, height, center_lon, center_lat)
      svg_parts = [svg_header(width, height)]

      # Add background (space/black)
      svg_parts << %(<rect x="0" y="0" width="#{width}" height="#{height}" fill="#000"/>)

      # Globe circle (ocean color)
      cx = width / 2.0
      cy = height / 2.0
      radius = [width, height].min / 2.0 - 10

      svg_parts << %(<circle cx="#{cx}" cy="#{cy}" r="#{radius}" fill="#{WorldTerrainConfig::TERRAIN_COLORS['ocean']}"/>)

      # Convert center to radians
      center_lon_rad = center_lon * Math::PI / 180.0
      center_lat_rad = center_lat * Math::PI / 180.0

      # Calculate hex radius based on hex count
      hex_radius = calculate_hex_radius(width, height) * 0.8

      @hexes.each do |hex|
        next unless hex.latitude && hex.longitude

        # Convert to radians
        lat_rad = hex.latitude * Math::PI / 180.0
        lon_rad = hex.longitude * Math::PI / 180.0

        # Orthographic projection
        projected = orthographic_project(lat_rad, lon_rad, center_lat_rad, center_lon_rad)
        next unless projected # Skip hexes on back side of globe

        proj_x, proj_y = projected

        # Scale to screen coordinates
        x = (cx + proj_x * radius).round(2)
        y = (cy - proj_y * radius).round(2) # Flip Y for screen coords

        color = terrain_color(hex.terrain_type)
        svg_parts << render_hex_svg(x, y, hex_radius, color)
      end

      # Add globe outline
      svg_parts << %(<circle cx="#{cx}" cy="#{cy}" r="#{radius}" fill="none" stroke="#fff" stroke-width="2"/>)

      svg_parts << '</svg>'
      svg_parts.join("\n")
    end

    # Orthographic projection of a point.
    # Returns [x, y] in range [-1, 1] or nil if point is on back side.
    def orthographic_project(lat, lon, center_lat, center_lon)
      # Calculate the cosine of the angular distance from center
      cos_c = Math.sin(center_lat) * Math.sin(lat) +
              Math.cos(center_lat) * Math.cos(lat) * Math.cos(lon - center_lon)

      # Point is on back side of globe
      return nil if cos_c < 0

      # Calculate projected coordinates
      x = Math.cos(lat) * Math.sin(lon - center_lon)
      y = Math.cos(center_lat) * Math.sin(lat) -
          Math.sin(center_lat) * Math.cos(lat) * Math.cos(lon - center_lon)

      [x, y]
    end

    # Calculate appropriate hex radius based on number of hexes and image size.
    def calculate_hex_radius(width, height)
      return HEX_RADIUS if @hexes.empty?

      # Estimate hexes per unit area
      total_area = width * height
      hex_area = total_area.to_f / @hexes.size

      # Radius for a hex with that area (approximate)
      radius = Math.sqrt(hex_area / Math::PI) * 0.8
      [radius, HEX_RADIUS].max
    end

    # Get color for terrain type.
    def terrain_color(terrain_type)
      WorldTerrainConfig::TERRAIN_COLORS[terrain_type] || WorldTerrainConfig::TERRAIN_COLORS[WorldHex::DEFAULT_TERRAIN]
    end

    # Render a single hex as SVG.
    def render_hex_svg(x, y, radius, color)
      # Use a circle for simplicity (true hexes would require polygon calculations)
      %(<circle cx="#{x}" cy="#{y}" r="#{radius}" fill="#{color}"/>)
    end

    # SVG header with viewBox.
    def svg_header(width, height)
      <<~SVG.strip
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{width} #{height}" width="#{width}" height="#{height}">
      SVG
    end

    # Render grid lines for equirectangular projection.
    def render_grid_lines(width, height)
      lines = []

      # Latitude lines (every 30 degrees)
      [-60, -30, 0, 30, 60].each do |lat|
        y = ((90.0 - lat) / 180.0 * height).round(2)
        lines << %(<line x1="0" y1="#{y}" x2="#{width}" y2="#{y}" stroke="#ffffff33" stroke-width="1"/>)
      end

      # Longitude lines (every 30 degrees)
      (-150..150).step(30).each do |lon|
        x = ((lon + 180.0) / 360.0 * width).round(2)
        lines << %(<line x1="#{x}" y1="0" x2="#{x}" y2="#{height}" stroke="#ffffff33" stroke-width="1"/>)
      end

      lines.join("\n")
    end
  end
end
