# frozen_string_literal: true

require_relative '../concerns/clothing_command_helper'

module Commands
  module Clothing
    class Cover < Commands::Base::Command
      include Commands::Clothing::ClothingCommandHelper
      command_name 'cover'
      aliases 'conceal', 'hide'
      category :clothing
      help_text 'Conceal visible items you are wearing'
      usage 'cover <item> [, item2, item3...]'
      examples 'cover dagger', 'conceal badge', 'hide weapon', 'cover dagger, badge, weapon'

      protected

      def perform_command(parsed_input)
        input = parsed_input[:text]
        return error_result("Cover what?") if blank?(input)

        item_names = parse_multi_item_input(input)
        return error_result("Cover what?") if item_names.empty?

        worn_items = character_instance.worn_items.all

        # Single item case
        if item_names.length == 1
          item = find_worn_item(item_names.first)
          return error_result("You're not wearing '#{item_names.first}'.") unless item
          return error_result("#{item.name} is already concealed.") if item.concealed?

          item.update(concealed: true)

          # No broadcast - concealing is supposed to be subtle
          return success_result(
            "You discreetly cover #{item.name}, hiding it from view.",
            type: :message,
            data: { action: 'cover', item_id: item.id, item_name: item.name }
          )
        end

        # Multiple items case
        result = toggle_worn_items(
          item_names: item_names,
          worn_items: worn_items,
          attribute: :concealed,
          target_value: true,
          already_msg: 'already concealed'
        )
        successes = result[:successes]
        failures  = result[:failures]

        if successes.empty?
          return error_result(failures.first[:reason].capitalize + '.')
        end

        success_names = successes.map(&:name)
        message = "You discreetly cover #{success_names.join(', ')}, hiding them from view."
        message += format_failure_notes(failures, prefix: 'Could not cover')

        success_result(
          message,
          type: :message,
          data: { action: 'cover', items: success_names, item_ids: successes.map(&:id) }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Clothing::Cover)
