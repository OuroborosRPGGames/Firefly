# frozen_string_literal: true

# Renders city maps and minimaps as SVG for the webclient.
#
# Supports two viewing contexts:
# - Exterior: Shows streets, buildings, and city overview
# - Interior: Shows rooms within a building (rooms sharing inside_room_id)
#
# Two modes control viewport size:
# - :minimap - 200ft radius, compact display
# - :city    - 500ft radius, detailed city view
#
# Room detail levels:
# - :high   - Shows furniture, inner room outlines
# - :medium - Shows inner room outlines
# - :low    - Shows building outlines only
# - nil     - Auto-detect based on mode (:minimap => :low, :city => :medium)
#
# @example
#   result = CityMapRenderService.render(viewer: character_instance, mode: :minimap)
#   result[:svg]      # => SVG XML string
#   result[:metadata] # => { center_room_id:, context:, mode:, location_id:, location_name: }
#
class CityMapRenderService
  VALID_MODES = %i[minimap city].freeze
  VALID_CONTEXTS = %i[auto interior exterior].freeze
  VALID_DETAIL_LEVELS = %i[high medium low].freeze

  # Viewport radius in feet per mode
  VIEWPORT_RADIUS = {
    minimap: 200,
    city: 500
  }.freeze

  # SVG output dimensions in pixels
  SVG_DIMENSIONS = {
    minimap: { width: 400, height: 400 },
    city: { width: 800, height: 600 }
  }.freeze

  # Room types that indicate an interior context (from centralized config)
  INTERIOR_ROOM_TYPES = RoomTypeConfig.tagged(:interior).freeze

  # Room types that are streets (rendered differently)
  STREET_ROOM_TYPES = RoomTypeConfig.tagged(:street).freeze

  # Color palette
  COLORS = {
    background: '#0d1117',
    street: '#3d444d',
    street_border: '#252a30',
    grid: '#1a1f26',
    buildings: {
      residential: '#2a5090',
      commercial: '#8a6a2a',
      tavern: '#8a4a2a',
      temple: '#5a2a8a',
      default: '#3a5a6a'
    },
    door: '#e0c070',
    current_room: '#ffd700',
    character_self: '#ef4444',
    character_other: '#22d3ee',
    labels: {
      room_name: '#ffffff',
      street_name: '#ffffff',
      building_name: '#ffffff'
    }
  }.freeze

  # Maps room_type to building color category
  BUILDING_COLOR_MAP = {
    'apartment' => :residential, 'residence' => :residential, 'bedroom' => :residential,
    'bathroom' => :residential, 'kitchen' => :residential, 'living_room' => :residential,
    'basement' => :residential, 'attic' => :residential, 'garage' => :residential,
    'shop' => :commercial, 'office' => :commercial, 'commercial' => :commercial,
    'warehouse' => :commercial, 'factory' => :commercial, 'lobby' => :commercial,
    'bar' => :tavern, 'restaurant' => :tavern, 'nightclub' => :tavern,
    'temple' => :temple, 'church' => :temple, 'guild' => :temple
  }.freeze

  # Minimum room dimension in pixels to show a label
  MIN_LABEL_SIZE_PX = 30

  # Maximum building dimension in feet before we consider it a container/sky room
  # Rooms larger than this are filtered from building rendering
  MAX_BUILDING_DIMENSION = 400

  # Maximum rooms to render in interior view (delve buildings can have hundreds)
  MAX_INTERIOR_ROOMS = 50

  class << self
    # Render a city map or minimap SVG centered on the viewer's position.
    #
    # @param viewer [CharacterInstance] the viewer character instance
    # @param mode [Symbol] :minimap or :city (default :minimap)
    # @param room_detail [Symbol, nil] :high, :medium, :low, or nil for auto
    # @param context [Symbol] :auto, :interior, or :exterior (default :auto)
    # @return [Hash] { svg: String, metadata: Hash }
    def render(viewer:, mode: :minimap, room_detail: nil, context: :auto)
      validate_params!(viewer, mode, room_detail, context)

      room = viewer.current_room
      raise ArgumentError, 'Viewer must have a current room' unless room

      resolved_context = resolve_context(context, room)
      resolved_detail = resolve_detail(room_detail, mode, resolved_context)
      viewport = calculate_viewport(viewer, room, mode, resolved_context)
      dimensions = SVG_DIMENSIONS[mode]

      visible_rooms = query_visible_rooms(room, resolved_context, viewport)
      characters = query_characters(room, viewer, viewport, resolved_context)

      svg = build_svg(
        dimensions: dimensions,
        viewport: viewport,
        visible_rooms: visible_rooms,
        characters: characters,
        viewer: viewer,
        current_room: room,
        resolved_context: resolved_context,
        resolved_detail: resolved_detail
      )

      location = room.location
      {
        svg: svg,
        metadata: {
          center_room_id: room.id,
          context: resolved_context,
          mode: mode,
          location_id: location&.id,
          location_name: location&.display_name,
          viewport: viewport,
          svg_width: dimensions[:width],
          svg_height: dimensions[:height]
        }
      }
    end

    private

    # =========================================
    # Parameter Validation
    # =========================================

    def validate_params!(viewer, mode, room_detail, context)
      raise ArgumentError, 'viewer is required' if viewer.nil?
      raise ArgumentError, "Invalid mode: #{mode}. Must be one of: #{VALID_MODES.join(', ')}" unless VALID_MODES.include?(mode)
      raise ArgumentError, "Invalid context: #{context}. Must be one of: #{VALID_CONTEXTS.join(', ')}" unless VALID_CONTEXTS.include?(context)

      if room_detail && !VALID_DETAIL_LEVELS.include?(room_detail)
        raise ArgumentError, "Invalid room_detail: #{room_detail}. Must be one of: #{VALID_DETAIL_LEVELS.join(', ')}"
      end
    end

    # =========================================
    # Context Detection
    # =========================================

    def resolve_context(context, room)
      return context if context != :auto

      if room.inside_room_id
        :interior
      elsif INTERIOR_ROOM_TYPES.include?(room.room_type)
        :interior
      else
        :exterior
      end
    end

    def resolve_detail(room_detail, mode, context = :exterior)
      return room_detail if room_detail

      # Interior minimaps need medium detail to show inner room outlines
      if mode == :minimap && context == :interior
        :medium
      elsif mode == :minimap
        :low
      else
        :medium
      end
    end

    # =========================================
    # Viewport Calculation
    # =========================================

    def calculate_viewport(viewer, room, mode, context = :exterior)
      if context == :interior
        calculate_interior_viewport(room, mode)
      else
        calculate_exterior_viewport(viewer, room, mode)
      end
    end

    def calculate_exterior_viewport(viewer, room, mode)
      # Character x/y is in location-absolute coordinates.
      # Fall back to room center if position is unset.
      world_x, world_y = resolve_world_position(viewer, room)
      radius = VIEWPORT_RADIUS[mode]

      {
        center_x: world_x,
        center_y: world_y,
        radius: radius,
        min_x: world_x - radius,
        max_x: world_x + radius,
        min_y: world_y - radius,
        max_y: world_y + radius
      }
    end

    def calculate_interior_viewport(room, mode)
      # For interior views, fit the viewport to the container room with padding
      container_id = room.inside_room_id || room.id
      container = Room[container_id]
      container ||= room

      # Container bounds
      cx_min = container.min_x || 0
      cy_min = container.min_y || 0
      cx_max = container.max_x || 100
      cy_max = container.max_y || 100

      container_w = cx_max - cx_min
      container_h = cy_max - cy_min

      # Add 20% padding around the container, minimum 10ft
      padding = [([container_w, container_h].max * 0.2), 10].max
      center_x = (cx_min + cx_max) / 2.0
      center_y = (cy_min + cy_max) / 2.0

      # Make viewport square (largest dimension + padding)
      half_size = ([container_w, container_h].max / 2.0) + padding

      # Don't exceed the normal mode radius
      max_radius = VIEWPORT_RADIUS[mode]
      half_size = [half_size, max_radius].min

      {
        center_x: center_x,
        center_y: center_y,
        radius: half_size,
        min_x: center_x - half_size,
        max_x: center_x + half_size,
        min_y: center_y - half_size,
        max_y: center_y + half_size
      }
    end

    # =========================================
    # Room Queries
    # =========================================

    def query_visible_rooms(room, context, viewport)
      location_id = room.location_id
      return [] unless location_id

      if context == :interior
        query_interior_rooms(room, location_id)
      else
        query_exterior_rooms(location_id, viewport)
      end
    rescue StandardError => e
      warn "[CityMapRenderService] Failed to query rooms: #{e.message}"
      []
    end

    def query_interior_rooms(room, location_id)
      container_id = room.inside_room_id || room.id
      rooms = Room.where(location_id: location_id, inside_room_id: container_id)
                  .exclude(active: false)
                  .exclude(is_temporary: true)
                  .all

      # Cap room count to avoid overwhelming the minimap (delve buildings can have hundreds)
      if rooms.length > MAX_INTERIOR_ROOMS
        # Keep rooms closest to the current room by spatial distance
        cur_cx = ((room.min_x || 0) + (room.max_x || 0)) / 2.0
        cur_cy = ((room.min_y || 0) + (room.max_y || 0)) / 2.0
        rooms = rooms.sort_by do |r|
          rx = ((r.min_x || 0) + (r.max_x || 0)) / 2.0
          ry = ((r.min_y || 0) + (r.max_y || 0)) / 2.0
          (rx - cur_cx) ** 2 + (ry - cur_cy) ** 2
        end.first(MAX_INTERIOR_ROOMS)
      end

      # Include the container room itself
      container = Room[container_id]
      rooms = rooms + [container] if container && !rooms.any? { |r| r.id == container.id }

      rooms
    end

    def query_exterior_rooms(location_id, viewport)
      # Find rooms whose bounding box overlaps the viewport
      Room.where(location_id: location_id)
          .exclude(active: false)
          .exclude(is_temporary: true)
          .where { min_x <= viewport[:max_x] }
          .where { max_x >= viewport[:min_x] }
          .where { min_y <= viewport[:max_y] }
          .where { max_y >= viewport[:min_y] }
          .where(inside_room_id: nil)
          .all
    rescue StandardError => e
      warn "[CityMapRenderService] Exterior room query failed: #{e.message}"
      []
    end

    # =========================================
    # Character Queries
    # =========================================

    def query_characters(room, viewer, viewport, context)
      if context == :interior
        # Show characters in rooms with same container
        container_id = room.inside_room_id || room.id
        sibling_room_ids = Room.where(inside_room_id: container_id).select_map(:id)
        sibling_room_ids << container_id

        CharacterInstance.where(current_room_id: sibling_room_ids, online: true)
                         .exclude(id: viewer.id)
                         .all
      else
        # Show characters in visible rooms within viewport
        visible_room_ids = Room.where(location_id: room.location_id)
                               .exclude(active: false)
                               .where { min_x <= viewport[:max_x] }
                               .where { max_x >= viewport[:min_x] }
                               .where { min_y <= viewport[:max_y] }
                               .where { max_y >= viewport[:min_y] }
                               .where(inside_room_id: nil)
                               .select_map(:id)

        CharacterInstance.where(current_room_id: visible_room_ids, online: true)
                         .exclude(id: viewer.id)
                         .all
      end
    rescue StandardError => e
      warn "[CityMapRenderService] Character query failed: #{e.message}"
      []
    end

    # =========================================
    # SVG Construction
    # =========================================

    def build_svg(dimensions:, viewport:, visible_rooms:, characters:, viewer:, current_room:, resolved_context:, resolved_detail:)
      width = dimensions[:width]
      height = dimensions[:height]

      svg = SvgBuilder.new(width, height, background: COLORS[:background])

      # Add glow filter definitions
      add_filter_defs(svg)

      # Layer 1: Grid lines
      draw_grid(svg, viewport, width, height)

      # Layer 2: Streets
      street_rooms = visible_rooms.select { |r| STREET_ROOM_TYPES.include?(r.room_type) }
      street_rooms.each { |r| draw_street(svg, r, viewport, width, height) }

      # Layer 3: Buildings (non-street, non-inside rooms)
      # Filter out oversized rooms (sky/container rooms that span the whole city)
      building_rooms = visible_rooms.reject do |r|
        STREET_ROOM_TYPES.include?(r.room_type) ||
          (r.max_x - r.min_x) > MAX_BUILDING_DIMENSION ||
          (r.max_y - r.min_y) > MAX_BUILDING_DIMENSION
      end
      building_rooms.each { |r| draw_building(svg, r, viewport, width, height) }

      # Layer 3.5: Door indicators on buildings
      draw_door_indicators(svg, building_rooms, viewport, width, height)

      # Layer 4: Room detail (inner rooms, furniture) - only when inside a building
      if resolved_context == :interior && (resolved_detail == :high || resolved_detail == :medium)
        draw_room_detail(svg, visible_rooms, viewport, width, height, resolved_detail, current_room)
      end

      # Layer 5: Street names
      draw_street_names(svg, street_rooms, viewport, width, height)

      # Layer 6: Building labels (after room detail so text isn't covered)
      building_rooms.each { |r| draw_building_label(svg, r, viewport, width, height) }

      # Layer 7: Characters (others first, then self on top)
      characters.each do |char|
        draw_character(svg, char, viewport, width, height, is_self: false)
      end
      draw_character(svg, viewer, viewport, width, height, is_self: true)

      # Layer 8: Current room highlight
      draw_current_room_highlight(svg, current_room, viewport, width, height)

      # Strip XML declaration — not needed for innerHTML injection and breaks browser parsing
      svg.to_xml.sub(/\s*<\?xml[^?]*\?>\s*/, '')
    end

    # =========================================
    # Coordinate Transform
    # =========================================

    # Convert world coordinates to SVG pixel coordinates.
    # Resolve a character's world position from their stored coordinates.
    # Character x/y are in location-absolute space. If the position is
    # unset (0,0 outside room bounds), fall back to the room center.
    def resolve_world_position(char_instance, room)
      pos = char_instance.position
      cx = pos[0]
      cy = pos[1]

      room_min_x = room.min_x || 0.0
      room_min_y = room.min_y || 0.0
      room_max_x = room.max_x || 100.0
      room_max_y = room.max_y || 100.0

      # Check if position is within room bounds (with small tolerance)
      in_room = cx.between?(room_min_x - 1, room_max_x + 1) &&
                cy.between?(room_min_y - 1, room_max_y + 1)

      if in_room
        [cx, cy]
      else
        # Unset/default position — use room center
        [(room_min_x + room_max_x) / 2.0, (room_min_y + room_max_y) / 2.0]
      end
    end

    # World Y increases upward; SVG Y increases downward.
    def world_to_svg(world_x, world_y, viewport, svg_width, svg_height)
      vp_width = viewport[:max_x] - viewport[:min_x]
      vp_height = viewport[:max_y] - viewport[:min_y]

      # Normalize to 0..1 within viewport
      norm_x = (world_x - viewport[:min_x]) / vp_width.to_f
      norm_y = (world_y - viewport[:min_y]) / vp_height.to_f

      # Flip Y axis: world Y up => SVG Y down
      svg_x = norm_x * svg_width
      svg_y = (1.0 - norm_y) * svg_height

      [svg_x, svg_y]
    end

    # Convert world dimensions (width, height in feet) to SVG pixel dimensions
    def world_to_svg_size(world_w, world_h, viewport, svg_width, svg_height)
      vp_width = viewport[:max_x] - viewport[:min_x]
      vp_height = viewport[:max_y] - viewport[:min_y]

      px_w = (world_w / vp_width.to_f) * svg_width
      px_h = (world_h / vp_height.to_f) * svg_height

      [px_w, px_h]
    end

    # =========================================
    # Drawing: Filter Definitions
    # =========================================

    def add_filter_defs(svg)
      svg.instance_variable_get(:@defs) << <<~FILTER
        <filter id="glow-gold" x="-50%" y="-50%" width="200%" height="200%">
          <feGaussianBlur in="SourceGraphic" stdDeviation="3" result="blur"/>
          <feFlood flood-color="#{COLORS[:current_room]}" flood-opacity="0.6" result="color"/>
          <feComposite in="color" in2="blur" operator="in" result="glow"/>
          <feMerge>
            <feMergeNode in="glow"/>
            <feMergeNode in="SourceGraphic"/>
          </feMerge>
        </filter>
        <filter id="glow-red" x="-50%" y="-50%" width="200%" height="200%">
          <feGaussianBlur in="SourceGraphic" stdDeviation="2" result="blur"/>
          <feFlood flood-color="#{COLORS[:character_self]}" flood-opacity="0.6" result="color"/>
          <feComposite in="color" in2="blur" operator="in" result="glow"/>
          <feMerge>
            <feMergeNode in="glow"/>
            <feMergeNode in="SourceGraphic"/>
          </feMerge>
        </filter>
      FILTER
    end

    # =========================================
    # Drawing: Grid
    # =========================================

    def draw_grid(svg, viewport, width, height)
      grid_spacing = GridCalculationService::GRID_CELL_SIZE # 175 feet - aligns with city cells

      # Vertical lines
      start_x = (viewport[:min_x] / grid_spacing).ceil * grid_spacing
      x = start_x
      while x <= viewport[:max_x]
        sx, _sy1 = world_to_svg(x, viewport[:min_y], viewport, width, height)
        svg.line(sx, 0, sx, height, stroke: COLORS[:grid], stroke_width: 0.5)
        x += grid_spacing
      end

      # Horizontal lines
      start_y = (viewport[:min_y] / grid_spacing).ceil * grid_spacing
      y = start_y
      while y <= viewport[:max_y]
        _sx1, sy = world_to_svg(viewport[:min_x], y, viewport, width, height)
        svg.line(0, sy, width, sy, stroke: COLORS[:grid], stroke_width: 0.5)
        y += grid_spacing
      end
    end

    # =========================================
    # Drawing: Streets
    # =========================================

    def draw_street(svg, room, viewport, width, height)
      sx, sy = world_to_svg(room.min_x, room.max_y, viewport, width, height)
      sw, sh = world_to_svg_size(room.max_x - room.min_x, room.max_y - room.min_y, viewport, width, height)

      svg.rect(sx, sy, sw, sh,
               fill: COLORS[:street],
               stroke: COLORS[:street_border],
               stroke_width: 0.5,
               'data-room-id' => room.id.to_s,
               'data-room-name' => escape_attr(room.name),
               'data-room-type' => room.room_type.to_s)
    end

    # =========================================
    # Drawing: Street Names
    # =========================================

    def draw_street_names(svg, street_rooms, viewport, width, height)
      # Group segments by street_name (or room name as fallback)
      by_name = {}
      street_rooms.each do |room|
        name = room.respond_to?(:street_name) && !room.street_name.to_s.empty? ? room.street_name.to_s : room.name.to_s
        next if name.empty?

        by_name[name] ||= { rooms: [], type: room.room_type }
        by_name[name][:rooms] << room
      end

      ew_labels = []
      ns_labels = []

      by_name.each do |name, info|
        rooms = info[:rooms]
        is_ns = info[:type] == 'avenue'

        # Compute bounding box of all segments with this name
        min_x = rooms.map(&:min_x).min
        max_x = rooms.map(&:max_x).max
        min_y = rooms.map(&:min_y).min
        max_y = rooms.map(&:max_y).max

        # Convert to SVG coords
        span_w, span_h = world_to_svg_size(max_x - min_x, max_y - min_y, viewport, width, height)
        long_axis = [span_w, span_h].max
        next if long_axis < 40

        # Center of the span
        center_wx = (min_x + max_x) / 2.0
        center_wy = (min_y + max_y) / 2.0
        cx, cy = world_to_svg(center_wx, center_wy, viewport, width, height)

        # Font size: proportional to span length, capped
        font_size = [(long_axis * 0.06).round(1), 12].min
        font_size = [font_size, 6].max

        entry = { name: name, cx: cx, cy: cy, font_size: font_size, span: long_axis }
        if is_ns
          ns_labels << entry
        else
          ew_labels << entry
        end
      end

      # Render with overlap avoidance
      render_street_labels_avoiding_overlap(svg, ew_labels, :ew)
      render_street_labels_avoiding_overlap(svg, ns_labels, :ns)
    end

    # Group labels by grid position and render only the most prominent label
    # per grid slot. Labels at the same grid position (within tolerance) are
    # grouped, and only the longest-spanning one is rendered. This prevents
    # clutter when multiple parallel streets share the same grid row/column.
    def render_street_labels_avoiding_overlap(svg, labels, direction)
      return if labels.empty?

      # Sort by position on the relevant axis
      sorted = if direction == :ew
                 labels.sort_by { |l| l[:cy] }
               else
                 labels.sort_by { |l| l[:cx] }
               end

      # Group labels that are at the same grid position (within tolerance).
      # N-S labels need wider tolerance since rotated text occupies more space.
      tolerance = sorted.first[:font_size] * (direction == :ns ? 3.0 : 2.0)
      groups = []

      sorted.each do |label|
        pos = direction == :ew ? label[:cy] : label[:cx]
        placed = false

        groups.each do |group|
          group_pos = direction == :ew ? group.first[:cy] : group.first[:cx]
          if (pos - group_pos).abs < tolerance
            group << label
            placed = true
            break
          end
        end

        groups << [label] unless placed
      end

      # From each group, render only the label with the longest visible span
      groups.each do |group|
        best = group.max_by { |l| l[:span] }
        fs = best[:font_size]

        text_opts = {
          font_size: fs,
          fill: COLORS[:labels][:street_name],
          text_anchor: 'middle',
          opacity: 0.7,
          'font-family' => 'sans-serif',
          'pointer-events' => 'none'
        }

        if direction == :ew
          svg.text(best[:cx], best[:cy] + (fs / 3.0), best[:name], **text_opts)
        else
          text_opts[:transform] = "rotate(-90, #{best[:cx].round(2)}, #{best[:cy].round(2)})"
          svg.text(best[:cx], best[:cy] + (fs / 3.0), best[:name], **text_opts)
        end
      end
    end

    # =========================================
    # Drawing: Buildings
    # =========================================

    def draw_building(svg, room, viewport, width, height)
      sx, sy = world_to_svg(room.min_x, room.max_y, viewport, width, height)
      sw, sh = world_to_svg_size(room.max_x - room.min_x, room.max_y - room.min_y, viewport, width, height)

      color = building_color(room.room_type)

      svg.rect(sx, sy, sw, sh,
               fill: color,
               stroke: '#1a1f26',
               stroke_width: 1,
               rx: 2,
               ry: 2,
               'data-room-id' => room.id.to_s,
               'data-room-name' => escape_attr(room.name),
               'data-room-type' => room.room_type.to_s)
    end

    def building_color(room_type)
      category = BUILDING_COLOR_MAP[room_type.to_s] || :default
      COLORS[:buildings][category]
    end

    # =========================================
    # Drawing: Building Labels
    # =========================================

    def draw_building_label(svg, room, viewport, width, height)
      sw, sh = world_to_svg_size(room.max_x - room.min_x, room.max_y - room.min_y, viewport, width, height)
      return if sw < MIN_LABEL_SIZE_PX || sh < MIN_LABEL_SIZE_PX

      center_world_x = (room.min_x + room.max_x) / 2.0
      center_world_y = (room.min_y + room.max_y) / 2.0
      cx, cy = world_to_svg(center_world_x, center_world_y, viewport, width, height)

      label = room.name.to_s
      return if label.empty?

      # Available space with padding
      avail_w = sw * 0.85
      avail_h = sh * 0.85

      # Find best font size that fits with word wrap (largest first)
      best_size = 5
      best_lines = [label]
      (5..14).reverse_each do |size|
        char_w = size * 0.6
        chars_per_line = (avail_w / char_w).to_i
        next if chars_per_line < 2

        lines = word_wrap(label, chars_per_line)
        line_height = size * 1.3
        total_text_height = lines.length * line_height

        if total_text_height <= avail_h
          best_size = size
          best_lines = lines
          break
        end
      end

      # Build multiline text with tspan elements
      line_height = best_size * 1.3
      total_height = best_lines.length * line_height
      start_y = cy - (total_height / 2.0) + best_size

      tspans = best_lines.map.with_index do |line, i|
        y_pos = (start_y + (i * line_height)).round(2)
        "<tspan x=\"#{cx.round(2)}\" y=\"#{y_pos}\">#{escape_attr(line)}</tspan>"
      end.join

      svg.raw(
        "<text font-size=\"#{best_size}\" fill=\"#{COLORS[:labels][:building_name]}\" " \
        "text-anchor=\"middle\" font-family=\"sans-serif\" pointer-events=\"none\">" \
        "#{tspans}</text>"
      )
    end

    def word_wrap(text, max_chars)
      words = text.split(' ')
      lines = []
      current = ''

      words.each do |word|
        if current.empty?
          current = word
        elsif (current.length + 1 + word.length) <= max_chars
          current += " #{word}"
        else
          lines << current
          current = word
        end
      end
      lines << current unless current.empty?
      lines
    end

    # =========================================
    # Drawing: Door Indicators
    # =========================================

    def draw_door_indicators(svg, building_rooms, viewport, width, height)
      building_ids = building_rooms.map(&:id)
      return if building_ids.empty?

      doors = RoomFeature.where(room_id: building_ids)
                         .where(feature_type: %w[door gate])
                         .all

      doors.each do |door|
        room = building_rooms.find { |r| r.id == door.room_id }
        next unless room

        draw_door_icon(svg, door, room, viewport, width, height)
      end
    end

    def draw_door_icon(svg, door, room, viewport, width, height)
      mid_x = (room.min_x + room.max_x) / 2.0
      mid_y = (room.min_y + room.max_y) / 2.0

      case door.direction
      when 'south'
        wx = door.x || mid_x
        wy = room.min_y
      when 'north'
        wx = door.x || mid_x
        wy = room.max_y
      when 'west'
        wx = room.min_x
        wy = door.y || mid_y
      when 'east'
        wx = room.max_x
        wy = door.y || mid_y
      else
        return
      end

      dx, dy = world_to_svg(wx, wy, viewport, width, height)
      door_size = 4
      color = COLORS[:door]

      if %w[north south].include?(door.direction)
        svg.line(dx - door_size, dy - 2, dx - door_size, dy + 2,
                 stroke: color, stroke_width: 1.5)
        svg.line(dx + door_size, dy - 2, dx + door_size, dy + 2,
                 stroke: color, stroke_width: 1.5)
        svg.line(dx - door_size, dy, dx + door_size, dy,
                 stroke: color, stroke_width: 1)
      else
        svg.line(dx - 2, dy - door_size, dx + 2, dy - door_size,
                 stroke: color, stroke_width: 1.5)
        svg.line(dx - 2, dy + door_size, dx + 2, dy + door_size,
                 stroke: color, stroke_width: 1.5)
        svg.line(dx, dy - door_size, dx, dy + door_size,
                 stroke: color, stroke_width: 1)
      end
    end

    # =========================================
    # Drawing: Room Detail
    # =========================================

    def draw_room_detail(svg, visible_rooms, viewport, width, height, detail_level, current_room)
      # At medium/high detail, draw inner room outlines for rooms that contain sub-rooms
      container_ids = visible_rooms.select { |r| !STREET_ROOM_TYPES.include?(r.room_type) }.map(&:id)
      return if container_ids.empty?

      # Build a lookup of container rooms by ID for color inheritance
      container_lookup = visible_rooms.each_with_object({}) { |r, h| h[r.id] = r }

      inner_rooms = Room.where(inside_room_id: container_ids).exclude(active: false).exclude(is_temporary: true).all
      inner_rooms.each do |inner|
        sx, sy = world_to_svg(inner.min_x, inner.max_y, viewport, width, height)
        sw, sh = world_to_svg_size(inner.max_x - inner.min_x, inner.max_y - inner.min_y, viewport, width, height)

        # Use a semi-transparent fill so inner rooms capture mouse events
        # (otherwise clicks fall through to the parent container rect below)
        # Inherit parent building color when inner room type has no specific mapping
        inner_color = if BUILDING_COLOR_MAP.key?(inner.room_type.to_s)
                        building_color(inner.room_type)
                      else
                        parent = container_lookup[inner.inside_room_id]
                        parent ? building_color(parent.room_type) : building_color(inner.room_type)
                      end
        svg.rect(sx, sy, sw, sh,
                 fill: inner_color,
                 opacity: 0.85,
                 stroke: '#8b949e',
                 stroke_width: 1,
                 'data-room-id' => inner.id.to_s,
                 'data-room-name' => escape_attr(inner.name),
                 'data-room-type' => inner.room_type.to_s)
      end

      # At high detail, draw furniture in the current room
      return unless detail_level == :high

      places = Place.where(room_id: current_room.id, invisible: false).all
      places.each do |place|
        next unless place.x && place.y

        # Place coordinates are stored in room/world coordinate space.
        world_x = place.x
        world_y = place.y
        px, py = world_to_svg(world_x, world_y, viewport, width, height)

        svg.circle(px, py, 3,
                   fill: '#4a5568',
                   stroke: '#718096',
                   stroke_width: 0.5)
      end
    end

    # =========================================
    # Drawing: Characters
    # =========================================

    def draw_character(svg, char_instance, viewport, width, height, is_self:)
      char_room = char_instance.current_room
      return unless char_room

      # Character x/y is in location-absolute coordinates.
      # Fall back to room center if position is unset (0,0 outside room bounds).
      world_x, world_y = resolve_world_position(char_instance, char_room)
      cx, cy = world_to_svg(world_x, world_y, viewport, width, height)

      if is_self
        svg.circle(cx, cy, 5,
                   fill: COLORS[:character_self],
                   stroke: '#ffffff',
                   stroke_width: 1,
                   filter: 'url(#glow-red)',
                   'data-char-id' => char_instance.id.to_s)
      else
        dot_color = char_instance.character&.distinctive_color || COLORS[:character_other]
        svg.circle(cx, cy, 3,
                   fill: dot_color,
                   stroke: 'none',
                   'data-char-id' => char_instance.id.to_s)
      end
    end

    # =========================================
    # Drawing: Current Room Highlight
    # =========================================

    def draw_current_room_highlight(svg, room, viewport, width, height)
      sx, sy = world_to_svg(room.min_x, room.max_y, viewport, width, height)
      sw, sh = world_to_svg_size(room.max_x - room.min_x, room.max_y - room.min_y, viewport, width, height)

      svg.rect(sx, sy, sw, sh,
               fill: 'none',
               stroke: COLORS[:current_room],
               stroke_width: 2,
               rx: 2,
               ry: 2,
               filter: 'url(#glow-gold)')
    end

    # =========================================
    # Helpers
    # =========================================

    def escape_attr(str)
      str.to_s.gsub('&', '&amp;').gsub('"', '&quot;').gsub('<', '&lt;').gsub('>', '&gt;')
    end
  end
end
