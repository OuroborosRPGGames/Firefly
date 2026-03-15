# frozen_string_literal: true

module Commands
  module Navigation
    class Walk < Commands::Base::Command
      command_name 'walk'
      aliases 'move', 'go', 'run', 'jog', 'crawl', 'limp', 'strut', 'meander', 'stroll', 'sneak', 'sprint', 'fly',
              'swagger', 'stride', 'march', 'hike', 'creep', 'shuffle', 'amble', 'trudge', 'wander',
              'lumber', 'pad', 'skip', 'plod', 'shamble', 'patrol', 'sashay', 'stalk', 'stomp',
              'pace', 'scramble', 'stagger', 'prowl', 'traipse', 'drift', 'go to', 'saunter'
      category :navigation
      help_text 'Walk toward a target (direction, room, character, or place)'
      usage 'walk <target>, move <target>, go <direction>, run <target>'
      examples 'walk north', 'move east', 'go south', 'run to tavern', 'crawl to John'

      requires :not_in_combat, message: "You can't leave while in combat! Use fight commands instead."

      protected

      def perform_command(parsed_input)
        verb = extract_verb_from_command(parsed_input[:command_word])
        target = parsed_input[:text]&.strip

        # Strip "to " prefix if present (e.g., "walk to tavern" -> "tavern")
        target = target.sub(/^to\s+/i, '') if target

        # Extract manner adverb (e.g., "angrily" from "angrily north")
        manner, target = extract_manner_adverb(target) if target

        if target.nil? || target.empty?
          return error_result("Where do you want to #{verb}?")
        end

        result = MovementService.start_movement(
          character_instance,
          target: target,
          adverb: verb,
          manner: manner
        )

        if result.success
          success_result(result.message, **movement_data(result))
        elsif result.data&.dig(:autodrive_prompt)
          handle_autodrive_prompt(result)
        elsif result.data&.dig(:ambiguous)
          handle_ambiguous(result.data, verb)
        else
          error_result(result.message)
        end
      end

      private

      def extract_verb_from_command(command_word)
        verbs = %w[walk run jog crawl limp strut meander stroll sneak sprint fly
                   swagger stride march hike creep shuffle amble trudge wander
                   lumber pad skip plod shamble patrol sashay stalk stomp
                   pace scramble stagger prowl traipse drift saunter]
        verbs.include?(command_word) ? command_word : 'walk'
      end

      MANNER_ADVERBS = %w[
        angrily awkwardly boldly briskly calmly carefully carelessly casually
        cautiously cheerfully clumsily confidently defiantly deliberately
        desperately dramatically drunkenly eagerly elegantly frantically
        furiously gracefully happily hastily heavily hurriedly lazily
        loudly nervously noisily proudly quietly quickly reluctantly
        sadly silently sleepily slowly sneakily softly stealthily
        stiffly swiftly timidly tiredly wearily wildly
      ].freeze

      # Extract a manner adverb from the target text (must be a known adverb)
      def extract_manner_adverb(text)
        return [nil, text] if text.nil? || text.empty?

        words = text.split
        adverb_index = words.find_index { |word| MANNER_ADVERBS.include?(word.downcase) }

        if adverb_index
          adverb = words.delete_at(adverb_index)
          remaining = words.join(' ')
          # Strip leading "to " that might be exposed after adverb removal
          remaining = remaining.sub(/^to\s+/i, '') if remaining.start_with?('to ')
          [adverb.downcase, remaining]
        else
          [nil, text]
        end
      end

      def movement_data(result)
        data = { moving: true }
        return data unless result.data.is_a?(Hash)

        data[:duration] = result.data[:duration] if result.data[:duration]
        data[:destination] = result.data[:destination]&.name if result.data[:destination]
        data[:path_length] = result.data[:path_length] if result.data[:path_length]
        data[:target_world_x] = result.data[:target_world_x] if result.data[:target_world_x]
        data[:target_world_y] = result.data[:target_world_y] if result.data[:target_world_y]
        data
      end

      def handle_autodrive_prompt(result)
        data = result.data
        options = data[:options].map do |opt|
          { key: opt[:key], label: opt[:label], description: opt[:description] }
        end

        context = {
          command: 'travel_choice',
          destination_id: data[:destination_id],
          destination_name: data[:destination_name],
          adverb: data[:adverb]
        }

        menu_result = create_quickmenu(
          character_instance,
          result.message,
          options,
          context: context
        )

        disambiguation_result(menu_result, result.message)
      end

      def handle_ambiguous(ambiguous_data, adverb)
        matches = ambiguous_data[:matches]
        type = ambiguous_data[:type]

        # Build quickmenu options
        options = matches.map do |match|
          case type
          when :character
            { key: match[:id].to_s, label: match[:name], description: 'Character' }
          when :exit
            { key: match[:id].to_s, label: "#{match[:name]} (#{match[:direction]})", description: 'Exit' }
          when :room
            { key: match[:id].to_s, label: match[:name], description: 'Location' }
          when :furniture
            { key: match[:id].to_s, label: match[:name], description: 'Object' }
          when :event
            { key: match[:id].to_s, label: match[:name], description: match[:room] || 'Event' }
          else
            { key: match[:id].to_s, label: match[:name].to_s }
          end
        end

        # Create quickmenu for disambiguation
        context = {
          action: 'walk',
          adverb: adverb,
          type: type.to_s,
          matches: matches
        }

        menu_result = create_quickmenu(
          character_instance,
          "Which #{type} do you mean?",
          options,
          context: context
        )

        # Return quickmenu data
        success_result(
          "Which #{type} do you mean?",
          quickmenu: true,
          interaction_id: menu_result[:interaction_id],
          type: type,
          options: menu_result[:options]
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Navigation::Walk)
