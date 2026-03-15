# frozen_string_literal: true

module Commands
  module Inventory
    class Get < Commands::Base::Command
      command_name 'get'
      aliases 'take', 'pickup', 'grab', 'pick up'
      category :inventory
      help_text 'Pick up items or money from the room'
      usage 'get <item> | get <amount> | get money | get all'
      examples 'get sword', 'get 100', 'get money', 'get all'

      protected

      def perform_command(parsed_input)
        target = parsed_input[:text]
        items = room_items

        # No argument - show quickmenu of items on ground
        if blank?(target)
          return error_result("There's nothing here to pick up.") if items.empty?
          return item_selection_menu(items, 'What would you like to pick up?', command: 'get')
        end

        target = target.strip

        # Handle "get all"
        return get_all_items(items) if target.downcase == 'all'

        # Handle money (e.g., "get 100", "get money", "get cash")
        return money_pickup(target) if money_reference?(target)

        # Use normalizer to strip articles and extract container references
        # "get the sword" → item: "sword", "get sword from bag" → item: "sword", container: "bag"
        normalized = parsed_input[:normalized]
        if normalized[:item]
          target = normalized[:item]
        end

        # Get specific item
        return error_result("There's nothing here to pick up.") if items.empty?

        item_action_with_disambiguation(
          input: target,
          candidates: items,
          action_method: ->(item) { item.move_to_character(character_instance) },
          action_name: 'get',
          self_verb: 'pick up',
          other_verb: 'picks up',
          not_found_error: "You don't see '%{input}' here.",
          disambiguation_prompt: "Which '%{input}' do you want to get?"
        )
      end

      private

      def room_items
        location.objects_here.all.reject { |item| is_money_item?(item) }
      end

      def get_all_items(items)
        perform_bulk_action(
          items: items,
          action_method: ->(item) { item.move_to_character(character_instance) },
          action_name: 'get_all',
          self_verb: 'pick up',
          other_verb: 'picks up',
          empty_error: "There's nothing here to pick up."
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Inventory::Get)
