# frozen_string_literal: true

# MapSvgRenderService generates SVG visualizations of game maps.
#
# Renders world maps, city layouts, room interiors, and battle maps
# as SVG images for use by MCP building tools.
#
# @example Render a world region
#   svg = MapSvgRenderService.render_world(world, bounds: { min_x: 0, max_x: 20, min_y: 0, max_y: 20 })
#
# @example Render a city
#   svg = MapSvgRenderService.render_city(location, width: 800, height: 600)
#
class MapSvgRenderService
  class << self
    # Render a region of the world map as SVG (equirectangular projection).
    # @param world [World] the world to render
    # @param bounds [Hash] region bounds — accepts { min_lon:, max_lon:, min_lat:, max_lat: }
    #                      or { min_x:, max_x:, min_y:, max_y: } treating x as longitude, y as latitude
    # @param width [Integer] viewport width in pixels
    # @param height [Integer] viewport height in pixels
    # @return [String] SVG XML
    def render_world(world, bounds:, width: 800, height: 600)
      svg = SvgBuilder.new(width, height, background: '#0a1628')

      # Convert bounds - treat x as longitude, y as latitude if not explicitly named
      min_lon = bounds[:min_lon] || bounds[:min_x] || -180
      max_lon = bounds[:max_lon] || bounds[:max_x] || 180
      min_lat = bounds[:min_lat] || bounds[:min_y] || -90
      max_lat = bounds[:max_lat] || bounds[:max_y] || 90

      # Clamp to valid ranges
      min_lon = [min_lon, -180].max
      max_lon = [max_lon, 180].min
      min_lat = [min_lat, -90].max
      max_lat = [max_lat, 90].min

      padding = 20

      # Get hexes in lat/lon bounds
      hexes = WorldHex.where(world_id: world.id)
                      .where { latitude >= min_lat }
                      .where { latitude <= max_lat }
                      .where { longitude >= min_lon }
                      .where { longitude <= max_lon }
                      .all

      # If no hexes found with strict bounds, try full world
      if hexes.empty?
        hexes = WorldHex.where(world_id: world.id).all
        min_lon, max_lon = -180, 180
        min_lat, max_lat = -90, 90
      end

      return error_svg(width, height, 'No hexes found for this world') if hexes.empty?

      # Calculate hex radius based on hex count for reasonable coverage
      total_area = (width - padding * 2) * (height - padding * 2)
      hex_area = total_area.to_f / [hexes.size, 1].max
      hex_radius = [Math.sqrt(hex_area / Math::PI) * 0.6, 2].max

      lon_range = max_lon - min_lon
      lat_range = max_lat - min_lat

      # Draw background ocean
      svg.rect(padding, padding, width - padding * 2, height - padding * 2,
               fill: SvgBuilder::TERRAIN_COLORS['ocean'] || '#1e3a5f')

      # Draw hexes
      hexes.each do |hex|
        next unless hex.latitude && hex.longitude

        # Convert lat/lon to pixel coordinates (equirectangular projection)
        # Longitude: min_lon to max_lon -> padding to width-padding
        # Latitude: max_lat to min_lat -> padding to height-padding (north at top)
        px = padding + ((hex.longitude - min_lon) / lon_range * (width - padding * 2))
        py = padding + ((max_lat - hex.latitude) / lat_range * (height - padding * 2))

        color = SvgBuilder::TERRAIN_COLORS[hex.terrain_type] || SvgBuilder::TERRAIN_COLORS['unknown']
        svg.circle(px.round(1), py.round(1), hex_radius, fill: color)
      end

      # Add grid lines
      add_globe_grid_lines(svg, min_lon, max_lon, min_lat, max_lat, width, height, padding)

      # Add legend
      add_world_legend(svg, width, height)

      # Add title with lat/lon bounds
      title = "#{world.name} - Region (#{min_lon.round}°, #{min_lat.round}°) to (#{max_lon.round}°, #{max_lat.round}°)"
      svg.text(width / 2, 15, title, font_size: 12, fill: '#9ca3af', text_anchor: 'middle')

      svg.to_xml
    rescue StandardError => e
      warn "[MapSvgRenderService] render_world error: #{e.message}"
      error_svg(width, height, "World render error: #{e.message}")
    end

    # Render a city layout as SVG
    # @param location [Location] the city location
    # @param width [Integer] viewport width
    # @param height [Integer] viewport height
    # @return [String] SVG XML
    def render_city(location, width: 800, height: 600)
      svg = SvgBuilder.new(width, height, background: '#1a1a2e')

      streets = location.horizontal_streets || 10
      avenues = location.vertical_streets || 10

      # Calculate scale
      padding = 40
      cell_feet = GridCalculationService::GRID_CELL_SIZE
      total_width_feet = avenues * cell_feet
      total_height_feet = streets * cell_feet

      scale_x = (width - padding * 2) / total_width_feet.to_f
      scale_y = (height - padding * 2) / total_height_feet.to_f
      scale = [scale_x, scale_y].min

      offset_x = padding + (width - padding * 2 - total_width_feet * scale) / 2
      offset_y = padding + (height - padding * 2 - total_height_feet * scale) / 2

      # Draw street grid background
      draw_city_grid(svg, location, scale, offset_x, offset_y)

      # Get all rooms for this city
      rooms = Room.where(location_id: location.id)
                  .where { room_type !~ 'intersection' }
                  .where { room_type !~ 'street' }
                  .where { room_type !~ 'avenue' }
                  .all

      # Draw buildings
      rooms.each do |room|
        draw_city_building(svg, room, scale, offset_x, offset_y)
      end

      # Draw street labels
      draw_street_labels(svg, location, scale, offset_x, offset_y, width, height)

      # Title
      city_name = location.city_name || location.name
      svg.text(width / 2, 20, city_name, font_size: 14, fill: '#f0f0f0', text_anchor: 'middle')

      svg.to_xml
    rescue StandardError => e
      warn "[MapSvgRenderService] render_city error: #{e.message}"
      error_svg(width, height, "City render error: #{e.message}")
    end

    # Render a room interior as SVG
    # @param room [Room] the room to render
    # @param width [Integer] viewport width
    # @param height [Integer] viewport height
    # @return [String] SVG XML
    def render_room(room, width: 400, height: 400)
      svg = SvgBuilder.new(width, height, background: '#1a202c')

      # Calculate scale
      room_width = (room.max_x || 100) - (room.min_x || 0)
      room_height = (room.max_y || 100) - (room.min_y || 0)

      padding = 30
      scale_x = (width - padding * 2) / room_width.to_f
      scale_y = (height - padding * 2) / room_height.to_f
      scale = [scale_x, scale_y].min

      offset_x = padding + (width - padding * 2 - room_width * scale) / 2 - (room.min_x || 0) * scale
      offset_y = padding + (height - padding * 2 - room_height * scale) / 2 - (room.min_y || 0) * scale

      # Draw room background
      room_color = SvgBuilder::ROOM_COLORS[room.room_type&.to_sym] || '#2d3748'
      svg.rect(
        offset_x + (room.min_x || 0) * scale,
        offset_y + (room.min_y || 0) * scale,
        room_width * scale,
        room_height * scale,
        fill: room_color, stroke: '#4a5568', stroke_width: 2
      )

      # Draw custom polygon if present
      if room.has_custom_polygon? && room.room_polygon.is_a?(Array)
        polygon_points = room.room_polygon.map do |pt|
          [offset_x + pt[0] * scale, offset_y + pt[1] * scale]
        end
        svg.polygon(polygon_points, fill: 'none', stroke: '#10b981', stroke_width: 2, stroke_dasharray: '4,4')
      end

      # Draw furniture/places
      room.places.each do |place|
        draw_place(svg, place, scale, offset_x, offset_y)
      end

      # Draw spatial exits (calculated from polygon adjacency)
      room.passable_spatial_exits.each do |exit|
        draw_spatial_exit(svg, exit, room, scale, offset_x, offset_y)
      end

      # Draw room features (doors, windows)
      if room.respond_to?(:room_features)
        room.room_features.each do |feature|
          draw_feature(svg, feature, scale, offset_x, offset_y)
        end
      end

      # Title
      svg.text(width / 2, 18, room.name || 'Room', font_size: 12, fill: '#f0f0f0', text_anchor: 'middle')

      # Dimensions label
      svg.text(width / 2, height - 10, "#{room_width.round}ft x #{room_height.round}ft",
               font_size: 10, fill: '#6b7280', text_anchor: 'middle')

      svg.to_xml
    rescue StandardError => e
      warn "[MapSvgRenderService] render_room error: #{e.message}"
      error_svg(width, height, "Room render error: #{e.message}")
    end

    # Render a battle map as SVG
    # @param fight [Fight] the fight to render
    # @param width [Integer] viewport width
    # @param height [Integer] viewport height
    # @return [String] SVG XML
    def render_battle(fight, width: 600, height: 600)
      svg = SvgBuilder.new(width, height, background: '#0d1117')

      arena_w = fight.arena_width || 10
      arena_h = fight.arena_height || 10

      # Calculate hex size
      padding = 30
      hex_width = (width - padding * 2) / (arena_w * 1.5 + 0.5)
      hex_height = (height - padding * 2) / (arena_h * Math.sqrt(3) + 0.5)
      hex_size = [hex_width / 2, hex_height / Math.sqrt(3)].min

      # Draw hex grid (Y-flipped: north at top)
      (0...arena_w).each do |x|
        (0...arena_h).each do |y|
          px = padding + hex_size * (1.5 * x + 1)
          py = padding + hex_size * Math.sqrt(3) * ((arena_h - 1 - y) + (x.odd? ? 1 : 0.5))

          # Get hex type from RoomHex if exists
          room_hex = RoomHex.where(room_id: fight.room_id, hex_x: x, hex_y: y).first
          hex_color = room_hex ? hex_type_color(room_hex.hex_type) : '#1e2228'

          svg.hexagon(px, py, hex_size * 0.95, fill: hex_color, stroke: '#3a3f44', stroke_width: 0.5)
        end
      end

      # Draw participants (Y-flipped: north at top)
      fight.fight_participants.each do |participant|
        next unless participant.hex_x && participant.hex_y

        px = padding + hex_size * (1.5 * participant.hex_x + 1)
        py = padding + hex_size * Math.sqrt(3) * ((arena_h - 1 - participant.hex_y) + (participant.hex_x.odd? ? 1 : 0.5))

        # Determine color by side
        color = participant.side == 1 ? '#22c55e' : '#ef4444'
        color = '#6b7280' if participant.is_knocked_out

        svg.circle(px, py, hex_size * 0.4, fill: color, stroke: '#fff', stroke_width: 1)

        # Name label
        name = participant.character_instance&.character&.full_name&.slice(0, 3)&.upcase || '???'
        svg.text(px, py + 3, name, font_size: [hex_size * 0.35, 8].min, fill: '#fff', text_anchor: 'middle')
      end

      # Title
      svg.text(width / 2, 18, "Battle - Round #{fight.round_number}", font_size: 12, fill: '#f0f0f0', text_anchor: 'middle')

      svg.to_xml
    rescue StandardError => e
      warn "[MapSvgRenderService] render_battle error: #{e.message}"
      error_svg(width, height, "Battle render error: #{e.message}")
    end

    # Render a room as a schematic blueprint for AI reference.
    # White background, black walls, labeled furniture/features, dimensions.
    # Designed to be sent as a reference image to Gemini for battle map generation.
    #
    # @param room [Room] the room to render
    # @param width [Integer] viewport width (height calculated from aspect ratio)
    # @return [String] SVG XML
    # Render a schematic blueprint of a room for use as a reference image.
    # Returns both the SVG and a text legend for passing to the LLM prompt.
    # @param room [Room] the room to render
    # @param width [Integer] output width in pixels
    # @return [Hash] { svg: String, legend: String } or just String (SVG) for backward compat
    def render_blueprint(room, width: 800)
      room_width = (room.max_x || 100) - (room.min_x || 0)
      room_height = (room.max_y || 100) - (room.min_y || 0)
      room_width = 100 if room_width <= 0
      room_height = 100 if room_height <= 0

      aspect = room_height.to_f / room_width
      padding = 30
      map_height = ((width - padding * 2) * aspect).round
      height = map_height + padding * 2

      svg = SvgBuilder.new(width, height, background: '#ffffff')

      # Scale: room feet → pixels
      scale = (width - padding * 2).to_f / room_width
      offset_x = padding - (room.min_x || 0) * scale
      offset_y = padding - (room.min_y || 0) * scale

      rx = offset_x + (room.min_x || 0) * scale
      ry = offset_y + (room.min_y || 0) * scale
      rw = room_width * scale
      rh = room_height * scale
      outdoor = room.outdoor_room?
      features = room.respond_to?(:room_features) ? room.room_features.to_a : []

      # Draw floor fill and segmented walls with gaps for features
      draw_room_floor_and_walls(svg, room, rx, ry, rw, rh, features, scale, offset_x, offset_y,
                                floor_color: outdoor ? '#e8efe8' : '#f0f0f0',
                                wall_color: '#000000', wall_width: 3, outdoor: outdoor)

      # Legend collector (for text output, not rendered on image)
      legend_items = []

      # Size constants in feet
      hatch_ft = 3.0
      label_ft = 1.4

      # Draw furniture with distinctive shapes and text labels
      places = room.respond_to?(:places) ? room.places.to_a : []
      furniture = places.select { |p| p.respond_to?(:is_furniture) ? p.is_furniture : true }
      furniture.each_with_index do |place, idx|
        key = ('A'.ord + idx).chr
        px = offset_x + (place.x || 0) * scale
        py = offset_y + (place.y || 0) * scale
        name = (place.name || '').downcase

        draw_furniture_shape(svg, px, py, name, scale, filled: true)

        # Text label below shape
        label_text = place.name || 'Furniture'
        font = (label_ft * scale).clamp(8, 13)
        # Shrink font for long labels so they don't clip
        font = [font, font * 12.0 / label_text.length].max.round(1) if label_text.length > 12
        svg.text(px, py + furniture_label_offset(name, scale) + font, label_text,
                 font_size: font, fill: '#333333', text_anchor: 'middle', font_family: 'sans-serif')

        legend_items << { key: key, name: place.name || 'Furniture', type: 'furniture' }
      end

      # Draw non-furniture places as simple position markers
      non_furniture = places.select { |p| p.respond_to?(:is_furniture) && !p.is_furniture }
      non_furniture.each do |place|
        px = offset_x + (place.x || 0) * scale
        py = offset_y + (place.y || 0) * scale
        r = 3
        svg.circle(px, py, r, fill: 'none', stroke: '#999999', stroke_width: 1, stroke_dasharray: '2,2')
      end

      # Draw room feature notation at wall gaps
      feature_idx = 0
      features.each do |feature|
        fx = offset_x + (feature.x || 0) * scale
        fy = offset_y + (feature.y || 0) * scale
        dir = infer_wall_for_feature(feature, room).to_s
        ft = feature.feature_type || 'door'
        feature_idx += 1
        label = "#{ft[0].upcase}#{feature_idx}"
        font = (label_ft * scale * 0.7).clamp(9, 14)
        horiz = %w[north south].include?(dir)

        # For east/west walls, nudge label inward so it doesn't clip outside
        inward = font * 1.2
        lx = case dir
             when 'east' then fx - inward
             when 'west' then fx + inward
             else fx
             end

        case ft
        when 'door', 'gate'
          gap_half = feature_gap_px(ft, scale) / 2.0
          tick = 8
          if horiz
            svg.line(fx - gap_half, fy - tick / 2, fx - gap_half, fy + tick / 2, stroke: '#000000', stroke_width: 1.5)
            svg.line(fx + gap_half, fy - tick / 2, fx + gap_half, fy + tick / 2, stroke: '#000000', stroke_width: 1.5)
          else
            svg.line(fx - tick / 2, fy - gap_half, fx + tick / 2, fy - gap_half, stroke: '#000000', stroke_width: 1.5)
            svg.line(fx - tick / 2, fy + gap_half, fx + tick / 2, fy + gap_half, stroke: '#000000', stroke_width: 1.5)
          end
          svg.text(lx, fy + font / 3.0, label,
                   font_size: font, fill: '#333333', text_anchor: 'middle', font_family: 'sans-serif', font_weight: 'bold')
        when 'hatch', 'stairs'
          size = 3.0 * scale
          svg.rect(fx - size / 2, fy - size / 2, size, size,
                   fill: 'none', stroke: '#555555', stroke_width: 1.5)
          svg.line(fx - size / 2, fy - size / 2, fx + size / 2, fy + size / 2, stroke: '#555555', stroke_width: 1)
          svg.line(fx + size / 2, fy - size / 2, fx - size / 2, fy + size / 2, stroke: '#555555', stroke_width: 1)
          hatch_label = feature.name || ft.capitalize
          svg.text(fx, fy + size / 2 + font + 2, hatch_label,
                   font_size: font, fill: '#333333', text_anchor: 'middle', font_family: 'sans-serif')
        when 'window'
          gap_half = feature_gap_px(ft, scale) / 2.0
          line_gap = 3
          if horiz
            svg.line(fx - gap_half, fy - line_gap, fx + gap_half, fy - line_gap, stroke: '#0066cc', stroke_width: 2)
            svg.line(fx - gap_half, fy + line_gap, fx + gap_half, fy + line_gap, stroke: '#0066cc', stroke_width: 2)
          else
            svg.line(fx - line_gap, fy - gap_half, fx - line_gap, fy + gap_half, stroke: '#0066cc', stroke_width: 2)
            svg.line(fx + line_gap, fy - gap_half, fx + line_gap, fy + gap_half, stroke: '#0066cc', stroke_width: 2)
          end
          svg.text(lx, fy + font / 3.0, label,
                   font_size: font, fill: '#0066cc', text_anchor: 'middle', font_family: 'sans-serif', font_weight: 'bold')
        when 'opening', 'archway'
          svg.text(lx, fy + font / 3.0, label,
                   font_size: font, fill: '#666666', text_anchor: 'middle', font_family: 'sans-serif', font_weight: 'bold')
        end

        legend_items << { key: label, name: feature.name || ft.capitalize, type: ft }
      end

      svg.to_xml
    rescue StandardError => e
      warn "[MapSvgRenderService] render_blueprint error: #{e.message}"
      error_svg(width, 100, "Blueprint error: #{e.message}")
    end

    # Render a clean blueprint with NO text labels — just shapes.
    # Used as the reference image for Gemini so it doesn't overlay text.
    # All labeling goes into the text prompt via blueprint_legend().
    def render_blueprint_clean(room, width: 800)
      room_width = (room.max_x || 100) - (room.min_x || 0)
      room_height = (room.max_y || 100) - (room.min_y || 0)
      room_width = 100 if room_width <= 0
      room_height = 100 if room_height <= 0

      aspect = room_height.to_f / room_width
      padding = 20
      map_height = ((width - padding * 2) * aspect).round
      height = map_height + padding * 2

      svg = SvgBuilder.new(width, height, background: '#ffffff')

      scale = (width - padding * 2).to_f / room_width
      offset_x = padding - (room.min_x || 0) * scale
      offset_y = padding - (room.min_y || 0) * scale

      rx = offset_x + (room.min_x || 0) * scale
      ry = offset_y + (room.min_y || 0) * scale
      rw = room_width * scale
      rh = room_height * scale
      outdoor = room.outdoor_room?
      features = room.respond_to?(:room_features) ? room.room_features.to_a : []

      # Draw floor fill and segmented walls with gaps for features
      draw_room_floor_and_walls(svg, room, rx, ry, rw, rh, features, scale, offset_x, offset_y,
                                floor_color: outdoor ? '#e8efe8' : '#f0f0f0',
                                wall_color: '#000000', wall_width: 3, outdoor: outdoor)

      # Size constants in feet
      hatch_ft = 3.0

      # Furniture — distinctive outline-only shapes (no text for AI/ControlNet)
      places = room.respond_to?(:places) ? room.places.to_a : []
      furniture = places.select { |p| p.respond_to?(:is_furniture) ? p.is_furniture : true }
      furniture.each do |place|
        px = offset_x + (place.x || 0) * scale
        py = offset_y + (place.y || 0) * scale
        name = (place.name || '').downcase

        draw_furniture_shape(svg, px, py, name, scale, filled: false)
      end

      # 5-foot grid overlay — helps AI understand scale and proportions
      grid_spacing_ft = 5.0
      grid_px = grid_spacing_ft * scale
      grid_color = outdoor ? '#c0d0c0' : '#d8d8d8'
      # Vertical lines
      x_pos = rx + grid_px
      while x_pos < rx + rw
        svg.line(x_pos, ry, x_pos, ry + rh, stroke: grid_color, stroke_width: 0.5, stroke_opacity: 0.5)
        x_pos += grid_px
      end
      # Horizontal lines
      y_pos = ry + grid_px
      while y_pos < ry + rh
        svg.line(rx, y_pos, rx + rw, y_pos, stroke: grid_color, stroke_width: 0.5, stroke_opacity: 0.5)
        y_pos += grid_px
      end

      # Feature notation at wall gaps — minimal markers, no labels
      features.each do |feature|
        fx = offset_x + (feature.x || 0) * scale
        fy = offset_y + (feature.y || 0) * scale
        ft = feature.feature_type || 'door'

        case ft
        when 'door', 'gate'
          # Clean gap — nothing drawn (ControlNet needs empty gaps)
        when 'hatch', 'stairs'
          r = (hatch_ft * scale * 0.4).clamp(6, 16)
          svg.circle(fx, fy, r, fill: 'none', stroke: '#444444', stroke_width: 1)
        when 'window'
          # Clean gap — nothing drawn (ControlNet needs empty gaps)
        when 'opening', 'archway'
          # Clean gap — nothing drawn
        end
      end

      svg.to_xml
    rescue StandardError => e
      warn "[MapSvgRenderService] render_blueprint_clean error: #{e.message}"
      error_svg(width, 100, "Blueprint error: #{e.message}")
    end

    # Build a text legend for a room's blueprint (for passing to LLM prompt alongside the image)
    # @param room [Room]
    # @return [String] legend text like "A = long wooden table\nB = worn bench\nD1 = Main Entrance"
    def blueprint_legend(room)
      items = []
      room_w = ((room.max_x || 100) - (room.min_x || 0)).to_f
      room_h = ((room.max_y || 100) - (room.min_y || 0)).to_f
      room_w = 100.0 if room_w <= 0
      room_h = 100.0 if room_h <= 0
      min_x = room.min_x || 0
      min_y = room.min_y || 0

      places = room.respond_to?(:places) ? room.places.to_a : []
      furniture = places.select { |p| p.respond_to?(:is_furniture) ? p.is_furniture : true }
      furniture.each_with_index do |place, idx|
        key = ('A'.ord + idx).chr
        pct_x = (((place.x || 0) - min_x) / room_w * 100).round
        pct_y = (((place.y || 0) - min_y) / room_h * 100).round
        items << "#{key} = #{place.name || 'Furniture'} (#{pct_x}%, #{pct_y}%)"
      end

      features = room.respond_to?(:room_features) ? room.room_features.to_a : []
      features.each_with_index do |feature, idx|
        ft = feature.feature_type || 'door'
        label = "#{ft[0].upcase}#{idx + 1}"
        pct_x = (((feature.x || 0) - min_x) / room_w * 100).round
        pct_y = (((feature.y || 0) - min_y) / room_h * 100).round
        items << "#{label} = #{feature.name || ft.capitalize} (#{pct_x}%, #{pct_y}%)"
      end

      items.join("\n")
    end

    # Trim black/white/gray borders from a generated image using ImageMagick.
    # @param image_path [String] path to the image file
    # @param fuzz_percent [Integer] color tolerance for border detection (default 8%)
    # @return [String] the image path (same file, trimmed in place)
    def trim_image_borders(image_path)
      return image_path unless image_path && File.exist?(image_path)

      require 'vips'
      # Disable vips operation cache to prevent a null-pointer crash in
      # vips_cache_operation_build when processing large images.
      Vips.vips_cache_set_max(0)
      image = Vips::Image.new_from_file(image_path)
      w = image.width
      h = image.height

      # Sobel edge detection to find the bounding box of actual content.
      # Works with any background color — cream, white, grey, dark.
      # The background is featureless (no edges), so the edge bbox = content bbox.
      # Force into memory once so random-access crops and subsequent operations
      # don't re-decode the full image on every strip pass.
      grey = image.colourspace(:b_w).cast(:float).copy_memory

      # Suppress text-on-background before edge detection.
      # Generated maps sometimes have watermark text on a bright border; the Sobel
      # detects those character edges and prevents the white border from being trimmed.
      # Fix: sample corner brightness → if bright background found, morphologically
      # close the background mask (fills text-character gaps) → neutralise those pixels.
      begin
        cs = [[w, h].min / 8, 40].min
        corner_data = [[0, 0], [w - cs, 0], [0, h - cs], [w - cs, h - cs]].flat_map do |cx, cy|
          grey.crop(cx, cy, cs, cs).to_a.flatten
        end
        bg_level = corner_data.sort[corner_data.size / 2].to_f
        if bg_level > 150
          # Blur the near-background mask to "grow" it over adjacent text pixels.
          # sigma=5 covers characters up to ~15px wide.
          near_bg_f = ((grey - bg_level).abs < 55.0).cast(:float)
          expanded = near_bg_f.gaussblur(5.0)
          grey = (expanded > 127.5).ifthenelse(bg_level.round, grey.cast(:uchar)).cast(:float)
        end
      rescue StandardError => e
        warn "[MapSvgRenderService] Background suppression fallback: #{e.message}"
        # fall back to unmodified grey
      end

      blurred = grey.gaussblur(1.5)
      gx = blurred.conv(Vips::Image.new_from_array([[-1, 0, 1], [-2, 0, 2], [-1, 0, 1]]))
      gy = blurred.conv(Vips::Image.new_from_array([[-1, -2, -1], [0, 0, 0], [1, 2, 1]]))
      mag = ((gx ** 2) + (gy ** 2)) ** 0.5
      edge_mask = (mag > 15).ifthenelse(255, 0).cast(:uchar)

      # Save edge mask for debugging
      ext = File.extname(image_path)
      base = image_path.sub(/#{Regexp.escape(ext)}$/, '')
      edge_mask.write_to_file("#{base}_edges#{ext}")

      # Find bounding box of edge content
      left, top, crop_w, crop_h = edge_mask.find_trim(threshold: 1, background: [0])
      return image_path if crop_w == 0 || crop_h == 0 || (crop_w >= w && crop_h >= h)

      # Expand outward by a small margin to ensure wall edges at the image
      # border are fully included in the crop. find_trim fires right at the
      # first edge pixel, so a few pixels of breathing room prevents clipping
      # the outermost wall line.
      margin = 5
      right  = [left + crop_w - 1 + margin, w - 1].min
      bottom = [top  + crop_h - 1 + margin, h - 1].min
      left   = [left  - margin, 0].max
      top    = [top   - margin, 0].max

      # Safety cap — never remove more than 40% from any edge
      max_edge = 0.40
      left = [left, (w * max_edge).to_i].min
      top = [top, (h * max_edge).to_i].min
      right = [right, (w * (1 - max_edge)).to_i].max
      bottom = [bottom, (h * (1 - max_edge)).to_i].max
      crop_w = right - left + 1
      crop_h = bottom - top + 1

      if crop_w < w || crop_h < h
        FileUtils.cp(image_path, "#{base}_pretrim#{ext}")

        cropped = image.crop(left, top, crop_w, crop_h)
        tmp_path = "#{image_path}.tmp#{ext}"
        cropped.write_to_file(tmp_path)
        FileUtils.mv(tmp_path, image_path)
      end

      image_path
    rescue StandardError => e
      warn "[MapSvgRenderService] Trim failed: #{e.message}"
      image_path
    end

    # Convert an image file to WebP format for smaller file sizes.
    # @param image_path [String] path to the source image (PNG, JPG, etc.)
    # @param quality [Integer] WebP quality (1-100, default 85)
    # @return [String] path to WebP file, or original path on failure
    def convert_to_webp(image_path, quality: 85)
      return image_path unless image_path && File.exist?(image_path)

      require 'vips'
      webp_path = image_path.sub(/\.(png|jpg|jpeg)$/i, '.webp')
      # Read via buffer to avoid vips file cache — if another step (e.g. upscaler)
      # replaced the file at this path, new_from_file may return stale cached data.
      image = Vips::Image.new_from_buffer(File.read(image_path), '')
      image.webpsave(webp_path, Q: quality)
      File.delete(image_path) if File.exist?(image_path) && image_path != webp_path
      webp_path
    rescue StandardError => e
      warn "[MapSvgRenderService] WebP conversion failed: #{e.message}"
      image_path
    end

    # Convert SVG string to PNG file using rsvg-convert.
    #
    # @param svg_string [String] SVG XML content
    # @param width [Integer] output width in pixels (default 1024)
    # @return [String, nil] path to temporary PNG file, or nil on failure
    def svg_to_png(svg_string, width: 1024)
      return nil if svg_string.nil? || svg_string.to_s.empty?

      require 'tempfile'

      svg_file = Tempfile.new(['blueprint', '.svg'])
      svg_file.write(svg_string)
      svg_file.close

      png_file = Tempfile.new(['blueprint', '.png'])
      png_file.close

      # Primary: rsvg-convert (best quality)
      if system('which rsvg-convert > /dev/null 2>&1')
        success = system("rsvg-convert -w #{width.to_i} -o #{png_file.path} #{svg_file.path}")
        if success && File.exist?(png_file.path) && File.size(png_file.path) > 0
          svg_file.unlink
          return png_file.path
        end
      end

      # Fallback: ruby-vips
      begin
        require 'vips'
        image = Vips::Image.svgload(svg_file.path)
        scale_factor = width.to_f / image.width
        image = image.resize(scale_factor) if scale_factor != 1.0
        image.pngsave(png_file.path)
        svg_file.unlink
        png_file.path
      rescue StandardError => e
        warn "[MapSvgRenderService] SVG to PNG conversion failed: #{e.message}"
        svg_file.unlink rescue nil
        png_file.unlink rescue nil
        nil
      end
    end

    private

    # Draw room floor fill and segmented walls with gaps for features
    def draw_room_floor_and_walls(svg, room, rx, ry, rw, rh, features, scale, offset_x, offset_y,
                                   floor_color:, wall_color:, wall_width:, outdoor: false)
      if outdoor
        svg.rect(rx, ry, rw, rh, fill: floor_color, stroke: '#aabbaa', stroke_width: 1, stroke_dasharray: '8,4')
        return
      end

      # Custom polygon rooms
      if room.has_custom_polygon? && room.room_polygon.is_a?(Array)
        draw_polygon_walls(svg, room, features, scale, offset_x, offset_y,
                           floor_color: floor_color, wall_color: wall_color, wall_width: wall_width)
        return
      end

      # Rectangular room: floor fill (no stroke), then segmented walls
      svg.rect(rx, ry, rw, rh, fill: floor_color, stroke: 'none')

      grouped = group_wall_features(features, room)

      # North wall (left to right at top)
      draw_wall_with_gaps(svg, rx, ry, rx + rw, ry, grouped[:north], scale, offset_x, offset_y,
                          horizontal: true, wall_color: wall_color, wall_width: wall_width)
      # South wall (left to right at bottom)
      draw_wall_with_gaps(svg, rx, ry + rh, rx + rw, ry + rh, grouped[:south], scale, offset_x, offset_y,
                          horizontal: true, wall_color: wall_color, wall_width: wall_width)
      # West wall (top to bottom on left)
      draw_wall_with_gaps(svg, rx, ry, rx, ry + rh, grouped[:west], scale, offset_x, offset_y,
                          horizontal: false, wall_color: wall_color, wall_width: wall_width)
      # East wall (top to bottom on right)
      draw_wall_with_gaps(svg, rx + rw, ry, rx + rw, ry + rh, grouped[:east], scale, offset_x, offset_y,
                          horizontal: false, wall_color: wall_color, wall_width: wall_width)
    end

    # Draw polygon room floor and walls with gaps for features
    def draw_polygon_walls(svg, room, features, scale, offset_x, offset_y,
                           floor_color:, wall_color:, wall_width:)
      points = room.room_polygon.map do |pt|
        x = (pt['x'] || pt[:x] || pt[0]).to_f
        y = (pt['y'] || pt[:y] || pt[1]).to_f
        [offset_x + x * scale, offset_y + y * scale]
      end

      # Draw floor fill
      svg.polygon(points, fill: floor_color, stroke: 'none')

      # Assign features to nearest polygon edge
      wall_features = features.select { |f| %w[door gate window opening archway].include?(f.feature_type) }
      edge_features = Hash.new { |h, k| h[k] = [] }

      wall_features.each do |f|
        fx = offset_x + (f.x || 0) * scale
        fy = offset_y + (f.y || 0) * scale
        nearest_edge = find_nearest_edge(fx, fy, points)
        edge_features[nearest_edge] << f if nearest_edge
      end

      # Draw each polygon edge with gaps
      points.each_with_index do |pt, i|
        next_pt = points[(i + 1) % points.length]
        edge_feats = edge_features[i] || []

        if edge_feats.empty?
          svg.line(pt[0], pt[1], next_pt[0], next_pt[1], stroke: wall_color, stroke_width: wall_width)
        else
          draw_polygon_edge_with_gaps(svg, pt, next_pt, edge_feats, scale, offset_x, offset_y,
                                      wall_color: wall_color, wall_width: wall_width)
        end
      end
    end

    # Find nearest polygon edge index for a point
    def find_nearest_edge(px, py, polygon_points)
      min_dist = Float::INFINITY
      nearest = nil

      polygon_points.each_with_index do |pt, i|
        next_pt = polygon_points[(i + 1) % polygon_points.length]
        dist = point_to_segment_distance(px, py, pt[0], pt[1], next_pt[0], next_pt[1])
        if dist < min_dist
          min_dist = dist
          nearest = i
        end
      end

      nearest
    end

    # Distance from point to line segment
    def point_to_segment_distance(px, py, x1, y1, x2, y2)
      dx = x2 - x1
      dy = y2 - y1
      len_sq = dx * dx + dy * dy
      return Math.sqrt((px - x1)**2 + (py - y1)**2) if len_sq.zero?

      t = ((px - x1) * dx + (py - y1) * dy) / len_sq.to_f
      t = [[t, 0].max, 1].min

      proj_x = x1 + t * dx
      proj_y = y1 + t * dy
      Math.sqrt((px - proj_x)**2 + (py - proj_y)**2)
    end

    # Draw a polygon edge with gaps for features
    def draw_polygon_edge_with_gaps(svg, start_pt, end_pt, features, scale, offset_x, offset_y,
                                     wall_color:, wall_width:)
      dx = end_pt[0] - start_pt[0]
      dy = end_pt[1] - start_pt[1]
      edge_len = Math.sqrt(dx * dx + dy * dy)
      return if edge_len.zero?

      nx = dx / edge_len
      ny = dy / edge_len

      # Project features onto edge and sort
      projections = features.map do |f|
        fx = offset_x + (f.x || 0) * scale
        fy = offset_y + (f.y || 0) * scale
        t = ((fx - start_pt[0]) * nx + (fy - start_pt[1]) * ny).clamp(0, edge_len)
        { feature: f, t: t }
      end.sort_by { |p| p[:t] }

      cursor = 0.0
      projections.each do |proj|
        ft = proj[:feature].feature_type || 'door'
        gap_half = feature_gap_px(ft, scale) / 2.0
        gap_start = [proj[:t] - gap_half, 0].max
        gap_end = [proj[:t] + gap_half, edge_len].min

        if cursor < gap_start - 1
          svg.line(start_pt[0] + cursor * nx, start_pt[1] + cursor * ny,
                   start_pt[0] + gap_start * nx, start_pt[1] + gap_start * ny,
                   stroke: wall_color, stroke_width: wall_width)
        end
        cursor = gap_end
      end

      # Final segment
      if cursor < edge_len - 1
        svg.line(start_pt[0] + cursor * nx, start_pt[1] + cursor * ny,
                 end_pt[0], end_pt[1],
                 stroke: wall_color, stroke_width: wall_width)
      end
    end

    # Infer which wall a feature belongs to by proximity to room edges.
    # This is more reliable than trusting orientation/direction metadata.
    def infer_wall_for_feature(feature, room)
      fx = feature.x || 0
      fy = feature.y || 0
      min_x = room.min_x || 0
      min_y = room.min_y || 0
      max_x = room.max_x || 100
      max_y = room.max_y || 100

      distances = {
        north: (fy - min_y).abs,
        south: (fy - max_y).abs,
        west: (fx - min_x).abs,
        east: (fx - max_x).abs
      }

      distances.min_by { |_, d| d }[0]
    end

    # Group wall-gap features by coordinate proximity to room edges
    def group_wall_features(features, room)
      walls = { north: [], south: [], east: [], west: [] }
      features.each do |f|
        ft = f.feature_type || 'door'
        next unless %w[door gate window opening archway].include?(ft)

        wall_sym = infer_wall_for_feature(f, room)
        walls[wall_sym] << f
      end
      walls
    end

    # Draw a wall line from (x1,y1) to (x2,y2) with gaps for features
    def draw_wall_with_gaps(svg, x1, y1, x2, y2, features, scale, offset_x, offset_y,
                            horizontal:, wall_color:, wall_width:)
      if features.empty?
        svg.line(x1, y1, x2, y2, stroke: wall_color, stroke_width: wall_width)
        return
      end

      sorted = features.sort_by do |f|
        horizontal ? (offset_x + (f.x || 0) * scale) : (offset_y + (f.y || 0) * scale)
      end

      fixed = horizontal ? y1 : x1
      cursor = horizontal ? x1 : y1

      sorted.each do |feature|
        ft = feature.feature_type || 'door'
        gap_half = feature_gap_px(ft, scale) / 2.0
        feat_pos = horizontal ? (offset_x + (feature.x || 0) * scale) : (offset_y + (feature.y || 0) * scale)
        gap_start = feat_pos - gap_half
        gap_end = feat_pos + gap_half

        if cursor < gap_start - 1
          if horizontal
            svg.line(cursor, fixed, gap_start, fixed, stroke: wall_color, stroke_width: wall_width)
          else
            svg.line(fixed, cursor, fixed, gap_start, stroke: wall_color, stroke_width: wall_width)
          end
        end
        cursor = gap_end
      end

      axis_end = horizontal ? x2 : y2
      if cursor < axis_end - 1
        if horizontal
          svg.line(cursor, fixed, axis_end, fixed, stroke: wall_color, stroke_width: wall_width)
        else
          svg.line(fixed, cursor, fixed, axis_end, stroke: wall_color, stroke_width: wall_width)
        end
      end
    end

    # Gap width in pixels for a wall feature type
    def feature_gap_px(feature_type, scale)
      gap_ft = case feature_type
               when 'door', 'gate' then 3.0
               when 'window' then 3.0
               when 'opening', 'archway' then 4.0
               else 0
               end
      (gap_ft * scale).clamp(50, 70)
    end

    # Draw a distinctive furniture shape at (px, py) in pixel coords.
    # @param filled [Boolean] true for human blueprint (filled shapes), false for AI blueprint (outlines only)
    def draw_furniture_shape(svg, px, py, name, scale, filled: true)
      fill = filled ? '#cccccc' : 'none'
      stroke = filled ? '#333333' : '#666666'
      sw = 1.5

      leg = 6  # leg line length in px

      case name
      when /bed|cot|mattress|hammock/
        w = 3.5 * scale   # ~3.5ft wide (twin/double)
        h = 6.5 * scale   # ~6.5ft long
        svg.rect(px - w / 2, py - h / 2, w, h, fill: fill, stroke: stroke, stroke_width: sw, rx: 2)
        # Pillow at head end
        pillow_h = [h * 0.12, 4].max
        svg.rect(px - w / 2 + 2, py - h / 2 + 2, w - 4, pillow_h,
                 fill: filled ? '#bbbbbb' : 'none', stroke: stroke, stroke_width: 1)
        # Legs at four corners
        draw_legs(svg, px, py, w, h, leg, stroke)
      when /sofa|couch/
        w = 6.0 * scale
        h = 3.0 * scale
        svg.rect(px - w / 2, py - h / 2, w, h, fill: fill, stroke: stroke, stroke_width: sw, rx: 3)
        svg.line(px - w / 2, py - h / 2, px + w / 2, py - h / 2, stroke: stroke, stroke_width: sw * 2.5)
        draw_legs(svg, px, py, w, h, leg, stroke)
      when /table|desk|altar/
        w = 4.0 * scale
        h = 2.5 * scale
        svg.rect(px - w / 2, py - h / 2, w, h, fill: fill, stroke: stroke, stroke_width: sw, rx: 2)
        draw_legs(svg, px, py, w, h, leg, stroke)
      when /counter|bar(?!rel)/
        w = 6.0 * scale
        h = 2.0 * scale
        svg.rect(px - w / 2, py - h / 2, w, h, fill: fill, stroke: stroke, stroke_width: sw, rx: 2)
        draw_legs(svg, px, py, w, h, leg, stroke)
      when /display|cabinet|bookcase|shelf|bookshelf/
        w = 4.0 * scale
        h = 1.5 * scale
        svg.rect(px - w / 2, py - h / 2, w, h, fill: fill, stroke: stroke, stroke_width: sw, rx: 1)
        svg.line(px - w / 2 + 2, py, px + w / 2 - 2, py, stroke: stroke, stroke_width: 0.8)
        draw_legs(svg, px, py, w, h, leg, stroke)
      when /log|driftwood/
        w = 5.0 * scale
        h = 1.5 * scale
        svg.rect(px - w / 2, py - h / 2, w, h, fill: fill, stroke: stroke, stroke_width: sw, rx: 6)
      when /bench|pew/
        w = 6.0 * scale
        h = 1.5 * scale
        svg.rect(px - w / 2, py - h / 2, w, h, fill: fill, stroke: stroke, stroke_width: sw, rx: 4)
        draw_legs(svg, px, py, w, h, leg, stroke)
      when /chair|stool/
        s = 1.8 * scale
        # Seat — square with rounded corners
        svg.rect(px - s / 2, py - s / 2, s, s, fill: fill, stroke: stroke, stroke_width: sw, rx: 2)
        # Backrest — oval overlapping seat (center of oval aligns with seat top edge)
        back_w = s
        back_h = s * 0.5
        svg.rect(px - back_w / 2, py - s / 2 - back_h / 2, back_w, back_h,
                 fill: fill, stroke: stroke, stroke_width: sw, rx: back_w / 2, ry: back_h / 2)
        draw_legs(svg, px, py, s, s, leg, stroke)
      when /cushion|mat|rug/
        s = 2.5 * scale
        svg.rect(px - s / 2, py - s / 2, s, s, fill: fill, stroke: stroke, stroke_width: sw, rx: 3)
      when /crate|chest|box/
        s = 2.5 * scale
        svg.rect(px - s / 2, py - s / 2, s, s, fill: fill, stroke: stroke, stroke_width: sw, rx: 1)
        svg.line(px - s / 2, py - s / 2, px + s / 2, py + s / 2, stroke: stroke, stroke_width: 0.8)
        svg.line(px + s / 2, py - s / 2, px - s / 2, py + s / 2, stroke: stroke, stroke_width: 0.8)
      when /barrel|keg/
        r = 1.5 * scale
        svg.circle(px, py, r, fill: fill, stroke: stroke, stroke_width: sw)
        svg.line(px - r, py - r * 0.4, px + r, py - r * 0.4, stroke: stroke, stroke_width: 0.8)
        svg.line(px - r, py + r * 0.4, px + r, py + r * 0.4, stroke: stroke, stroke_width: 0.8)
      when /boulder|rock/
        r = 2.5 * scale
        svg.circle(px, py, r, fill: fill, stroke: stroke, stroke_width: sw)
      when /pillar|column/
        r = 1.0 * scale
        svg.circle(px, py, r, fill: filled ? '#999999' : 'none', stroke: stroke, stroke_width: sw)
      when /stump|planter/
        r = 1.5 * scale
        svg.circle(px, py, r, fill: fill, stroke: stroke, stroke_width: sw)
      when /stalagmite|stalactite/
        r = 1.0 * scale
        svg.circle(px, py, r, fill: fill, stroke: stroke, stroke_width: sw)
      when /rubble|debris/
        r = 2.0 * scale
        svg.circle(px, py, r, fill: fill, stroke: stroke, stroke_width: sw, stroke_dasharray: '3,2')
      when /firepit|campfire|fire/
        r = 2.0 * scale
        svg.circle(px, py, r, fill: fill, stroke: stroke, stroke_width: sw)
        svg.circle(px, py, r * 0.5, fill: 'none', stroke: stroke, stroke_width: 0.8)
      else
        r = 1.5 * scale
        svg.circle(px, py, r, fill: fill, stroke: stroke, stroke_width: sw)
      end
    end

    # Draw 2.5D-style legs: short lines angling down-right from the bottom edge
    # Only the two front legs are visible (back legs hidden behind furniture)
    def draw_legs(svg, cx, cy, w, h, leg, stroke)
      hw = w / 2.0
      hh = h / 2.0
      # Two front legs at bottom-left and bottom-right corners, angling down-right
      [[-1, 1], [1, 1]].each do |dx, _dy|
        x = cx + dx * hw
        y = cy + hh
        svg.line(x, y, x + leg * 0.5, y + leg, stroke: stroke, stroke_width: 1)
      end
    end

    # Vertical offset from furniture center to bottom edge (for label placement)
    def furniture_label_offset(name, scale)
      case name
      when /bed|cot|mattress|hammock/ then 6.5 * scale / 2
      when /sofa|couch/ then 3.0 * scale / 2
      when /table|desk|altar/ then 3.0 * scale / 2
      when /counter|bar(?!rel)/ then 2.0 * scale / 2
      when /display|cabinet|bookcase|shelf|bookshelf/ then 1.5 * scale / 2
      when /log|driftwood/ then 1.5 * scale / 2
      when /bench|pew/ then 1.5 * scale / 2
      when /chair|stool/ then 2.0 * scale / 2
      when /cushion|mat|rug/ then 2.5 * scale / 2
      when /crate|chest|box/ then 2.5 * scale / 2
      when /barrel|keg/ then 1.5 * scale
      when /boulder|rock/ then 2.5 * scale
      when /firepit|campfire|fire/ then 2.0 * scale
      else 1.5 * scale
      end
    end

    # Position a feature label centered in the gap and pushed inward from the wall.
    # For N/S walls: label goes below/above the gap.
    # For E/W walls: label goes to the right/left of the gap (into the room).
    def feature_label_pos(fx, fy, dir, inward, _font)
      case dir.to_s
      when 'north' then [fx, fy + inward]
      when 'south' then [fx, fy - inward * 0.5]
      when 'east'  then [fx - inward, fy + 4]
      when 'west'  then [fx + inward, fy + 4]
      else [fx, fy + inward]
      end
    end

    def draw_city_grid(svg, location, scale, offset_x, offset_y)
      streets = location.horizontal_streets || 10
      avenues = location.vertical_streets || 10
      cell = GridCalculationService::GRID_CELL_SIZE
      street_w = GridCalculationService::STREET_WIDTH

      # Draw horizontal streets
      (0..streets).each do |y|
        py = offset_y + y * cell * scale
        svg.rect(offset_x, py - street_w * scale / 2, avenues * cell * scale, street_w * scale,
                 fill: '#3d3d3d', stroke: 'none')
      end

      # Draw vertical avenues
      (0..avenues).each do |x|
        px = offset_x + x * cell * scale
        svg.rect(px - street_w * scale / 2, offset_y, street_w * scale, streets * cell * scale,
                 fill: '#3d3d3d', stroke: 'none')
      end
    end

    def draw_city_building(svg, room, scale, offset_x, offset_y)
      return unless room.min_x && room.min_y && room.max_x && room.max_y

      x = offset_x + room.min_x * scale
      y = offset_y + room.min_y * scale
      w = (room.max_x - room.min_x) * scale
      h = (room.max_y - room.min_y) * scale

      building_type = room.room_type&.to_sym
      color = SvgBuilder::BUILDING_COLORS[building_type] || '#4a5568'

      svg.rect(x, y, w, h, fill: color, stroke: '#2d3748', stroke_width: 1)

      # Label if space
      if w > 20 && h > 12
        label = room.name&.slice(0, 8) || ''
        svg.text(x + w / 2, y + h / 2 + 3, label, font_size: [w / 8, 9].min, fill: '#fff', text_anchor: 'middle')
      end
    end

    def draw_street_labels(svg, location, scale, offset_x, offset_y, width, height)
      # Draw street names from location cache
      street_names = location.street_names_json || []
      avenue_names = location.avenue_names_json || []

      cell = GridCalculationService::GRID_CELL_SIZE

      # Label streets (left side)
      street_names.each_with_index do |name, i|
        py = offset_y + (i + 0.5) * cell * scale
        svg.text(5, py, name&.slice(0, 15) || "St #{i + 1}", font_size: 8, fill: '#9ca3af', text_anchor: 'start')
      end

      # Label avenues (top)
      avenue_names.each_with_index do |name, i|
        px = offset_x + (i + 0.5) * cell * scale
        svg.text(px, height - 8, name&.slice(0, 10) || "Ave #{i + 1}", font_size: 8, fill: '#9ca3af', text_anchor: 'middle')
      end
    end

    def draw_place(svg, place, scale, offset_x, offset_y)
      x = offset_x + place.x * scale
      y = offset_y + place.y * scale
      size = 12

      svg.rect(x - size / 2, y - size / 2, size, size,
               fill: '#4a5568', stroke: '#718096', stroke_width: 1, rx: 2)

      label = place.name&.slice(0, 3)&.upcase || 'FRN'
      svg.text(x, y + 3, label, font_size: 7, fill: '#fff', text_anchor: 'middle')
    end

    def draw_spatial_exit(svg, exit_data, room, scale, offset_x, offset_y)
      # Position exit at edge of room based on direction
      direction = exit_data[:direction].to_s
      room_cx = ((room.min_x || 0) + (room.max_x || 100)) / 2.0
      room_cy = ((room.min_y || 0) + (room.max_y || 100)) / 2.0

      case direction
      when 'north' then x, y = room_cx, room.min_y || 0
      when 'south' then x, y = room_cx, room.max_y || 100
      when 'east' then x, y = room.max_x || 100, room_cy
      when 'west' then x, y = room.min_x || 0, room_cy
      when 'northeast' then x, y = room.max_x || 100, room.min_y || 0
      when 'northwest' then x, y = room.min_x || 0, room.min_y || 0
      when 'southeast' then x, y = room.max_x || 100, room.max_y || 100
      when 'southwest' then x, y = room.min_x || 0, room.max_y || 100
      else x, y = room_cx, room_cy
      end

      px = offset_x + x * scale
      py = offset_y + y * scale

      # Draw arrow
      svg.circle(px, py, 6, fill: '#ef4444', stroke: '#fff', stroke_width: 1)
      svg.text(px, py + 3, direction[0].upcase, font_size: 7, fill: '#fff', text_anchor: 'middle')
    end

    def draw_feature(svg, feature, scale, offset_x, offset_y)
      x = offset_x + (feature.x || 0) * scale
      y = offset_y + (feature.y || 0) * scale
      w = (feature.width || 3) * scale
      h = 4

      color = case feature.feature_type
              when 'door' then '#8b5cf6'
              when 'window' then '#06b6d4'
              else '#f59e0b'
              end

      case feature.orientation
      when 'north', 'south'
        svg.rect(x - w / 2, y - h / 2, w, h, fill: color, stroke: '#fff', stroke_width: 0.5)
      else
        svg.rect(x - h / 2, y - w / 2, h, w, fill: color, stroke: '#fff', stroke_width: 0.5)
      end
    end

    def hex_type_color(hex_type)
      case hex_type
      when 'wall' then '#4a4a4a'
      when 'water' then '#3182ce'
      when 'fire', 'lava' then '#e53e3e'
      when 'cover', 'half_cover' then '#718096'
      when 'debris' then '#a0aec0'
      when 'trap' then '#d69e2e'
      else '#1e2228'
      end
    end

    def terrain_abbrev(terrain)
      case terrain
      when 'ocean', 'deep_ocean' then 'OCN'
      when 'lake', 'shallow_water' then 'WTR'
      when 'light_forest', 'dense_forest', 'jungle', 'forest' then 'FOR'
      when 'mountain' then 'MTN'
      when 'grassy_plains', 'rocky_plains' then 'PLN'
      when 'grassy_hills', 'rocky_hills' then 'HIL'
      when 'grassland' then 'GRS'
      when 'desert' then 'DST'
      when 'urban', 'light_urban' then 'URB'
      when 'swamp' then 'SWP'
      when 'tundra' then 'TUN'
      when 'snow', 'ice' then 'SNW'
      when 'rocky_coast', 'sandy_coast' then 'CST'
      when 'volcanic' then 'VOL'
      else terrain&.slice(0, 3)&.upcase || '???'
      end
    end

    def add_globe_grid_lines(svg, min_lon, max_lon, min_lat, max_lat, width, height, padding)
      lon_range = max_lon - min_lon
      lat_range = max_lat - min_lat

      # Draw latitude lines (every 30 degrees within range)
      (-60..60).step(30).each do |lat|
        next if lat < min_lat || lat > max_lat

        y = padding + ((max_lat - lat) / lat_range * (height - padding * 2))
        svg.line(padding, y.round(1), width - padding, y.round(1),
                 stroke: '#ffffff22', stroke_width: 1)
        svg.text(padding + 5, y.round(1) - 3, "#{lat}°", font_size: 8, fill: '#ffffff44')
      end

      # Draw longitude lines (every 30 degrees within range)
      (-150..150).step(30).each do |lon|
        next if lon < min_lon || lon > max_lon

        x = padding + ((lon - min_lon) / lon_range * (width - padding * 2))
        svg.line(x.round(1), padding, x.round(1), height - padding,
                 stroke: '#ffffff22', stroke_width: 1)
        svg.text(x.round(1) + 3, padding + 10, "#{lon}°", font_size: 8, fill: '#ffffff44')
      end
    end

    def add_world_legend(svg, width, height)
      legend_items = [
        ['OCN', '#1e3a5f'], ['FOR', '#228b22'], ['MTN', '#696969'],
        ['GRS', '#7cba5c'], ['DST', '#deb887'], ['URB', '#4a4a4a']
      ]

      legend_x = width - 80
      legend_y = height - 15

      legend_items.each_with_index do |(label, color), i|
        x = legend_x + i * 12
        svg.rect(x, legend_y, 10, 10, fill: color, stroke: '#333')
      end
    end

    def error_svg(width, height, message)
      svg = SvgBuilder.new(width, height, background: '#1a1a2e')
      svg.text(width / 2, height / 2, 'Error', font_size: 16, fill: '#ef4444', text_anchor: 'middle')
      svg.text(width / 2, height / 2 + 20, message, font_size: 10, fill: '#9ca3af', text_anchor: 'middle')
      svg.to_xml
    end
  end
end
