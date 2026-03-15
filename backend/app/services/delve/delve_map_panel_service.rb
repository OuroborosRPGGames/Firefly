# frozen_string_literal: true

require_relative '../../helpers/canvas_helper'

# Renders delve maps as SVG for the web client.
# Shows the dungeon grid with fog-of-war based on line-of-sight.
#
# Visibility rules:
#   Current room    — bright, full detail
#   In LOS (≤2)     — visible, monsters + exits only
#   Explored + !LOS — faded memory, all details (traps, puzzles, blockers, treasure)
#   !Explored + !LOS — invisible (not rendered)
class DelveMapPanelService
  CELL_SIZE = 40       # pixels per room cell
  CELL_GAP = 4         # gap between cells
  CELL_INNER = CELL_SIZE - CELL_GAP  # 36
  PADDING = 20         # SVG padding
  LOS_DEPTH = 2        # line-of-sight BFS depth (2 rooms in any direction)

  COLORS = {
    background: '#0d1117',
    current: '#c8a84b',
    current_border: '#d4b85c',
    visible: '#2d3f52',
    visible_border: '#3d5470',
    memory: '#161e28',
    memory_border: '#1f2d3d',
    connection_open: '#4a6a8a',
    connection_highlight: '#6a8aaa',
    connection_memory: '#1e2a38',
    connection_blocked: '#8b3333',
    monster: '#c04040',
    treasure: '#c8a84b',
    trap: '#c07030',
    blocker: '#607080',
    puzzle: '#6a5acd',
    stairs: '#4a7ab5',
    entrance: '#3a8a5a'
  }.freeze

  DIRECTION_OFFSETS = {
    'north' => [0, -1],
    'south' => [0, 1],
    'east'  => [1, 0],
    'west'  => [-1, 0]
  }.freeze

  # Delegate to CanvasHelper for opposite directions (canonical source)
  REVERSE_DIRECTION = CanvasHelper::OPPOSITE_DIRECTIONS

  class << self
    # Render the delve map as SVG.
    # @param participant [DelveParticipant]
    # @return [Hash] { svg: String|nil, metadata: Hash }
    def render(participant:)
      current_room = participant.current_room
      unless current_room
        return { svg: nil, metadata: { room_count: 0 } }
      end

      delve = participant.delve
      level = participant.current_level
      all_rooms = delve.rooms_on_level(level).all

      if all_rooms.empty?
        return { svg: nil, metadata: { room_count: 0 } }
      end

      # Compute line-of-sight via BFS (propagates through all connected rooms)
      los_set = compute_line_of_sight(current_room, all_rooms)

      # Only render rooms that are visible: in LOS or previously explored
      visible_rooms = all_rooms.select { |rm| los_set.include?(rm.id) || rm.explored? }

      # Also include neighbor rooms of visible rooms that have hazards (blockers/traps/puzzles)
      # so connection icons render even when the room beyond the hazard is unexplored
      visible_ids = visible_rooms.map(&:id).to_set
      all_rooms_by_coord = {}
      all_rooms.each { |r| all_rooms_by_coord["#{r.grid_x},#{r.grid_y}"] = r }

      hazard_neighbors = []
      visible_rooms.each do |rm|
        rm.available_exits.each do |exit_dir|
          next if exit_dir == 'down'
          offset = DIRECTION_OFFSETS[exit_dir]
          next unless offset

          neighbor = all_rooms_by_coord["#{rm.grid_x + offset[0]},#{rm.grid_y + offset[1]}"]
          next unless neighbor
          next if visible_ids.include?(neighbor.id)

          # Check if there's a hazard on this connection
          has_blocker = DelveBlocker.first(delve_room_id: rm.id, direction: exit_dir, cleared: false)
          reverse_dir = REVERSE_DIRECTION[exit_dir]
          has_blocker ||= reverse_dir && DelveBlocker.first(delve_room_id: neighbor.id, direction: reverse_dir, cleared: false)
          has_trap = DelveTrap.first(delve_room_id: rm.id, direction: exit_dir, disabled: false)
          has_trap ||= reverse_dir && DelveTrap.first(delve_room_id: neighbor.id, direction: reverse_dir, disabled: false)

          if has_blocker || has_trap
            hazard_neighbors << neighbor
            visible_ids << neighbor.id
          end
        end
      end

      visible_rooms = visible_rooms + hazard_neighbors

      if visible_rooms.empty?
        return { svg: nil, metadata: { room_count: 0 } }
      end

      # Calculate grid bounds from visible rooms only
      min_x = visible_rooms.map(&:grid_x).min
      max_x = visible_rooms.map(&:grid_x).max
      min_y = visible_rooms.map(&:grid_y).min
      max_y = visible_rooms.map(&:grid_y).max

      grid_cols = max_x - min_x + 1
      grid_rows = max_y - min_y + 1

      svg_width = grid_cols * CELL_SIZE + PADDING * 2
      svg_height = grid_rows * CELL_SIZE + PADDING * 2

      # Build room lookup by coordinate (only visible rooms)
      room_lookup = {}
      visible_rooms.each { |r| room_lookup["#{r.grid_x},#{r.grid_y}"] = r }

      # Build SVG
      svg_parts = []
      svg_parts << svg_open(svg_width, svg_height)
      svg_parts << svg_background(svg_width, svg_height)

      # Render connections first (behind rooms)
      visible_rooms.each do |rm|
        rx = (rm.grid_x - min_x) * CELL_SIZE + PADDING
        ry = (rm.grid_y - min_y) * CELL_SIZE + PADDING

        rm.available_exits.each do |exit_dir|
          next if exit_dir == 'down'

          offset = DIRECTION_OFFSETS[exit_dir]
          next unless offset

          neighbor_key = "#{rm.grid_x + offset[0]},#{rm.grid_y + offset[1]}"
          neighbor = room_lookup[neighbor_key]
          next unless neighbor

          # Only draw from the "earlier" room to avoid duplicates
          next unless rm.id < neighbor.id

          svg_parts << svg_connection(rx, ry, exit_dir, rm, neighbor, los_set, current_room)
        end
      end

      # Render room cells
      visible_rooms.each do |rm|
        rx = (rm.grid_x - min_x) * CELL_SIZE + PADDING
        ry = (rm.grid_y - min_y) * CELL_SIZE + PADDING
        is_current = (rm.id == current_room.id)
        in_los = los_set.include?(rm.id)

        fill_color = room_fill_color(is_current, in_los)
        opacity = room_opacity(is_current, in_los)
        vis_class = room_visibility_class(rm, is_current, in_los)

        # Fetch monsters for this room (used by both cell data-attrs and content icons)
        room_monsters = (is_current || in_los) ? (delve.monsters_in_room(rm) rescue []) : []

        svg_parts << svg_room_cell(rx, ry, rm, vis_class, fill_color, opacity, room_monsters)

        # Content icons depend on visibility state
        svg_parts << svg_room_content(rx, ry, rm, delve, is_current, in_los)
      end

      svg_parts << '</svg>'
      svg_string = svg_parts.join("\n")

      {
        svg: svg_string,
        metadata: {
          room_count: all_rooms.size,
          current_level: level,
          explored_count: all_rooms.count(&:explored?),
          visible_count: los_set.size
        }
      }
    end

    private

    # BFS from current room through ALL connected rooms up to LOS_DEPTH.
    # You can see 2 rooms in any direction regardless of explored state.
    # @return [Set<Integer>] set of room IDs in line-of-sight
    def compute_line_of_sight(current_room, rooms)
      los = Set.new
      los.add(current_room.id)

      room_by_coord = {}
      rooms.each { |r| room_by_coord["#{r.grid_x},#{r.grid_y}"] = r }

      queue = [[current_room, 0]]
      visited = Set.new([current_room.id])

      while (item = queue.shift)
        rm, depth = item
        next if depth >= LOS_DEPTH

        rm.available_exits.each do |exit_dir|
          next if exit_dir == 'down'

          offset = DIRECTION_OFFSETS[exit_dir]
          next unless offset

          neighbor_key = "#{rm.grid_x + offset[0]},#{rm.grid_y + offset[1]}"
          neighbor = room_by_coord[neighbor_key]
          next unless neighbor
          next if visited.include?(neighbor.id)

          visited.add(neighbor.id)
          los.add(neighbor.id)

          # Continue BFS through all rooms (can see through corridors)
          queue << [neighbor, depth + 1]
        end
      end

      los
    end

    def room_visibility_class(room, is_current, in_los)
      if is_current
        'current-room'
      elsif in_los
        'visible'
      elsif room.explored?
        'memory'
      else
        'hidden' # shouldn't render, but safety fallback
      end
    end

    def room_fill_color(is_current, in_los)
      if is_current
        'url(#grad-current)'
      elsif in_los
        'url(#grad-visible)'
      else
        'url(#grad-memory)'
      end
    end

    def room_opacity(is_current, in_los)
      if is_current
        1.0
      elsif in_los
        1.0
      else
        0.55
      end
    end

    # ====== SVG Builders ======

    def svg_open(width, height)
      %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{width} #{height}" ) +
        %(width="#{width}" height="#{height}" ) +
        %(style="background: #{COLORS[:background]}">) +
        svg_defs
    end

    def svg_defs
      <<~SVG
        <defs>
          <filter id="glow-current" x="-50%" y="-50%" width="200%" height="200%">
            <feGaussianBlur in="SourceGraphic" stdDeviation="3" result="blur"/>
            <feColorMatrix in="blur" type="matrix"
              values="0.8 0 0 0 0.1
                      0.6 0 0 0 0.08
                      0.1 0 0 0 0
                      0 0 0 0.6 0" result="glow"/>
            <feMerge>
              <feMergeNode in="glow"/>
              <feMergeNode in="SourceGraphic"/>
            </feMerge>
          </filter>
          <linearGradient id="grad-current" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stop-color="#3a3020"/>
            <stop offset="100%" stop-color="#2a2418"/>
          </linearGradient>
          <linearGradient id="grad-visible" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stop-color="#2d3f52"/>
            <stop offset="100%" stop-color="#243348"/>
          </linearGradient>
          <linearGradient id="grad-memory" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stop-color="#161e28"/>
            <stop offset="100%" stop-color="#111920"/>
          </linearGradient>
        </defs>
      SVG
    end

    def svg_background(width, height)
      %(<rect x="0" y="0" width="#{width}" height="#{height}" fill="#{COLORS[:background]}"/>)
    end

    def svg_connection(rx, ry, direction, from_room, to_room, los_set, current_room)
      half = CELL_SIZE / 2
      gap_half = CELL_GAP / 2

      from_in_los = los_set.include?(from_room.id)
      to_in_los = los_set.include?(to_room.id)
      either_in_los = from_in_los || to_in_los

      # Base connection color: bright if in LOS, faded if memory only
      color = either_in_los ? COLORS[:connection_open] : COLORS[:connection_memory]

      parts = []

      # Connections are drawn from lower-ID room, so we need to check both rooms
      # for hazards. The reverse direction is the opposite of the draw direction.
      reverse_dir = REVERSE_DIRECTION[direction]

      # Check for hazards on this connection (either room's perspective)
      trap = begin
        DelveTrap.first(delve_room_id: from_room.id, direction: direction, disabled: false) ||
          (reverse_dir && DelveTrap.first(delve_room_id: to_room.id, direction: reverse_dir, disabled: false))
      rescue StandardError => e
        warn "[DelveMapPanelService] trap lookup failed for connection #{from_room.id}->#{direction}: #{e.message}"
        nil
      end

      blocker = begin
        DelveBlocker.first(delve_room_id: from_room.id, direction: direction, cleared: false) ||
          (reverse_dir && DelveBlocker.first(delve_room_id: to_room.id, direction: reverse_dir, cleared: false))
      rescue StandardError => e
        warn "[DelveMapPanelService] blocker lookup failed for connection #{from_room.id}->#{direction}: #{e.message}"
        nil
      end

      puzzle = begin
        p = DelvePuzzle.first(delve_room_id: from_room.id, solved: false)
        p = p && p.blocks_direction?(direction) ? p : nil
        unless p
          p2 = reverse_dir && DelvePuzzle.first(delve_room_id: to_room.id, solved: false)
          p = p2 && p2.blocks_direction?(reverse_dir) ? p2 : nil
        end
        p
      rescue StandardError => e
        warn "[DelveMapPanelService] puzzle lookup failed for connection #{from_room.id}->#{direction}: #{e.message}"
        nil
      end

      has_hazard = trap || blocker || puzzle
      color = has_hazard ? COLORS[:connection_blocked] : color

      x1, y1, x2, y2 = connection_coords(rx, ry, direction, half, gap_half)
      return '' unless x1

      if either_in_los && !has_hazard
        # Dual-line effect: wider muted base + thinner bright highlight
        parts << %(<line x1="#{x1}" y1="#{y1}" x2="#{x2}" y2="#{y2}" ) +
          %(stroke="#{color}" stroke-width="4" stroke-linecap="round" opacity="0.4"/>)
        parts << %(<line x1="#{x1}" y1="#{y1}" x2="#{x2}" y2="#{y2}" ) +
          %(stroke="#{COLORS[:connection_highlight]}" stroke-width="2" stroke-linecap="round" opacity="0.8"/>)
      elsif blocker && either_in_los
        # Dashed line for blockers — visually distinct from open passages
        parts << %(<line x1="#{x1}" y1="#{y1}" x2="#{x2}" y2="#{y2}" ) +
          %(stroke="#{color}" stroke-width="3" stroke-linecap="round" stroke-dasharray="4,3" opacity="0.8"/>)
      else
        conn_opacity = either_in_los ? 0.7 : 0.25
        parts << %(<line x1="#{x1}" y1="#{y1}" x2="#{x2}" y2="#{y2}" ) +
          %(stroke="#{color}" stroke-width="3" stroke-linecap="round" opacity="#{conn_opacity}"/>)
      end

      # Trap/blocker icons on connections:
      # Show if either connected room is in LOS or explored
      show_hazard_icon = from_in_los || to_in_los || from_room.explored? || to_room.explored?
      if show_hazard_icon
        mid_x = (x1 + x2) / 2
        mid_y = (y1 + y2) / 2
        icon_opacity = from_in_los ? 1.0 : 0.5

        if trap
          parts << svg_connection_hazard(mid_x, mid_y, :trap, COLORS[:trap], 'trap-conn-icon', icon_opacity)
        elsif blocker
          blocker_json = { type: blocker.blocker_type, stat: blocker.stat_for_check, dc: blocker.effective_difficulty, direction: direction }.to_json.gsub('"', '&quot;')
          parts << svg_connection_hazard(mid_x, mid_y, :blocker, COLORS[:blocker], 'blocker-conn-icon', icon_opacity, data_attrs: "data-blocker=\"#{blocker_json}\"")
        elsif puzzle
          parts << svg_connection_hazard(mid_x, mid_y, :puzzle, COLORS[:puzzle], 'puzzle-conn-icon', icon_opacity)
        end
      end

      parts.join("\n")
    end

    # Geometric hazard icons on connections
    def svg_connection_hazard(cx, cy, type, color, css_class, opacity = 1.0, data_attrs: '')
      case type
      when :trap
        # Triangle warning shape
        x1, y1 = cx, cy - 6
        x2, y2 = cx - 5, cy + 4
        x3, y3 = cx + 5, cy + 4
        %(<polygon points="#{x1},#{y1} #{x2},#{y2} #{x3},#{y3}" ) +
          %(fill="#{color}" class="#{css_class}" opacity="#{opacity}" ) +
          %(style="pointer-events: auto; cursor: pointer;"/>)
      when :puzzle
        # Circle with ? for puzzle (filled background for easier clicking)
        %(<g class="#{css_class}" opacity="#{opacity}" style="pointer-events: auto; cursor: pointer;">) +
          %(<circle cx="#{cx}" cy="#{cy}" r="8" fill="#{COLORS[:background]}" opacity="0.8"/>) +
          %(<circle cx="#{cx}" cy="#{cy}" r="8" fill="none" stroke="#{color}" stroke-width="1.5"/>) +
          %(<text x="#{cx}" y="#{cy + 4}" text-anchor="middle" fill="#{color}" font-size="10" font-family="sans-serif" font-weight="bold" style="pointer-events:none;">?</text>) +
          %(</g>)
      else
        # X shape for blocker
        s = 5
        %(<g class="#{css_class}" opacity="#{opacity}" #{data_attrs} style="pointer-events: auto; cursor: pointer;">) +
          %(<line x1="#{cx - s}" y1="#{cy - s}" x2="#{cx + s}" y2="#{cy + s}" stroke="#{color}" stroke-width="2" stroke-linecap="round"/>) +
          %(<line x1="#{cx + s}" y1="#{cy - s}" x2="#{cx - s}" y2="#{cy + s}" stroke="#{color}" stroke-width="2" stroke-linecap="round"/>) +
          %(</g>)
      end
    end

    def connection_coords(rx, ry, direction, half, _gap_half)
      case direction
      when 'north'
        [rx + half, ry + CELL_GAP / 2, rx + half, ry - CELL_GAP / 2]
      when 'south'
        [rx + half, ry + CELL_INNER + CELL_GAP / 2, rx + half, ry + CELL_SIZE + CELL_GAP / 2]
      when 'east'
        [rx + CELL_INNER + CELL_GAP / 2, ry + half, rx + CELL_SIZE + CELL_GAP / 2, ry + half]
      when 'west'
        [rx + CELL_GAP / 2, ry + half, rx - CELL_GAP / 2, ry + half]
      else
        [nil, nil, nil, nil]
      end
    end

    def svg_room_cell(rx, ry, room, vis_class, fill_color, opacity, monsters = [])
      inner_x = rx + CELL_GAP / 2
      inner_y = ry + CELL_GAP / 2

      stroke_color, stroke_width = room_stroke(room, vis_class)
      filter_attr = vis_class == 'current-room' ? ' filter="url(#glow-current)"' : ''

      # Embed monster data as JSON for JS click popup
      monster_attr = ''
      if monsters.any?
        monster_json = monsters.map { |m|
          { name: m.display_name, hp: m.hp, max_hp: m.max_hp,
            difficulty: m.difficulty_text, direction: m.movement_direction }
        }
        escaped = monster_json.to_json.gsub('"', '&quot;')
        monster_attr = %( data-monsters="#{escaped}")
      end

      %(<rect x="#{inner_x}" y="#{inner_y}" ) +
        %(width="#{CELL_INNER}" height="#{CELL_INNER}" ) +
        %(rx="5" ry="5" ) +
        %(fill="#{fill_color}" ) +
        %(class="room-cell #{vis_class}" ) +
        %(data-room-id="#{room.id}" ) +
        %(data-grid-x="#{room.grid_x}" ) +
        %(data-grid-y="#{room.grid_y}" ) +
        %(data-vis="#{vis_class}" ) +
        %(stroke="#{stroke_color}" stroke-width="#{stroke_width}" opacity="#{opacity}"#{filter_attr}#{monster_attr}/>)
    end

    def room_stroke(room, vis_class)
      case vis_class
      when 'current-room'
        [COLORS[:current_border], 2]
      when 'visible'
        [COLORS[:visible_border], 1]
      else
        [COLORS[:memory_border], 1]
      end
    end

    # Render content icons based on visibility:
    #   Current room: all details
    #   In LOS (not current): monsters + stairs/entrance only
    #   Memory (explored, out of LOS): all remembered details
    def svg_room_content(rx, ry, room, delve, is_current, in_los)
      cx = rx + CELL_SIZE / 2
      cy = ry + CELL_SIZE / 2

      if is_current
        # Current room: show everything except puzzle (shown in action buttons + purple border)
        render_all_content(cx, cy, room, delve, 1.0, skip_puzzle: true)
      elsif in_los
        # LOS rooms: monsters + static markers only (can see at a distance)
        render_los_content(cx, cy, room, delve)
      elsif room.explored?
        # Memory rooms: show all remembered details, faded
        render_all_content(cx, cy, room, delve, 0.6)
      else
        ''
      end
    end

    # Full content: monsters > treasure > puzzle > stairs > entrance
    def render_all_content(cx, cy, room, delve, opacity, skip_puzzle: false)
      monsters = begin
        delve.monsters_in_room(room)
      rescue StandardError => e
        warn "[DelveMapPanelService] monsters_in_room failed for room #{room.id}: #{e.message}"
        []
      end

      if monsters.any?
        parts = []
        parts << svg_geo_icon(cx, cy - 4, :monster, COLORS[:monster], 'monster-icon', opacity)
        label = monsters.first.monster_type.capitalize
        label += " +#{monsters.size - 1}" if monsters.size > 1
        parts << svg_label(cx, cy + 14, label, COLORS[:monster], opacity * 0.85)
        # Direction arrow for first monster
        parts << svg_direction_arrow(cx, cy - 4, monsters.first, opacity)
        return parts.join("\n")
      end

      if room.has_monster?
        parts = []
        parts << svg_geo_icon(cx, cy - 4, :monster, COLORS[:monster], 'monster-icon', opacity)
        parts << svg_label(cx, cy + 14, room.monster_type.capitalize, COLORS[:monster], opacity * 0.85)
        return parts.join("\n")
      end

      treasure = begin
        DelveTreasure.first(delve_room_id: room.id, looted: false)
      rescue StandardError => e
        warn "[DelveMapPanelService] treasure lookup failed for room #{room.id}: #{e.message}"
        nil
      end

      if treasure
        return svg_geo_icon(cx, cy, :treasure, COLORS[:treasure], 'treasure-icon', opacity)
      end

      unless skip_puzzle
        puzzle = begin
          DelvePuzzle.first(delve_room_id: room.id, solved: false)
        rescue StandardError => e
          warn "[DelveMapPanelService] puzzle lookup failed for room #{room.id}: #{e.message}"
          nil
        end

        if puzzle
          return svg_geo_icon(cx, cy, :puzzle, COLORS[:puzzle], 'puzzle-icon', opacity)
        end
      end

      if room.is_exit
        return svg_geo_icon(cx, cy, :stairs, COLORS[:stairs], 'stairs-icon', opacity)
      elsif room.is_entrance
        return svg_geo_icon(cx, cy, :entrance, COLORS[:entrance], 'entrance-icon', opacity)
      end

      ''
    end

    # LOS content: only monsters + static markers (stairs/entrance)
    def render_los_content(cx, cy, room, delve)
      monsters = begin
        delve.monsters_in_room(room)
      rescue StandardError => e
        warn "[DelveMapPanelService] monsters_in_room (LOS) failed for room #{room.id}: #{e.message}"
        []
      end

      if monsters.any?
        parts = []
        parts << svg_geo_icon(cx, cy - 4, :monster, COLORS[:monster], 'monster-icon', 0.9)
        label = monsters.first.monster_type.capitalize
        label += " +#{monsters.size - 1}" if monsters.size > 1
        parts << svg_label(cx, cy + 14, label, COLORS[:monster], 0.8)
        # Direction arrow for first monster
        parts << svg_direction_arrow(cx, cy - 4, monsters.first, 0.9)
        return parts.join("\n")
      end

      if room.has_monster?
        parts = []
        parts << svg_geo_icon(cx, cy - 4, :monster, COLORS[:monster], 'monster-icon', 0.9)
        parts << svg_label(cx, cy + 14, room.monster_type.capitalize, COLORS[:monster], 0.8)
        return parts.join("\n")
      end

      if room.is_exit
        return svg_geo_icon(cx, cy, :stairs, COLORS[:stairs], 'stairs-icon', 0.9)
      elsif room.is_entrance
        return svg_geo_icon(cx, cy, :entrance, COLORS[:entrance], 'entrance-icon', 0.9)
      end

      ''
    end

    # Geometric SVG icons replacing emoji
    def svg_geo_icon(cx, cy, type, color, css_class, opacity = 1.0)
      inner = case type
              when :monster
                # Small circle with two eye dots
                %(<circle cx="#{cx}" cy="#{cy}" r="7" fill="none" stroke="#{color}" stroke-width="1.5"/>) +
                  %(<circle cx="#{cx - 3}" cy="#{cy - 1}" r="1.5" fill="#{color}"/>) +
                  %(<circle cx="#{cx + 3}" cy="#{cy - 1}" r="1.5" fill="#{color}"/>)
              when :treasure
                # Rotated diamond
                %(<polygon points="#{cx},#{cy - 7} #{cx + 6},#{cy} #{cx},#{cy + 7} #{cx - 6},#{cy}" ) +
                  %(fill="#{color}" opacity="0.7"/>) +
                  %(<polygon points="#{cx},#{cy - 7} #{cx + 6},#{cy} #{cx},#{cy + 7} #{cx - 6},#{cy}" ) +
                  %(fill="none" stroke="#{color}" stroke-width="1.5"/>)
              when :puzzle
                # Circle outline with ? text
                %(<circle cx="#{cx}" cy="#{cy}" r="7" fill="none" stroke="#{color}" stroke-width="1.5"/>) +
                  %(<text x="#{cx}" y="#{cy + 4}" text-anchor="middle" fill="#{color}" font-size="10" font-family="sans-serif" font-weight="bold" style="pointer-events:none;">?</text>)
              when :stairs
                # Down chevron
                %(<polyline points="#{cx - 6},#{cy - 3} #{cx},#{cy + 3} #{cx + 6},#{cy - 3}" ) +
                  %(fill="none" stroke="#{color}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>)
              when :entrance
                # Up chevron
                %(<polyline points="#{cx - 6},#{cy + 3} #{cx},#{cy - 3} #{cx + 6},#{cy + 3}" ) +
                  %(fill="none" stroke="#{color}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>)
              else
                ''
              end
      %(<g class="#{css_class}" opacity="#{opacity}" style="pointer-events: none;">#{inner}</g>)
    end

    # Small direction arrow offset from monster icon center
    def svg_direction_arrow(cx, cy, monster, opacity)
      return '' unless monster.respond_to?(:direction_arrow) && monster.direction_arrow

      arrow_offsets = { 'north' => [0, -9], 'south' => [0, 9], 'east' => [9, 0], 'west' => [-9, 0] }
      ox, oy = arrow_offsets[monster.movement_direction] || [0, 0]
      %(<text x="#{cx + ox}" y="#{cy + oy}" text-anchor="middle" dominant-baseline="central" ) +
        %(font-size="7" fill="#ffffff" opacity="#{opacity * 0.8}" style="pointer-events: none;">#{monster.direction_arrow}</text>)
    end

    def svg_label(cx, cy, text, color, opacity = 1.0)
      %(<text x="#{cx}" y="#{cy}" text-anchor="middle" ) +
        %(fill="#{color}" font-size="8" font-family="sans-serif" ) +
        %(opacity="#{opacity}" style="pointer-events: none;">#{text}</text>)
    end

  end
end
