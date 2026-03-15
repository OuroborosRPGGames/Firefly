# frozen_string_literal: true

module Commands
  module Prisoner
    class Blindfold < Commands::Base::Command
      command_name 'blindfold'
      aliases 'hood'
      category :combat
      help_text 'Blindfold a helpless character to block their vision'
      usage 'blindfold <character>'
      examples 'blindfold Bob'

      requires_alive

      protected

      def perform_command(parsed_input)
        apply_restraint_action(
          target_name: parsed_input[:args].join(' '),
          restraint_type: 'blindfold',
          action_verb: 'blindfold',
          target_msg_template: '%{actor} blindfolds you. Everything goes dark.'
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Prisoner::Blindfold)
