# frozen_string_literal: true

require_relative '../concerns/status_command_helper'

module Commands
  module Status
    class Quiet < Commands::Base::Command
      include Commands::Status::StatusCommandHelper
      command_name 'quiet'
      aliases 'quietmode'
      category :system
      help_text 'Toggle quiet mode to hide all channel messages (OOC, global, area, group)'
      usage 'quiet'
      examples 'quiet'

      protected

      def perform_command(_parsed_input)
        if character_instance.quiet_mode?
          # Exiting quiet mode - show catch-up menu
          exit_quiet_mode
        else
          # Entering quiet mode
          enter_quiet_mode
        end
      end

      private

      def enter_quiet_mode
        character_instance.set_quiet_mode!

        broadcast_status_change('puts on their headphones, tuning out the chatter. [Quiet Mode]')

        success_result(
          'Quiet mode enabled. Channel messages will be hidden until you type "quiet" again.',
          type: :message,
          data: { action: 'quiet_enabled' }
        )
      end

      def exit_quiet_mode
        # Count missed messages for the prompt
        since = character_instance.quiet_mode_since
        missed_count = count_missed_messages(since)

        if missed_count.zero?
          # No messages to catch up on, just disable
          character_instance.clear_quiet_mode!
          broadcast_status_change('takes off their headphones. [Quiet Mode Off]')

          return success_result(
            'Quiet mode disabled. No missed messages.',
            type: :message,
            data: { action: 'quiet_disabled', missed_count: 0 }
          )
        end

        # Show catch-up quickmenu
        options = [
          { key: 'yes', label: 'Yes', description: "View up to #{[missed_count, 100].min} missed messages" },
          { key: 'no', label: 'No', description: 'Skip the catch-up summary' }
        ]

        create_quickmenu(
          character_instance,
          "You missed #{missed_count} channel message#{'s' if missed_count != 1}. Would you like to catch up?",
          options,
          context: {
            command: 'quiet',
            quiet_mode_since: since&.iso8601
          }
        )
      end

      def count_missed_messages(since)
        return 0 unless since

        Message.where(message_type: channel_types)
               .where { created_at >= since }
               .count
      end

      def channel_types
        %w[ooc channel broadcast global area group]
      end

    end
  end
end

Commands::Base::Registry.register(Commands::Status::Quiet)
