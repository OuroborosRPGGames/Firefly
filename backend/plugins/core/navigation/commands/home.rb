# frozen_string_literal: true

module Commands
  module Navigation
    class Home < Commands::Base::Command
      command_name 'home'
      aliases 'gohome'
      category :navigation
      help_text 'Head home to your home location'
      usage 'home'
      examples 'home', 'gohome'

      requires :not_in_combat, message: "You can't do that while in combat!"

      protected

      def perform_command(_parsed_input)
        home_room = character.home_room

        unless home_room
          return error_result("You don't have a home set. Use 'sethome' in a room you own.")
        end

        if character_instance.current_room_id == home_room.id
          return error_result("You're already at home.")
        end

        # Staff characters teleport instantly; everyone else walks
        if character.staff?
          teleport_home(home_room)
        else
          walk_home(home_room)
        end
      end

      private

      def teleport_home(home_room)
        original_room = character_instance.current_room

        broadcast_to_room("#{character.full_name} heads home.", exclude_character: character_instance, type: :departure)

        character_instance.update(
          current_room_id: home_room.id,
          x: 50.0,
          y: 50.0,
          z: 0.0
        )

        broadcast_to_room("#{character.full_name} arrives home.", exclude_character: character_instance, type: :arrival)

        success_result(
          "You head home to #{home_room.name}.",
          type: :teleport,
          data: {
            action: 'teleport',
            from_room: original_room.name,
            to_room: home_room.name
          }
        )
      end

      def walk_home(home_room)
        result = MovementService.move_to_room(character_instance, home_room, adverb: 'walk')

        if result.success
          data = {}
          if result.data.is_a?(Hash)
            data[:moving] = true
            data[:duration] = result.data[:duration] if result.data[:duration]
            data[:destination] = result.data[:destination]&.name if result.data[:destination]
            data[:path_length] = result.data[:path_length] if result.data[:path_length]
          end
          success_result(result.message, **data)
        else
          # Pathfinding failed (no route) — fall back to teleport
          teleport_home(home_room)
        end
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Navigation::Home)
