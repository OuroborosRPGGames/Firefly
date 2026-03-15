# frozen_string_literal: true

# Shared logic for consumable commands (eat, drink, smoke).
#
# Usage:
#   class Eat < Commands::Base::Command
#     include ConsumableConcern
#
#     consumable_config(
#       consume_type: 'food',
#       verb: 'eating',
#       verb_past: 'eat',
#       state_check: :eating?,
#       item_accessor: :eating_item,
#       start_method: :start_eating!,
#       default_action: 'It looks edible.',
#       broadcast_verb: 'begins eating'
#     )
#   end
#
module ConsumableConcern
  def self.included(base)
    base.extend ClassMethods
  end

  module ClassMethods
    def consumable_config(options = {})
      @consumable_config = options
    end

    def get_consumable_config
      @consumable_config || {}
    end
  end

  protected

  def perform_command(parsed_input)
    config = self.class.get_consumable_config
    item_name = parsed_input[:text]&.strip

    # Validate input
    if blank?(item_name)
      return error_result("#{config[:verb_past].capitalize} what? Use: #{self.class.command_name} <item>")
    end

    # Check if already consuming
    if character_instance.send(config[:state_check])
      current_item = character_instance.send(config[:item_accessor])
      return error_result("You're already #{config[:verb]} #{current_item&.name || 'something'}.")
    end

    # Find consumable item in inventory
    item = find_consumable_item(item_name, config[:consume_type])
    unless item
      return error_result("You don't have any '#{item_name}' to #{config[:verb_past]}.")
    end

    # Start consuming
    item.start_consuming!
    character_instance.send(config[:start_method], item)

    taste_text = item.taste_text
    action_text = taste_text ? taste_text : config[:default_action]

    broadcast_to_room(
      "#{character.full_name} #{config[:broadcast_verb]} #{item.name}.",
      exclude_character: character_instance
    )

    success_result(
      "You start #{config[:verb]} #{item.name}. #{action_text}",
      type: :message,
      data: {
        action: config[:verb_past],
        item_id: item.id,
        item_name: item.name,
        consume_time: item.pattern&.consume_time
      }
    )
  end

  private

  def find_consumable_item(name, consume_type)
    items = character_instance.inventory_items
              .eager(:pattern)
              .all
              .select { |i| i.pattern&.consume_type == consume_type }

    TargetResolverService.resolve(
      query: name,
      candidates: items,
      name_field: :name
    )
  end
end
