# frozen_string_literal: true

module Commands
  module Communication
    class LeaveChannel < Commands::Base::Command
      command_name 'leave channel'
      aliases 'leavechannel', 'chan leave', 'channel leave', 'part channel'
      category :communication
      help_text 'Leave a communication channel'
      usage 'leave channel <name>'
      examples 'leave channel OOC', 'leavechannel General'

      protected

      def perform_command(parsed_input)
        channel_name = parsed_input[:text]&.strip

        if blank?(channel_name)
          return error_result("Which channel do you want to leave? Usage: leave channel <name>")
        end

        # Find the channel
        channel = ChannelBroadcastService.find_channel(channel_name)

        unless channel
          return error_result("No channel found named '#{channel_name}'.")
        end

        # Check if a member
        unless channel.member?(character)
          return error_result("You're not a member of #{channel.name}.")
        end

        # Notify other members before leaving
        online_members = ChannelBroadcastService.online_members(channel, exclude: [character_instance])
        leave_message = "[#{channel.name}] #{character.full_name} has left the channel."

        online_members.each do |member_instance|
          BroadcastService.to_character(member_instance, leave_message, type: :channel)
        end

        # Leave the channel
        channel.remove_member(character)

        success_result(
          "You have left #{channel.name}.",
          type: :message,
          data: {
            action: 'leave_channel',
            channel_id: channel.id,
            channel_name: channel.name
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Communication::LeaveChannel)
