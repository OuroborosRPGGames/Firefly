# frozen_string_literal: true

module Commands
  module Navigation
    class DirectionWalk < Commands::Base::Command
      command_name 'direction_walk'
      aliases 'north', 'n', 'south', 's', 'east', 'e', 'west', 'w',
              'northeast', 'ne', 'northwest', 'nw', 'southeast', 'se', 'southwest', 'sw',
              'up', 'u', 'down', 'd'
      category :navigation
      help_text 'Start walking in a direction (continuous on streets, single step elsewhere)'
      usage '<direction>'
      examples 'north', 'n', 'south', 'se'

      requires :not_in_combat, message: "You can't leave while in combat! Use fight commands instead."

      # Direction alias map
      DIRECTION_ALIASES = {
        'n' => 'north', 'north' => 'north',
        's' => 'south', 'south' => 'south',
        'e' => 'east', 'east' => 'east',
        'w' => 'west', 'west' => 'west',
        'ne' => 'northeast', 'northeast' => 'northeast',
        'nw' => 'northwest', 'northwest' => 'northwest',
        'se' => 'southeast', 'southeast' => 'southeast',
        'sw' => 'southwest', 'southwest' => 'southwest',
        'u' => 'up', 'up' => 'up',
        'd' => 'down', 'down' => 'down'
      }.freeze

      protected

      def perform_command(parsed_input)
        command_word = parsed_input[:command_word]&.downcase
        direction = DIRECTION_ALIASES[command_word]

        return error_result("Unknown direction: #{command_word}") unless direction

        # Check if already moving
        if MovementService.moving?(character_instance)
          return error_result("You're already moving. Type 'stop' first.")
        end

        room = character_instance.current_room
        next_room = RoomAdjacencyService.resolve_direction_movement(room, direction.to_sym)

        return error_result("You can't go #{direction}.") unless next_room

        # Up/down is always single-step (no continuous walk)
        return perform_single_move(direction) if %w[up down].include?(direction)

        # On outdoor city streets: start continuous directional walking
        if city_outdoor_room?(room) && city_outdoor_room?(next_room)
          start_directional_walk(direction)
        else
          # Fallback to single-room move via the walk command's MovementService
          perform_single_move(direction)
        end
      end

      private

      def city_outdoor_room?(room)
        return false unless room
        RoomTypeConfig.street?(room.city_role.to_s) ||
          RoomTypeConfig.street?(room.room_type)
      end

      def start_directional_walk(direction)
        result = MovementService.start_directional_walk(character_instance, direction)

        if result.success
          extra = { moving: true }
          if result.data.is_a?(Hash)
            extra[:duration] = result.data[:duration] if result.data[:duration]
            extra[:target_world_x] = result.data[:target_world_x] if result.data[:target_world_x]
            extra[:target_world_y] = result.data[:target_world_y] if result.data[:target_world_y]
          end
          success_result(result.message, **extra)
        else
          error_result(result.message)
        end
      end

      def perform_single_move(direction)
        result = MovementService.start_movement(
          character_instance,
          target: direction,
          adverb: 'walk'
        )

        if result.success
          extra = { moving: true }
          if result.data.is_a?(Hash)
            extra[:duration] = result.data[:duration] if result.data[:duration]
            extra[:target_world_x] = result.data[:target_world_x] if result.data[:target_world_x]
            extra[:target_world_y] = result.data[:target_world_y] if result.data[:target_world_y]
          end
          success_result(result.message, **extra)
        else
          error_result(result.message)
        end
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Navigation::DirectionWalk)
