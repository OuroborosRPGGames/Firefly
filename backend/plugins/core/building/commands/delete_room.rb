# frozen_string_literal: true

module Commands
  module Building
    class DeleteRoom < Commands::Base::Command
      command_name 'delete room'
      aliases 'remove room'
      category :building
      help_text 'Delete the current room (must own it)'
      usage 'delete room'
      examples 'delete room'

      protected

      def perform_command(_parsed_input)
        room = location
        outer_room = room.outer_room

        # Check ownership
        unless outer_room.owned_by?(character_instance.character)
          return error_result("You don't own this room.")
        end

        # Cannot delete if this is the only room in the location
        location_obj = room.location
        if location_obj && location_obj.rooms.count <= 1
          return error_result("Cannot delete the only room in a location. Delete the location instead.")
        end

        # Cannot delete room if other characters are present
        other_characters = room.character_instances_dataset.where(online: true).exclude(id: character_instance.id)
        if other_characters.count.positive?
          return error_result("Cannot delete a room with other characters present. Ask them to leave first.")
        end

        # Find parent room to move to
        parent_room = room.inside_room
        unless parent_room
          # If no parent room, find another room in the same location
          parent_room = location_obj.rooms_dataset.exclude(id: room.id).first
        end

        unless parent_room
          return error_result("Cannot find a safe location to move you to after deletion.")
        end

        room_name = room.name
        room_id = room.id

        # Reparent any nested rooms to parent
        Room.where(inside_room_id: room.id).update(inside_room_id: parent_room.id)

        # Move any items in the room to parent room
        Item.where(room_id: room.id).update(room_id: parent_room.id)

        # Delete associated data
        room.cleanup_contents!

        # Move ALL characters (including offline) to parent room to avoid FK violations
        CharacterInstance.where(current_room_id: room.id).update(
          current_room_id: parent_room.id,
          x: 0.0,
          y: 0.0,
          z: 0.0
        )

        # Delete the room
        room.delete

        actor_name = character.full_name

        # Broadcast arrival to new room
        BroadcastService.to_room(
          parent_room.id,
          "#{actor_name} appears as they demolish a room.",
          exclude: [character_instance.id],
          type: :message
        )

        success_result(
          "You have deleted '#{room_name}'. You are now in '#{parent_room.name}'.",
          type: :action,
          data: {
            action: 'delete_room',
            deleted_room_id: room_id,
            deleted_room_name: room_name,
            new_room_id: parent_room.id,
            new_room_name: parent_room.name
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Building::DeleteRoom)
