# frozen_string_literal: true

module Commands
  module Building
    class CleanGraffiti < Commands::Base::Command
      command_name 'clean graffiti'
      aliases 'cleangraffiti'
      category :building
      help_text 'Remove all graffiti from a room you own'
      usage 'clean graffiti'
      examples 'clean graffiti'

      protected

      def perform_command(_parsed_input)
        room = location
        outer_room = room.outer_room

        # Check ownership
        unless outer_room.owned_by?(character_instance.character)
          return error_result("You don't own this room.")
        end

        graffiti_count = room.graffiti_dataset.count

        if graffiti_count.zero?
          return error_result('There is no graffiti to clean.')
        end

        room.clear_graffiti!

        actor_name = character_instance.character.full_name
        message = "#{actor_name} scrubs the graffiti from the walls."

        BroadcastService.to_room(
          room.id,
          message,
          exclude: [character_instance.id],
          type: :message
        )

        success_result(
          "You clean #{graffiti_count} piece#{'s' if graffiti_count > 1} of graffiti from the walls.",
          type: :message,
          data: {
            action: 'clean_graffiti',
            room_id: room.id,
            graffiti_removed: graffiti_count
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Building::CleanGraffiti)
