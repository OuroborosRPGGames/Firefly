# frozen_string_literal: true

require_relative '../../../../app/helpers/inventory_display_helper'
require_relative '../concerns/item_display_concern'

module Commands
  module Inventory
    class Equipment < Commands::Base::Command
      include InventoryDisplayHelper
      include ItemDisplayConcern
      command_name 'equipment'
      aliases 'eq', 'worn', 'wearing'
      category :inventory
      output_category :info
      help_text 'View what you are wearing and holding'
      usage 'equipment'
      examples 'equipment', 'eq', 'worn'

      protected

      def perform_command(_parsed_input)
        items = character_instance.objects_dataset.all

        held_items = items.select(&:held?)
        worn_items = items.select(&:worn?)

        if held_items.empty? && worn_items.empty?
          return success_result("You aren't wearing or holding anything.", type: :message, data: { action: 'equipment' })
        end

        html = +""
        html << build_section("In Hand", held_items) if held_items.any?
        html << build_section("Wearing", worn_items) if worn_items.any?

        success_result(
          html,
          type: :message,
          data: {
            action: 'equipment',
            worn_count: worn_items.count,
            held_count: held_items.count
          }
        )
      end

    end
  end
end

Commands::Base::Registry.register(Commands::Inventory::Equipment)
