# frozen_string_literal: true

module Commands
  module Staff
    class Broadcast < ::Commands::Base::Command
      command_name 'broadcast'
      aliases 'announce'
      category :staff
      help_text 'Send a broadcast message to all players'
      usage 'broadcast <message>'
      examples 'broadcast Server maintenance in 10 minutes!'

      protected

      def perform_command(parsed_input)
        error = require_staff(via_user: true)
        return error if error

        text = parsed_input[:text]
        error = require_input(text, 'Usage: broadcast <message>')
        return error if error

        broadcast = StaffBroadcast.create(
          created_by_user_id: character.user.id,
          content: text.strip
        )

        delivered_count = broadcast.deliver!

        success_result(
          "Broadcast sent to #{delivered_count} online player#{'s' unless delivered_count == 1}. Offline players will receive it on login."
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Staff::Broadcast)
