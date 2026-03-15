# frozen_string_literal: true

module Commands
  module Inventory
    class Showdesc < Commands::Base::Command
      command_name 'showdesc'
      aliases 'show description', 'showitem'
      category :inventory
      help_text 'Show the description of an item to other players'
      usage 'showdesc <item>'
      examples 'showdesc ring', 'showdesc silver necklace'

      protected

      def perform_command(parsed_input)
        target = parsed_input[:text]
        return error_result("Show the description of what?") if blank?(target)

        target = target.strip

        # Find item in all owned items (worn, carried, stored)
        item = find_owned_item(target)
        return error_result("You don't have any items like '#{target}'.") unless item

        unless item.desc_hidden
          return error_result("#{item.name} already has its description visible.")
        end

        item.update(desc_hidden: false)

        success_result(
          "You reveal the description of #{item.name}. Others can now see its details.",
          type: :message,
          data: { action: 'showdesc', item_id: item.id, item_name: item.name }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Inventory::Showdesc)
