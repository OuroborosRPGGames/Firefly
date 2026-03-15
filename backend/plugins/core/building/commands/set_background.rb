# frozen_string_literal: true

module Commands
  module Building
    class SetBackground < Commands::Base::Command
      command_name 'set background'
      aliases 'setbg', 'setbackground'
      category :building
      help_text 'Set the background image for a room you own'
      usage 'set background <url>'
      examples 'set background https://example.com/room.jpg', 'setbg https://i.imgur.com/abc123.png'

      protected

      def perform_command(parsed_input)
        room = location
        outer_room = room.outer_room

        # Check ownership
        unless outer_room.owned_by?(character_instance.character)
          return error_result("You don't own this room.")
        end

        # Parse URL from text
        text = (parsed_input[:text] || '').strip
        text = text.sub(/^background\s*/i, '') if parsed_input[:command_word] == 'set'

        url = text.strip

        if url.empty?
          if room.default_background_url
            room.update(default_background_url: nil)
            return success_result(
              'You remove the background image.',
              type: :message,
              data: { action: 'set_background', room_id: room.id, url: nil }
            )
          else
            return error_result('What image URL do you want to use?')
          end
        end

        # Basic URL validation
        unless url.match?(%r{^https?://})
          return error_result('Please provide a valid URL starting with http:// or https://')
        end

        if url.length > 2048
          return error_result('URL too long (max 2048 characters).')
        end

        room.set_background!(url)

        actor_name = character_instance.character.full_name
        message = "#{actor_name} changes the room's background."

        BroadcastService.to_room(
          room.id,
          message,
          exclude: [character_instance.id],
          type: :message
        )

        success_result(
          'You set the background image.',
          type: :message,
          data: {
            action: 'set_background',
            room_id: room.id,
            url: url
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Building::SetBackground)
