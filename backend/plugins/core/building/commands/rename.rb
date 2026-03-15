# frozen_string_literal: true

module Commands
  module Building
    class Rename < Commands::Base::Command
      command_name 'rename'
      category :building
      help_text 'Rename a room you own'
      usage 'rename <new name>'
      examples 'rename Cozy Living Room', 'rename The Den'

      requires_can_modify_rooms

      protected

      def perform_command(parsed_input)
        room = location
        outer_room = room.outer_room

        # Check ownership
        unless outer_room.owned_by?(character_instance.character)
          return error_result("You don't own this room.")
        end

        new_name = (parsed_input[:text] || '').strip

        if new_name.empty?
          return error_result('What do you want to rename this room to?')
        end

        if new_name.length > 100
          return error_result('Room name must be 100 characters or less.')
        end

        old_name = room.name
        room.update(name: new_name)

        actor_name = character_instance.character.full_name
        message = "#{actor_name} renames the room to '#{new_name}'."

        BroadcastService.to_room(
          room.id,
          message,
          exclude: [character_instance.id],
          type: :message
        )

        success_result(
          "You rename '#{old_name}' to '#{new_name}'.",
          type: :message,
          data: {
            action: 'rename',
            room_id: room.id,
            old_name: old_name,
            new_name: new_name
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Building::Rename)
