# frozen_string_literal: true

require_relative '../concerns/result_handler'

# Handles puzzle generation, solving, and help.
class DelvePuzzleService
  extend ResultHandler

  PUZZLE_TYPES = %w[symbol_grid pipe_network toggle_matrix].freeze

  # Difficulty scaling by level
  DIFFICULTY_BY_LEVEL = {
    1 => 'easy',
    2 => 'easy',
    3 => 'medium',
    4 => 'medium',
    5 => 'hard',
    6 => 'hard'
  }.freeze

  class << self
    # Generate a puzzle for a room
    # @param room [DelveRoom] the room
    # @param level [Integer] dungeon level
    # @param seed [Integer] random seed
    # @return [DelvePuzzle] the generated puzzle
    def generate!(room, level, seed, direction: nil, puzzle_type: nil)
      rng = Random.new(seed)
      puzzle_type ||= PUZZLE_TYPES.sample(random: rng)
      difficulty = DIFFICULTY_BY_LEVEL[level] || 'hard'

      puzzle_data = generate_puzzle_data(puzzle_type, difficulty, seed)

      DelvePuzzle.create(
        delve_room_id: room.id,
        puzzle_type: puzzle_type,
        difficulty: difficulty,
        seed: seed,
        puzzle_data: puzzle_data,
        direction: direction
      )
    end

    # Attempt to solve a puzzle
    # @param participant [DelveParticipant] the participant
    # @param puzzle [DelvePuzzle] the puzzle
    # @param answer [String, Hash] the submitted answer
    # @return [Result]
    def attempt!(participant, puzzle, answer)
      # Accessibility mode: replace puzzle with a stat check
      return accessibility_stat_check!(participant, puzzle) if participant.accessibility_mode?

      # Spend time
      time_cost = GameSetting.integer('delve_time_puzzle_attempt') || 15
      time_result = participant.spend_time_seconds!(time_cost)
      if time_result == :time_expired
        return Result.new(
          success: false,
          message: "Time runs out before you can finish the puzzle attempt!",
          data: { solved: false, time_expired: true }
        )
      end

      valid = validate_answer(puzzle, answer)

      if valid
        puzzle.solve!

        Result.new(
          success: true,
          message: "The puzzle clicks into place. The way forward opens!",
          data: { solved: true }
        )
      else
        Result.new(
          success: false,
          message: "That's not quite right. The puzzle remains unsolved.",
          data: { solved: false }
        )
      end
    end

    # Get help for a puzzle (corrects multiple cells based on puzzle size)
    # @param participant [DelveParticipant] the participant
    # @param puzzle [DelvePuzzle] the puzzle
    # @return [Result]
    def request_help!(participant, puzzle)
      time_cost = GameSetting.integer('delve_time_puzzle_help') || GameSetting.integer('delve_time_puzzle_hint') || 30
      time_result = participant.spend_time_seconds!(time_cost)
      if time_result == :time_expired
        return Result.new(
          success: false,
          message: "Time runs out before you can gather help from the puzzle.",
          data: { time_expired: true }
        )
      end

      puzzle.increment_hints!

      help_data = generate_structured_help(puzzle)
      message = help_data[:message]

      # Persist new clues for symbol_grid so they show on re-open
      if help_data[:new_clues]&.any? && puzzle.puzzle_type == 'symbol_grid'
        data = JSON.parse(puzzle.puzzle_data.to_json)
        data['clues'] = (data['clues'] || []) + help_data[:new_clues]
        puzzle.update(puzzle_data: Sequel.pg_jsonb_wrap(data))
      end

      Result.new(
        success: true,
        message: message,
        data: { hints_used: puzzle.hints_used }
      )
    end

    # Accessibility mode: replace puzzle with a stat check instead of requiring
    # the visual/spatial puzzle to be solved directly.
    # @param participant [DelveParticipant] the participant
    # @param puzzle [DelvePuzzle] the puzzle
    # @return [Result]
    def accessibility_stat_check!(participant, puzzle)
      # Spend time (same as normal puzzle attempt)
      time_cost = GameSetting.integer('delve_time_puzzle_attempt') || 15
      time_result = participant.spend_time_seconds!(time_cost)
      if time_result == :time_expired
        return Result.new(
          success: false,
          message: "Time runs out before you can bypass the puzzle mechanism.",
          data: { solved: false, accessibility_check: true, time_expired: true }
        )
      end

      # Pick a random stat for the check
      stat_options = DelveBlocker::DEFAULT_STATS.values.uniq
      stat_abbrev = stat_options.sample

      # Calculate modifier
      char_instance = participant.character_instance
      stat_calc = GameConfig::Mechanics::STAT_CALCULATION
      stat_value = char_instance ? (StatAllocationService.get_stat_value(char_instance, stat_abbrev) || stat_calc[:base]) : stat_calc[:base]
      stat_modifier = (stat_value - stat_calc[:base]) / stat_calc[:divisor]

      # DC scales with puzzle difficulty
      base_dc = GameSetting.integer('delve_base_skill_dc') || 10
      difficulty_bonus = case puzzle.difficulty
                         when 'easy' then 0
                         when 'medium' then 2
                         when 'hard' then 4
                         else 4
                         end
      dc = base_dc + difficulty_bonus

      # Roll 2d8 + stat modifier
      dice_sides = GameConfig::Mechanics::STAT_CALCULATION[:skill_dice_sides]
      die1 = rand(1..dice_sides)
      die2 = rand(1..dice_sides)
      total = die1 + die2 + stat_modifier

      if total >= dc
        puzzle.solve!

        Result.new(
          success: true,
          message: "You find an alternative way past the puzzle mechanism using #{stat_abbrev}! " \
                   "(Rolled #{die1}+#{die2}+#{stat_modifier}=#{total} vs DC #{dc})",
          data: { solved: true, accessibility_check: true, roll: { dice: [die1, die2], modifier: stat_modifier, total: total }, dc: dc }
        )
      else
        Result.new(
          success: false,
          message: "You try to bypass the puzzle mechanism using #{stat_abbrev} but fail. Try again! " \
                   "(Rolled #{die1}+#{die2}+#{stat_modifier}=#{total} vs DC #{dc})",
          data: { solved: false, accessibility_check: true, roll: { dice: [die1, die2], modifier: stat_modifier, total: total }, dc: dc }
        )
      end
    end

    # Get puzzle display for player
    # @param puzzle [DelvePuzzle] the puzzle
    # @return [Hash] display data
    def get_display(puzzle)
      base = {
        puzzle_type: puzzle.puzzle_type,
        difficulty: puzzle.difficulty,
        description: puzzle.description,
        grid: puzzle.initial_layout,
        size: puzzle.grid_size,
        hints_used: puzzle.hints_used,
        puzzle_id: puzzle.id
      }

      case puzzle.puzzle_type
      when 'symbol_grid'
        base[:symbols] = puzzle.puzzle_data['symbols'] || %w[A B C D]
        base[:clues] = puzzle.clues
      when 'pipe_network'
        base[:source] = puzzle.puzzle_data['source']
        base[:drain] = puzzle.puzzle_data['drain']
        base[:locked_pipes] = puzzle.puzzle_data['locked_pipes'] || []
      when 'toggle_matrix'
        base[:target_state] = puzzle.puzzle_data['target_state']
        base[:locked] = puzzle.puzzle_data['locked'] || []
      end

      base
    end

    private

    # Number of cells to correct per help, scales with puzzle size
    # size 3 → 1, size 4 → 2, size 5 → 3, size 6 → 4
    def help_count(puzzle)
      [puzzle.grid_size - 2, 1].max
    end

    def generate_puzzle_data(puzzle_type, difficulty, seed)
      rng = Random.new(seed)

      case puzzle_type
      when 'symbol_grid'
        generate_symbol_grid(difficulty, rng)
      when 'pipe_network'
        generate_pipe_network(difficulty, rng)
      when 'toggle_matrix'
        generate_toggle_matrix(difficulty, rng)
      else
        { solution: 'unknown' }
      end
    end

    # ====== Symbol Grid (Latin Square) ======

    def generate_symbol_grid(difficulty, rng)
      size = case difficulty
             when 'easy' then 4
             when 'medium' then 5
             when 'hard' then 6
             else 6
             end

      symbols = %w[A B C D E F].take(size)
      solution = generate_latin_square(size, symbols, rng)

      # Reveal enough cells for deduction; harder = fewer clues
      clue_ratio = case difficulty
                   when 'easy' then 0.6
                   when 'medium' then 0.45
                   when 'hard' then 0.3
                   else 0.3
                   end
      clue_count = (size * size * clue_ratio).round
      clues = generate_grid_clues(solution, clue_count, rng)

      {
        type: 'symbol_grid',
        size: size,
        symbols: symbols,
        solution: solution,
        clues: clues,
        initial: Array.new(size) { Array.new(size) { nil } }
      }
    end

    def generate_latin_square(size, symbols, rng)
      base = (0...size).to_a
      rows = Array.new(size) { |i| base.rotate(i) }

      # Shuffle row order, column order, and symbol assignment
      rows.shuffle!(random: rng)
      col_order = (0...size).to_a.shuffle(random: rng)
      rows = rows.map { |row| col_order.map { |c| row[c] } }

      shuffled_symbols = symbols.shuffle(random: rng)
      rows.map { |row| row.map { |v| shuffled_symbols[v] } }
    end

    def generate_grid_clues(solution, count, rng)
      size = solution.length
      all_positions = (0...size).flat_map { |y| (0...size).map { |x| [x, y] } }
      selected = all_positions.shuffle(random: rng).take(count)
      selected.map { |x, y| { 'x' => x, 'y' => y, 'symbol' => solution[y][x] } }
    end

    # ====== Pipe Network (Connected Path) ======

    def generate_pipe_network(difficulty, rng)
      size = case difficulty
             when 'easy' then 4
             when 'medium' then 5
             when 'hard' then 6
             else 6
             end

      source = [0, rng.rand(size)]
      drain = [size - 1, rng.rand(size)]

      path = find_random_path(size, source, drain, rng)
      solution = build_pipe_solution(size, path, rng)
      initial = scramble_pipe_rotations(solution, rng)

      {
        type: 'pipe_network',
        size: size,
        solution: solution,
        initial: initial,
        source: source,
        drain: drain
      }
    end

    # DFS with random neighbor ordering and backtracking to find a winding path
    def find_random_path(size, source, drain, rng)
      visited = Set.new
      path = []

      dfs = lambda do |pos|
        path << pos
        visited.add("#{pos[0]},#{pos[1]}")
        return true if pos == drain

        [[-1, 0], [1, 0], [0, -1], [0, 1]].shuffle(random: rng).each do |dy, dx|
          ny, nx = pos[0] + dy, pos[1] + dx
          next if ny < 0 || ny >= size || nx < 0 || nx >= size
          next if visited.include?("#{ny},#{nx}")

          return true if dfs.call([ny, nx])
        end

        path.pop
        visited.delete("#{pos[0]},#{pos[1]}")
        false
      end

      dfs.call(source)
      path
    end

    # Build the solution grid: correct pipe types/rotations on the path,
    # random straight/bend pipes for non-path cells
    def build_pipe_solution(size, path, rng)
      grid = Array.new(size) { Array.new(size) { nil } }

      path.each_with_index do |pos, i|
        if i == 0
          # Source cell: external north connection + direction to next cell
          next_dir = [path[i + 1][0] - pos[0], path[i + 1][1] - pos[1]]
          type, rotation = pipe_type_for_directions([-1, 0], next_dir)
        elsif i == path.length - 1
          # Drain cell: direction from prev cell + external south connection
          prev_dir = [path[i - 1][0] - pos[0], path[i - 1][1] - pos[1]]
          type, rotation = pipe_type_for_directions(prev_dir, [1, 0])
        else
          prev_dir = [path[i - 1][0] - pos[0], path[i - 1][1] - pos[1]]
          next_dir = [path[i + 1][0] - pos[0], path[i + 1][1] - pos[1]]
          type, rotation = pipe_type_for_directions(prev_dir, next_dir)
        end
        grid[pos[0]][pos[1]] = { 'type' => type, 'rotation' => rotation }
      end

      # Fill non-path cells with random straight/bend
      size.times do |y|
        size.times do |x|
          next if grid[y][x]

          grid[y][x] = {
            'type' => %w[straight bend].sample(random: rng),
            'rotation' => rng.rand(0..3)
          }
        end
      end

      grid
    end

    # Determine pipe type and rotation for two connection directions.
    # Directions are [dy, dx] vectors: [-1,0]=N, [1,0]=S, [0,1]=E, [0,-1]=W
    def pipe_type_for_directions(dir1, dir2)
      if dir1[0] == -dir2[0] && dir1[1] == -dir2[1]
        # Opposite directions -> straight pipe
        dir1[0] != 0 ? ['straight', 0] : ['straight', 1]
      else
        # Adjacent directions -> bend pipe
        dirs = Set.new([dir1, dir2])
        if dirs == Set[[-1, 0], [0, 1]]    then ['bend', 0] # N+E
        elsif dirs == Set[[0, 1], [1, 0]]   then ['bend', 1] # E+S
        elsif dirs == Set[[1, 0], [0, -1]]  then ['bend', 2] # S+W
        elsif dirs == Set[[0, -1], [-1, 0]] then ['bend', 3] # W+N
        else ['straight', 0]
        end
      end
    end

    # Scramble pipe rotations so no pipe starts at its solution rotation
    def scramble_pipe_rotations(solution, rng)
      solution.map do |row|
        row.map do |pipe|
          type = pipe['type']
          sol_rot = pipe['rotation']
          period = type == 'straight' ? 2 : 4

          options = (0..3).to_a.reject { |r| (r % period) == (sol_rot % period) }
          { 'type' => type, 'rotation' => options.sample(random: rng) }
        end
      end
    end

    # Get connection direction vectors for a pipe type at a given rotation.
    # Returns array of [dy, dx] vectors.
    def pipe_connection_vectors(type, rotation)
      base = case type
             when 'straight' then [[-1, 0], [1, 0]]       # N, S
             when 'bend'     then [[-1, 0], [0, 1]]        # N, E
             when 'cross'    then [[-1, 0], [1, 0], [0, -1], [0, 1]]
             else [[-1, 0], [1, 0]]
             end

      # Rotate clockwise: [dy, dx] -> [dx, -dy]
      rotation.times { base = base.map { |dy, dx| [dx, -dy] } }
      base
    end

    # ====== Toggle Matrix (Lights Out) ======

    def generate_toggle_matrix(difficulty, rng)
      size = case difficulty
             when 'easy' then 3
             when 'medium' then 4
             when 'hard' then 5
             else 5
             end

      # Start with all on (target state), then scramble with random moves
      move_count = rng.rand(3..6)

      current = Array.new(size) { Array.new(size) { true } }
      moves = []

      move_count.times do
        x = rng.rand(size)
        y = rng.rand(size)
        moves << [x, y]
        apply_toggle(current, x, y, size)
      end

      {
        type: 'toggle_matrix',
        size: size,
        solution: moves,
        initial: current,
        target_state: true
      }
    end

    def apply_toggle(grid, x, y, size)
      [[0, 0], [0, 1], [0, -1], [1, 0], [-1, 0]].each do |dx, dy|
        nx = x + dx
        ny = y + dy
        next unless nx >= 0 && nx < size && ny >= 0 && ny < size

        grid[ny][nx] = !grid[ny][nx]
      end
    end

    # ====== Validation ======

    def validate_answer(puzzle, answer)
      case puzzle.puzzle_type
      when 'symbol_grid'
        validate_symbol_grid(puzzle, answer)
      when 'pipe_network'
        validate_pipe_network(puzzle, answer)
      when 'toggle_matrix'
        validate_toggle_matrix(puzzle, answer)
      else
        false
      end
    end

    def validate_symbol_grid(puzzle, answer)
      solution = puzzle.solution
      return false unless solution

      if answer.is_a?(Array)
        return false unless answer.length == solution.length

        answer.each_with_index do |row, y|
          return false unless row.is_a?(Array) && row.length == solution[y].length

          row.each_with_index do |cell, x|
            return false unless cell.to_s.downcase == solution[y][x].to_s.downcase
          end
        end
        true
      else
        answer.to_s.downcase.strip == solution.to_s.downcase.strip
      end
    end

    # Validate by connectivity: source must connect north, drain must connect south,
    # and there must be a connected pipe path from source to drain.
    def validate_pipe_network(puzzle, answer)
      return false unless answer.is_a?(Array)

      size = puzzle.grid_size
      source = puzzle.puzzle_data['source']
      drain = puzzle.puzzle_data['drain']
      return false unless source && drain && answer.length == size

      # Source must connect north (to S marker)
      source_cell = answer.dig(source[0], source[1])
      return false unless source_cell.is_a?(Hash)

      source_conns = pipe_connection_vectors(
        source_cell['type'] || source_cell[:type] || 'straight',
        (source_cell['rotation'] || source_cell[:rotation] || 0).to_i
      )
      return false unless source_conns.include?([-1, 0])

      # Drain must connect south (to D marker)
      drain_cell = answer.dig(drain[0], drain[1])
      return false unless drain_cell.is_a?(Hash)

      drain_conns = pipe_connection_vectors(
        drain_cell['type'] || drain_cell[:type] || 'straight',
        (drain_cell['rotation'] || drain_cell[:rotation] || 0).to_i
      )
      return false unless drain_conns.include?([1, 0])

      # BFS from source: follow pipe connections to see if drain is reachable
      visited = Set.new(["#{source[0]},#{source[1]}"])
      queue = [source]

      while queue.any?
        y, x = queue.shift
        return true if y == drain[0] && x == drain[1]

        cell = answer.dig(y, x)
        next unless cell.is_a?(Hash)

        type = cell['type'] || cell[:type] || 'straight'
        rot = (cell['rotation'] || cell[:rotation] || 0).to_i
        conns = pipe_connection_vectors(type, rot)

        conns.each do |dy, dx|
          ny, nx = y + dy, x + dx
          next unless ny >= 0 && ny < size && nx >= 0 && nx < size
          key = "#{ny},#{nx}"
          next if visited.include?(key)

          ncell = answer.dig(ny, nx)
          next unless ncell.is_a?(Hash)

          ntype = ncell['type'] || ncell[:type] || 'straight'
          nrot = (ncell['rotation'] || ncell[:rotation] || 0).to_i
          nconns = pipe_connection_vectors(ntype, nrot)

          # Neighbor must connect back (opposite direction)
          next unless nconns.include?([-dy, -dx])

          visited.add(key)
          queue << [ny, nx]
        end
      end

      false
    end

    def validate_toggle_matrix(puzzle, answer)
      return false unless answer.is_a?(Array)

      target = puzzle.puzzle_data['target_state']
      answer.all? { |row| row.is_a?(Array) && row.all? { |cell| cell == target } }
    end

    # ====== Help ======

    def generate_help(puzzle)
      generate_structured_help(puzzle)[:message]
    end

    def generate_structured_help(puzzle)
      case puzzle.puzzle_type
      when 'symbol_grid'
        generate_symbol_grid_help(puzzle)
      when 'pipe_network'
        generate_pipe_network_help(puzzle)
      when 'toggle_matrix'
        generate_toggle_matrix_help(puzzle)
      else
        { message: "Study the puzzle carefully." }
      end
    end

    # Help: reveal multiple symbols based on puzzle size
    def generate_symbol_grid_help(puzzle)
      solution = puzzle.solution
      existing_clues = puzzle.clues || []
      size = puzzle.grid_size
      clue_set = Set.new(existing_clues.map { |c| "#{c['x'] || c[:x]},#{c['y'] || c[:y]}" })

      candidates = []
      size.times do |y|
        size.times do |x|
          candidates << [x, y] unless clue_set.include?("#{x},#{y}")
        end
      end

      if candidates.empty?
        return { message: "All cells have been revealed!" }
      end

      count = [help_count(puzzle), candidates.size].min
      selected = candidates.sample(count)

      new_clues = selected.map do |x, y|
        { 'x' => x, 'y' => y, 'symbol' => solution[y][x], 'locked' => true }
      end

      positions = selected.map { |x, y| "(#{x + 1}, #{y + 1})" }.join(', ')
      symbols = new_clues.map { |c| "'#{c['symbol']}'" }.join(', ')
      msg = if count == 1
              "A symbol is revealed at position #{positions} \u2014 it's #{symbols}."
            else
              "Symbols are revealed at positions #{positions} \u2014 #{symbols}."
            end

      { message: msg, new_clues: new_clues }
    end

    # Help: correct multiple pipes on the solution path to their correct orientation
    def generate_pipe_network_help(puzzle)
      solution = puzzle.solution
      return { message: "Try rotating the pipes to connect source to drain." } unless solution

      size = puzzle.grid_size
      initial = puzzle.puzzle_data['initial']
      return { message: "Try rotating the pipes to connect source to drain." } unless initial

      locked_set = Set.new((puzzle.puzzle_data['locked_pipes'] || []).map { |c| "#{c['x']},#{c['y']}" })

      # Only help pipes on the solution path (BFS through solution grid)
      path_cells = solution_path_cells(puzzle)

      # Find path pipes that aren't at the correct rotation and aren't locked
      candidates = []
      path_cells.each do |py, px|
        next if locked_set.include?("#{px},#{py}")

        sol_pipe = solution[py][px]
        sol_rot = sol_pipe.is_a?(Hash) ? (sol_pipe['rotation'] || sol_pipe[:rotation] || 0) : 0
        cur_pipe = initial[py][px]
        cur_rot = cur_pipe.is_a?(Hash) ? (cur_pipe['rotation'] || cur_pipe[:rotation] || 0) : 0
        pipe_type = sol_pipe.is_a?(Hash) ? (sol_pipe['type'] || sol_pipe[:type]) : sol_pipe.to_s

        period = pipe_type == 'straight' ? 2 : 4
        candidates << [px, py, sol_rot] unless (cur_rot % period) == (sol_rot % period)
      end

      if candidates.empty?
        return { message: "All pipes on the path are already correctly oriented!" }
      end

      count = [help_count(puzzle), candidates.size].min
      selected = candidates.sample(count)

      # Update the initial layout and lock the corrected pipes
      data = JSON.parse(puzzle.puzzle_data.to_json)
      corrected = data['initial']
      new_locked = []

      selected.each do |x, y, sol_rot|
        pipe = corrected[y][x]
        if pipe.is_a?(Hash)
          pipe['rotation'] = sol_rot
        else
          corrected[y][x] = { 'type' => pipe.to_s, 'rotation' => sol_rot }
        end
        new_locked << { 'x' => x, 'y' => y }
      end

      data['initial'] = corrected
      data['locked_pipes'] = (data['locked_pipes'] || []) + new_locked
      puzzle.update(puzzle_data: Sequel.pg_jsonb_wrap(data))

      positions = selected.map { |x, y, _| "(#{x + 1}, #{y + 1})" }.join(', ')
      msg = if count == 1
              "A pipe at position #{positions} clicks into the correct orientation."
            else
              "Pipes at positions #{positions} click into the correct orientation."
            end

      { message: msg }
    end

    # BFS through the solution grid to find cells on the correct path
    def solution_path_cells(puzzle)
      solution = puzzle.solution
      size = puzzle.grid_size
      source = puzzle.puzzle_data['source']
      drain = puzzle.puzzle_data['drain']
      return [] unless solution && source && drain

      visited = Set.new(["#{source[0]},#{source[1]}"])
      queue = [source]
      parent = {}

      while queue.any?
        y, x = queue.shift

        if y == drain[0] && x == drain[1]
          # Trace back from drain to source
          path = [[y, x]]
          while parent["#{path.last[0]},#{path.last[1]}"]
            path << parent["#{path.last[0]},#{path.last[1]}"]
          end
          return path
        end

        cell = solution[y] && solution[y][x]
        next unless cell.is_a?(Hash)

        type = cell['type'] || 'straight'
        rot = (cell['rotation'] || 0).to_i
        conns = pipe_connection_vectors(type, rot)

        conns.each do |dy, dx|
          ny, nx = y + dy, x + dx
          next unless ny >= 0 && ny < size && nx >= 0 && nx < size
          key = "#{ny},#{nx}"
          next if visited.include?(key)

          ncell = solution[ny] && solution[ny][nx]
          next unless ncell.is_a?(Hash)

          ntype = ncell['type'] || 'straight'
          nrot = (ncell['rotation'] || 0).to_i
          nconns = pipe_connection_vectors(ntype, nrot)
          next unless nconns.include?([-dy, -dx])

          visited.add(key)
          parent[key] = [y, x]
          queue << [ny, nx]
        end
      end

      [] # No path found (shouldn't happen with valid puzzle)
    end

    # Help: lock multiple OFF cells to ON permanently
    def generate_toggle_matrix_help(puzzle)
      initial = puzzle.puzzle_data['initial']
      locked = puzzle.puzzle_data['locked'] || []
      locked_set = Set.new(locked.map { |c| "#{c['x']},#{c['y']}" })

      return { message: "All cells are already lit!" } unless initial

      # Find cells that are OFF and not already locked
      candidates = []
      initial.each_with_index do |row, y|
        row.each_with_index do |cell, x|
          candidates << [x, y] if cell == false && !locked_set.include?("#{x},#{y}")
        end
      end

      if candidates.empty?
        return { message: "All cells are already lit or locked!" }
      end

      count = [help_count(puzzle), candidates.size].min
      selected = candidates.sample(count)

      # Lock the cells to ON: update initial state and record locks
      data = JSON.parse(puzzle.puzzle_data.to_json)
      new_locked = []

      selected.each do |x, y|
        data['initial'][y][x] = true
        new_locked << { 'x' => x, 'y' => y }
      end

      data['locked'] = (data['locked'] || []) + new_locked
      puzzle.update(puzzle_data: Sequel.pg_jsonb_wrap(data))

      positions = selected.map { |x, y| "(#{x + 1}, #{y + 1})" }.join(', ')
      msg = if count == 1
              "A cell at position #{positions} locks into the ON position!"
            else
              "Cells at positions #{positions} lock into the ON position!"
            end

      { message: msg, locked_cells: new_locked.map { |c| { x: c['x'], y: c['y'] } } }
    end
  end
end
