# frozen_string_literal: true

module Commands
  module Inventory
    class Hold < Commands::Base::Command
      command_name 'hold'
      aliases 'wield', 'brandish', 'unsheathe', 'unholster', 'draw'
      category :inventory
      help_text 'Hold an item from your inventory or draw from a holster (visible to others)'
      usage 'hold <item>'
      examples 'hold sword', 'hold torch', 'draw dagger'

      protected

      def perform_command(parsed_input)
        target = parsed_input[:text]
        items = holdable_items

        # No argument - show menu
        if blank?(target)
          return error_result("You have nothing to hold.") if items.empty?
          return item_selection_menu(items, 'What would you like to hold?', command: 'hold')
        end

        target = target.strip

        return error_result("You have nothing to hold.") if items.empty?

        # Find the item
        result = resolve_item_with_menu(target, items)

        if result[:disambiguation]
          return disambiguation_result(result[:result], "Which '#{target}' do you want to hold?")
        end

        return error_result(result[:error] || "You don't have '#{target}'.") if result[:error]

        item = result[:match]

        if item.held?
          return error_result("You're already holding #{item.name}.")
        end

        # Check if drawing from a holster
        if item.holstered?
          draw_from_holster(item)
        else
          perform_item_action(
            item: item,
            action_method: :hold!,
            action_name: 'hold',
            self_verb: 'hold',
            other_verb: 'holds up'
          )
        end
      end

      private

      def holdable_items
        # Include both inventory items and holstered weapons
        inventory = character_instance.inventory_items.all.reject(&:held?)
        holstered = character_instance.holstered_items.all
        inventory + holstered
      end

      def draw_from_holster(item)
        holster = item.holster_item
        holster_name = holster&.name || 'holster'

        item.unholster!
        item.hold!

        broadcast_to_room("#{character.full_name} draws #{item.name} from #{holster_name}.")
        success_result("You draw #{item.name} from #{holster_name}.")
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Inventory::Hold)
