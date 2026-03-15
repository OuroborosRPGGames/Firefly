# frozen_string_literal: true

require_relative '../concerns/consumable_concern'

module Commands
  module Consumption
    class Smoke < Commands::Base::Command
      include ConsumableConcern

      command_name 'smoke'
      aliases 'puff', 'light up'
      category :inventory
      help_text 'Smoke something from your inventory'
      usage 'smoke <item>'
      examples 'smoke cigarette', 'smoke cigar', 'puff pipe'

      consumable_config(
        consume_type: 'smoke',
        verb: 'smoking',
        verb_past: 'smoke',
        state_check: :smoking?,
        item_accessor: :smoking_item,
        start_method: :start_smoking!,
        default_action: 'Wisps of smoke curl upward.',
        broadcast_verb: 'lights up'
      )
    end
  end
end

Commands::Base::Registry.register(Commands::Consumption::Smoke)
