# frozen_string_literal: true

module Commands
  module Building
    class Decorate < Commands::Base::Command
      command_name 'decorate'
      category :building
      help_text 'Add a decoration description to a room you own'
      usage 'decorate <description>'
      examples 'decorate A plush velvet couch sits by the window.', 'decorate Vintage posters line the walls.'

      requires_can_modify_rooms

      protected

      def perform_command(parsed_input)
        room = location

        # Check ownership using inherited helper
        error = require_property_ownership
        return error if error

        text = (parsed_input[:text] || '').strip

        if text.empty?
          return error_result('What decoration do you want to add?')
        end

        # Create a new decoration
        max_order = room.decorations_dataset.max(:display_order) || 0
        decoration = Decoration.create(
          room_id: room.id,
          name: "Decoration #{max_order + 1}",
          description: text,
          display_order: max_order + 1
        )

        actor_name = character_instance.character.full_name
        message = "#{actor_name} adds some decoration to the room."

        BroadcastService.to_room(
          room.id,
          message,
          exclude: [character_instance.id],
          type: :message
        )

        success_result(
          'You add decoration to the room.',
          type: :message,
          data: {
            action: 'decorate',
            room_id: room.id,
            decoration_id: decoration.id
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Building::Decorate)
