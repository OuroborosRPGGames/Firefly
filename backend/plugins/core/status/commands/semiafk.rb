# frozen_string_literal: true

require_relative '../concerns/status_command_helper'

module Commands
  module Status
    class Semiafk < Commands::Base::Command
      include Commands::Status::StatusCommandHelper
      command_name 'semiafk'
      aliases 'semi-afk', 'semi', 'distracted'
      category :system
      help_text 'Toggle semi-away status (partially present but distracted)'
      usage 'semiafk [minutes]'
      examples 'semiafk', 'semiafk 30', 'semi-afk 15'

      protected

      def perform_command(parsed_input)
        minutes = parse_minutes(parsed_input[:text])

        if character_instance.semiafk?
          clear_semiafk
        else
          set_semiafk(minutes)
        end
      end

      private

      def clear_semiafk
        character_instance.clear_semiafk!

        broadcast_status_change("refocuses as they put away their phone. [Semi-AFK removed]")

        success_result(
          "You are no longer semi-AFK.",
          type: :message,
          data: { action: 'semiafk_clear' }
        )
      end

      def set_semiafk(minutes)
        character_instance.set_semiafk!(minutes)

        duration_text = minutes ? "#{minutes} Minutes" : "Indefinite"
        broadcast_status_change("gets distracted by their phone. [Semi-AFK #{duration_text}]")

        message = minutes ? "You are now semi-AFK for #{minutes} minutes." : "You are now semi-AFK."
        success_result(
          message,
          type: :message,
          data: { action: 'semiafk_set', duration_minutes: minutes }
        )
      end

    end
  end
end

Commands::Base::Registry.register(Commands::Status::Semiafk)
