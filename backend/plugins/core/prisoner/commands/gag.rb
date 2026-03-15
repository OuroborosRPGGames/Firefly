# frozen_string_literal: true

module Commands
  module Prisoner
    class Gag < Commands::Base::Command
      command_name 'gag'
      aliases 'muzzle'
      category :combat
      help_text 'Gag a helpless character to prevent speech'
      usage 'gag <character>'
      examples 'gag Bob'

      requires_alive

      protected

      def perform_command(parsed_input)
        apply_restraint_action(
          target_name: parsed_input[:args].join(' '),
          restraint_type: 'gag',
          action_verb: 'gag',
          target_msg_template: '%{actor} gags you. You can no longer speak.'
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Prisoner::Gag)
