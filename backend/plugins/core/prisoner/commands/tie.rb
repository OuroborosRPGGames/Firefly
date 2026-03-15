# frozen_string_literal: true

module Commands
  module Prisoner
    class Tie < Commands::Base::Command
      command_name 'tie'
      aliases 'bind', 'restrain'
      category :combat
      help_text 'Bind a helpless character'
      usage 'tie <character> [hands/feet]'
      examples 'tie Bob', 'tie Jane hands', 'bind Bob feet'

      requires_alive

      protected

      def perform_command(parsed_input)
        args = parsed_input[:args].dup

        # Parse restraint type from end of args
        restraint_type = 'hands' # default
        if %w[hands feet].include?(args.last&.downcase)
          restraint_type = args.pop.downcase
        end

        apply_restraint_action(
          target_name: args.join(' '),
          restraint_type: restraint_type,
          action_verb: 'bind',
          empty_error: 'Tie whom?',
          other_msg_template: "%{actor} binds %{target}'s %{type}.",
          target_msg_template: "%{actor} binds your %{type}.",
          self_msg_template: "You bind %{target}'s %{type}.",
          check_timeline: true
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Prisoner::Tie)
