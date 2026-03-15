# frozen_string_literal: true

module Commands
  module Building
    class GraffitiCmd < Commands::Base::Command
      command_name 'graffiti'
      aliases 'tag'
      category :building
      help_text 'Write graffiti on the walls'
      usage 'graffiti <text>'
      examples 'graffiti Kilroy was here', 'graffiti FOR A GOOD TIME CALL...'

      requires_can_modify_rooms

      protected

      def perform_command(parsed_input)
        room = location
        text = (parsed_input[:text] || '').strip

        if text.empty?
          return error_result('What do you want to write?')
        end

        if text.length > Graffiti::MAX_LENGTH
          return error_result("Graffiti must be #{Graffiti::MAX_LENGTH} characters or less.")
        end

        graffiti = Graffiti.create(
          room_id: room.id,
          text: text,
          x: character_instance.x,
          y: character_instance.y
        )

        actor_name = character_instance.character.full_name
        message = "#{actor_name} scrawls something on the wall."

        BroadcastService.to_room(
          room.id,
          message,
          exclude: [character_instance.id],
          type: :message
        )

        success_result(
          'You write graffiti on the wall.',
          type: :message,
          data: {
            action: 'graffiti',
            room_id: room.id,
            graffiti_id: graffiti.id,
            text: text
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Building::GraffitiCmd)
