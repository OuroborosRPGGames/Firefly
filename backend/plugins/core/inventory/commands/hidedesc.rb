# frozen_string_literal: true

module Commands
  module Inventory
    class Hidedesc < Commands::Base::Command
      command_name 'hidedesc'
      aliases 'hide description', 'hideitem'
      category :inventory
      help_text 'Hide the description of an item from other players'
      usage 'hidedesc <item>'
      examples 'hidedesc ring', 'hidedesc silver necklace'

      protected

      def perform_command(parsed_input)
        target = parsed_input[:text]
        return error_result("Hide the description of what?") if blank?(target)

        target = target.strip

        # Find item in all owned items (worn, carried, stored)
        item = find_owned_item(target)
        return error_result("You don't have any items like '#{target}'.") unless item

        if item.desc_hidden
          return error_result("#{item.name} already has its description hidden.")
        end

        item.update(desc_hidden: true)

        success_result(
          "You hide the description of #{item.name}. Others won't see its details.",
          type: :message,
          data: { action: 'hidedesc', item_id: item.id, item_name: item.name }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Inventory::Hidedesc)
