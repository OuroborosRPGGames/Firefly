# frozen_string_literal: true

require_relative '../concerns/consumable_concern'

module Commands
  module Consumption
    class Drink < Commands::Base::Command
      include ConsumableConcern

      command_name 'drink'
      aliases 'sip', 'gulp', 'quaff'
      category :inventory
      help_text 'Drink a beverage from your inventory'
      usage 'drink <item>'
      examples 'drink water', 'drink coffee', 'sip wine'

      consumable_config(
        consume_type: 'drink',
        verb: 'drinking',
        verb_past: 'drink',
        state_check: :drinking?,
        item_accessor: :drinking_item,
        start_method: :start_drinking!,
        default_action: 'It looks refreshing.',
        broadcast_verb: 'begins drinking'
      )
    end
  end
end

Commands::Base::Registry.register(Commands::Consumption::Drink)
