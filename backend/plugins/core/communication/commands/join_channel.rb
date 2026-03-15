# frozen_string_literal: true

module Commands
  module Communication
    class JoinChannel < Commands::Base::Command
      command_name 'join channel'
      aliases 'joinchannel', 'chan join', 'channel join'
      category :communication
      help_text 'Join a communication channel'
      usage 'join channel <name>'
      examples 'join channel OOC', 'joinchannel General'

      protected

      def perform_command(parsed_input)
        channel_name = parsed_input[:text]&.strip

        if blank?(channel_name)
          return error_result("Which channel do you want to join? Usage: join channel <name>")
        end

        # Find the channel
        channel = ChannelBroadcastService.find_channel(channel_name)

        unless channel
          return error_result("No channel found named '#{channel_name}'.\nUse 'channels' to see available channels.")
        end

        # Check if already a member
        if channel.member?(character)
          return error_result("You're already a member of #{channel.name}.")
        end

        # Check if channel is public or invite-only
        unless channel.is_public
          return error_result("#{channel.name} is a private channel. You need an invitation to join.")
        end

        # Join the channel
        channel.add_member(character)

        # Notify other members
        online_members = ChannelBroadcastService.online_members(channel, exclude: [character_instance])
        join_message = "[#{channel.name}] #{character.full_name} has joined the channel."

        online_members.each do |member_instance|
          BroadcastService.to_character(member_instance, join_message, type: :channel)
        end

        success_result(
          "You have joined #{channel.name}.\nUse 'channel #{channel.name} <message>' to chat.",
          type: :message,
          data: {
            action: 'join_channel',
            channel_id: channel.id,
            channel_name: channel.name
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Communication::JoinChannel)
