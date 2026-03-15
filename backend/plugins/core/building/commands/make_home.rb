# frozen_string_literal: true

module Commands
  module Building
    class MakeHome < Commands::Base::Command
      command_name 'make home'
      aliases 'makehome', 'sethome'
      category :building
      help_text 'Set your current location as your home'
      usage 'make home'
      examples 'make home', 'makehome'

      protected

      def perform_command(_parsed_input)
        room = location
        outer_room = room.outer_room
        character = character_instance.character

        # Check ownership
        unless outer_room.owned_by?(character)
          return error_result("You can only set your home in a room you own.")
        end

        old_home = character.home_room
        character.set_home!(outer_room)

        message = if old_home
                    "You set this room as your new home (replacing #{old_home.name})."
                  else
                    'You set this room as your home.'
                  end

        success_result(
          message,
          type: :message,
          data: {
            action: 'make_home',
            room_id: outer_room.id,
            old_home_id: old_home&.id
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Building::MakeHome)
