# frozen_string_literal: true

module Commands
  module Prisoner
    class Drag < Commands::Base::Command
      command_name 'drag'
      aliases 'haul'
      category :combat
      help_text 'Drag a helpless character'
      usage 'drag <character>'
      examples 'drag Bob'

      requires_alive

      protected

      def perform_command(parsed_input)
        transport_action(
          target_name: parsed_input[:args].join(' '),
          action_type: :drag,
          check_timeline: true
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Prisoner::Drag)
