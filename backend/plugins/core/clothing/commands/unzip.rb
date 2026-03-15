# frozen_string_literal: true

require_relative '../concerns/clothing_command_helper'

module Commands
  module Clothing
    class Unzip < Commands::Base::Command
      include Commands::Clothing::ClothingCommandHelper
      command_name 'unzip'
      aliases 'unbutton', 'tear open', 'rip open'
      category :clothing
      help_text 'Unzip or unbutton worn clothing'
      usage 'unzip <item> [, item2, item3...]'
      examples 'unzip jacket', 'unbutton shirt', 'unzip jacket, hoodie', 'unzip jacket and shirt'

      protected

      def perform_command(parsed_input)
        input = parsed_input[:text]
        return error_result("Unzip what?") if blank?(input)

        item_names = parse_multi_item_input(input)
        return error_result("Unzip what?") if item_names.empty?

        worn_items = character_instance.worn_items.all

        # Single item case
        if item_names.length == 1
          item = find_worn_item(item_names.first)
          return error_result("You're not wearing '#{item_names.first}'.") unless item
          return error_result("#{item.name} is already unzipped.") unless item.zipped?

          item.update(zipped: false)

          broadcast_to_room(
            "#{character.full_name} unzips their #{item.name}.",
            exclude_character: character_instance
          )

          return success_result(
            "You unzip #{item.name}.",
            type: :message,
            data: { action: 'unzip', item_id: item.id, item_name: item.name }
          )
        end

        # Multiple items case
        result = toggle_worn_items(
          item_names: item_names,
          worn_items: worn_items,
          attribute: :zipped,
          target_value: false,
          already_msg: 'already unzipped'
        )
        successes = result[:successes]
        failures  = result[:failures]

        if successes.empty?
          return error_result(failures.first[:reason].capitalize + '.')
        end

        success_names = successes.map(&:name)

        broadcast_to_room(
          "#{character.full_name} unzips their #{success_names.join(', ')}.",
          exclude_character: character_instance
        )

        message = "You unzip #{success_names.join(', ')}."
        message += format_failure_notes(failures, prefix: 'Could not unzip')

        success_result(
          message,
          type: :message,
          data: { action: 'unzip', items: success_names, item_ids: successes.map(&:id) }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Clothing::Unzip)
