# frozen_string_literal: true

module Commands
  module Building
    class Redecorate < Commands::Base::Command
      command_name 'redecorate'
      category :building
      help_text 'Replace all decorations in a room you own'
      usage 'redecorate <description>'
      examples 'redecorate Minimalist furnishings create a zen atmosphere.'

      requires_can_modify_rooms

      protected

      def perform_command(parsed_input)
        room = location

        # Check ownership using inherited helper
        error = require_property_ownership
        return error if error

        text = (parsed_input[:text] || '').strip

        if text.empty?
          return error_result('What decoration do you want to set?')
        end

        # Delete all existing decorations
        old_count = room.decorations_dataset.count
        room.decorations_dataset.delete

        # Create a single new decoration
        decoration = Decoration.create(
          room_id: room.id,
          name: 'Room Decoration',
          description: text,
          display_order: 1
        )

        actor_name = character_instance.character.full_name
        message = "#{actor_name} completely redecorates the room."

        BroadcastService.to_room(
          room.id,
          message,
          exclude: [character_instance.id],
          type: :message
        )

        success_result(
          "You redecorate the room#{" (replacing #{old_count} decoration#{'s' if old_count > 1})" if old_count > 0}.",
          type: :message,
          data: {
            action: 'redecorate',
            room_id: room.id,
            decoration_id: decoration.id,
            decorations_replaced: old_count
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Building::Redecorate)
