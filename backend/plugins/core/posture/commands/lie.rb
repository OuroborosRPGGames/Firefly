# frozen_string_literal: true

module Commands
  module Posture
    class Lie < Commands::Base::Command
      command_name 'lie'
      aliases 'lie down', 'lay', 'lay down'
      category :navigation
      help_text 'Lie down, optionally on furniture'
      usage 'lie [on <furniture>]'
      examples 'lie down', 'lie on bed', 'lay on couch'

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]&.strip

        if character_instance.lying?
          return error_result("You're already lying down.")
        end

        if text.nil? || text.empty? || text.downcase == 'down'
          return lie_on_ground
        end

        # Parse "lie on <furniture>" or just "lie <furniture>"
        match = text.match(/\A(?:down\s+)?(?:on\s+)?(.+)\z/i)
        furniture_name = match ? match[1] : text

        place = find_furniture(furniture_name)
        unless place
          return error_result("You don't see '#{furniture_name}' to lie on here.")
        end

        lie_on_furniture(place)
      end

      private

      def lie_on_ground
        character_instance.update(stance: 'lying', current_place_id: nil)

        broadcast_to_room(
          "#{character.full_name} lies down.",
          exclude_character: character_instance
        )

        success_result(
          "You lie down.",
          type: :message,
          data: { action: 'lie', stance: 'lying' }
        )
      end

      def lie_on_furniture(place)
        if place.full?
          return error_result("There's no room on #{place.name}.")
        end

        character_instance.update(stance: 'lying', current_place_id: place.id)

        broadcast_to_room(
          "#{character.full_name} lies down on #{place.name}.",
          exclude_character: character_instance
        )

        success_result(
          "You lie down on #{place.name}.",
          type: :message,
          data: {
            action: 'lie',
            stance: 'lying',
            place_id: place.id,
            place_name: place.name
          }
        )
      end

    end
  end
end

Commands::Base::Registry.register(Commands::Posture::Lie)
