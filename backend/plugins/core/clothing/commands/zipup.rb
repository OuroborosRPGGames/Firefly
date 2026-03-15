# frozen_string_literal: true

require_relative '../concerns/clothing_command_helper'

module Commands
  module Clothing
    class Zipup < Commands::Base::Command
      include Commands::Clothing::ClothingCommandHelper
      command_name 'zipup'
      aliases 'zip', 'button', 'do up', 'button up'
      category :clothing
      help_text 'Zip up or button worn clothing'
      usage 'zipup <item> [, item2, item3...]'
      examples 'zipup jacket', 'zip hoodie', 'button shirt', 'zipup jacket, hoodie', 'zip jacket and hoodie'

      protected

      def perform_command(parsed_input)
        input = parsed_input[:text]
        return error_result("Zip up what?") if blank?(input)

        item_names = parse_multi_item_input(input)
        return error_result("Zip up what?") if item_names.empty?

        worn_items = character_instance.worn_items.all

        # Single item case
        if item_names.length == 1
          item = find_worn_item(item_names.first)
          return error_result("You're not wearing '#{item_names.first}'.") unless item
          return error_result("#{item.name} is already zipped up.") if item.zipped?

          item.update(zipped: true)

          broadcast_to_room(
            "#{character.full_name} zips up their #{item.name}.",
            exclude_character: character_instance
          )

          return success_result(
            "You zip up #{item.name}.",
            type: :message,
            data: { action: 'zipup', item_id: item.id, item_name: item.name }
          )
        end

        # Multiple items case
        result = toggle_worn_items(
          item_names: item_names,
          worn_items: worn_items,
          attribute: :zipped,
          target_value: true,
          already_msg: 'already zipped up'
        )
        successes = result[:successes]
        failures  = result[:failures]

        if successes.empty?
          return error_result(failures.first[:reason].capitalize + '.')
        end

        success_names = successes.map(&:name)

        broadcast_to_room(
          "#{character.full_name} zips up their #{success_names.join(', ')}.",
          exclude_character: character_instance
        )

        message = "You zip up #{success_names.join(', ')}."
        message += format_failure_notes(failures, prefix: 'Could not zip up')

        success_result(
          message,
          type: :message,
          data: { action: 'zipup', items: success_names, item_ids: successes.map(&:id) }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Clothing::Zipup)
