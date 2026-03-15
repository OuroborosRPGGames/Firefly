# frozen_string_literal: true

module Commands
  module Communication
    class Undo < Commands::Base::Command
      command_name 'undo'
      category :communication
      help_text 'Delete your last message'
      usage 'undo'
      examples 'undo'

      protected

      def perform_command(_parsed_input)
        panel = request_env['firefly.source_panel'] || 'right'
        redis_key = "undo:#{panel}:#{character_instance.id}"

        undo_data = nil
        REDIS_POOL.with do |redis|
          raw = redis.get(redis_key)
          return error_result("Nothing to undo.") unless raw

          undo_data = JSON.parse(raw)
          redis.del(redis_key)
        end

        broadcast_id = undo_data['broadcast_id']

        if panel == 'right'
          undo_right_panel(undo_data, broadcast_id)
        else
          undo_left_panel(undo_data, broadcast_id)
        end

        success_result("Message undone.", target_panel: panel == 'left' ? :left_main_feed : :right_main_feed)
      end

      private

      def undo_right_panel(undo_data, broadcast_id)
        # Delete IC message from database
        if undo_data['message_id']
          msg = Message[undo_data['message_id']]
          msg&.delete
        end

        # Send delete event to everyone in the room
        room_id = undo_data['room_id']
        if room_id
          BroadcastService.to_room(
            room_id,
            { broadcast_id: broadcast_id },
            type: :delete_message
          )
        end
      end

      def undo_left_panel(undo_data, broadcast_id)
        # Channel messages
        channel = ::Channel[undo_data['channel_id']] if undo_data['channel_id']
        if channel
          members = ChannelBroadcastService.online_members(channel, exclude: [character_instance])
          members.each do |member|
            BroadcastService.to_character(
              member,
              { broadcast_id: broadcast_id },
              type: :delete_message
            )
          end
        end

        # DM messages - delete records and notify recipients
        if undo_data['dm_ids']
          undo_data['dm_ids'].each do |dm_id|
            dm = DirectMessage[dm_id]
            dm&.delete
          end
        end

        # OOC/DM recipient screen deletion
        recipient_ids = undo_data['recipient_instance_ids'] || undo_data['ooc_recipient_instance_ids'] || []
        recipient_ids.each do |rid|
          ci = CharacterInstance[rid]
          next unless ci&.online

          BroadcastService.to_character(
            ci,
            { broadcast_id: broadcast_id },
            type: :delete_message
          )
        end

        # Always delete from sender's own screen
        BroadcastService.to_character(
          character_instance,
          { broadcast_id: broadcast_id },
          type: :delete_message
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Communication::Undo)
