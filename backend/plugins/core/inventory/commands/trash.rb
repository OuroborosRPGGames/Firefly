# frozen_string_literal: true

module Commands
  module Inventory
    class Trash < Commands::Base::Command
      command_name 'trash'
      aliases 'destroy', 'junk'
      category :inventory
      help_text 'Permanently destroy an item from your inventory'
      usage 'trash <item>'
      examples 'trash sword', 'trash broken shield'

      protected

      def perform_command(parsed_input)
        target = parsed_input[:text]
        return error_result("Trash what?") if blank?(target)

        target = target.strip

        # Find item in inventory
        item = find_item_in_inventory(target)
        return error_result("You don't have '#{target}'.") unless item

        # Don't allow trashing money items
        if is_money_item?(item)
          return error_result("You can't trash money. Use 'drop' instead.")
        end

        item_name = item.name

        # Permanently destroy the item
        item.destroy

        broadcast_to_room(
          "#{character.full_name} discards #{item_name}.",
          exclude_character: character_instance
        )

        success_result(
          "You trash #{item_name}. It's gone forever.",
          type: :message,
          data: { action: 'trash', item_name: item_name }
        )
      end

      private

      # NOTE: is_money_item? is inherited from Commands::Base::Command
      # Uses inherited find_item_in_inventory from base command
    end
  end
end

Commands::Base::Registry.register(Commands::Inventory::Trash)
