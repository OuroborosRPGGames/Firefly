# frozen_string_literal: true

module Commands
  module Status
    class DryOff < Commands::Base::Command
      command_name 'dry off'
      aliases 'dryoff', 'dry'
      category :system
      help_text 'Dry yourself off using a towel'
      usage 'dry off [adverb]'
      examples 'dry off', 'dry off quickly', 'dryoff thoroughly'

      protected

      def perform_command(parsed_input)
        adverb = parsed_input[:text]&.strip
        adverb = nil if adverb&.empty?

        unless character_instance.wet?
          return error_result("You're not wet.")
        end

        # Find a towel in inventory
        towel = find_towel
        unless towel
          return error_result("You'd need a towel first.")
        end

        wetness_before = character_instance.wetness_description
        character_instance.dry_off!

        action_text = build_action_text(adverb)
        broadcast_action(action_text)

        success_result(
          "You #{action_text} using your #{towel.name}.\nYou were #{wetness_before}, now you're dry.",
          type: :message,
          data: {
            action: 'dry_off',
            towel_name: towel.name,
            previous_wetness: wetness_before
          }
        )
      end

      private

      def find_towel
        # Search for towel in carried and worn items
        items = character_instance.objects_dataset.where(
          Sequel.|(
            { held: true },
            { worn: true },
            Sequel.&({ worn: false, held: false, equipped: false, stored: false })
          )
        ).all

        items.find do |item|
          name = item.name.downcase
          name.include?('towel') || name.include?('cloth') || name.include?('rag')
        end
      end

      def build_action_text(adverb)
        if adverb && !adverb.empty?
          "#{adverb} dry off"
        else
          "dry off"
        end
      end

      def broadcast_action(action_text)
        # Third person version
        message = if action_text.start_with?('dry')
                    "#{character.full_name} dries off."
                  else
                    "#{character.full_name} #{action_text.sub('dry off', 'dries off')}."
                  end

        broadcast_to_room(message, exclude_character: character_instance, type: :action)
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Status::DryOff)
