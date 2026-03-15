# frozen_string_literal: true

module Commands
  module Communication
    class Reply < Commands::Base::Command
      command_name 'reply'
      aliases 'respond'
      category :communication
      help_text 'Reply to whoever last OOC or MSG messaged you'
      usage 'reply [message]'
      examples(
        'reply',
        'reply Hey, got your message!'
      )

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]&.strip

        target_info = character_instance.last_reply_target
        unless target_info
          return error_result('No one has messaged you recently.')
        end

        target_char = target_info[:character]
        target_type = target_info[:type]

        if target_type == :ooc
          handle_ooc_reply(target_char, text)
        else
          handle_msg_reply(target_char, text)
        end
      end

      private

      def handle_ooc_reply(target_char, message)
        target_user = target_char.user
        unless target_user
          return error_result('Could not find that player.')
        end

        target_name = target_char.full_name

        # Set OOC mode targeting the sender
        character_instance.update(
          messaging_mode: 'ooc',
          last_channel_name: 'ooc',
          current_ooc_target_ids: Sequel.pg_array([target_user.id]),
          ooc_target_names: target_name
        )
        ChannelHistoryService.push(character_instance)

        # If no message, just set mode
        if blank?(message)
          return success_result(
            "OOC mode set. Now messaging: #{target_name}",
            type: :status,
            data: { action: 'ooc_mode_set', target_names: target_name }
          )
        end

        # Send via OocMessageService
        broadcast_id = SecureRandom.uuid
        result = OocMessageService.send_message(character_instance, [target_user], message, broadcast_id: broadcast_id)

        if result[:success]
          # Store undo context
          recipient_ci = CharacterInstance.where(character_id: target_char.id, online: true).first
          store_undo_context('left', broadcast_id: broadcast_id, ooc_recipient_instance_ids: [recipient_ci&.id].compact)

          success_result(
            result[:message],
            type: :message,
            data: {
              action: 'ooc_message_sent',
              recipient_user_ids: result[:data][:recipient_user_ids],
              recipient_names: result[:data][:recipient_names],
              sent_count: result[:data][:sent_count]
            }
          )
        else
          error_result(result[:error] || result[:message] || 'Failed to send OOC message.')
        end
      end

      def handle_msg_reply(target_char, message)
        target_name = target_char.full_name

        # Set MSG mode targeting the sender
        character_instance.update(
          messaging_mode: 'msg',
          last_channel_name: 'msg',
          msg_target_character_ids: Sequel.pg_array([target_char.id]),
          msg_target_names: target_name
        )
        ChannelHistoryService.push(character_instance)

        # If no message, just set mode
        if blank?(message)
          return success_result(
            "MSG mode set. Now messaging: #{target_name}",
            type: :status,
            data: { action: 'msg_mode_set', target_names: target_name }
          )
        end

        # Send via DirectMessageService
        broadcast_id = SecureRandom.uuid
        result = DirectMessageService.send_message(character_instance, target_char, message, broadcast_id: broadcast_id)

        if result[:success]
          # Store undo context
          dm_id = result[:data]&.dig(:message_id)
          recipient_ci = CharacterInstance.where(character_id: target_char.id, online: true).first
          store_undo_context('left', broadcast_id: broadcast_id, dm_ids: [dm_id].compact, recipient_instance_ids: [recipient_ci&.id].compact)

          success_result(
            result[:message],
            type: :message,
            data: result[:data]&.merge(action: 'dm_sent') || { action: 'dm_sent' }
          )
        else
          error_result(result[:error] || result[:message] || 'Failed to send message.')
        end
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Communication::Reply)
