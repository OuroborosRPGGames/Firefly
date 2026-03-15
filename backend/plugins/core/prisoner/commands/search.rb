# frozen_string_literal: true

module Commands
  module Prisoner
    class Search < Commands::Base::Command
      command_name 'search'
      aliases 'frisk', 'rob'
      category :combat
      help_text 'Search a helpless character and examine their possessions'
      usage 'search <character>'
      examples 'search Bob', 'frisk Jane'

      requires_alive

      protected

      def perform_command(parsed_input)
        args = parsed_input[:args]

        return error_result('Search whom?') if args.empty?

        target_name = args.join(' ')

        # Resolve target
        resolution = resolve_character_with_menu(target_name)
        return disambiguation_result(resolution[:result]) if resolution[:disambiguation]
        return error_result(resolution[:error]) if resolution[:error]

        target = resolution[:match]

        # Can't search yourself
        if target.id == character_instance.id
          return error_result("You can't search yourself. Use 'inventory' instead.")
        end

        # Search them
        result = PrisonerService.search_inventory(character_instance, target)

        return error_result(result[:error]) unless result[:success]

        # Build output
        lines = ["You search #{target.full_name}:"]
        lines << ''

        # Worn items
        if result[:worn].any?
          lines << 'Wearing:'
          result[:worn].each do |item|
            lines << "  - #{item[:name]}"
          end
          lines << ''
        end

        # Inventory items
        if result[:items].any?
          lines << 'Carrying:'
          result[:items].each do |item|
            qty = item[:quantity] > 1 ? " (x#{item[:quantity]})" : ''
            lines << "  - #{item[:name]}#{qty}"
          end
          lines << ''
        end

        # Money
        if result[:money].any? && result[:money].values.any? { |v| v > 0 }
          lines << 'Money:'
          result[:money].each do |currency, amount|
            lines << "  - #{amount} #{currency}" if amount > 0
          end
          lines << ''
        end

        if result[:worn].empty? && result[:items].empty? && result[:money].values.all? { |v| v <= 0 }
          lines << '  Nothing of interest.'
        end

        # Notify room with personalized names
        broadcast_to_room(
          "#{character.full_name} searches #{target.character.full_name}.",
          exclude_character: character_instance
        )

        # Notify target with personalized name
        target_msg = substitute_names_for_viewer("#{character.full_name} searches your belongings.", target)
        send_to_character(target, target_msg)

        success_result(
          lines.join("\n"),
          type: :action,
          data: {
            action: 'search',
            target: target.full_name,
            worn: result[:worn],
            items: result[:items],
            money: result[:money]
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Prisoner::Search)
