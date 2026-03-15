# frozen_string_literal: true

module Commands
  module Communication
    class Channels < Commands::Base::Command
      command_name 'channels'
      aliases 'chanlist', 'channel list', 'listchannels'
      category :communication
      help_text 'List available communication channels'
      usage 'channels'
      examples 'channels', 'chanlist'

      protected

      def perform_command(_parsed_input)
        channels = ChannelBroadcastService.available_channels(character)

        if channels.empty?
          return success_result(
            "No channels available.\nAsk an admin to create channels for this game.",
            type: :message,
            data: { action: 'channels', count: 0 }
          )
        end

        lines = ["<h3>Available Channels</h3>"]

        channels.each do |ch|
          status = if ch[:is_member]
                     ch[:muted] ? '(muted)' : '(joined)'
                   else
                     '(not joined)'
                   end

          type_label = ch[:type].upcase
          online = "#{ch[:online_count]} online"

          lines << "  [#{type_label}] <b>#{ch[:name]}</b> #{status} - #{online}"
          lines << "      #{ch[:description]}" if ch[:description] && !ch[:description].empty?
        end

        lines << ""
        lines << "Use 'join channel <name>' to join a channel."
        lines << "Use 'channel <name> <message>' to chat."
        lines << "Use 'ooc <message>' for quick OOC chat."

        success_result(
          lines.join("\n"),
          type: :message,
          data: {
            action: 'channels',
            count: channels.length
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Communication::Channels)
