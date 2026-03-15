# frozen_string_literal: true

require_relative '../../helpers/canvas_helper'
require 'digest'

# Generates delve levels using a fractal branching algorithm.
# 3 atomic segment types (passage, corner, branch) with pressure-based
# branching and recursive budget halving for organic dungeon layouts.
class DelveGeneratorService
  ROOM_TYPES = %w[corridor corner branch terminal].freeze

  # Monster types by tier (higher tier = deeper/harder)
  MONSTERS = %w[rat spider goblin skeleton orc troll ogre demon dragon].freeze

  # Direction helpers — uses symbol keys for internal grid operations
  REVERSE_DIR = { north: :south, south: :north, east: :west, west: :east }.freeze
  DIRECTION_DELTA = { north: [0, -1], south: [0, 1], east: [1, 0], west: [-1, 0] }.freeze

  class << self
    # Generate a complete level for a delve
    # @param delve [Delve] the delve to generate for
    # @param level_num [Integer] the level number (1-based)
    # @return [Array<DelveRoom>] generated rooms
    def generate_level!(delve, level_num)
      grid_width = delve.grid_width || 15
      grid_height = delve.grid_height || 15

      # Initialize empty grid
      grid = Array.new(grid_height) { Array.new(grid_width) { nil } }
      rooms = []

      # Create seeded random for reproducibility
      seed = deterministic_seed(delve.seed, level_num)
      rng = Random.new(seed)

      # Step 1: Calculate budgets
      density = GameConfig::Delve::DENSITY
      total_budget = (grid_width * grid_height * density[:room_ratio]).to_i
      main_budget = (total_budget * density[:main_tunnel_ratio]).to_i
      main_budget = [main_budget, density[:min_main_rooms]].max
      sub_budget = total_budget - main_budget

      # Step 2: Build main tunnel with fractal branching (handles sub-tunnels internally)
      build_main_tunnel(grid, grid_width, grid_height, main_budget, sub_budget, rng)

      # Step 3: Convert grid to DelveRoom records with shape-based types
      grid.each_with_index do |row, y|
        row.each_with_index do |cell, x|
          next unless cell

          room_type = infer_room_shape(grid, x, y)

          room = DelveRoom.create(
            delve_id: delve.id,
            level: level_num,
            grid_x: x,
            grid_y: y,
            room_type: room_type,
            depth: level_num,
            is_entrance: false,
            is_exit: false
          )

          rooms << room
        end
      end

      # Step 3.5: Identify terminal rooms (dead ends)
      mark_terminal_rooms!(grid, rooms)

      # Step 4: Assign entrance, exit, and boss
      if rooms.any?
        # Entrance at one end (top-left area)
        entrance = rooms.min_by { |r| r.grid_x + r.grid_y }
        entrance.update(is_entrance: true)

        # Exit at opposite end (farthest from entrance)
        exit_room = rooms.max_by { |r| (r.grid_x - entrance.grid_x).abs + (r.grid_y - entrance.grid_y).abs }
        exit_room.update(is_exit: true)

        # Boss room before exit (if enough rooms)
        if rooms.length > GameConfig::Delve::DENSITY[:min_boss_rooms]
          candidates = rooms.reject { |r| r.id == entrance.id || r.id == exit_room.id }
          pre_exit = candidates.max_by { |r| (r.grid_x - entrance.grid_x).abs + (r.grid_y - entrance.grid_y).abs }
          pre_exit&.update(is_boss: true, monster_type: assign_boss_monster(level_num, rng))
        end
      end

      # Step 5: Add dynamic content (blockers, puzzles, traps, treasures, monsters)
      add_dynamic_content!(delve, level_num, rooms, rng)

      # Step 6: Create real Room records and wire features
      create_real_rooms!(delve, level_num, rooms)

      rooms
    end

    private

    # ====== Direction Helpers ======

    def reverse_direction(dir)
      REVERSE_DIR[dir]
    end

    # The 2 perpendicular directions (e.g., north → [:east, :west])
    def valid_turns(direction)
      case direction
      when :north, :south then %i[east west]
      when :east, :west then %i[north south]
      end
    end

    def direction_delta(dir)
      DIRECTION_DELTA[dir]
    end

    def in_bounds?(x, y, width, height)
      x >= 0 && x < width && y >= 0 && y < height
    end

    # Check if a cell is in bounds AND empty
    def can_place?(grid, x, y, width, height)
      in_bounds?(x, y, width, height) && grid[y][x].nil?
    end

    # ====== Segment Constructors ======
    # Each validates ALL positions before writing ANY (no partial writes).
    # Returns nil on failure.

    # Place 3 rooms in a straight line ahead of cursor
    def construct_passage(grid, x, y, dir, w, h, _rng)
      dx, dy = direction_delta(dir)
      positions = (1..3).map { |i| [x + dx * i, y + dy * i] }

      return nil unless positions.all? { |px, py| can_place?(grid, px, py, w, h) }

      positions.each { |px, py| grid[py][px] = { type: :tunnel, x: px, y: py } }
      { rooms: positions, end_x: positions.last[0], end_y: positions.last[1], end_dir: dir }
    end

    # 2 rooms straight ahead, then 1 room in a perpendicular turn
    def construct_corner(grid, x, y, dir, w, h, rng)
      dx, dy = direction_delta(dir)
      straight = (1..2).map { |i| [x + dx * i, y + dy * i] }

      return nil unless straight.all? { |px, py| can_place?(grid, px, py, w, h) }

      turns = valid_turns(dir).shuffle(random: rng)
      turns.each do |turn_dir|
        tdx, tdy = direction_delta(turn_dir)
        corner_pos = [straight.last[0] + tdx, straight.last[1] + tdy]

        next unless can_place?(grid, corner_pos[0], corner_pos[1], w, h)

        all_pos = straight + [corner_pos]
        all_pos.each { |px, py| grid[py][px] = { type: :tunnel, x: px, y: py } }
        return { rooms: all_pos, end_x: corner_pos[0], end_y: corner_pos[1], end_dir: turn_dir }
      end

      nil
    end

    # 1 room straight (junction), then 1 room in each perpendicular direction
    def construct_branch(grid, x, y, dir, w, h, _rng)
      dx, dy = direction_delta(dir)
      junction = [x + dx, y + dy]

      return nil unless can_place?(grid, junction[0], junction[1], w, h)

      perp = valid_turns(dir)
      arm1_delta = direction_delta(perp[0])
      arm2_delta = direction_delta(perp[1])
      arm1_pos = [junction[0] + arm1_delta[0], junction[1] + arm1_delta[1]]
      arm2_pos = [junction[0] + arm2_delta[0], junction[1] + arm2_delta[1]]

      return nil unless can_place?(grid, arm1_pos[0], arm1_pos[1], w, h) &&
                         can_place?(grid, arm2_pos[0], arm2_pos[1], w, h)

      all_pos = [junction, arm1_pos, arm2_pos]
      all_pos.each { |px, py| grid[py][px] = { type: :tunnel, x: px, y: py } }

      {
        rooms: all_pos,
        junction: junction,
        arm1: { x: arm1_pos[0], y: arm1_pos[1], dir: perp[0] },
        arm2: { x: arm2_pos[0], y: arm2_pos[1], dir: perp[1] }
      }
    end

    # 50/50 passage vs corner, falls back to the other if first fails
    def try_segment(grid, x, y, dir, w, h, rng)
      if rng.rand(2) == 0
        construct_passage(grid, x, y, dir, w, h, rng) ||
          construct_corner(grid, x, y, dir, w, h, rng)
      else
        construct_corner(grid, x, y, dir, w, h, rng) ||
          construct_passage(grid, x, y, dir, w, h, rng)
      end
    end

    # ====== Main Tunnel Builder ======

    def build_main_tunnel(grid, width, height, main_budget, sub_budget, rng)
      fractal = GameConfig::Delve::FRACTAL
      segment_cost = fractal[:segment_cost]

      # Place entrance at random x in middle third, y=0, heading south
      start_x = width / 3 + rng.rand(width / 3)
      cursor_x = start_x
      cursor_y = 0
      cursor_dir = :south
      branch_chance = fractal[:initial_branch_chance]

      # Place starting room
      grid[cursor_y][cursor_x] = { type: :main, x: cursor_x, y: cursor_y }
      main_budget -= 1

      while main_budget >= segment_cost
        # Try branching
        if branch_chance > 0 && rng.rand(branch_chance) == 0 && sub_budget >= fractal[:min_branch_budget]
          result = construct_branch(grid, cursor_x, cursor_y, cursor_dir, width, height, rng)
          if result
            main_budget -= segment_cost
            half = sub_budget / 2
            sub_budget -= half
            # Spawn sub-tunnel from arm2
            build_sub_tunnel(grid, result[:arm2][:x], result[:arm2][:y], result[:arm2][:dir], half, width, height, rng)
            # Continue main tunnel from arm1
            cursor_x = result[:arm1][:x]
            cursor_y = result[:arm1][:y]
            cursor_dir = result[:arm1][:dir]
            branch_chance = fractal[:initial_branch_chance]
            next
          end
        end

        # Normal segment (passage or corner)
        result = try_segment(grid, cursor_x, cursor_y, cursor_dir, width, height, rng)
        break unless result

        main_budget -= segment_cost
        cursor_x = result[:end_x]
        cursor_y = result[:end_y]
        cursor_dir = result[:end_dir]
        branch_chance = [branch_chance - fractal[:branch_chance_ramp], 1].max
      end
    end

    # ====== Sub-Tunnel Builder (recursive) ======

    def build_sub_tunnel(grid, x, y, direction, budget, width, height, rng)
      fractal = GameConfig::Delve::FRACTAL
      segment_cost = fractal[:segment_cost]

      while budget >= segment_cost
        # Try branching with fixed sub-branch chance
        if rng.rand(fractal[:sub_branch_chance]) == 0 && budget >= fractal[:min_branch_budget]
          result = construct_branch(grid, x, y, direction, width, height, rng)
          if result
            budget -= segment_cost
            half = budget / 2
            budget -= half
            # Recurse from arm2
            build_sub_tunnel(grid, result[:arm2][:x], result[:arm2][:y], result[:arm2][:dir], half, width, height, rng)
            # Continue from arm1
            x = result[:arm1][:x]
            y = result[:arm1][:y]
            direction = result[:arm1][:dir]
            next
          end
        end

        # Normal segment
        result = try_segment(grid, x, y, direction, width, height, rng)
        break unless result

        budget -= segment_cost
        x = result[:end_x]
        y = result[:end_y]
        direction = result[:end_dir]
      end
    end

    # Infer room shape from grid topology
    def infer_room_shape(grid, x, y)
      dirs = neighbor_directions(grid, x, y)
      case dirs.length
      when 0, 1
        'terminal'
      when 2
        # Opposite directions = corridor, perpendicular = corner
        if (dirs.include?(:north) && dirs.include?(:south)) ||
           (dirs.include?(:east) && dirs.include?(:west))
          'corridor'
        else
          'corner'
        end
      else
        'branch'
      end
    end

    # Get directions to neighboring occupied cells
    def neighbor_directions(grid, x, y)
      dirs = []
      { north: [0, -1], south: [0, 1], east: [1, 0], west: [-1, 0] }.each do |dir, (dx, dy)|
        nx = x + dx
        ny = y + dy
        next unless in_bounds?(nx, ny, grid[0].length, grid.length)

        dirs << dir if grid[ny][nx]
      end
      dirs
    end

    def weighted_sample(weights, rng)
      total = weights.values.sum
      target = rng.rand(total)
      cumulative = 0

      weights.each do |type, weight|
        cumulative += weight
        return type.to_s if cumulative > target
      end

      weights.keys.first.to_s
    end

    # Assign a boss monster (always high tier)
    def assign_boss_monster(level, rng)
      max_tier = MONSTERS.length - 1
      tier = [level / 2 + 2, max_tier].min
      min_tier = [tier - 1, 0].max
      min_tier = [min_tier, tier].min

      MONSTERS[rng.rand(min_tier..tier)]
    end

    # ====== Dynamic Content Generation ======

    # Mark terminal rooms (dead ends with only one exit)
    def mark_terminal_rooms!(grid, rooms)
      rooms.each do |room|
        exits = count_exits(grid, room.grid_x, room.grid_y)
        room.update(is_terminal: true) if exits <= 1
      end
    end

    # Count available exits from a position
    def count_exits(grid, x, y)
      count = 0
      [[0, -1], [0, 1], [-1, 0], [1, 0]].each do |dx, dy|
        nx = x + dx
        ny = y + dy
        next unless in_bounds?(nx, ny, grid[0].length, grid.length)

        count += 1 if grid[ny][nx]
      end
      count
    end

    # Add all dynamic content to a level
    def add_dynamic_content!(delve, level, rooms, rng)
      era = current_era

      # 0. Assign content (monsters, puzzles) to non-special rooms
      assign_content!(delve, level, rooms, rng)

      # 1. Add treasure to terminal rooms (except exit path)
      add_treasures!(delve, level, rooms, era, rng)

      # 2. Add skill check blockers (15% of connections)
      add_blockers!(delve, level, rooms, rng)

      # 3. Add puzzles to rooms flagged has_puzzle
      add_puzzles!(delve, level, rooms, rng)

      # 4. Add traps to exits
      add_traps!(delve, level, rooms, era, rng)

      # 5. Spawn roving monsters
      DelveMonsterService.spawn_monsters!(delve, level, rng)

      # 6. Spawn lurking monsters in terminal rooms
      DelveMonsterService.spawn_lurkers!(delve, level, rng)
    end

    # Assign content (monsters, puzzles) to non-special rooms based on difficulty weights
    def assign_content!(delve, level, rooms, rng)
      weights = GameConfig::Delve::CONTENT_WEIGHTS[delve.difficulty.to_sym] || GameConfig::Delve::CONTENT_WEIGHTS[:normal]
      rooms.each do |room|
        next if room.is_entrance || room.is_exit || room.is_boss || room.is_terminal

        content = weighted_sample(weights, rng)
        case content
        when 'monster'
          tier = [level / 2, MONSTERS.length - 2].min
          room.update(monster_type: MONSTERS[rng.rand([tier - 1, 0].max..[tier + 1, MONSTERS.length - 2].min)])
        when 'puzzle'
          room.update(has_puzzle: true)
        end
      end
    end

    # Add treasures to terminal rooms
    def add_treasures!(delve, level, rooms, era, rng)
      terminal_rooms = rooms.select { |r| r.is_terminal && !r.is_exit && !r.is_entrance }

      terminal_rooms.each do |room|
        DelveTreasureService.generate!(room, level, era)
        room.update(has_treasure: true)
      end
    end

    # Add skill check blockers
    def add_blockers!(delve, level, rooms, rng)
      blocker_types = DelveBlocker::BLOCKER_TYPES
      entrance = delve.entrance_room(level)

      rooms.each do |room|
        next if room.is_entrance || room.is_exit
        next if room.has_puzzle # Puzzles ARE the gating mechanism

        entry_dir = entry_direction_for(room, delve, entrance)

        room.available_exits.each do |direction|
          next if direction == entry_dir
          next unless rng.rand < GameConfig::Delve::CONTENT[:blocker_chance]

          base_dc = GameSetting.integer('delve_base_skill_dc') || 10
          dc_per_level = GameSetting.integer('delve_dc_per_level') || 2
          difficulty = base_dc + (dc_per_level * level)

          DelveBlocker.create(
            delve_room_id: room.id,
            direction: direction,
            blocker_type: blocker_types.sample(random: rng),
            difficulty: difficulty
          )
        end
      end
    end

    # Add puzzles to rooms flagged with has_puzzle
    def add_puzzles!(delve, level, rooms, rng)
      puzzle_rooms = rooms.select { |r| r.has_puzzle }
      entrance = delve.entrance_room(level)

      # Cycle through types to ensure variety (no consecutive repeats)
      types = DelvePuzzleService::PUZZLE_TYPES.dup
      last_type = nil

      puzzle_rooms.each do |room|
        seed = deterministic_seed(delve.seed, level, room.id) % 2_000_000_000
        entry_dir = entry_direction_for(room, delve, entrance)
        exits = room.available_exits.reject { |d| d == 'down' || d == entry_dir }
        direction = exits.sample(random: rng)

        # Pick a type that differs from the last one used
        available = types.reject { |t| t == last_type && types.size > 1 }
        chosen_type = available.sample(random: rng)
        last_type = chosen_type

        DelvePuzzleService.generate!(room, level, seed, direction: direction, puzzle_type: chosen_type)
      end
    end

    # Add traps to exits - traps are directional obstacles that block movement
    def add_traps!(delve, level, rooms, era, rng)
      entrance = delve.entrance_room(level)

      rooms.each do |room|
        next if room.is_entrance || room.is_exit
        next if room.has_puzzle # Don't add traps to puzzle rooms

        entry_dir = entry_direction_for(room, delve, entrance)

        room.available_exits.each do |direction|
          next if direction == entry_dir
          # Configured chance per exit to have a trap
          next unless rng.rand < GameConfig::Delve::CONTENT[:trap_chance]

          # Don't put trap if there's already a blocker in that direction
          existing_blocker = DelveBlocker.first(delve_room_id: room.id, direction: direction)
          next if existing_blocker

          DelveTrapService.generate!(room, direction, level, era)
          room.update(has_trap: true)
        end
      end
    end

    # Delegate to CanvasHelper for opposite directions (canonical source)
    REVERSE_DIRECTION = CanvasHelper::OPPOSITE_DIRECTIONS

    # Determine which direction leads toward the entrance from this room.
    # We find which adjacent room is closest to the entrance by Manhattan distance.
    def entry_direction_for(room, delve, entrance)
      return nil unless entrance
      return nil if room.available_exits.empty?

      best_dir = nil
      best_dist = Float::INFINITY

      room.available_exits.each do |dir|
        adj = delve.adjacent_room(room, dir)
        next unless adj

        dist = (adj.grid_x - entrance.grid_x).abs + (adj.grid_y - entrance.grid_y).abs
        if dist < best_dist
          best_dist = dist
          best_dir = dir
        end
      end

      best_dir
    end

    # Get current era for theming
    def current_era
      return :modern unless defined?(EraService)

      era_name = EraService.current_era rescue 'modern'
      era_name.to_sym
    end

    # ====== Real Room Creation ======

    # Create real Room records for each DelveRoom and wire features
    # Must be called AFTER add_dynamic_content! so traps/blockers exist
    #
    # @param delve [Delve] the delve
    # @param level_num [Integer] the level number
    # @param delve_rooms [Array<DelveRoom>] the generated delve rooms
    def create_real_rooms!(delve, level_num, delve_rooms)
      pool_location = resolve_delve_location(delve)
      raise "Cannot resolve delve pool location" unless pool_location

      # Ensure delve room template exists for pool acquisition
      ensure_delve_room_template!

      delve_rooms.each do |dr|
        # Room dimensions vary by type — corridors are narrow rectangles, boss rooms are large squares.
        # Grid spacing is 30ft for positioning; rooms are centered within cells.
        room_w, room_h = delve_room_dimensions_feet(dr)
        offset_x = (30.0 - room_w) / 2.0
        offset_y = (30.0 - room_h) / 2.0
        min_x = dr.grid_x * 30.0 + offset_x
        min_y = dr.grid_y * 30.0 + offset_y

        # Acquire from pool or create directly
        result = TemporaryRoomPoolService.acquire_for_delve(delve)
        if result.success?
          room = result[:room]
        else
          # Fallback: create directly
          room = Room.create(
            location_id: pool_location.id,
            name: 'Delve Chamber',
            is_temporary: true,
            pool_status: 'in_use',
            temp_delve_id: delve.id,
            spatial_group_id: "delve:#{delve.id}",
            room_type: 'dungeon',
            min_x: 0.0, max_x: room_w,
            min_y: 0.0, max_y: room_h,
            min_z: 0.0, max_z: 10.0
          )
        end

        unless room
          warn "[DelveGeneratorService] Failed to create/acquire room for DelveRoom #{dr.id}"
          next
        end

        # Set bounds — room centered within 30ft grid cell
        room_label = if dr.is_exit then 'Exit'
                     elsif dr.is_entrance then 'Entrance'
                     elsif dr.is_boss then 'Boss Chamber'
                     else NamingHelper.titleize(dr.room_type || 'chamber')
                     end
        room_name = "Dungeon #{room_label} [#{dr.grid_x},#{dr.grid_y}]"
        room.update(
          min_x: min_x, max_x: min_x + room_w,
          min_y: min_y, max_y: min_y + room_h,
          min_z: 0.0, max_z: 10.0,
          name: room_name,
          location_id: pool_location.id
        )

        # Link DelveRoom to Room
        dr.update(room_id: room.id)
      end

      # Wire features after all rooms exist (so we know adjacency)
      delve_rooms.each do |dr|
        dr.reload
        next unless dr.room_id

        open_dirs = []
        blocked_dirs = {}

        %w[north south east west].each do |dir|
          offset = Delve::DIRECTION_OFFSETS[dir]
          next unless offset

          adjacent = delve.room_at(level_num, dr.grid_x + offset[0], dr.grid_y + offset[1])
          next unless adjacent

          # Check for hazards on either side of the connection.
          trap = delve.respond_to?(:trap_at) ? delve.trap_at(dr, dir) : DelveTrap.first(delve_room_id: dr.id, direction: dir, disabled: false)
          blocker = delve.respond_to?(:blocker_at) ? delve.blocker_at(dr, dir) : DelveBlocker.first(delve_room_id: dr.id, direction: dir, cleared: false)
          puzzle = delve.respond_to?(:puzzle_blocking_at) ? delve.puzzle_blocking_at(dr, dir) : nil

          if trap
            blocked_dirs[dir] = :trap
          elsif blocker && !blocker.cleared?
            blocked_dirs[dir] = :blocker
          elsif puzzle
            blocked_dirs[dir] = :puzzle
          else
            open_dirs << dir
          end
        end

        DelveRoomFeatureService.wire_features!(
          dr.room,
          open_directions: open_dirs,
          blocked_directions: blocked_dirs
        )

        # Set description
        content_flags = build_content_flags(dr, delve, blocked_dirs)
        combo_key = DelveRoomDescriptionService.combo_key(
          exits: open_dirs + blocked_dirs.keys,
          content: content_flags
        )
        description = DelveRoomDescriptionService.description_for(combo_key: combo_key)
        dr.room.update(
          short_description: description,
          long_description: description
        )
      end
    rescue StandardError => e
      warn "[DelveGeneratorService] Failed to create real rooms: #{e.message}"
      warn e.backtrace.first(5).join("\n")
    end

    # Resolve or create the delve pool location for a specific delve.
    # Uses that delve's own location ancestry, falls back to any zone.
    # @return [Location] the delve pool location
    def resolve_delve_location(delve)
      Location.first(name: 'Delve Pool') || begin
        zone = nil
        world_id = nil

        # Use the delve's own world context if available
        if delve&.location
          zone = delve.location.zone
          world_id = delve.location.world_id || zone&.world_id
        end

        # Fallback: find any zone
        zone ||= Zone.first
        world_id ||= zone&.world_id

        raise "No zone available to create Delve Pool location" unless zone

        Location.create(
          zone_id: zone.id,
          world_id: world_id,
          name: 'Delve Pool',
          location_type: 'building'
        )
      end
    end

    # Room dimensions [width, height] in feet based on shape and boss flag.
    # Must match BattleMapTemplateService::DELVE_SHAPES so the arena grid
    # aligns with pre-generated template hex data.
    # With HEX_SIZE_FEET=2: 12ft→6 hex, 18ft→9 hex, 24ft→12 hex, 26ft→13 hex
    def delve_room_dimensions_feet(room)
      return [26.0, 26.0] if room.is_boss # matches large_chamber template
      case room.room_type.to_s
      when 'corridor'
        # Orient corridor based on exits: east-west corridors are wide+short
        exits = room.available_exits.reject { |d| d == 'down' }
        east_west = (exits & %w[east west]).any? && (exits & %w[north south]).empty?
        east_west ? [24.0, 12.0] : [12.0, 24.0] # matches rect_horizontal/rect_vertical templates
      else [18.0, 18.0] # corner, branch, terminal — matches small_chamber template
      end
    end

    # Ensure a delve room template exists for pool acquisition
    def ensure_delve_room_template!
      RoomTemplate.first(template_type: 'delve_room', active: true) ||
        RoomTemplate.create(
          name: 'Delve Room',
          template_type: 'delve_room',
          category: 'delve',
          room_type: 'dungeon',
          short_description: 'A dark dungeon chamber.',
          long_description: 'Stone walls surround you, slick with moisture.',
          width: 30,
          length: 30,
          height: 10,
          active: true
        )
    end

    # Stable hash-based seed generator for reproducible layouts across processes.
    def deterministic_seed(*parts)
      Digest::SHA256.hexdigest(parts.join(':'))[0, 16].to_i(16)
    end

    # Build content flags for room description generation
    # @param dr [DelveRoom] the delve room
    # @param delve [Delve] the delve
    # @param blocked_dirs [Hash] blocked directions
    # @return [Array<String>] content flags
    def build_content_flags(dr, delve, blocked_dirs)
      flags = []
      flags << 'monster' if dr.monster_type && !dr.monster_cleared
      flags << 'treasure' if dr.has_treasure || dr.loot_value.to_i > 0
      flags << 'puzzle' if dr.has_puzzle
      blocked_dirs.each { |dir, type| flags << "#{type}_#{dir}" }
      flags
    end
  end
end
