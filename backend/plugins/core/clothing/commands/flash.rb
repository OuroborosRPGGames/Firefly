# frozen_string_literal: true

module Commands
  module Clothing
    class Flash < Commands::Base::Command
      command_name 'flash'
      category :clothing
      help_text 'Quickly flash a concealed item (reveal then hide again)'
      usage 'flash <item>'
      examples 'flash badge', 'flash weapon'

      protected

      def perform_command(parsed_input)
        item_name = parsed_input[:text]
        return error_result("Flash what?") if blank?(item_name)

        item_name = item_name.strip

        item = find_worn_item(item_name)
        return error_result("You're not wearing '#{item_name}'.") unless item
        return error_result("#{item.name} is already visible - use 'expose' instead.") unless item.concealed?

        # Flash is a theatrical reveal - item stays concealed
        # The broadcast message conveys the brief reveal

        broadcast_to_room(
          "#{character.full_name} briefly flashes #{item.name}.",
          exclude_character: character_instance
        )

        success_result(
          "You briefly flash #{item.name}, giving others a glimpse before concealing it again.",
          type: :message,
          data: { action: 'flash', item_id: item.id, item_name: item.name }
        )
      end

      private

      # Uses inherited find_worn_item from base command
    end
  end
end

Commands::Base::Registry.register(Commands::Clothing::Flash)
