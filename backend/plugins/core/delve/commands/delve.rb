# frozen_string_literal: true

module Commands
  module Delve
    # Delve command - procedural dungeon exploration with timed challenges.
    #
    # Subcommands:
    # - enter [name] : Create or enter a dungeon
    # - n/s/e/w      : Move in a direction (traps block movement until timed)
    # - down         : Descend to the next level
    # - map          : Show the minimap
    # - grab/take    : Collect visible treasure
    # - fight        : Fight a monster
    # - status       : Show current stats
    # - flee         : Exit the dungeon
    class DelveCommand < Commands::Base::Command
      command_name 'delve'
      aliases 'dv'
      category :navigation
      help_text 'Explore procedural dungeons with time limits and fog of war'
      usage 'delve <subcommand> [args]'
      examples(
        'delve enter Dark Cave',
        'delve n',
        'delve map',
        'delve grab',
        'delve fight',
        'delve flee'
      )

      requires_alive

      SUBCOMMANDS = %w[enter n s e w north south east west down d map fullmap fight status flee look l recover rest focus study easier listen go grab take solve help cross jump break pick].freeze
      DIRECTION_ALIASES = {
        'n' => 'north',
        's' => 'south',
        'e' => 'east',
        'w' => 'west'
      }.freeze

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]&.strip || ''
        cmd_word = parsed_input[:command_word]&.downcase

        # When invoked via contextual alias (e.g., "cross e" or "easier e"),
        # cmd_word is the subcommand and text is the argument.
        if cmd_word && cmd_word != 'delve' && cmd_word != 'dv' && SUBCOMMANDS.include?(cmd_word)
          subcommand = cmd_word
          args = text.empty? ? nil : text
        else
          parts = text.split(/\s+/, 2)
          subcommand = parts[0]&.downcase
          args = parts[1]
        end

        # No arguments: show status if in delve, otherwise show help
        unless subcommand && !subcommand.empty?
          return participant ? show_delve_dashboard : show_help
        end

        case subcommand
        when 'enter'
          handle_enter(args)
        when 'n', 's', 'e', 'w', 'north', 'south', 'east', 'west'
          handle_move(DIRECTION_ALIASES[subcommand] || subcommand, args)
        when 'down', 'd'
          handle_down
        when 'map'
          handle_map
        when 'fullmap'
          handle_fullmap
        when 'fight'
          handle_fight
        when 'status'
          handle_status
        when 'flee', 'exit', 'leave'
          handle_flee
        when 'look', 'l'
          handle_look
        when 'recover', 'rest'
          handle_recover
        when 'focus'
          handle_focus
        when 'study'
          handle_study(args)
        when 'easier'
          handle_easier(args)
        when 'listen'
          handle_listen(args)
        when 'go'
          handle_go(args)
        when 'grab', 'take'
          handle_grab
        when 'solve'
          handle_solve(args)
        when 'help'
          handle_help
        when 'cross', 'jump', 'break', 'pick'
          handle_cross(args)
        else
          error_result("Unknown subcommand: #{subcommand}. Try: enter, n/s/e/w, map, grab, fight, recover, focus, study, status, flee")
        end
      end

      private

      # Build common delve response data including map SVG, current room, and stats
      # @param participant_to_use [DelveParticipant] the participant to build data for
      # @return [Hash] structured response data
      def build_delve_response_data(participant_to_use)
        p = participant_to_use || participant

        map_data = begin
          DelveMapService.render_minimap(p)
        rescue StandardError => e
          warn "[DelveCommand] Failed to render minimap: #{e.message}"
          nil
        end

        map_result = begin
          DelveMapPanelService.render(participant: p)
        rescue StandardError => e
          warn "[DelveCommand] Failed to render delve map: #{e.message}"
          { svg: nil }
        end

        room_data = begin
          DelveMovementService.build_current_room_data(p)
        rescue StandardError => e
          warn "[DelveCommand] Failed to build room data: #{e.message}"
          {}
        end

        data = {
          map: map_data,
          delve_map_svg: map_result[:svg],
          current_room: room_data,
          in_delve: true
        }

        data[:delve_name] = p.delve&.name
        data[:current_level] = p.current_level
        data[:time_remaining] = p.time_remaining_seconds
        data[:current_hp] = p.current_hp
        data[:max_hp] = p.max_hp
        data[:willpower_dice] = p.willpower_dice
        data[:loot_collected] = p.loot_collected

        data
      end

      # Show a rich dashboard with status and available actions when in a delve
      def show_delve_dashboard
        delve = participant.delve
        room = participant.current_room

        # Basic stats
        hp_display = "#{participant.current_hp || 6}/#{participant.max_hp || 6}"
        willpower_display = participant.willpower_dice || 0
        remaining_secs = participant.time_remaining_seconds || 0
        time_mins = remaining_secs / 60
        time_secs = remaining_secs % 60

        # Build direction info
        direction_lines = []
        %w[north east south west].each do |dir|
          short = dir[0].upcase

          # Check for blocker
          blocker = begin
            participant.delve&.blocker_at(room, dir)
          rescue StandardError => e
            warn "[DelveCommand] Failed to check blocker for room #{room&.id} dir #{dir}: #{e.message}"
            nil
          end
          blocker = nil if blocker&.cleared?

          if blocker
            stat = blocker.stat_for_check
            dc = blocker.effective_difficulty
            direction_lines << "[#{short}] #{dir.capitalize} - Blocked (#{stat} DC #{dc})"
          elsif begin
                  connection_trap(room, dir)
                rescue StandardError => e
                  warn "[DelveCommand] Failed to check trap for room #{room&.id} dir #{dir}: #{e.message}"
                  nil
                end
            direction_lines << "[#{short}] #{dir.capitalize} - Trap detected!"
          elsif begin
                  connection_puzzle(room, dir)
                rescue StandardError => e
                  warn "[DelveCommand] Failed to check puzzle for room #{room&.id} dir #{dir}: #{e.message}"
                  nil
                end
            direction_lines << "[#{short}] #{dir.capitalize} - Puzzle blocks passage"
          else
            # Check if there's a valid exit in this direction
            exit_room = begin
              room.adjacent_room(dir)
            rescue StandardError => e
              warn "[DelveCommand] Failed to get adjacent room for #{dir}: #{e.message}"
              nil
            end
            if exit_room
              direction_lines << "[#{short}] #{dir.capitalize} - Clear ✓"
            end
          end
        end

        # Check for down exit
        if room.has_stairs_down?
          direction_lines << "[D] Down - Stairs to level #{(participant.current_level || 1) + 1}"
        end

        # Build room contents
        contents = []
        if room.has_monster?
          contents << "⚔ Monster: #{room.monster_type}"
        end
        treasure = begin
          DelveTreasure.first(delve_room_id: room.id)
        rescue StandardError => e
          warn "[DelveCommand] Failed to query treasure: #{e.message}"
          nil
        end
        if treasure && !treasure.looted?
          contents << "💰 Treasure available"
        end
        puzzle = begin
          active_puzzle_for_room(room)
        rescue StandardError => e
          warn "[DelveCommand] Failed to query puzzle: #{e.message}"
          nil
        end
        if puzzle && !puzzle.solved?
          contents << "🧩 Puzzle unsolved"
        end

        # Build actions list
        actions = []
        if room.has_monster?
          actions << "[fight] Attack the monster"
          actions << "[study #{room.monster_type}] Study for combat bonus"
        end
        if treasure && !treasure.looted?
          actions << "[grab] Collect treasure"
        end
        if puzzle && !puzzle.solved?
          actions << "[solve <answer>] Attempt puzzle"
        end
        if (participant.current_hp || 6) < (participant.max_hp || 6)
          actions << "[recover] Rest to full HP (5 min)"
        end
        actions << "[focus] Gain willpower die (30 sec)"
        actions << "[map] View minimap"
        actions << "[flee] Exit dungeon"

        # Build the dashboard
        dashboard = []
        dashboard << "<h3>#{delve.name}</h3>"
        dashboard << "<div>Level #{participant.current_level || 1} &middot; Time: <strong>#{format('%d:%02d', time_mins, time_secs)}</strong> &middot; HP: #{hp_display} &middot; Willpower: #{willpower_display} &middot; Loot: #{participant.loot_collected || 0}g</div>"

        if contents.any?
          dashboard << "<div class=\"divider my-1\"></div>"
          dashboard << "<div class=\"font-bold\">In this room:</div>"
          contents.each { |c| dashboard << "<div>#{c}</div>" }
        end

        if direction_lines.any?
          dashboard << "<div class=\"divider my-1\"></div>"
          dashboard << "<div class=\"font-bold\">Directions:</div>"
          direction_lines.each { |d| dashboard << "<div>#{d}</div>" }
        end

        dashboard << "<div class=\"divider my-1\"></div>"
        dashboard << "<div class=\"font-bold\">Actions:</div>"
        actions.each { |a| dashboard << "<div>#{a}</div>" }

        # Build quickmenu options from available state
        options = build_delve_quickmenu_options(room, treasure, puzzle)

        menu = create_quickmenu(character_instance, "What would you like to do?", options,
                                context: { command: 'delve' })

        success_result(
          dashboard.join("\n"),
          type: :message,
          data: build_delve_response_data(participant).merge(quickmenu: menu[:data])
        )
      end

      def show_help
        help_text = <<~HTML
          <h3>Delve Commands</h3>
          <div class="text-sm opacity-70 mb-2">While in a dungeon, you can use commands without the 'delve' prefix.</div>

          <div class="font-bold mt-2">Movement <span class="opacity-50">(10 sec each)</span></div>
          <div><code>n/s/e/w</code> Move in a direction</div>
          <div><code>down</code> Descend to the next level</div>
          <div><code>flee</code> Exit the dungeon</div>

          <div class="font-bold mt-2">Information</div>
          <div><code>look</code> Look at current room</div>
          <div><code>map</code> Show the minimap</div>
          <div><code>status</code> Show current stats</div>

          <div class="font-bold mt-2">Actions</div>
          <div><code>grab</code> Collect visible treasure (free)</div>
          <div><code>fight</code> Fight a monster (5 min)</div>
          <div><code>recover</code> Rest and heal to full HP (5 min)</div>
          <div><code>focus</code> Gain a willpower die (30 sec)</div>

          <div class="font-bold mt-2">Study <span class="opacity-50">(no time cost)</span></div>
          <div><code>study n/s/e/w</code> Study a trap or obstacle</div>
          <div><code>study puzzle</code> Study a puzzle in the room</div>
          <div><code>study [monster]</code> Study a monster for +2 combat bonus (1 min)</div>

          <div class="font-bold mt-2">Obstacles</div>
          <div><code>easier [dir]</code> Lower obstacle difficulty by 1 (30 sec)</div>
          <div><code>solve [answer]</code> Solve a puzzle (15 sec attempt)</div>

          <div class="font-bold mt-2">Traps</div>
          <div><code>listen [dir]</code> Observe trap timing longer (10 sec)</div>
          <div><code>[dir] [pulse#]</code> Pass through trap at that pulse (e.g. <code>s 4</code>)</div>
          <div class="text-sm opacity-70 ml-4">First time: chosen pulse AND next must be safe. Repeat: only your pulse.</div>
        HTML

        success_result(help_text.strip)
      end

      def build_delve_quickmenu_options(room, treasure, puzzle)
        options = []

        # Movement directions (only if there's an exit)
        %w[north east south west].each do |dir|
          exit_room = begin
            room.adjacent_room(dir)
          rescue StandardError => e
            warn "[DelveCommand] Failed to resolve adjacent room for quickmenu room #{room&.id} dir #{dir}: #{e.message}"
            nil
          end
          blocker = begin
            b = participant.delve&.blocker_at(room, dir)
            b && !b.cleared? ? b : nil
          rescue StandardError => e
            warn "[DelveCommand] Failed to check quickmenu blocker for room #{room&.id} dir #{dir}: #{e.message}"
            nil
          end
          next unless exit_room || blocker

          if blocker
            # Show cross/easier/wp buttons for blocked exits
            options << { key: nil, label: "Cross #{dir.capitalize}", description: "cross #{dir[0]}" }
            options << { key: nil, label: "Easier #{dir.capitalize} (DC #{blocker.effective_difficulty})", description: "easier #{dir[0]}" }
            if (participant.willpower_dice || 0) > 0
              options << { key: nil, label: "Cross #{dir.capitalize} + WP", description: "cross #{dir[0]} wp" }
            end
          elsif connection_trap(room, dir)
            label = "#{dir.capitalize} - Trap!"
            options << { key: dir[0], label: label, description: "delve #{dir}" }
          elsif connection_puzzle(room, dir)
            label = "#{dir.capitalize} - Puzzle"
            options << { key: nil, label: label, description: "study puzzle" }
          else
            options << { key: dir[0], label: dir.capitalize, description: "delve #{dir}" }
          end
        end

        if room.has_stairs_down?
          options << { key: 'd', label: 'Down', description: "delve down" }
        end

        # Context actions
        if room.has_monster?
          options << { key: 'f', label: 'Fight', description: "delve fight" }
        end
        if treasure && !treasure.looted?
          options << { key: 'g', label: 'Grab', description: "delve grab" }
        end
        if puzzle && !puzzle.solved?
          options << { key: 'p', label: 'Solve puzzle', description: "delve solve" }
        end
        if (participant.current_hp || 6) < (participant.max_hp || 6)
          options << { key: 'r', label: 'Recover', description: "delve recover" }
        end
        options << { key: 'o', label: 'Focus', description: "delve focus" }
        options << { key: 'm', label: 'Map', description: "delve map" }
        options << { key: 'x', label: 'Flee', description: "delve flee" }

        options
      end

      def participant
        @participant ||= DelveParticipant.where(character_instance_id: character_instance.id)
                                          .where(status: 'active')
                                          .eager(:delve)
                                          .first
      end

      def handle_enter(name)
        # Check if already in a delve
        if participant
          return error_result("You are already exploring #{participant.delve.name}! Use 'delve flee' to exit first.")
        end

        # Clean up any zombie delves stuck in 'generating' status
        cleanup_zombie_delves!

        name = name&.strip
        name = "Mysterious Dungeon" if name.nil? || name.empty?

        delve = nil
        begin
          # Create the delve
          delve = ::Delve.create(
            name: name,
            difficulty: 'normal',
            time_limit_minutes: 60,
            grid_width: 15,
            grid_height: 15,
            levels_generated: 1,
            seed: rand(1_000_000)
          )

          # Generate first level
          DelveGeneratorService.generate_level!(delve, 1)

          # Find entrance
          entrance = delve.entrance_room(1)
          unless entrance
            delve.update(status: 'failed')
            return error_result("Failed to generate dungeon. Please try again.")
          end

          # Create participant
          new_participant = DelveParticipant.create(
            delve_id: delve.id,
            character_instance_id: character_instance.id,
            status: 'active',
            current_level: 1,
            current_delve_room_id: entrance.id,
            time_spent_minutes: 0,
            loot_collected: 0,
            rooms_explored: 1,
            monsters_killed: 0,
            traps_triggered: 0,
            damage_taken: 0
          )

          # Store pre-delve room and move character to real entrance room
          new_participant.update(pre_delve_room_id: character_instance.current_room_id)

          delve.start!

          if entrance.room_id
            character_instance.update(current_room_id: entrance.room_id)
          end

          entrance.update(explored: true)

          # Get initial room description
          look_result = DelveMovementService.look(new_participant)

          success_result(
            "You enter #{name}...\n\n#{look_result.message}",
            type: :message,
            data: build_delve_response_data(new_participant).merge(delve_id: delve.id)
          )
        rescue StandardError => e
          warn "[DelveCommand] Failed to create delve: #{e.message}"
          warn e.backtrace.first(5).join("\n")
          delve&.update(status: 'failed') rescue nil
          error_result("Failed to generate dungeon. Please try again.")
        end
      end

      # Clean up delves stuck in 'generating' status (older than 5 minutes)
      def cleanup_zombie_delves!
        zombie_delves = ::Delve.where(status: 'generating')
                               .where { created_at < Time.now - 300 }
                               .all
        return if zombie_delves.empty?

        zombie_ids = zombie_delves.map(&:id)

        # Extract any participants stuck in these delves
        DelveParticipant.where(delve_id: zombie_ids, status: 'active')
                        .update(status: 'extracted')

        # Release temporary rooms back to pool
        zombie_delves.each do |zd|
          TemporaryRoomPoolService.release_delve_rooms(zd) rescue nil
        end

        # Mark as failed
        ::Delve.where(id: zombie_ids).update(status: 'failed')
        warn "[DelveCommand] Cleaned up #{zombie_ids.length} zombie delve(s)"
      end

      def handle_move(direction, pulse_arg = nil)
        return not_in_delve unless participant

        # If a pulse number is provided (e.g. "s 4"), treat as trap passage
        if pulse_arg && pulse_arg.strip =~ /\A\d+\z/
          return handle_go("#{direction} #{pulse_arg.strip}")
        end

        result = DelveMovementService.move!(participant, direction)

        # Trap challenge is returned as !success but contains HTML that
        # needs to render — route it through success_result instead of error_result
        if !result.success && result.data&.dig(:trap_challenge)
          return success_result(
            result.message,
            type: :message,
            data: result.data.merge(build_delve_response_data(participant))
          )
        end

        return error_result(result.message) unless result.success

        # Tick monster movement (10 seconds of travel time)
        # Skip if combat already started from entering the room
        collision_combat = nil
        unless result.data[:combat_started]
          collision_combat = tick_monsters_if_needed(movement_time_seconds)
        end

        reloaded = participant.reload

        # If a monster roamed into the player's room, show combat
        if collision_combat
          monster_names = collision_combat[:monster_names].join(', ')
          success_result(
            "#{result.message}<br><br><strong class=\"text-error\">COMBAT!</strong> #{monster_names} ambushes you!",
            type: :combat,
            data: result.data.merge(build_delve_response_data(reloaded)).merge(
              combat_started: true,
              fight_id: collision_combat[:fight_id],
              monster_names: collision_combat[:monster_names],
              quickmenu: collision_combat[:quickmenu]
            )
          )
        else
          success_result(
            result.message,
            type: :message,
            data: result.data.merge(build_delve_response_data(reloaded))
          )
        end
      end

      def handle_down
        return not_in_delve unless participant

        result = DelveMovementService.descend!(participant)
        return error_result(result.message) unless result.success

        reloaded = participant.reload

        success_result(
          result.message,
          type: :message,
          data: result.data.merge(build_delve_response_data(reloaded))
        )
      end

      def handle_map
        return not_in_delve unless participant

        # The delve map is shown in the HUD panel - just refresh it silently
        success_result(
          "",
          type: :message,
          data: build_delve_response_data(participant)
        )
      end

      def handle_fullmap
        return not_in_delve unless participant

        map_data = DelveMapService.render_full_map(participant)

        success_result(
          "<h3>Explored Map</h3>",
          type: :message,
          data: { map: map_data }
        )
      end

      def handle_look
        return not_in_delve unless participant

        result = DelveMovementService.look(participant)
        return error_result(result.message) unless result.success

        success_result(
          result.message,
          type: :message,
          data: result.data.merge(build_delve_response_data(participant))
        )
      end

      def handle_fight
        return not_in_delve unless participant

        delve = participant.delve
        room = participant.current_room

        # Check if already in combat - reopen combat menu instead of error
        active_fight = FightService.find_active_fight(participant.character_instance)
        if active_fight
          OutputHelper.clear_pending_interactions(participant.character_instance.id)
          fight_participant = active_fight.fight_participants.find { |fp| fp.character_instance_id == participant.character_instance_id }
          return error_result("You're in a fight but not participating!") unless fight_participant

          menu_data = CombatQuickmenuHandler.show_menu(fight_participant, participant.character_instance)
          return success_result(
            "You're already in combat. Here's the combat menu.",
            type: :combat,
            data: {
              fight_id: active_fight.id,
              quickmenu: menu_data
            }
          )
        end

        # Fast-fail when there is no threat in the room.
        monsters = delve.monsters_in_room(room)
        if monsters.empty? && !room.has_monster?
          return error_result("There's nothing to fight here.")
        end

        # Start combat via auto-combat path so static room monsters get spawned
        # into DelveMonster records consistently with movement-triggered combat.
        combat_result = DelveCombatService.check_auto_combat!(delve, participant, room)

        if combat_result.nil?
          return error_result("Unable to start combat - no valid room found. Try moving to another room.")
        end

        fight = Fight[combat_result[:fight_id]]
        fight_participant = fight.fight_participants.find { |fp| fp.character_instance_id == participant.character_instance_id }

        # Show combat menu
        menu_data = CombatQuickmenuHandler.show_menu(fight_participant, participant.character_instance)

        monster_names = combat_result[:monster_names].join(', ')
        success_result(
          "<strong class=\"text-error\">COMBAT!</strong> You engage #{monster_names}!",
          type: :combat,
          data: {
            fight_id: fight.id,
            monster_names: combat_result[:monster_names],
            monster_count: combat_result[:monster_count],
            quickmenu: menu_data
          }
        )
      end

      def handle_status
        return not_in_delve unless participant

        result = DelveActionService.status(participant)

        if result.success
          success_result(
            result.message,
            type: :message,
            data: result.data
          )
        else
          error_result(result.message)
        end
      end

      def handle_flee
        return not_in_delve unless participant

        result = DelveActionService.flee!(participant)

        if result.success
          success_result(
            result.message,
            type: :message,
            data: result.data
          )
        else
          error_result(result.message)
        end
      end

      def not_in_delve
        error_result("You're not currently in a delve. Use 'delve enter [name]' to start.")
      end

      # ====== New Action Handlers ======

      def handle_recover
        return not_in_delve unless participant

        result = DelveActionService.recover!(participant)
        collision = nil
        if result.success
          collision = tick_monsters_if_needed(::Delve.action_time_seconds(:recover) || ::Delve::ACTION_TIMES_SECONDS[:recover])
        end

        respond(result, collision_combat: collision)
      end

      def handle_focus
        return not_in_delve unless participant

        result = DelveActionService.focus!(participant)
        collision = nil
        if result.success
          collision = tick_monsters_if_needed(::Delve.action_time_seconds(:focus) || ::Delve::ACTION_TIMES_SECONDS[:focus])
        end

        respond(result, collision_combat: collision)
      end

      def handle_study(target)
        return not_in_delve unless participant
        return error_result("Study what? Specify a direction (n/s/e/w), puzzle, or monster type.") if target.nil? || target.strip.empty?

        target_str = target.strip.downcase
        room = participant.current_room
        delve = participant.delve

        # Check if target is a direction (trap or blocker)
        direction = DIRECTION_ALIASES[target_str] || target_str
        if %w[north south east west n s e w].include?(target_str)
          return study_direction(room, direction)
        end

        # Check if target is "puzzle"
        if target_str == 'puzzle'
          return study_puzzle(room)
        end

        # Otherwise treat as monster type
        study_monster(delve, room, target_str)
      end

      def study_direction(room, direction)
        direction = DIRECTION_ALIASES[direction] || direction

        # Check for trap in this direction
        trap = connection_trap(room, direction)
        if trap && !trap.disabled?
          sequence_data = DelveTrapService.get_initial_sequence(trap, participant.id)
          experienced = participant.has_passed_trap?(trap.id)

          hint = if experienced
                   "You've passed this trap before - only your chosen pulse needs to be safe."
                 else
                   "First time through - your chosen pulse AND the next must both be safe!"
                 end

          return success_result(
            "You study the trap to the #{direction}...\n\n" \
            "#{trap.description}\n\n" \
            "#{sequence_data[:formatted]}\n\n#{hint}\n\n" \
            "<span class=\"opacity-70\">Type <code>#{direction[0]} &lt;pulse#&gt;</code> to pass through, " \
            "or <code>listen #{direction[0]}</code> to observe longer.</span>",
            type: :message,
            data: sequence_data.merge(direction: direction, type: :trap)
          )
        end

        # Check for blocker in this direction
        blocker = delve.blocker_at(room, direction)
        if blocker && !blocker.cleared?
          stat = blocker.stat_for_check
          dc = blocker.effective_difficulty

          return success_result(
            "You study the obstacle to the #{direction}...\n\n" \
            "#{blocker.description}\n\n" \
            "Type: #{NamingHelper.titleize(blocker.blocker_type)}\n" \
            "Skill Check: #{stat} vs DC #{dc}\n" \
            "Easier attempts: #{blocker.easier_attempts || 0}\n\n" \
            "Move #{direction[0]} to attempt, or use 'easier #{direction[0]}' to lower the DC by 1.",
            type: :message,
            data: { direction: direction, type: :blocker, dc: dc, stat: stat }
          )
        end

        puzzle = connection_puzzle(room, direction)
        if puzzle
          return success_result(
            "A puzzle blocks movement to the #{direction}. Use <code>study puzzle</code> to inspect it, " \
            "or <code>solve &lt;answer&gt;</code> to attempt a solution.",
            type: :message,
            data: { direction: direction, type: :puzzle, difficulty: puzzle.difficulty }
          )
        end

        error_result("There's nothing blocking the way #{direction}.")
      end

      def study_puzzle(room)
        puzzle = active_puzzle_for_room(room)

        unless puzzle
          return error_result("There's no puzzle in this room.")
        end

        if puzzle.solved?
          return error_result("The puzzle has already been solved.")
        end

        display = begin
          DelvePuzzleService.get_display(puzzle)
        rescue StandardError => e
          warn "[DelveCommand] Failed to get puzzle display: #{e.message}"
          {}
        end

        success_result(
          puzzle.description,
          type: :puzzle,
          output_category: :info,
          data: display.merge(build_delve_response_data(participant))
        )
      end

      def study_monster(delve, room, target_type)
        monsters = delve.monsters_in_room(room)

        if monsters.empty?
          return error_result("There are no enemies here to study.")
        end

        monster = monsters.find { |m| m.monster_type.downcase == target_type }

        unless monster
          available = monsters.map(&:monster_type).uniq.join(', ')
          return error_result("No '#{target_type}' here. Available: #{available}")
        end

        result = DelveActionService.study!(participant, monster.monster_type)
        collision = nil
        if result.success
          collision = tick_monsters_if_needed(::Delve.action_time_seconds(:study) || ::Delve::ACTION_TIMES_SECONDS[:study])
        end

        respond(result, collision_combat: collision)
      end

      def delve
        participant&.delve
      end

      def handle_cross(direction)
        return not_in_delve unless participant
        return error_result("Which direction? Specify n/s/e/w.") if direction.nil? || direction.strip.empty?

        # Parse direction and optional willpower flag
        parts = direction.strip.downcase.split(/\s+/)
        dir = DIRECTION_ALIASES[parts[0]] || parts[0]
        use_wp = parts.include?('wp') || parts.include?('willpower')

        room = participant.current_room
        blocker = participant.delve.blocker_at(room, dir)

        unless blocker
          return error_result("There's no obstacle blocking the #{dir} exit.")
        end

        if blocker.cleared?
          return error_result("That obstacle has already been cleared. You can move #{dir[0]}.")
        end

        if use_wp && (participant.willpower_dice || 0) <= 0
          return error_result("You have no willpower dice. Use 'focus' to gain one.")
        end

        party_bonus = begin
          DelveSkillCheckService.party_bonus(participant, blocker)
        rescue StandardError => e
          warn "[DelveCommand] Failed to calculate party bonus: #{e.message}"
          0
        end

        result = DelveSkillCheckService.attempt!(
          participant,
          blocker,
          use_willpower: use_wp,
          party_bonus: party_bonus
        )

        if result.success
          # After clearing the obstacle, move through automatically
          move_result = DelveMovementService.move!(participant, dir)
          collision = tick_monsters_if_needed(skill_check_time_seconds) unless move_result.data&.dig(:combat_started)

          # Combine the cross message with the movement result
          combined_message = "#{result.message}<br><br>#{move_result.message}"

          reloaded = participant.reload
          base_data = (result.data || {}).merge(move_result.data || {}).merge(build_delve_response_data(reloaded))

          anim_data = nil
          roll_total = nil
          roll_modifier = nil
          if result.data[:roll_result]
            roll_result = result.data[:roll_result]
            anim_data = DiceRollService.generate_animation_data(
              roll_result,
              character_name: "skill check",
              color: 'w'
            )
            roll_total = roll_result.total
            roll_modifier = result.data.dig(:roll, :modifier) || 0
          end

          if collision
            monster_names = collision[:monster_names].join(', ')
            success_result(
              "#{combined_message}<br><br><strong class=\"text-error\">COMBAT!</strong> #{monster_names} ambushes you!",
              type: :combat,
              animation_data: anim_data,
              roll_total: roll_total,
              roll_modifier: roll_modifier,
              data: base_data.merge(
                combat_started: true,
                fight_id: collision[:fight_id],
                monster_names: collision[:monster_names],
                quickmenu: collision[:quickmenu]
              )
            )
          else
            success_result(
              combined_message,
              type: :message,
              animation_data: anim_data,
              roll_total: roll_total,
              roll_modifier: roll_modifier,
              data: base_data
            )
          end
        else
          respond_with_roll(result)
        end
      end

      def handle_easier(direction)
        return not_in_delve unless participant
        return error_result("Which direction? Specify n/s/e/w.") if direction.nil? || direction.strip.empty?

        direction = DIRECTION_ALIASES[direction.strip.downcase] || direction.strip.downcase
        blocker = participant.delve.blocker_at(participant.current_room, direction)

        unless blocker
          return error_result("There's no obstacle in that direction.")
        end

        if blocker.cleared?
          return error_result("That obstacle has already been cleared.")
        end

        result = DelveSkillCheckService.make_easier!(participant, blocker)
        collision = nil
        if result.success
          collision = tick_monsters_if_needed(::Delve.action_time_seconds(:easier) || ::Delve::ACTION_TIMES_SECONDS[:easier])
        end

        respond(result, collision_combat: collision)
      end

      def handle_listen(args)
        return not_in_delve unless participant

        room = participant.current_room
        direction = args&.strip&.downcase
        direction = DIRECTION_ALIASES[direction] || direction if direction

        # If no direction specified, list trapped directions
        unless direction
          trapped_dirs = trapped_directions(room)
          if trapped_dirs.empty?
            return error_result("There are no traps blocking exits from this room.")
          end
          return error_result("Specify a direction: delve listen <#{trapped_dirs.join('/')}>")
        end

        trap = connection_trap(room, direction)

        unless trap
          return error_result("There's no trap blocking the #{direction} exit.")
        end

        if trap.disabled?
          return error_result("The trap to the #{direction} has been disabled.")
        end

        # Get or extend trap sequence for this direction (persisted per participant)
        trap_state = participant.trap_observation_state(trap.id)

        if trap_state.nil?
          # First observation also costs listen time.
          time_result = participant.spend_time_seconds!(trap_listen_time_seconds)
          if time_result == :time_expired
            return error_result("Time runs out while you listen to the trap pattern!")
          end

          # First observation
          sequence_data = DelveTrapService.get_initial_sequence(trap, participant.id)
          if participant.respond_to?(:set_trap_observation_state!)
            participant.set_trap_observation_state!(
              trap.id,
              start: sequence_data[:start_point],
              length: sequence_data[:length]
            )
          end

          experienced = participant.has_passed_trap?(trap.id)
          hint = experienced ? "(Experienced: only chosen pulse needs to be safe)" : "(First time: chosen pulse AND next must be safe)"

          collision = tick_monsters_if_needed(trap_listen_time_seconds)
          payload = sequence_data.merge(direction: direction)

          if collision
            monster_names = collision[:monster_names].join(', ')
            reloaded = participant.reload
            success_result(
              "You observe the trap to the #{direction}...\n\n#{sequence_data[:formatted]}\n\n#{hint}\n\n" \
              "<span class=\"opacity-70\">Type <code>#{direction[0]} &lt;pulse#&gt;</code> to pass through, " \
              "or <code>listen #{direction[0]}</code> to observe longer.</span>" \
              "<br><br><strong class=\"text-error\">COMBAT!</strong> #{monster_names} ambushes you!",
              type: :combat,
              data: payload.merge(build_delve_response_data(reloaded)).merge(
                combat_started: true,
                fight_id: collision[:fight_id],
                monster_names: collision[:monster_names],
                quickmenu: collision[:quickmenu]
              )
            )
          else
            success_result(
              "You observe the trap to the #{direction}...\n\n#{sequence_data[:formatted]}\n\n#{hint}\n\n" \
              "<span class=\"opacity-70\">Type <code>#{direction[0]} &lt;pulse#&gt;</code> to pass through, " \
              "or <code>listen #{direction[0]}</code> to observe longer.</span>",
              type: :message,
              data: payload
            )
          end
        else
          # Extend observation
          start_point = trap_state['start'] || trap_state[:start]
          length = trap_state['length'] || trap_state[:length]
          result = DelveTrapService.listen_more!(participant, trap, start_point, length)
          if result.success && participant.respond_to?(:set_trap_observation_state!)
            participant.set_trap_observation_state!(
              trap.id,
              start: result.data[:start_point],
              length: result.data[:length]
            )
          end
          collision = nil
          collision = tick_monsters_if_needed(trap_listen_time_seconds) if result.success

          respond(result, collision_combat: collision)
        end
      end

      def handle_go(args)
        return not_in_delve unless participant
        return error_result("Usage: delve go <direction> <pulse>") if args.nil? || args.strip.empty?

        parts = args.strip.split(/\s+/)
        direction = parts[0]&.downcase
        direction = DIRECTION_ALIASES[direction] || direction
        pulse_str = parts[1]

        room = participant.current_room
        trap = connection_trap(room, direction)

        unless trap
          return error_result("There's no trap blocking the #{direction} exit.")
        end

        # If no pulse provided, show the sequence
        unless pulse_str
          sequence_data = DelveTrapService.get_initial_sequence(trap, participant.id)
          experienced = participant.has_passed_trap?(trap.id)
          hint = experienced ? "(Experienced: only chosen pulse needs to be safe)" : "(First time: chosen pulse AND next must be safe)"

          return success_result(
            "You study the trap to the #{direction}...\n\n#{sequence_data[:formatted]}\n\n#{hint}\n\n" \
            "<span class=\"opacity-70\">Type <code>#{direction[0]} &lt;pulse#&gt;</code> to pass through.</span>",
            type: :message,
            data: sequence_data.merge(direction: direction)
          )
        end

        pulse_num = pulse_str.to_i
        if pulse_num <= 0
          return error_result("Invalid pulse number. Use a positive integer.")
        end

        # Generate sequence with fixed seed so it's consistent with listen output
        start_range = GameConfig::DelveTrap::SEQUENCE_START_RANGE
        sequence_seed = trap.id * 1000 + participant.id
        sequence_start = start_range.min + (sequence_seed % start_range.size)

        # Attempt passage through the trap and move
        result = DelveMovementService.move!(
          participant,
          direction,
          trap_pulse: pulse_num,
          trap_sequence_start: sequence_start
        )

        if result.success
          participant.clear_trap_observation_state!(trap.id) if participant.respond_to?(:clear_trap_observation_state!)
          collision_combat = nil
          unless result.data[:combat_started]
            collision_combat = tick_monsters_if_needed(movement_time_seconds)
          end
          reloaded = participant.reload

          if collision_combat
            monster_names = collision_combat[:monster_names].join(', ')
            success_result(
              "#{result.message}<br><br><strong class=\"text-error\">COMBAT!</strong> #{monster_names} ambushes you!",
              type: :combat,
              data: result.data.merge(build_delve_response_data(reloaded)).merge(
                combat_started: true,
                fight_id: collision_combat[:fight_id],
                monster_names: collision_combat[:monster_names],
                quickmenu: collision_combat[:quickmenu]
              )
            )
          else
            success_result(
              result.message,
              type: :message,
              data: result.data.merge(build_delve_response_data(reloaded))
            )
          end
        else
          error_result(result.message)
        end
      end

      def handle_grab
        return not_in_delve unless participant

        room = participant.current_room
        treasure = DelveTreasure.first(delve_room_id: room.id)

        unless treasure
          return error_result("There's no treasure here to grab.")
        end

        result = DelveTreasureService.loot!(participant, treasure)

        respond(result)
      end

      def handle_solve(answer)
        return not_in_delve unless participant

        room = participant.current_room
        puzzle = active_puzzle_for_room(room)

        unless puzzle
          return error_result("There's no puzzle here to solve.")
        end

        if puzzle.solved?
          return error_result("The puzzle has already been solved.")
        end

        if answer.nil? || answer.strip.empty?
          # No answer provided — open the puzzle UI instead
          return study_puzzle(room)
        end

        parsed = parse_puzzle_answer(answer.strip)
        result = DelvePuzzleService.attempt!(participant, puzzle, parsed)
        collision = nil
        collision = tick_monsters_if_needed(puzzle_attempt_time_seconds) if result.success

        # Always return success_result for puzzle attempts so the message
        # appears in game output without "Error:" prefix
        reloaded = participant.reload
        base_data = (result.data || {}).merge(build_delve_response_data(reloaded))

        if collision
          monster_names = collision[:monster_names].join(', ')
          success_result(
            "#{result.message}<br><br><strong class=\"text-error\">COMBAT!</strong> #{monster_names} ambushes you!",
            type: :combat,
            data: base_data.merge(
              combat_started: true,
              fight_id: collision[:fight_id],
              monster_names: collision[:monster_names],
              quickmenu: collision[:quickmenu]
            )
          )
        else
          success_result(
            result.message,
            type: :message,
            data: base_data
          )
        end
      end

      def parse_puzzle_answer(raw)
        decoded = Base64.strict_decode64(raw) rescue nil
        if decoded
          parsed = JSON.parse(decoded) rescue nil
          return parsed if parsed
        end
        raw # Fallback: raw text for MCP/accessibility
      end

      def handle_help
        return not_in_delve unless participant

        room = participant.current_room
        puzzle = active_puzzle_for_room(room)

        unless puzzle
          return error_result("There's no puzzle here.")
        end

        if puzzle.solved?
          return error_result("The puzzle has already been solved.")
        end

        result = DelvePuzzleService.request_help!(participant, puzzle)
        collision = nil
        collision = tick_monsters_if_needed(::Delve.action_time_seconds(:puzzle_hint) || 30) if result.success

        # Return the puzzle UI with updated help data
        display = begin
          DelvePuzzleService.get_display(puzzle.reload)
        rescue StandardError => e
          warn "[DelveCommand] Failed to get puzzle display: #{e.message}"
          {}
        end

        if collision
          monster_names = collision[:monster_names].join(', ')
          reloaded = participant.reload
          success_result(
            "#{result.message}<br><br><strong class=\"text-error\">COMBAT!</strong> #{monster_names} ambushes you!",
            type: :combat,
            data: display.merge(build_delve_response_data(reloaded)).merge(
              help_message: result.message,
              combat_started: true,
              fight_id: collision[:fight_id],
              monster_names: collision[:monster_names],
              quickmenu: collision[:quickmenu]
            )
          )
        else
          success_result(
            result.message,
            type: :puzzle,
            output_category: :info,
            data: display.merge(build_delve_response_data(participant)).merge(help_message: result.message)
          )
        end
      end

      # ====== Utility Methods ======

      # Tick monster movement and handle any collisions.
      # Returns combat data hash if a monster roamed into the player's room, nil otherwise.
      def tick_monsters_if_needed(seconds)
        threshold = GameSetting.integer('delve_monster_move_threshold') || 10
        return nil if seconds < threshold

        delve = participant.delve
        collisions = delve.tick_monster_movement!(seconds)

        # Handle any combat that started — return first collision combat data
        collisions.each do |collision|
          if collision[:type] == :collision
            combat_data = start_monster_combat(collision[:monster], collision[:participants], collision[:room])
            return combat_data if combat_data
          end
        end

        nil
      end

      def movement_time_seconds
        ::Delve.action_time_seconds(:move) || ::Delve::ACTION_TIMES_SECONDS[:move]
      end

      def skill_check_time_seconds
        ::Delve.action_time_seconds(:skill_check) || 15
      end

      def puzzle_attempt_time_seconds
        ::Delve.action_time_seconds(:puzzle_attempt) || 15
      end

      def trap_listen_time_seconds
        ::Delve.action_time_seconds(:trap_listen) || ::Delve::ACTION_TIMES_SECONDS[:trap_listen]
      end

      # Resolve traps on either side of a connection.
      def connection_trap(room, direction)
        dir = CanvasHelper.normalize_direction(direction)
        if delve&.respond_to?(:trap_at)
          delve.trap_at(room, dir)
        else
          DelveTrapService.trap_in_direction(room, dir)
        end
      end

      # Resolve puzzles that block movement through a connection.
      def connection_puzzle(room, direction)
        dir = CanvasHelper.normalize_direction(direction)
        if delve&.respond_to?(:puzzle_blocking_at)
          delve.puzzle_blocking_at(room, dir)
        else
          p = DelvePuzzle.first(delve_room_id: room.id, solved: false)
          return nil unless p

          # Test doubles and legacy puzzle rows may not implement directional
          # gating; in that case treat as room-scoped blocking.
          return p unless p.respond_to?(:blocks_direction?)

          p.blocks_direction?(dir) ? p : nil
        end
      end

      def trapped_directions(room)
        unless room.respond_to?(:available_exits)
          return DelveTrap.where(delve_room_id: room.id, disabled: false).select_map(:direction)
        end

        room.available_exits.select do |dir|
          next false if dir == 'down'
          connection_trap(room, dir)
        end
      end

      # Find an unsolved puzzle relevant to this room, including puzzle-gated
      # exits defined from either side of a connection.
      def active_puzzle_for_room(room)
        local = DelvePuzzle.first(delve_room_id: room.id, solved: false)
        return local if local

        return nil unless room.respond_to?(:available_exits)

        room.available_exits.each do |dir|
          next if dir == 'down'
          puzzle = connection_puzzle(room, dir)
          return puzzle if puzzle
        end

        nil
      end

      def start_monster_combat(monster, participants, delve_room)
        delve = participant.delve

        # Complete any stale fight before starting a new one
        active_fight = FightService.find_active_fight(participant.character_instance)
        active_fight&.complete!

        combat_result = DelveCombatService.create_fight!(delve, monster, participants, delve_room: delve_room)
        return nil unless combat_result&.dig(:fight_started)

        fight = Fight[combat_result[:fight_id]]
        return nil unless fight

        fight_participant = fight.fight_participants.find { |fp| fp.character_instance_id == participant.character_instance_id }
        menu_data = fight_participant ? CombatQuickmenuHandler.show_menu(fight_participant, participant.character_instance) : nil

        {
          fight_id: fight.id,
          monster_names: combat_result[:monster_names],
          monster_count: combat_result[:monster_count],
          quickmenu: menu_data
        }
      end

      def respond(result, collision_combat: nil)
        if result.success
          reloaded = participant.reload
          base_data = (result.data || {}).merge(build_delve_response_data(reloaded))

          if collision_combat
            monster_names = collision_combat[:monster_names].join(', ')
            return success_result(
              "#{result.message}<br><br><strong class=\"text-error\">COMBAT!</strong> #{monster_names} ambushes you!",
              type: :combat,
              data: base_data.merge(
                combat_started: true,
                fight_id: collision_combat[:fight_id],
                monster_names: collision_combat[:monster_names],
                quickmenu: collision_combat[:quickmenu]
              )
            )
          end

          success_result(
            result.message,
            type: :message,
            data: base_data
          )
        else
          error_result(result.message)
        end
      end

      # Like respond but includes dice animation data for skill checks
      def respond_with_roll(result, collision_combat: nil)
        if result.success
          reloaded = participant.reload
          base_data = (result.data || {}).merge(build_delve_response_data(reloaded))

          # Generate animation data from the roll result
          anim_data = nil
          roll_total = nil
          roll_modifier = nil
          if result.data[:roll_result]
            roll_result = result.data[:roll_result]
            anim_data = DiceRollService.generate_animation_data(
              roll_result,
              character_name: "skill check",
              color: 'w'
            )
            roll_total = roll_result.total
            roll_modifier = result.data.dig(:roll, :modifier) || 0
          end

          if collision_combat
            monster_names = collision_combat[:monster_names].join(', ')
            success_result(
              "#{result.message}<br><br><strong class=\"text-error\">COMBAT!</strong> #{monster_names} ambushes you!",
              type: :combat,
              animation_data: anim_data,
              roll_total: roll_total,
              roll_modifier: roll_modifier,
              data: base_data.merge(
                combat_started: true,
                fight_id: collision_combat[:fight_id],
                monster_names: collision_combat[:monster_names],
                quickmenu: collision_combat[:quickmenu]
              )
            )
          else
            success_result(
              result.message,
              type: :message,
              animation_data: anim_data,
              roll_total: roll_total,
              roll_modifier: roll_modifier,
              data: base_data
            )
          end
        else
          error_result(result.message)
        end
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Delve::DelveCommand)

# Register contextual aliases for movement and action commands when in a delve
# This allows typing "north" instead of "delve north" when in a dungeon
%w[n s e w north south east west down d look l map grab take fight flee recover rest focus status study easier listen go solve help cross jump break pick].each do |cmd|
  Commands::Base::Registry.add_alias(cmd, Commands::Delve::DelveCommand, context: :delve)
end
