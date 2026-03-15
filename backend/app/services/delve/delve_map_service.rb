# frozen_string_literal: true

# Renders delve maps as canvas commands for the web client.
# Supports minimap (partial visibility) and full map (all explored).
class DelveMapService
  CELL_SIZE = 20
  PADDING = 10

  COLORS = {
    corridor: '#666666',
    corner: '#777777',
    branch: '#888888',
    terminal: '#999999',
    player: '#00AAFF',
    fog: '#222222',
    unexplored: '#111111',
    danger_hint: '#AA4444',
    exit_marker: '#44FF44',
    connection: '#444444'
  }.freeze

  class << self
    # Render minimap showing nearby rooms and explored areas
    # @param participant [DelveParticipant]
    # @return [String] canvas format (width|||height|||commands)
    def render_minimap(participant)
      return empty_map unless participant.current_room

      delve = participant.delve
      level = participant.current_level
      rooms = delve.rooms_on_level(level).all

      return empty_map if rooms.empty?

      # Calculate bounds
      min_x = rooms.map(&:grid_x).min
      max_x = rooms.map(&:grid_x).max
      min_y = rooms.map(&:grid_y).min
      max_y = rooms.map(&:grid_y).max

      width = (max_x - min_x + 3) * CELL_SIZE + PADDING * 2
      height = (max_y - min_y + 3) * CELL_SIZE + PADDING * 2 + 20  # Extra for status

      # Get visibility data
      visible_data = DelveVisibilityService.visible_rooms(participant)
      visible_lookup = visible_data.each_with_object({}) do |v, h|
        h["#{v[:grid_x]},#{v[:grid_y]}"] = v
      end

      commands = []

      # Background
      commands << "frect::#{COLORS[:fog]},0,0,#{width},#{height}"

      # Draw connections first (behind rooms)
      rooms.each do |room|
        key = "#{room.grid_x},#{room.grid_y}"
        vis = visible_lookup[key]
        next unless vis && (vis[:visibility] != :hidden || room.explored?)

        rx = (room.grid_x - min_x + 1) * CELL_SIZE + PADDING
        ry = (room.grid_y - min_y + 1) * CELL_SIZE + PADDING

        room.available_exits.each do |exit_dir|
          conn = draw_connection(rx, ry, exit_dir, CELL_SIZE)
          commands << conn if conn
        end
      end

      # Draw rooms
      rooms.each do |room|
        key = "#{room.grid_x},#{room.grid_y}"
        vis = visible_lookup[key]

        next unless vis && (vis[:visibility] != :hidden || room.explored?)

        rx = (room.grid_x - min_x + 1) * CELL_SIZE + PADDING
        ry = (room.grid_y - min_y + 1) * CELL_SIZE + PADDING

        color = room_color(room, vis)
        commands << "frect::#{color},#{rx + 2},#{ry + 2},#{rx + CELL_SIZE - 4},#{ry + CELL_SIZE - 4}"

        # Get room content indicator
        indicator = room_indicator(room, vis, delve)
        if indicator
          commands << "text::#{rx + 5},#{ry + CELL_SIZE - 6}||Georgia||#{indicator}"
        end
      end

      # Draw player position
      if participant.current_room
        px = (participant.current_room.grid_x - min_x + 1) * CELL_SIZE + CELL_SIZE / 2 + PADDING
        py = (participant.current_room.grid_y - min_y + 1) * CELL_SIZE + CELL_SIZE / 2 + PADDING
        commands << "fcircle::#{COLORS[:player]},#{px},#{py},#{CELL_SIZE / 4}"
      end

      # Status bar at bottom
      status_y = height - 15
      remaining = participant.time_remaining_seconds || 0
      time_str = format('%d:%02d', remaining / 60, remaining % 60)
      commands << "text::#{PADDING},#{status_y}||Georgia||Level #{level} | Time: #{time_str} | Loot: #{participant.loot_collected || 0}g"

      "#{width}|||#{height}|||#{commands.join(';;;')}"
    end

    # Render full map showing all explored rooms plus visible monsters
    # @param participant [DelveParticipant]
    # @return [String] canvas format
    def render_full_map(participant)
      return empty_map unless participant.current_room

      delve = participant.delve
      level = participant.current_level
      rooms = delve.rooms_on_level(level).where(explored: true).all

      return empty_map if rooms.empty?

      # Get visibility data for monster display
      visible_data = DelveVisibilityService.visible_rooms(participant)
      visible_lookup = visible_data.each_with_object({}) do |v, h|
        h["#{v[:grid_x]},#{v[:grid_y]}"] = v
      end

      # Calculate bounds
      min_x = rooms.map(&:grid_x).min
      max_x = rooms.map(&:grid_x).max
      min_y = rooms.map(&:grid_y).min
      max_y = rooms.map(&:grid_y).max

      width = (max_x - min_x + 3) * CELL_SIZE + PADDING * 2
      height = (max_y - min_y + 3) * CELL_SIZE + PADDING * 2 + 40  # Extra for legend

      commands = []
      commands << "frect::#{COLORS[:fog]},0,0,#{width},#{height}"

      # Draw connections
      rooms.each do |room|
        rx = (room.grid_x - min_x + 1) * CELL_SIZE + PADDING
        ry = (room.grid_y - min_y + 1) * CELL_SIZE + PADDING

        room.available_exits.each do |exit_dir|
          conn = draw_connection(rx, ry, exit_dir, CELL_SIZE)
          commands << conn if conn
        end
      end

      # Draw rooms
      rooms.each do |room|
        rx = (room.grid_x - min_x + 1) * CELL_SIZE + PADDING
        ry = (room.grid_y - min_y + 1) * CELL_SIZE + PADDING

        key = "#{room.grid_x},#{room.grid_y}"
        vis = visible_lookup[key]

        color = COLORS[room.room_type.to_sym] || COLORS[:corridor]
        commands << "frect::#{color},#{rx + 2},#{ry + 2},#{rx + CELL_SIZE - 4},#{ry + CELL_SIZE - 4}"

        # Get room content indicator (showing monsters in visibility range)
        indicator = room_indicator_for_full_map(room, vis, delve)
        if indicator
          commands << "text::#{rx + 5},#{ry + CELL_SIZE - 6}||Georgia||#{indicator}"
        end
      end

      # Player position
      if participant.current_room&.explored?
        px = (participant.current_room.grid_x - min_x + 1) * CELL_SIZE + CELL_SIZE / 2 + PADDING
        py = (participant.current_room.grid_y - min_y + 1) * CELL_SIZE + CELL_SIZE / 2 + PADDING
        commands << "fcircle::#{COLORS[:player]},#{px},#{py},#{CELL_SIZE / 4}"
      end

      # Legend at bottom
      legend_y = height - 30
      commands << "text::#{PADDING},#{legend_y}||Georgia||Legend: @ You  M Monster  $ Treasure  T Trap  v Stairs  ^ Entrance"

      "#{width}|||#{height}|||#{commands.join(';;;')}"
    end

    # Render ASCII map for text clients
    # @param participant [DelveParticipant]
    # @return [String] ASCII representation
    def render_ascii(participant)
      return "No map available." unless participant.current_room

      delve = participant.delve
      level = participant.current_level
      rooms = delve.rooms_on_level(level).all

      return "No rooms on this level." if rooms.empty?

      # Get visibility
      visible_data = DelveVisibilityService.visible_rooms(participant)
      visible_lookup = visible_data.each_with_object({}) do |v, h|
        h["#{v[:grid_x]},#{v[:grid_y]}"] = v
      end

      # Calculate bounds
      min_x = rooms.map(&:grid_x).min
      max_x = rooms.map(&:grid_x).max
      min_y = rooms.map(&:grid_y).min
      max_y = rooms.map(&:grid_y).max

      lines = []

      (min_y..max_y).each do |y|
        line = +""
        (min_x..max_x).each do |x|
          room = delve.room_at(level, x, y)
          key = "#{x},#{y}"
          vis = visible_lookup[key]

          if room.nil?
            line << "  "
          elsif participant.current_room.grid_x == x && participant.current_room.grid_y == y
            line << "@ "
          elsif vis && vis[:visibility] == :hidden && !room.explored?
            line << ". "
          else
            char = room_char(room, vis, delve)
            line << "#{char} "
          end
        end
        lines << line.rstrip
      end

      # Add legend
      lines << ""
      lines << "Legend: @ You  M Monster  $ Treasure  T Trap  > Exit  ^ Start"

      lines.join("\n")
    end

    private

    def empty_map
      "100|||50|||text::10,25||Georgia||No map data"
    end

    # Get the indicator character for a room on the minimap
    # Priority: Monster > Treasure > Trap > Exit > Entrance > Danger
    def room_indicator(room, visibility, delve)
      # Full visibility - show all contents
      if visibility[:show_contents]
        # Check for monsters
        monsters = delve.monsters_in_room(room)
        return 'M' if monsters.any?

        # Check for treasure
        treasure = DelveTreasure.first(delve_room_id: room.id, looted: false)
        return '$' if treasure

        # Check for traps
        traps = DelveTrap.where(delve_room_id: room.id, disabled: false).any?
        return 'T' if traps

        # Check for blockers
        blockers = DelveBlocker.where(delve_room_id: room.id, cleared: false).any?
        return 'X' if blockers

        # Exit/entrance
        return 'v' if room.is_exit
        return '^' if room.is_entrance

        return nil
      end

      # Danger visibility - show monster warnings
      if visibility[:show_danger]
        monsters = delve.monsters_in_room(room)
        return 'M' if monsters.any?

        # Show danger hint for rooms with unknown threats
        return '!' if room.dangerous? && !room.cleared?

        return 'v' if room.is_exit
        return nil
      end

      # Explored but out of range - show static markers
      if room.explored?
        return 'v' if room.is_exit
        return '^' if room.is_entrance
      end

      nil
    end

    # Get the indicator for full map (shows monsters in visibility range)
    def room_indicator_for_full_map(room, visibility, delve)
      # Show monsters if within visibility range
      if visibility && visibility[:show_danger]
        monsters = delve.monsters_in_room(room)
        return 'M' if monsters.any?
      end

      # Check for treasure (only if explored and in this room or nearby)
      if visibility && visibility[:show_contents]
        treasure = DelveTreasure.first(delve_room_id: room.id, looted: false)
        return '$' if treasure
      end

      # Check for active traps (only if visible)
      if visibility && visibility[:show_contents]
        traps = DelveTrap.where(delve_room_id: room.id, disabled: false).any?
        return 'T' if traps
      end

      # Static markers
      return 'v' if room.is_exit
      return '^' if room.is_entrance

      nil
    end

    def room_color(room, visibility)
      return COLORS[:unexplored] if visibility[:visibility] == :hidden && !room.explored?
      return COLORS[:fog] if visibility[:visibility] == :explored && !visibility[:show_contents]

      if visibility[:show_danger] && room.dangerous? && !room.cleared?
        return COLORS[:danger_hint]
      end

      COLORS[room.room_type.to_sym] || COLORS[:corridor]
    end

    def room_char(room, visibility, delve = nil)
      return '?' unless visibility

      if visibility[:show_contents]
        # Check for dynamic content first (monsters, treasure, traps)
        if delve
          monsters = delve.monsters_in_room(room)
          return 'M' if monsters.any?
        end

        treasure = begin
          DelveTreasure.first(delve_room_id: room.id, looted: false)
        rescue StandardError => e
          warn "[DelveMapService] Failed to query treasure: #{e.message}"
          nil
        end
        return '$' if treasure

        traps = begin
          DelveTrap.where(delve_room_id: room.id, disabled: false).any?
        rescue StandardError => e
          warn "[DelveMapService] Failed to query traps: #{e.message}"
          false
        end
        return 'T' if traps

        # Fall back to special flags, then shape
        return '>' if room.is_exit
        return '^' if room.is_entrance
        case room.room_type
        when 'branch' then 'O'
        else '#'
        end
      elsif visibility[:show_danger]
        # Show monsters in danger range
        if delve
          monsters = delve.monsters_in_room(room)
          return 'M' if monsters.any?
        end

        return '!' if room.dangerous? && !room.cleared?
        return '>' if room.is_exit
        '#'
      else
        # Explored but out of range
        return '>' if room.is_exit
        return '^' if room.is_entrance
        '#'
      end
    end

    def draw_connection(rx, ry, direction, cell_size)
      half = cell_size / 2
      color = COLORS[:connection]

      case direction
      when 'north'
        "line::#{color},#{rx + half},#{ry + 2},#{rx + half},#{ry - 2}"
      when 'south'
        "line::#{color},#{rx + half},#{ry + cell_size - 2},#{rx + half},#{ry + cell_size + 2}"
      when 'east'
        "line::#{color},#{rx + cell_size - 2},#{ry + half},#{rx + cell_size + 2},#{ry + half}"
      when 'west'
        "line::#{color},#{rx + 2},#{ry + half},#{rx - 2},#{ry + half}"
      else
        nil
      end
    end
  end
end
