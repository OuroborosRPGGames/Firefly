# frozen_string_literal: true

module Commands
  module Building
    class Windows < Commands::Base::Command
      command_name 'windows'
      aliases 'curtains'
      category :building
      help_text 'Toggle the curtains/blinds on your windows'
      usage 'windows'
      examples 'windows', 'curtains'

      protected

      def perform_command(_parsed_input)
        room = location
        outer_room = room.outer_room

        # Check ownership
        unless outer_room.owned_by?(character_instance.character)
          return error_result("You don't own this room.")
        end

        old_state = room.curtains
        room.toggle_curtains!

        actor_name = character_instance.character.full_name

        if old_state
          # Curtains were closed, now open
          message = "#{actor_name} opens the curtains."
          self_message = 'You open the curtains.'
        else
          # Curtains were open, now closed
          message = "#{actor_name} closes the curtains."
          self_message = 'You close the curtains.'
        end

        BroadcastService.to_room(
          room.id,
          message,
          exclude: [character_instance.id],
          type: :message
        )

        success_result(
          self_message,
          type: :message,
          data: {
            action: 'windows',
            room_id: room.id,
            curtains: room.curtains
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Building::Windows)
