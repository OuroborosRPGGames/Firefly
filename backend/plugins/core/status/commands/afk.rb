# frozen_string_literal: true

require_relative '../concerns/status_command_helper'

module Commands
  module Status
    class Afk < Commands::Base::Command
      include Commands::Status::StatusCommandHelper
      command_name 'afk'
      aliases 'away'
      category :system
      help_text 'Toggle away from keyboard status'
      usage 'afk [minutes]'
      examples 'afk', 'afk 30', 'away'

      # Override touch_activity! to not clear AFK when this command sets it
      def touch_activity!
        return unless character_instance

        # Only update last_activity, don't clear AFK (this IS the AFK command)
        character_instance.update(last_activity: Time.now)
      end

      protected

      def perform_command(parsed_input)
        minutes = parse_minutes(parsed_input[:text])

        if character_instance.afk?
          clear_afk
        else
          set_afk(minutes)
        end
      end

      private

      def clear_afk
        character_instance.clear_afk!

        broadcast_status_change("refocuses as they put away their phone. [AFK removed]")

        success_result(
          "You are no longer AFK.",
          type: :message,
          data: { action: 'afk_clear' }
        )
      end

      def set_afk(minutes)
        character_instance.set_afk!(minutes)

        duration_text = minutes ? "#{minutes} Minutes" : "Indefinite"
        broadcast_status_change("gets busy with their phone. [AFK #{duration_text}]")

        message = minutes ? "You are now AFK for #{minutes} minutes." : "You are now AFK."
        success_result(
          message,
          type: :message,
          data: { action: 'afk_set', duration_minutes: minutes }
        )
      end

    end
  end
end

Commands::Base::Registry.register(Commands::Status::Afk)
