# frozen_string_literal: true

require_relative '../../helpers/canvas_helper'

# Renders a simplified interior view of a room showing characters, places, and exits.
# Uses Ravencroft-style canvas command format: width|||height|||commands
#
# @example
#   service = RoommapRenderService.new(room: room, viewer: character_instance)
#   canvas_string = service.render
#
class RoommapRenderService
  # Canvas constraints (from centralized config)
  MAX_CANVAS_SIZE = GameConfig::Rendering::ROOMMAP[:max_canvas_size]
  MIN_CANVAS_SIZE = GameConfig::Rendering::ROOMMAP[:min_canvas_size]
  PADDING = GameConfig::Rendering::ROOMMAP[:padding]

  # Element sizes (from centralized config)
  CHAR_RADIUS = GameConfig::Rendering::ROOMMAP[:char_radius]
  SELF_RADIUS = GameConfig::Rendering::ROOMMAP[:self_radius]
  PLACE_MIN_SIZE = GameConfig::Rendering::ROOMMAP[:place_min_size]
  EXIT_SIZE = GameConfig::Rendering::ROOMMAP[:exit_size]
  LEGEND_HEIGHT = GameConfig::Rendering::ROOMMAP[:legend_height]
  ROOM_NAME_HEIGHT = GameConfig::Rendering::ROOMMAP[:room_name_height]

  # Colors
  COLORS = {
    background: '#1a1a1a',
    wall: '#444444',
    floor: '#2a2a2a',
    place: '#663300',
    place_text: '#ccaa77',
    exit: '#336633',
    exit_text: '#88cc88',
    door: '#996633',
    character: '#22cc22',
    npc: '#888888',
    self_color: '#ff4444',
    self_glow: '#ff444466',
    self_text: '#ffffff',
    label: '#aaaaaa',
    legend_bg: '#111111',
    legend_divider: '#333333',
    legend_text: '#999999'
  }.freeze

  # Cardinal directions that get wall-gap treatment (includes abbreviations for defensive matching)
  # NOTE: Related to CanvasHelper::VALID_DIRECTIONS but intentionally includes abbreviations
  CARDINAL_DIRECTIONS = %w[north south east west n s e w].freeze

  # Feature types that render as doors (gap + small rectangle)
  OPENABLE_TYPES = %w[door gate hatch portal].freeze

  attr_reader :room, :viewer, :canvas_width, :canvas_height, :scale_x, :scale_y

  def initialize(room:, viewer:)
    @room = room
    @viewer = viewer
    calculate_dimensions
  end

  # Generate canvas command string
  # @return [String] canvas commands in format width|||height|||commands
  def render
    # Eager-load room features once to avoid N+1 queries
    @features_cache = if room.respond_to?(:room_features)
                        room.room_features
                      else
                        []
                      end

    commands = []

    # 1. Background
    commands << "frect::#{COLORS[:background]},0,0,#{canvas_width},#{canvas_height}"

    # 2. Floor area
    commands << render_floor

    # 3. Room boundaries (walls with gaps for exits)
    commands.concat(render_boundaries)

    # 4. Places/furniture
    commands.concat(render_places)

    # 5. Exits (arrows only for cardinal; full rendering for diagonal/vertical)
    commands.concat(render_exits)

    # 6. Other characters (with fan offsets for overlap)
    commands.concat(render_characters)

    # 7. Self marker (on top, with fan offset if overlapping)
    commands.concat(render_self)

    # 8. Room name
    commands << render_room_name

    # 9. Legend at bottom
    commands.concat(render_legend)

    "#{canvas_width}|||#{canvas_height}|||#{commands.compact.join(';;;')}"
  end

  private

  # Bottom of the map area (above room name and legend)
  def map_bottom
    canvas_height - PADDING - LEGEND_HEIGHT - ROOM_NAME_HEIGHT
  end

  def calculate_dimensions
    room_width = (room.max_x || 100) - (room.min_x || 0)
    room_height = (room.max_y || 100) - (room.min_y || 0)

    # Ensure non-zero dimensions
    room_width = 100 if room_width <= 0
    room_height = 100 if room_height <= 0

    # Calculate aspect ratio and fit within constraints
    aspect_ratio = room_width.to_f / room_height

    if room_width > room_height
      @canvas_width = [MAX_CANVAS_SIZE, [MIN_CANVAS_SIZE, room_width.to_i * 3].max].min
      @canvas_height = [(@canvas_width / aspect_ratio).to_i, MIN_CANVAS_SIZE].max
    else
      @canvas_height = [MAX_CANVAS_SIZE, [MIN_CANVAS_SIZE, room_height.to_i * 3].max].min
      @canvas_width = [(@canvas_height * aspect_ratio).to_i, MIN_CANVAS_SIZE].max
    end

    # Add space for legend and room name below the map
    @canvas_height += LEGEND_HEIGHT + ROOM_NAME_HEIGHT

    # Account for padding in scale
    usable_width = @canvas_width - (2 * PADDING)
    usable_height = map_bottom - PADDING

    @scale_x = usable_width.to_f / room_width
    @scale_y = usable_height.to_f / room_height
  end

  # Transform room coordinates to canvas coordinates
  # Y is inverted (canvas y=0 at top, room y=0 at bottom)
  def room_to_canvas(x, y)
    room_x = x || ((room.min_x || 0) + (room.max_x || 100)) / 2.0
    room_y = y || ((room.min_y || 0) + (room.max_y || 100)) / 2.0

    cx = PADDING + ((room_x - (room.min_x || 0)) * scale_x).to_i
    cy = PADDING + (((room.max_y || 100) - room_y) * scale_y).to_i

    [cx.clamp(PADDING, canvas_width - PADDING), cy.clamp(PADDING, map_bottom)]
  end

  def render_floor
    x1 = PADDING
    y1 = PADDING
    x2 = canvas_width - PADDING
    y2 = map_bottom

    "frect::#{COLORS[:floor]},#{x1},#{y1},#{x2},#{y2}"
  end

  # Draw wall boundaries with gaps where cardinal exits exist.
  # Outdoor gaps are ~half the wall width; indoor gaps are ~1/4 wall width.
  def render_boundaries
    x1 = PADDING
    y1 = PADDING
    x2 = canvas_width - PADDING
    y2 = map_bottom

    wall_w = x2 - x1
    wall_h = y2 - y1
    cx = (x1 + x2) / 2
    cy = (y1 + y2) / 2

    # Collect cardinal exit directions
    exit_dirs = cardinal_exit_directions

    commands = []

    # Top wall (north)
    if exit_dirs.include?('north')
      exit_type = classify_exit_type('north')
      half_gap = gap_half_size(exit_type, wall_w)
      commands << "line::#{COLORS[:wall]},#{x1},#{y1},#{cx - half_gap},#{y1}"
      commands << "line::#{COLORS[:wall]},#{cx + half_gap},#{y1},#{x2},#{y1}"
      if exit_type == :door
        commands << "frect::#{COLORS[:door]},#{cx - half_gap},#{y1 - 3},#{cx + half_gap},#{y1 + 3}"
      end
    else
      commands << "line::#{COLORS[:wall]},#{x1},#{y1},#{x2},#{y1}"
    end

    # Right wall (east)
    if exit_dirs.include?('east')
      exit_type = classify_exit_type('east')
      half_gap = gap_half_size(exit_type, wall_h)
      commands << "line::#{COLORS[:wall]},#{x2},#{y1},#{x2},#{cy - half_gap}"
      commands << "line::#{COLORS[:wall]},#{x2},#{cy + half_gap},#{x2},#{y2}"
      if exit_type == :door
        commands << "frect::#{COLORS[:door]},#{x2 - 3},#{cy - half_gap},#{x2 + 3},#{cy + half_gap}"
      end
    else
      commands << "line::#{COLORS[:wall]},#{x2},#{y1},#{x2},#{y2}"
    end

    # Bottom wall (south)
    if exit_dirs.include?('south')
      exit_type = classify_exit_type('south')
      half_gap = gap_half_size(exit_type, wall_w)
      commands << "line::#{COLORS[:wall]},#{x2},#{y2},#{cx + half_gap},#{y2}"
      commands << "line::#{COLORS[:wall]},#{cx - half_gap},#{y2},#{x1},#{y2}"
      if exit_type == :door
        commands << "frect::#{COLORS[:door]},#{cx - half_gap},#{y2 - 3},#{cx + half_gap},#{y2 + 3}"
      end
    else
      commands << "line::#{COLORS[:wall]},#{x2},#{y2},#{x1},#{y2}"
    end

    # Left wall (west)
    if exit_dirs.include?('west')
      exit_type = classify_exit_type('west')
      half_gap = gap_half_size(exit_type, wall_h)
      commands << "line::#{COLORS[:wall]},#{x1},#{y2},#{x1},#{cy + half_gap}"
      commands << "line::#{COLORS[:wall]},#{x1},#{cy - half_gap},#{x1},#{y1}"
      if exit_type == :door
        commands << "frect::#{COLORS[:door]},#{x1 - 3},#{cy - half_gap},#{x1 + 3},#{cy + half_gap}"
      end
    else
      commands << "line::#{COLORS[:wall]},#{x1},#{y2},#{x1},#{y1}"
    end

    commands
  end

  # Calculate half-gap size proportional to wall length.
  # Outdoor gaps are ~half the wall; door/open gaps are ~1/4 the wall.
  def gap_half_size(exit_type, wall_length)
    case exit_type
    when :outdoor_gap
      (wall_length * 0.25).to_i.clamp(30, 120)
    else
      (wall_length * 0.12).to_i.clamp(20, 60)
    end
  end

  def render_places
    commands = []

    places = room.respond_to?(:visible_places) ? room.visible_places.all : []
    places.each do |place|
      px, py = room_to_canvas(place.x, place.y)

      # Size based on capacity
      capacity = place.respond_to?(:capacity) ? (place.capacity || 2) : 2
      size = [PLACE_MIN_SIZE + (capacity * 3), 60].min
      half = size / 2

      # Rectangle for place
      commands << "frect::#{COLORS[:place]},#{px - half},#{py - half},#{px + half},#{py + half}"

      # Name label
      name = CanvasHelper.truncate_name(place.name || place.display_name || 'Place', 12)
      commands << "textrect::#{px - half},#{py - half},#{px + half},#{py + half}||sans-serif||#{CanvasHelper.sanitize_text(name)}"
    end

    commands
  end

  # Render exit indicators — cardinal exits rely solely on wall gaps (from render_boundaries).
  # Only diagonal/vertical/other exits get a small arrow indicator.
  def render_exits
    commands = []

    exits = all_navigable_exits

    exits.each do |exit_data|
      direction = exit_data[:direction].to_s

      # Skip cardinal exits — wall gaps handle them
      next if CARDINAL_DIRECTIONS.include?(direction.downcase)

      # Diagonal/vertical/other: small arrow indicator only
      ex, ey = exit_position_from_direction(direction)
      arrow = CanvasHelper::DIRECTION_ARROWS[direction.downcase] || direction[0].upcase
      commands << "coltext::#{COLORS[:exit_text]},#{ex},#{ey},20||sans-serif||#{arrow}"
    end

    commands
  end

  def exit_position_from_direction(direction)
    x1 = PADDING
    y1 = PADDING
    x2 = canvas_width - PADDING
    y2 = map_bottom

    cx = (x1 + x2) / 2
    cy = (y1 + y2) / 2

    case direction.to_s.downcase
    when 'north', 'n'
      [cx, y1 + EXIT_SIZE]
    when 'south', 's'
      [cx, y2 - EXIT_SIZE]
    when 'east', 'e'
      [x2 - EXIT_SIZE, cy]
    when 'west', 'w'
      [x1 + EXIT_SIZE, cy]
    when 'northeast', 'ne'
      [x2 - EXIT_SIZE * 2, y1 + EXIT_SIZE * 2]
    when 'northwest', 'nw'
      [x1 + EXIT_SIZE * 2, y1 + EXIT_SIZE * 2]
    when 'southeast', 'se'
      [x2 - EXIT_SIZE * 2, y2 - EXIT_SIZE * 2]
    when 'southwest', 'sw'
      [x1 + EXIT_SIZE * 2, y2 - EXIT_SIZE * 2]
    when 'up', 'u'
      [cx - 30, y1 + EXIT_SIZE * 2]
    when 'down', 'd'
      [cx + 30, y2 - EXIT_SIZE * 2]
    else
      [cx, cy]
    end
  end

  def render_characters
    commands = []

    # Get all characters in room except viewer
    @other_characters = if room.respond_to?(:character_instances_dataset)
                          room.character_instances_dataset
                              .where(online: true)
                              .exclude(id: viewer.id)
                              .eager(:character)
                              .all
                        else
                          []
                        end

    # Group by canvas position for fan offsets
    grouped = @other_characters.group_by { |ci| room_to_canvas(ci.x, ci.y) }

    grouped.each do |(_cx, _cy), chars_at_pos|
      offsets = calculate_fan_offsets(chars_at_pos.length)

      chars_at_pos.each_with_index do |ci, idx|
        base_cx, base_cy = room_to_canvas(ci.x, ci.y)
        ox, oy = offsets[idx]
        cx = base_cx + ox
        cy = base_cy + oy

        # Color based on NPC vs player
        is_npc = ci.character&.is_npc || false
        color = is_npc ? COLORS[:npc] : COLORS[:character]

        # Circle for character
        commands << "fcircle::#{color},#{cx},#{cy},#{CHAR_RADIUS}"

        # Truncated name above circle (personalized for viewer)
        char_label = ci.character&.display_name_for(viewer) || '?'
        display_name = CanvasHelper.truncate_name(char_label, 8)
        commands << "coltext::#{COLORS[:label]},#{cx},#{cy - CHAR_RADIUS - 10},14||sans-serif||#{CanvasHelper.sanitize_text(display_name)}"
      end
    end

    commands
  end

  def render_self
    base_cx, base_cy = room_to_canvas(viewer.x, viewer.y)
    cx, cy = base_cx, base_cy

    # Check if viewer overlaps with other characters and apply fan offset
    if defined?(@other_characters) && @other_characters
      overlapping = @other_characters.select { |ci| room_to_canvas(ci.x, ci.y) == [base_cx, base_cy] }
      unless overlapping.empty?
        # Viewer is one more in the group
        total = overlapping.length + 1
        offsets = calculate_fan_offsets(total)
        # Viewer gets the last offset
        ox, oy = offsets.last
        cx = base_cx + ox
        cy = base_cy + oy
      end
    end

    # Get viewer name
    forename = viewer.character&.forename || viewer.character&.full_name || 'You'
    display_name = CanvasHelper.truncate_name(forename, 8)

    [
      # Glow ring behind self
      "fcircle::#{COLORS[:self_glow]},#{cx},#{cy},#{SELF_RADIUS + 4}",
      # Self circle
      "fcircle::#{COLORS[:self_color]},#{cx},#{cy},#{SELF_RADIUS}",
      # Name above instead of X marker
      "coltext::#{COLORS[:self_text]},#{cx},#{cy - SELF_RADIUS - 10},14||sans-serif||#{CanvasHelper.sanitize_text(display_name)}"
    ]
  end

  def render_room_name
    name_top = map_bottom + 4
    name_bottom = map_bottom + ROOM_NAME_HEIGHT
    "textrect::#{PADDING},#{name_top},#{canvas_width - PADDING},#{name_bottom}||sans-serif||#{CanvasHelper.sanitize_text(room.name || 'Room')}"
  end

  def render_legend
    commands = []

    legend_top = map_bottom + ROOM_NAME_HEIGHT
    legend_bottom = canvas_height

    # Dark background strip
    commands << "frect::#{COLORS[:legend_bg]},0,#{legend_top},#{canvas_width},#{legend_bottom}"

    # Divider line
    commands << "line::#{COLORS[:legend_divider]},#{PADDING},#{legend_top + 2},#{canvas_width - PADDING},#{legend_top + 2}"

    # Legend items in a row
    row_y = legend_top + 28
    col_width = (canvas_width - 2 * PADDING) / 4
    start_x = PADDING + col_width / 2

    # You (red circle)
    commands << "fcircle::#{COLORS[:self_color]},#{start_x - 14},#{row_y},5"
    commands << "coltext::#{COLORS[:legend_text]},#{start_x + 6},#{row_y},12||sans-serif||You"

    # Player (green circle)
    col2_x = start_x + col_width
    commands << "fcircle::#{COLORS[:character]},#{col2_x - 14},#{row_y},5"
    commands << "coltext::#{COLORS[:legend_text]},#{col2_x + 12},#{row_y},12||sans-serif||Player"

    # NPC (grey circle)
    col3_x = start_x + col_width * 2
    commands << "fcircle::#{COLORS[:npc]},#{col3_x - 14},#{row_y},5"
    commands << "coltext::#{COLORS[:legend_text]},#{col3_x + 6},#{row_y},12||sans-serif||NPC"

    # Furniture (brown rect)
    col4_x = start_x + col_width * 3
    commands << "frect::#{COLORS[:place]},#{col4_x - 20},#{row_y - 6},#{col4_x - 8},#{row_y + 6}"
    commands << "coltext::#{COLORS[:legend_text]},#{col4_x + 16},#{row_y},12||sans-serif||Furniture"

    commands
  end

  # Calculate fan offsets for co-located characters
  # @param count [Integer] number of characters at the same position
  # @return [Array<Array<Integer>>] list of [dx, dy] offsets
  def calculate_fan_offsets(count)
    return [[0, 0]] if count <= 1

    fan_radius = CHAR_RADIUS * 2
    (0...count).map do |i|
      angle = (2 * Math::PI * i) / count
      [(fan_radius * Math.cos(angle)).to_i, (fan_radius * Math.sin(angle)).to_i]
    end
  end

  # Classify exit type for wall gap rendering
  # @param direction [String] cardinal direction
  # @return [Symbol] :outdoor_gap, :door, or :open_gap
  def classify_exit_type(direction)
    # Check if both rooms are outdoor
    exits = all_navigable_exits
    exit_data = exits.find { |e| CanvasHelper.normalize_direction(e[:direction].to_s) == CanvasHelper.normalize_direction(direction) }
    dest_room = exit_data[:room] if exit_data

    if dest_room && !room_indoors?(room) && !room_indoors?(dest_room)
      return :outdoor_gap
    end

    # Check room features for this direction
    dir_str = CanvasHelper.normalize_direction(direction)
    features = @features_cache.select do |f|
      f.respond_to?(:direction) && CanvasHelper.normalize_direction(f.direction.to_s) == dir_str &&
        f.feature_type != 'wall' && f.feature_type != 'window'
    end

    if features.any? { |f| OPENABLE_TYPES.include?(f.feature_type) }
      :door
    else
      :open_gap
    end
  end

  # Get set of normalized cardinal directions that have exits
  def cardinal_exit_directions
    exits = all_navigable_exits
    exits.map { |e| CanvasHelper.normalize_direction(e[:direction].to_s) }
         .select { |d| %w[north south east west].include?(d) }
         .to_set
  end

  # Build flat list of navigable exits from spatial_exits (direction => rooms hash).
  # Uses spatial_exits directly (like room_display_service) to avoid the sibling
  # filter in passable_spatial_exits which strips exits for building rooms in cities.
  def all_navigable_exits
    @all_navigable_exits ||= begin
      exits = []
      room.spatial_exits.each do |direction, rooms|
        rooms.each do |r|
          next unless r.navigable?
          exits << { direction: direction, room: r }
        end
      end
      exits
    end
  end

  def room_indoors?(r)
    return true unless r.respond_to?(:indoors?)

    r.indoors?
  end

end
