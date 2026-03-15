# frozen_string_literal: true

module Commands
  module Prisoner
    class Carry < Commands::Base::Command
      command_name 'carry'
      aliases 'pickup', 'lift'
      category :combat
      help_text 'Pick up and carry a helpless character'
      usage 'carry <character>'
      examples 'carry Bob', 'pickup Jane'

      requires_alive

      protected

      def perform_command(parsed_input)
        transport_action(
          target_name: parsed_input[:args].join(' '),
          action_type: :carry
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Prisoner::Carry)
