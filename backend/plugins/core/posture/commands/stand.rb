# frozen_string_literal: true

module Commands
  module Posture
    class Stand < Commands::Base::Command
      command_name 'stand'
      aliases 'stand up', 'get up', 'stand at', 'stand by', 'stand beside', 'stand near',
              'dance', 'dance with', 'dance on', 'dance at', 'pace', 'pace at', 'pace on'
      category :navigation
      help_text 'Stand up from sitting or lying position, optionally at furniture'
      usage 'stand [up] | stand at/by <furniture> | dance on <furniture>'
      examples 'stand', 'stand up', 'get up', 'stand at bar', 'dance on stage', 'pace at window'

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]&.strip
        command_word = parsed_input[:command_word]&.downcase || ''

        # Simple "stand", "stand up", "get up" - just stand up from current position
        if text.nil? || text.empty? || text.downcase == 'up'
          return stand_up
        end

        # Check if preposition was part of the command alias (e.g., "stand at table" matched "stand at")
        alias_preposition = extract_preposition_from_command(command_word)

        # Parse "stand at/by/near <furniture>" or just "stand <furniture>"
        # Also handle "stand up at bar" pattern
        place_match = text.match(/\A(?:up\s+)?(?:(at|by|beside|near|on|with)\s+)?(.+)\z/i)
        unless place_match
          return stand_up
        end

        # Text preposition overrides alias preposition
        text_preposition = place_match[1]&.downcase
        preposition = text_preposition || alias_preposition
        place_name = place_match[2]

        # Find place in room
        place = find_place(place_name)
        unless place
          return error_result("You don't see '#{place_name}' to stand at here.")
        end

        # Check if already standing at this place
        if character_instance.standing? && character_instance.current_place_id == place.id
          return error_result("You're already standing at #{place.name}.")
        end

        stand_at_place(place, preposition)
      end

      private

      # Extract preposition from command word if the alias included one
      # e.g., "stand at" -> "at", "dance on" -> "on", "stand" -> nil
      def extract_preposition_from_command(command_word)
        preposition_pattern = /\b(on|at|by|beside|near|with)\z/i
        match = command_word.match(preposition_pattern)
        match ? match[1].downcase : nil
      end

      def stand_up
        current_stance = character_instance.current_stance

        if current_stance == 'standing' && character_instance.current_place_id.nil?
          return error_result("You're already standing.")
        end

        was_at_place = character_instance.current_place
        place_name = was_at_place&.name

        # Stand up and leave furniture
        character_instance.update(
          stance: 'standing',
          current_place_id: nil
        )

        message = if place_name
                    "#{character.full_name} stands up from #{place_name}."
                  else
                    "#{character.full_name} stands up."
                  end

        broadcast_to_room(message, exclude_character: character_instance)

        you_message = place_name ? "You stand up from #{place_name}." : "You stand up."

        success_result(
          you_message,
          type: :message,
          data: {
            action: 'stand',
            stance: 'standing',
            previous_stance: current_stance,
            previous_place: place_name
          }
        )
      end

      def stand_at_place(place, preposition = nil)
        # Check capacity
        if place.full?
          return error_result("There's no room at #{place.name}.")
        end

        # Determine preposition: explicit > furniture default > fallback to 'at'
        prep = preposition || place.default_sit_action || 'at'

        previous_stance = character_instance.current_stance
        previous_place = character_instance.current_place&.name

        # Move to place with standing stance
        character_instance.update(
          stance: 'standing',
          current_place_id: place.id
        )

        broadcast_to_room(
          "#{character.full_name} stands #{prep} #{place.name}.",
          exclude_character: character_instance
        )

        success_result(
          "You stand #{prep} #{place.name}.",
          type: :message,
          data: {
            action: 'stand',
            stance: 'standing',
            place_id: place.id,
            place_name: place.name,
            preposition: prep,
            previous_stance: previous_stance,
            previous_place: previous_place
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Posture::Stand)
