# frozen_string_literal: true

require_relative '../concerns/status_command_helper'

module Commands
  module Status
    class Gtg < Commands::Base::Command
      include Commands::Status::StatusCommandHelper
      command_name 'gtg'
      aliases 'gottago', 'gotta_go'
      category :system
      help_text 'Set "got to go" status indicating imminent departure'
      usage 'gtg [minutes]'
      examples 'gtg', 'gtg 15', 'gtg 30'

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]&.strip

        # Empty command clears GTG status
        if blank?(text)
          return clear_gtg if character_instance.gtg?
          return error_result("You don't have GTG status set. Use 'gtg [minutes]' to set it.")
        end

        minutes = text.to_i
        minutes = 15 if minutes <= 0
        minutes = 1000 if minutes > 1000  # Cap at 1000 minutes

        set_gtg(minutes)
      end

      private

      def clear_gtg
        character_instance.clear_gtg!

        success_result(
          "GTG status cleared.",
          type: :message,
          data: { action: 'gtg_clear' }
        )
      end

      def set_gtg(minutes)
        character_instance.set_gtg!(minutes)

        broadcast_status_change("receives a message on their phone. [GTG #{minutes} Minutes]")

        success_result(
          "GTG status set for #{minutes} minutes.",
          type: :message,
          data: { action: 'gtg_set', duration_minutes: minutes }
        )
      end

    end
  end
end

Commands::Base::Registry.register(Commands::Status::Gtg)
