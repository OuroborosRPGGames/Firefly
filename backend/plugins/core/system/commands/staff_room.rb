# frozen_string_literal: true

module Commands
  module System
    class StaffRoom < ::Commands::Base::Command
      command_name 'staffroom'
      aliases 'staff room', 'staff-room', 'office'
      category :system
      help_text 'Teleport to the staff room (staff only)'
      usage 'staffroom'
      examples 'staffroom', 'office'

      protected

      def perform_command(_parsed_input)
        error = require_staff
        return error if error

        # Find the staff room
        staff_room = Room.first(room_type: 'staff')
        unless staff_room
          return error_result("No staff room has been configured. Contact an administrator.")
        end

        # Already in staff room?
        if character_instance.current_room_id == staff_room.id
          return error_result("You're already in the staff room.")
        end

        # Store original room for broadcast
        original_room = character_instance.current_room

        # Broadcast departure from original room
        BroadcastService.to_room(
          original_room.id,
          "#{character.full_name} vanishes in a shimmer of light.",
          exclude: [character_instance.id],
          type: :departure
        )

        # Teleport to staff room
        character_instance.update(
          current_room_id: staff_room.id,
          x: 50.0,
          y: 50.0,
          z: 0.0
        )

        # Broadcast arrival to staff room
        BroadcastService.to_room(
          staff_room.id,
          "#{character.full_name} appears in a shimmer of light.",
          exclude: [character_instance.id],
          type: :arrival
        )

        success_result(
          "You teleport to the staff room.",
          type: :teleport,
          data: {
            action: 'teleport',
            from_room: original_room.name,
            to_room: staff_room.name
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::System::StaffRoom)
