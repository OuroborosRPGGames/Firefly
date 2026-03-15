# frozen_string_literal: true

module Commands
  module Communication
    class Channel < Commands::Base::Command
      command_name 'channel'
      aliases 'chan', 'ch', '+'
      category :communication
      help_text 'Chat on a communication channel'
      usage 'channel <name> <message> OR + <message>'
      examples(
        'channel ooc Hello everyone!',
        '+ Hi there!',
        'chan general What\'s up?'
      )

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]&.strip
        command_word = parsed_input[:command_word]&.downcase

        # Handle '+' shortcut for OOC channel: '+ <message>'
        if command_word == '+'
          return handle_ooc_shortcut(text)
        end

        # Standard format: 'channel <name> <message>'
        if blank?(text)
          return error_result("Usage: channel <name> <message>\nOr use '+ <message>' for quick OOC channel chat.")
        end

        # Parse channel name and message - support multi-word channel names
        # Try progressively longer prefixes until we find a match
        channel, message = find_channel_and_message(text)

        unless channel
          first_word = text.split(/\s+/).first
          return error_result("No channel found named '#{first_word}'.\nUse 'channels' to see available channels.")
        end

        if blank?(message)
          return error_result("What do you want to say? Usage: channel #{channel.name} <message>")
        end

        send_to_channel_object(channel, message)
      end

      private

      # Find channel by progressively trying longer prefixes of the text
      # Returns [channel, remaining_message]
      def find_channel_and_message(text)
        words = text.split(/\s+/)

        # Try progressively longer prefixes
        words.length.downto(1) do |len|
          candidate_name = words[0...len].join(' ')
          channel = ChannelBroadcastService.find_channel(candidate_name)

          if channel
            remaining = words[len..].join(' ')
            return [channel, remaining]
          end
        end

        # No channel found - try prefix matching on first word
        first_word = words.first
        channel = ::Channel.where(Sequel.ilike(:name, "#{first_word}%")).first
        if channel
          remaining = words[1..].join(' ')
          return [channel, remaining]
        end

        [nil, nil]
      end

      def handle_ooc_shortcut(message)
        if blank?(message)
          return error_result("What do you want to say? Usage: ooc <message>")
        end

        # Find default OOC channel
        channel = ChannelBroadcastService.default_ooc_channel

        unless channel
          return error_result("No OOC channel exists.\nAsk an admin to create one, or use 'channel <name> <message>'.")
        end

        send_to_channel_object(channel, message)
      end

      def send_to_channel_object(channel, message)
        # Check membership
        unless channel.member?(character)
          # Auto-join public channels
          if channel.is_public
            channel.add_member(character)
          else
            return error_result("You're not a member of #{channel.name}.\nUse 'join channel #{channel.name}' to join.")
          end
        end

        # Check not muted
        membership = ChannelMember.where(channel_id: channel.id, character_id: character.id).first
        if membership&.is_muted
          return error_result("You are muted in #{channel.name}.")
        end

        # Validate message content (spam/abuse check)
        error = validate_message_content(message, message_type: 'channel')
        return error if error

        # Broadcast to channel
        broadcast_id = SecureRandom.uuid
        result = ChannelBroadcastService.broadcast(channel, character_instance, message, broadcast_id: broadcast_id)

        unless result[:success]
          return error_result(result[:error] || "Failed to send message.")
        end

        # Store undo context in Redis (60-second TTL)
        store_undo_context('left', broadcast_id: broadcast_id, channel_id: channel.id)

        # Track channel usage for status bar and reset messaging mode
        character_instance.update(last_channel_name: channel.name, messaging_mode: 'channel')
        ChannelHistoryService.push(character_instance)

        success_result(
          nil, # Message already sent by ChannelBroadcastService
          type: :message,
          data: {
            action: 'channel',
            channel_id: channel.id,
            channel_name: channel.name,
            message: message,
            member_count: result[:member_count]
          }
        )
      end

      # Check if we have the validation helper
      def validate_message_content(message, message_type:)
        return nil unless respond_to?(:check_for_abuse, true)

        result = check_for_abuse(message, message_type: message_type)
        return nil if result[:allowed]

        error_result(result[:reason] || "Your message could not be sent.")
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Communication::Channel)
