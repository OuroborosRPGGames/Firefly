# frozen_string_literal: true

require_relative '../concerns/consumable_concern'

module Commands
  module Consumption
    class Eat < Commands::Base::Command
      include ConsumableConcern

      command_name 'eat'
      aliases 'consume', 'taste', 'swallow'
      category :inventory
      help_text 'Eat food from your inventory'
      usage 'eat <item>'
      examples 'eat apple', 'eat sandwich', 'eat bread'

      consumable_config(
        consume_type: 'food',
        verb: 'eating',
        verb_past: 'eat',
        state_check: :eating?,
        item_accessor: :eating_item,
        start_method: :start_eating!,
        default_action: 'It looks edible.',
        broadcast_verb: 'begins eating'
      )
    end
  end
end

Commands::Base::Registry.register(Commands::Consumption::Eat)
