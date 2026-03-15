# frozen_string_literal: true

module Commands
  module Staff
    class Goto < ::Commands::Base::Command
      include CharacterLookupHelper

      command_name 'goto'
      aliases 'teleport', 'tp'
      category :staff
      help_text 'Teleport to a room by ID or to a character (staff only)'
      usage 'goto <room_id> | goto <character_name>'
      examples 'goto 42', 'goto Bob Smith', 'goto Bob'

      protected

      def perform_command(parsed_input)
        error = require_staff
        return error if error

        target = parsed_input[:text]&.strip
        if target.nil? || target.empty?
          return error_result("Usage: goto <room_id> or goto <character_name>")
        end

        # Determine if target is a room ID (numeric) or character name
        if target =~ /^\d+$/
          goto_room_by_id(target.to_i)
        else
          goto_character_by_name(target)
        end
      end

      private

      def goto_room_by_id(room_id)
        room = Room[room_id]
        unless room
          return error_result("No room found with ID #{room_id}.")
        end

        teleport_to_room(room)
      end

      def goto_character_by_name(name)
        # Search online characters globally
        target_instance = find_character_room_then_global(
          name,
          room: location,
          reality_id: nil,
          exclude_instance_id: character_instance.id
        )

        unless target_instance
          # Also try offline characters by name
          target_char = find_character_by_name_globally(name)
          if target_char
            # Get their most recent instance location
            target_instance = target_char.primary_instance
          end
        end

        unless target_instance
          return error_result("No character found matching '#{name}'.")
        end

        room = target_instance.current_room
        unless room
          return error_result("#{target_instance.character.full_name} has no current location.")
        end

        teleport_to_room(room, target_name: target_instance.character.full_name)
      end

      def teleport_to_room(room, target_name: nil)
        # Already there?
        if character_instance.current_room_id == room.id
          return error_result("You're already in #{room.name}.")
        end

        original_room = character_instance.current_room

        # Broadcast departure
        BroadcastService.to_room(
          original_room.id,
          "#{character.full_name} vanishes in a shimmer of light.",
          exclude: [character_instance.id],
          type: :departure
        )

        # Teleport
        character_instance.teleport_to_room!(room)

        # Broadcast arrival
        BroadcastService.to_room(
          room.id,
          "#{character.full_name} appears in a shimmer of light.",
          exclude: [character_instance.id],
          type: :arrival
        )

        # Send minimap update for the new room
        MovementService.notify_room_arrival(character_instance, room)

        message = if target_name
                    "You teleport to #{target_name}'s location (#{room.name})."
                  else
                    "You teleport to #{room.name}."
                  end

        success_result(
          message,
          type: :teleport,
          data: {
            action: 'teleport',
            from_room: original_room&.name,
            from_room_id: original_room&.id,
            to_room: room.name,
            to_room_id: room.id,
            target_character: target_name
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Staff::Goto)
