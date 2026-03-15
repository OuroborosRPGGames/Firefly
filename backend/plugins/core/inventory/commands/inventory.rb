# frozen_string_literal: true

require_relative '../../../../app/helpers/inventory_display_helper'
require_relative '../concerns/item_display_concern'

module Commands
  module Inventory
    class InventoryCmd < Commands::Base::Command
      include InventoryDisplayHelper
      include ItemDisplayConcern
      command_name 'inventory'
      aliases 'inv', 'i'
      category :inventory
      output_category :info
      help_text 'View your inventory and wallet balance'
      usage 'inventory'
      examples 'inventory', 'inv', 'i'

      protected

      def perform_command(_parsed_input)
        # Get non-worn items (inventory = what you're carrying, not wearing)
        items = character_instance.inventory_items.all
        wallets = character_instance.wallets_dataset.all

        held_items = items.select(&:held?)
        carried_items = items.reject(&:held?)

        if items.empty? && wallets.empty?
          return success_result("You aren't carrying anything.", type: :message, data: { action: 'inventory' })
        end

        html = +""

        # Wallet balances
        if wallets.any?
          html << "<b>Wallet</b>"
          html << "<ul style='margin:0 0 0.4em;padding-left:1.2em;list-style:none'>"
          wallets.each do |wallet|
            html << "<li>#{wallet.currency.format_amount(wallet.balance)}</li>"
          end
          html << "</ul>"
        end

        html << build_section("In Hand", held_items) if held_items.any?
        html << build_section("Carrying", carried_items) if carried_items.any?

        success_result(
          html,
          type: :message,
          data: {
            action: 'inventory',
            item_count: items.count,
            held_count: held_items.count,
            wallet_count: wallets.count
          }
        )
      end

      private

      # Prepend stack quantity when > 1, then delegate to shared formatting.
      def format_item(item)
        result = super
        item.quantity > 1 ? "(#{item.quantity}) #{result}" : result
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Inventory::InventoryCmd)
