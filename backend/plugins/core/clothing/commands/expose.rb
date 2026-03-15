# frozen_string_literal: true

require_relative '../concerns/clothing_command_helper'

module Commands
  module Clothing
    class Expose < Commands::Base::Command
      include Commands::Clothing::ClothingCommandHelper
      command_name 'expose'
      aliases 'reveal'
      category :clothing
      help_text 'Reveal hidden/concealed items you are wearing'
      usage 'expose <item> [, item2, item3...]'
      examples 'expose dagger', 'reveal badge', 'expose dagger, badge, weapon'

      protected

      def perform_command(parsed_input)
        input = parsed_input[:text]
        return error_result("Expose what?") if blank?(input)

        item_names = parse_multi_item_input(input)
        return error_result("Expose what?") if item_names.empty?

        worn_items = character_instance.worn_items.all

        # Single item case
        if item_names.length == 1
          item = find_worn_item(item_names.first)
          return error_result("You're not wearing '#{item_names.first}'.") unless item
          return error_result("#{item.name} is already visible.") unless item.concealed?

          item.update(concealed: false)

          broadcast_to_room(
            "#{character.full_name} reveals #{item.name}.",
            exclude_character: character_instance
          )

          return success_result(
            "You expose #{item.name}, making it visible.",
            type: :message,
            data: { action: 'expose', item_id: item.id, item_name: item.name }
          )
        end

        # Multiple items case
        result = toggle_worn_items(
          item_names: item_names,
          worn_items: worn_items,
          attribute: :concealed,
          target_value: false,
          already_msg: 'already visible'
        )
        successes = result[:successes]
        failures  = result[:failures]

        if successes.empty?
          return error_result(failures.first[:reason].capitalize + '.')
        end

        success_names = successes.map(&:name)

        broadcast_to_room(
          "#{character.full_name} reveals #{success_names.join(', ')}.",
          exclude_character: character_instance
        )

        message = "You expose #{success_names.join(', ')}, making them visible."
        message += format_failure_notes(failures, prefix: 'Could not expose')

        success_result(
          message,
          type: :message,
          data: { action: 'expose', items: success_names, item_ids: successes.map(&:id) }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Clothing::Expose)
