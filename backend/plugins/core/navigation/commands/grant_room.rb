# frozen_string_literal: true

module Commands
  module Navigation
    class GrantRoom < Commands::Base::Command
      command_name 'grant room'
      aliases 'grant room access'
      category :navigation
      help_text 'Grant access to a locked room within your property'
      usage 'grant room [access] <character>'
      examples 'grant room Bob', 'grant room access Alice'

      protected

      def perform_command(parsed_input)
        room = location

        # Check ownership of the room (not outer property, but this specific room)
        unless room.owned_by?(character_instance.character)
          return error_result("You don't own this room.")
        end

        # Parse target name (handle "access" prefix)
        text = (parsed_input[:text] || '').strip
        text = text.sub(/^access\s+/i, '')

        if text.empty?
          return error_result('Who do you want to grant room access to? Usage: grant room <character>')
        end

        # Find target character
        target = find_character_by_name(text)
        unless target
          return error_result("No character found named '#{text}'.")
        end

        if target.id == character.id
          return error_result("You already have access to your own room!")
        end

        # Check if already has access
        existing = RoomUnlock.where(room_id: room.id, character_id: target.id)
                             .where { (expires_at =~ nil) | (expires_at > Sequel::CURRENT_TIMESTAMP) }
                             .first
        if existing
          return error_result("#{target.full_name} already has access to this room.")
        end

        # Grant permanent access to this specific room
        room.grant_access!(target, permanent: true)

        success_result(
          "You grant #{target.full_name} access to this room.",
          type: :message,
          data: {
            action: 'grant_room',
            room_id: room.id,
            target_id: target.id,
            target_name: target.full_name
          }
        )
      end

      private

      # Uses inherited find_character_globally from base command (returns Character model)
      def find_character_by_name(name)
        find_character_globally(name)
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Navigation::GrantRoom)
