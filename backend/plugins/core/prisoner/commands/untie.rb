# frozen_string_literal: true

module Commands
  module Prisoner
    class Untie < Commands::Base::Command
      command_name 'untie'
      aliases 'unbind', 'free'
      category :combat
      help_text 'Remove restraints from a character'
      usage 'untie <character> [hands/feet/gag/blindfold/all]'
      examples 'untie Bob', 'untie Jane hands', 'free Bob all'

      requires_alive

      protected

      def perform_command(parsed_input)
        args = parsed_input[:args].dup

        # Parse restraint type from end of args
        restraint_type = 'all' # default - remove all
        valid_types = %w[hands feet gag blindfold all]
        if valid_types.include?(args.last&.downcase)
          restraint_type = args.pop.downcase
        end

        remove_restraint_action(
          target_name: args.join(' '),
          restraint_type: restraint_type
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Prisoner::Untie)
