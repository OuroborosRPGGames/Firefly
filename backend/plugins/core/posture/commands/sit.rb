# frozen_string_literal: true

module Commands
  module Posture
    class Sit < Commands::Base::Command
      command_name 'sit'
      aliases 'sit down', 'sit on', 'sit in', 'sit at', 'sit beside', 'sit by', 'lean on',
              'lean against', 'sprawl', 'sprawl on', 'sprawl in', 'sprawl at', 'get in',
              'get into', 'get on', 'relax on', 'relax at', 'relax in', 'lounge on', 'lounge at',
              'lounge in', 'kneel', 'kneel on', 'crouch', 'straddle', 'exercise', 'work out', 'study'
      category :navigation
      help_text 'Sit down, optionally on furniture'
      usage 'sit [on/at/in <furniture>]'
      examples 'sit', 'sit down', 'sit on couch', 'sit at bar', 'sit in booth'

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]&.strip
        command_word = parsed_input[:command_word]&.downcase || ''

        # Already sitting?
        if character_instance.sitting?
          return error_result("You're already sitting.")
        end

        # Simple "sit" or "sit down" - sit on floor/ground
        if text.nil? || text.empty? || text.downcase == 'down'
          return sit_on_ground
        end

        # Check if preposition was part of the command alias (e.g., "sit in sofa" matched "sit in")
        alias_preposition = extract_preposition_from_command(command_word)

        # Parse "sit on/at/in <furniture>" or just "sit <furniture>"
        furniture_match = text.match(/\A(?:down\s+)?(?:(on|at|in|beside|against|by)\s+)?(.+)\z/i)
        unless furniture_match
          return sit_on_ground
        end

        # Text preposition overrides alias preposition
        text_preposition = furniture_match[1]&.downcase
        preposition = text_preposition || alias_preposition
        furniture_name = furniture_match[2]

        # Find place in room (allow sitting on any place, not just furniture)
        place = find_place(furniture_name)
        unless place
          return error_result("You don't see '#{furniture_name}' to sit on here.")
        end

        sit_on_furniture(place, preposition)
      end

      private

      # Extract preposition from command word if the alias included one
      # e.g., "sit in" -> "in", "sit on" -> "on", "sit" -> nil
      def extract_preposition_from_command(command_word)
        preposition_pattern = /\b(on|at|in|beside|against|by)\z/i
        match = command_word.match(preposition_pattern)
        match ? match[1].downcase : nil
      end

      def sit_on_ground
        character_instance.update(stance: 'sitting', current_place_id: nil)

        broadcast_to_room(
          "#{character.full_name} sits down.",
          exclude_character: character_instance
        )

        success_result(
          "You sit down.",
          type: :message,
          data: { action: 'sit', stance: 'sitting' }
        )
      end

      def sit_on_furniture(place, preposition = nil)
        # Check capacity
        if place.full?
          return error_result("There's no room #{preposition_text(place, preposition)} #{place.name}.")
        end

        # Determine preposition: explicit > furniture default > fallback to 'on'
        prep = preposition || place.default_sit_action || 'on'

        # Move to place and sit
        character_instance.update(
          stance: 'sitting',
          current_place_id: place.id
        )

        broadcast_to_room(
          "#{character.full_name} sits #{prep} #{place.name}.",
          exclude_character: character_instance
        )

        success_result(
          "You sit #{prep} #{place.name}.",
          type: :message,
          data: {
            action: 'sit',
            stance: 'sitting',
            place_id: place.id,
            place_name: place.name,
            preposition: prep
          }
        )
      end

      def preposition_text(place, preposition)
        preposition || place.default_sit_action || 'on'
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Posture::Sit)
