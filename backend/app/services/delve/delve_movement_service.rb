# frozen_string_literal: true

require_relative '../concerns/result_handler'
require_relative '../concerns/delve_guards'
require_relative '../../helpers/canvas_helper'

# Handles movement within a delve, including time costs and level transitions.
class DelveMovementService
  extend ResultHandler
  extend DelveGuards

  class << self
    # Move a participant in a direction
    # @param participant [DelveParticipant]
    # @param direction [String] north/south/east/west or down
    # @param trap_pulse [Integer, nil] if attempting to pass a trap, the chosen pulse
    # @param trap_sequence_start [Integer, nil] the trap sequence start tick
    # @return [Result]
    def move!(participant, direction, trap_pulse: nil, trap_sequence_start: nil)
      guard = validate_for_movement(participant)
      return guard if guard

      delve = participant.delve
      current_room = participant.current_room
      direction = CanvasHelper.normalize_direction(direction)

      # Handle going down (level transition)
      if direction == 'down'
        return descend!(participant)
      end

      # Check for valid exit
      unless current_room.available_exits.include?(direction)
        return error("You can't go that way. Exits: #{current_room.available_exits.join(', ')}")
      end

      # Find target room
      target_room = delve.adjacent_room(current_room, direction)
      return error("There's nothing that way.") unless target_room

      # Check for uncleared blocker in this direction (either edge of the connection)
      blocker = delve.blocker_at(current_room, direction)
      if blocker && !blocker.cleared?
        # Gap/narrow: allow passage if participant has already crossed
        unless blocker.causes_damage_on_fail? && participant.has_cleared_blocker?(blocker.id)
          stat = blocker.stat_for_check
          dc = blocker.effective_difficulty
          return error(
            "A #{blocker.blocker_type.tr('_', ' ')} blocks the way #{direction}. " \
            "(#{stat} DC #{dc}) Use 'cross #{direction[0]}' to attempt it, or 'easier #{direction[0]}' to lower the DC."
          )
        end
      end

      # Check for unsolved puzzle blocking this direction
      puzzle = delve.respond_to?(:puzzle_blocking_at) ?
        delve.puzzle_blocking_at(current_room, direction) :
        DelvePuzzle.first(delve_room_id: current_room.id, solved: false)
      if puzzle
        puzzle_name = puzzle.puzzle_type.tr('_', ' ')
        return error(
          "A #{puzzle_name} puzzle blocks the way #{direction}. " \
          "(Difficulty: #{puzzle.difficulty}) Use 'study puzzle' to examine it, or 'solve <answer>' to attempt it."
        )
      end

      # Initialize trap tracking variables (may be set below if trap present)
      trap_message = nil
      trap_damage = 0

      # Check for trap in this direction
      trap = delve.respond_to?(:trap_at) ?
        delve.trap_at(current_room, direction) :
        DelveTrapService.trap_in_direction(current_room, direction)

      if trap && !trap.disabled?
        # If no pulse chosen, show the trap and wait for timing choice
        unless trap_pulse
          return show_trap_challenge(participant, trap, direction)
        end

        # Attempting to pass through trap
        trap_result = DelveTrapService.attempt_passage!(
          participant, trap, trap_pulse, trap_sequence_start
        )

        # Lethal trap damage ends the run immediately.
        if trap_result.data[:defeated] || (participant.is_a?(DelveParticipant) && !participant.active?)
          return Result.new(
            success: false,
            message: trap_result.message,
            data: trap_result.data.merge(defeated: true)
          )
        end

        unless trap_result.success
          return Result.new(
            success: false,
            message: trap_result.message,
            data: trap_result.data
          )
        end

        # Even if damaged, continue with movement
        trap_message = trap_result.message
        trap_damage = trap_result.data[:damage] || 0
      end

      # Monsters in the room being left may immediately pursue into the destination.
      # This is deterministic pursuit for retreat/follow behavior; roaming remains random.
      pursuers = monsters_in_room_safe(delve, current_room).select(&:active?)

      # Spend time for movement
      move_time = Delve.action_time_seconds(:move) || Delve::ACTION_TIMES_SECONDS[:move]
      time_result = participant.spend_time_seconds!(move_time)
      if time_result == :time_expired
        return Result.new(
          success: false,
          message: "Time has run out! You collapse from exhaustion in the darkness.",
          data: { time_expired: true, participant: participant }
        )
      end

      # Move to room
      participant.move_to_room!(target_room)

      # Update character's real room reference
      if target_room.room_id
        participant.character_instance.update(current_room_id: target_room.room_id)
      end

      followed_monsters = pursue_monsters_to_room!(pursuers, target_room)
      pursuit_message = pursuit_message_for(followed_monsters)

      # Check for auto-combat (pass travel direction so placement is correct)
      combat_result = DelveCombatService.check_auto_combat!(delve, participant, target_room, entry_direction: direction)

      if combat_result
        # Combat started - show combat menu instead of room description
        fight = Fight[combat_result[:fight_id]]
        fight_participant = fight.fight_participants.find { |fp| fp.character_instance_id == participant.character_instance_id }

        # Show combat menu
        menu_data = CombatQuickmenuHandler.show_menu(fight_participant, participant.character_instance)

        combat_parts = []
        combat_parts << trap_message if trap_message
        combat_parts << "You move #{direction}."
        combat_parts << pursuit_message if pursuit_message
        combat_message = combat_parts.join("\n\n")

        return Result.new(
          success: true,
          message: combat_message,
          data: {
            room: target_room,
            direction: direction,
            time_remaining: participant.time_remaining_seconds,
            combat_started: true,
            fight_id: fight.id,
            quickmenu: menu_data,
            trap_damage: trap_damage
          }
        )
      end

      # Build response (no combat)
      room_description = build_room_description(target_room, participant)

      # Include trap result in message if applicable
      movement_parts = []
      movement_parts << trap_message if trap_message
      movement_parts << "You move #{direction}."
      movement_parts << pursuit_message if pursuit_message
      movement_msg = movement_parts.join("\n\n")

      Result.new(
        success: true,
        message: "#{movement_msg}\n\n#{room_description}",
        data: {
          room: target_room,
          direction: direction,
          time_remaining: participant.time_remaining_seconds,
          trap_damage: trap_damage
        }
      )
    end

    # Show trap challenge when moving into a trapped direction
    # @return [Result] with trap_challenge flag
    def show_trap_challenge(participant, trap, direction)
      sequence_data = DelveTrapService.get_initial_sequence(trap, participant.id)
      experienced = participant.has_passed_trap?(trap.id)

      hint = if experienced
               "You've passed this trap before - only your chosen beat needs to be safe."
             else
               "First time through - your chosen beat AND the next beat must both be safe!"
             end

      Result.new(
        success: false,
        message: "A trap blocks the way #{direction}!\n\n#{trap.description}\n\n#{hint}\n\n" \
                 "#{sequence_data[:formatted]}\n\n" \
                 "<span class=\"opacity-70\">Type <code>#{direction[0]} &lt;pulse#&gt;</code> to pass through at that pulse, " \
                 "or <code>listen #{direction[0]}</code> to observe longer.</span>",
        data: {
          trap_challenge: true,
          trap_id: trap.id,
          direction: direction,
          sequence_start: sequence_data[:start_point],
          sequence_length: sequence_data[:length],
          experienced: experienced
        }
      )
    end

    # Descend to the next level
    # @param participant [DelveParticipant]
    # @return [Result]
    def descend!(participant)
      guard = validate_for_movement(participant)
      return guard if guard

      current_room = participant.current_room

      unless current_room.is_exit
        return error("There are no stairs here. Find the exit to descend.")
      end

      # Spend time
      move_time = Delve.action_time_seconds(:move) || Delve::ACTION_TIMES_SECONDS[:move]
      time_result = participant.spend_time_seconds!(move_time)
      if time_result == :time_expired
        return Result.new(
          success: false,
          message: "Time runs out as you reach the stairs! You collapse.",
          data: { time_expired: true }
        )
      end

      # Descend
      new_level = participant.descend_level!
      new_room = participant.current_room

      # Update character's real room reference
      if new_room&.room_id
        participant.character_instance.update(current_room_id: new_room.room_id)
      end

      room_description = build_room_description(new_room, participant)

      Result.new(
        success: true,
        message: "You descend the stairs to level #{new_level}.\n\n#{room_description}",
        data: {
          room: new_room,
          level: new_level,
          time_remaining: participant.time_remaining_seconds
        }
      )
    end

    # Get the current room description for a participant
    # @param participant [DelveParticipant]
    # @return [Result]
    def look(participant)
      guard = validate_for_action(participant)
      return guard if guard

      room = participant.current_room
      room_description = build_room_description(room, participant, verbose: true)

      Result.new(
        success: true,
        message: room_description,
        data: {
          room: room,
          exits: room.available_exits
        }
      )
    end

    # Build structured room data for the HUD action buttons and direction pad
    # @param participant [DelveParticipant]
    # @return [Hash] structured room data
    def build_current_room_data(participant)
      room = participant.current_room
      delve = participant.delve
      return {} unless room && delve

      # Gather room contents
      monsters = begin
        delve.monsters_in_room(room)
      rescue StandardError => e
        warn "[DelveMovementService] Failed to query monsters: #{e.message}"
        []
      end

      treasure = begin
        DelveTreasure.first(delve_room_id: room.id, looted: false)
      rescue StandardError => e
        warn "[DelveMovementService] Failed to query treasure: #{e.message}"
        nil
      end

      puzzle = begin
        DelvePuzzle.first(delve_room_id: room.id, solved: false)
      rescue StandardError => e
        warn "[DelveMovementService] Failed to query puzzle: #{e.message}"
        nil
      end

      # Build exit data with obstacle info
      exits = {}
      %w[north south east west].each do |dir|
        has_exit = room.available_exits.include?(dir)

        trap = if has_exit
                 begin
                   delve.respond_to?(:trap_at) ? delve.trap_at(room, dir) : DelveTrapService.trap_in_direction(room, dir)
                 rescue StandardError => e
                   warn "[DelveMovementService] Failed to query trap for #{dir}: #{e.message}"
                   nil
                 end
               end

        blocker_record = if has_exit
                           begin
                             delve.respond_to?(:blocker_at) ? delve.blocker_at(room, dir) :
                               DelveBlocker.first(delve_room_id: room.id, direction: dir, cleared: false)
                           rescue StandardError => e
                             warn "[DelveMovementService] Failed to query blocker for #{dir}: #{e.message}"
                             nil
                           end
                         end
        blocker_record = nil if blocker_record&.cleared?

        exit_data = { available: has_exit }
        if trap && !trap.disabled?
          exit_data[:trap] = { type: trap.trap_theme, damage: trap.damage }
        end
        if blocker_record
          exit_data[:blocker] = {
            type: blocker_record.blocker_type,
            dc: blocker_record.effective_difficulty,
            stat: blocker_record.stat_for_check.to_s.upcase
          }
        end
        # Check if current room has a puzzle blocking this direction
        puzzle_blocker = if has_exit
                           begin
                             delve.respond_to?(:puzzle_blocking_at) ? delve.puzzle_blocking_at(room, dir) : puzzle
                           rescue StandardError => e
                             warn "[DelveMovementService] Failed to query puzzle for #{dir}: #{e.message}"
                             nil
                           end
                         end
        if has_exit && puzzle_blocker
          exit_data[:puzzle] = {
            type: puzzle_blocker.puzzle_type.tr('_', ' '),
            difficulty: puzzle_blocker.difficulty
          }
        end

        # Show monsters in adjacent rooms
        if has_exit
          adjacent = delve.adjacent_room(room, dir)
          if adjacent
            adj_monsters = begin
              delve.monsters_in_room(adjacent)
            rescue StandardError => e
              warn "[DelveMovementService] Failed to get monsters in room: #{e.message}"
              []
            end
            if adj_monsters.any?
              exit_data[:monster] = adj_monsters.first.monster_type.capitalize
              exit_data[:monster_count] = adj_monsters.size
            elsif adjacent.has_monster?
              exit_data[:monster] = adjacent.monster_type&.capitalize
              exit_data[:monster_count] = 1
            end
          end
        end
        exits[dir.to_sym] = exit_data
      end

      # Add down exit if stairs present
      if room.respond_to?(:is_exit) && room.is_exit
        exits[:down] = { available: true }
      end

      {
        grid_x: room.grid_x,
        grid_y: room.grid_y,
        has_monster: monsters.any?,
        monster_name: monsters.first ? NamingHelper.titleize(monsters.first.monster_type) : nil,
        monster_names: monsters.map { |m| NamingHelper.titleize(m.monster_type) },
        has_treasure: !treasure.nil?,
        treasure_amount: treasure&.gold_value,
        has_puzzle: !puzzle.nil?,
        puzzle_type: puzzle&.puzzle_type&.tr('_', ' '),
        puzzle_difficulty: puzzle&.difficulty,
        puzzle_solved: puzzle.nil? ? nil : puzzle.solved?,
        hp_below_max: (participant.current_hp || 6) < (participant.max_hp || 6),
        willpower_dice: participant.willpower_dice || 0,
        can_study: monsters.any? { |m| !participant.has_studied?(m.monster_type) },
        exits: exits
      }
    end

    private

    def monsters_in_room_safe(delve, room)
      delve.monsters_in_room(room)
    rescue StandardError => e
      warn "[DelveMovementService] Failed to fetch monsters in room #{room&.id}: #{e.message}"
      []
    end

    def pursue_monsters_to_room!(monsters, destination_room)
      return [] if monsters.empty? || destination_room.nil?

      moved = []
      monsters.each do |monster|
        next unless monster
        next unless monster.active?

        move = monster.available_moves.find { |candidate| candidate[:room]&.id == destination_room.id }
        next unless move

        monster.move_to!(destination_room)
        moved << monster
      rescue StandardError => e
        warn "[DelveMovementService] Monster pursuit failed for #{monster&.id}: #{e.message}"
      end

      moved
    end

    def pursuit_message_for(monsters)
      return nil if monsters.empty?

      names = monsters.map(&:display_name).uniq.join(', ')
      if monsters.length == 1
        "#{names} follows after you."
      else
        "#{names} follow after you."
      end
    end

    def build_room_description(room, participant, verbose: false)
      delve = participant.delve
      parts = []

      # Room description
      parts << room.description_text

      # Show treasure immediately if present
      treasure = DelveTreasure.first(delve_room_id: room.id, looted: false)
      if treasure
        parts << ""
        parts << "<strong class=\"text-warning\">A #{treasure.container_type || 'treasure chest'} glints in the corner! (#{treasure.gold_value} gold)</strong>"
      end

      # Show monsters
      monsters = delve.monsters_in_room(room)
      monsters.each do |monster|
        parts << ""
        parts << "A #{NamingHelper.titleize(monster.monster_type)} lurks here!"
      end

      # Show obstacles (traps and blockers) per direction
      obstacle_descriptions = collect_obstacles(room, delve)
      if obstacle_descriptions.any?
        parts << ""
        obstacle_descriptions.each { |desc| parts << desc }
      end

      # Show puzzle if present
      puzzle = DelvePuzzle.first(delve_room_id: room.id, solved: false)
      if puzzle
        parts << ""
        dir_text = puzzle.direction ? " to the #{puzzle.direction}" : ""
        parts << "A #{puzzle.puzzle_type.tr('_', ' ')} puzzle blocks the way#{dir_text}. (Difficulty: #{puzzle.difficulty})"
      end

      # Exits with adjacent room info
      exits = room.available_exits
      if exits.any?
        parts << ""
        exit_details = exits.map do |dir|
          next "Down" if dir == 'down'

          adjacent = delve.adjacent_room(room, dir)
          suffix = nil
          if adjacent
            adj_monsters = delve.monsters_in_room(adjacent)
            if adj_monsters.any?
              names = adj_monsters.map { |m| m.monster_type.capitalize }.uniq.join(', ')
              suffix = "(#{names})"
            elsif adjacent.has_monster?
              suffix = "(#{adjacent.monster_type.capitalize})"
            end
          end
          suffix ? "#{dir.capitalize} #{suffix}" : dir.capitalize
        end
        parts << "Exits: #{exit_details.join(', ')}"
      end

      # Stairs indicator
      if room.is_exit
        parts << ""
        parts << "<strong>Stairs descend to the next level.</strong> <span class=\"opacity-50\">(down)</span>"
      end

      # Actions section (only on manual look, not auto-movement)
      if verbose
        actions = build_actions_list(room, participant, delve, treasure, monsters, puzzle)
        if actions.any?
          parts << ""
          parts << "Actions: #{actions.join(', ')}"
        end
      end

      parts.join("\n")
    end

    def collect_obstacles(room, delve = nil)
      descriptions = []
      delve ||= room.respond_to?(:delve) ? room.delve : nil
      exits = room.available_exits

      exits.each do |dir|
        next if dir == 'down'

        trap = if delve&.respond_to?(:trap_at)
                 delve.trap_at(room, dir)
               else
                 DelveTrapService.trap_in_direction(room, dir)
               end
        if trap
          descriptions << "#{dir.capitalize}: <strong class=\"text-warning\">Trap</strong> — #{trap.description} <span class=\"opacity-60\">(#{dir[0]} to attempt, study #{dir[0]} to observe)</span>"
          next
        end

        blocker = if delve&.respond_to?(:blocker_at)
                    delve.blocker_at(room, dir)
                  else
                    DelveBlocker.first(delve_room_id: room.id, direction: dir, cleared: false)
                  end
        if blocker && !blocker.cleared?
          stat = blocker.stat_for_check
          dc = blocker.effective_difficulty
          descriptions << "#{dir.capitalize}: <strong class=\"text-info\">#{NamingHelper.titleize(blocker.blocker_type)}</strong> — #{blocker.description} <span class=\"opacity-60\">(#{stat} DC #{dc})</span>"
        end
      end

      # Compatibility fallback for specs and edge cases where exits are not
      # populated but obstacle rows exist for the room.
      if descriptions.empty? && exits.empty?
        DelveTrap.where(delve_room_id: room.id, disabled: false).each do |trap|
          dir = trap.direction.to_s
          descriptions << "#{dir.capitalize}: <strong class=\"text-warning\">Trap</strong> — #{trap.description} <span class=\"opacity-60\">(#{dir[0]} to attempt, study #{dir[0]} to observe)</span>"
        end

        DelveBlocker.where(delve_room_id: room.id, cleared: false).each do |blocker|
          dir = blocker.direction.to_s
          stat = blocker.stat_for_check
          dc = blocker.effective_difficulty
          descriptions << "#{dir.capitalize}: <strong class=\"text-info\">#{NamingHelper.titleize(blocker.blocker_type)}</strong> — #{blocker.description} <span class=\"opacity-60\">(#{stat} DC #{dc})</span>"
        end
      end

      descriptions
    end

    def build_actions_list(room, participant, delve, treasure, monsters, puzzle)
      actions = []

      # Treasure
      actions << "grab" if treasure

      # Monster actions
      if monsters.any?
        actions << "fight"
        monsters.map { |m| m.monster_type.downcase }.uniq.each do |mt|
          actions << "study #{mt}" unless participant.has_studied?(mt)
        end
      end

      # Obstacle actions
      room.available_exits.each do |dir_name|
        next if dir_name == 'down'

        trap = delve.respond_to?(:trap_at) ? delve.trap_at(room, dir_name) : DelveTrapService.trap_in_direction(room, dir_name)
        actions << "#{dir_name[0]} <pulse#>" if trap
      end

      room.available_exits.each do |dir_name|
        next if dir_name == 'down'

        blocker = delve.respond_to?(:blocker_at) ? delve.blocker_at(room, dir_name) : DelveBlocker.first(delve_room_id: room.id, direction: dir_name, cleared: false)
        next unless blocker && !blocker.cleared?

        dir = dir_name[0]
        actions << "cross #{dir}"
        actions << "easier #{dir}"
      end

      # Puzzle
      if puzzle
        actions << "study puzzle"
        actions << "solve <answer>"
      end

      # Always available
      actions << "recover" if participant.current_hp < participant.max_hp
      actions << "focus" if (participant.willpower_dice || 0) < 3
      actions << "map"
      actions << "down" if room.is_exit

      actions.uniq
    end

  end
end
