# frozen_string_literal: true

module Commands
  module Inventory
    class Drop < Commands::Base::Command
      command_name 'drop'
      aliases 'discard', 'put down', 'put'
      category :inventory
      help_text 'Drop items or money to the room'
      usage 'drop <item> | drop <amount> | drop all'
      examples 'drop sword', 'drop 100', 'drop all'

      protected

      def perform_command(parsed_input)
        target = parsed_input[:text]
        items = character_instance.inventory_items.all

        # No argument - show quickmenu of inventory
        if blank?(target)
          return error_result("You aren't carrying anything.") if items.empty?
          return item_selection_menu(items, 'What would you like to drop?', command: 'drop')
        end

        target = target.strip

        # Handle "drop all"
        return drop_all_items(items) if target.downcase == 'all'

        # Handle money (numbers only, e.g., "drop 100")
        return drop_money(target) if money_reference?(target, include_keywords: false)

        # Use normalizer to strip articles and extract container references
        # "drop the sword" → item: "sword", "put sword on table" → item: "sword", container: "table"
        normalized = parsed_input[:normalized]
        if normalized[:item]
          target = normalized[:item]
        end

        # Drop specific item
        return error_result("You aren't carrying anything.") if items.empty?

        item_action_with_disambiguation(
          input: target,
          candidates: items,
          action_method: ->(item) { item.move_to_room(location) },
          action_name: 'drop',
          self_verb: 'drop',
          other_verb: 'drops',
          not_found_error: "You don't have '%{input}'.",
          disambiguation_prompt: "Which '%{input}' do you want to drop?"
        )
      end

      private

      def drop_all_items(items)
        perform_bulk_action(
          items: items,
          action_method: ->(item) { item.move_to_room(location) },
          action_name: 'drop_all',
          self_verb: 'drop',
          other_verb: 'drops',
          empty_error: "You aren't carrying anything."
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Inventory::Drop)
