# frozen_string_literal: true

require_relative '../concerns/multi_target_helper'

module Commands
  module Communication
    class Msg < Commands::Base::Command
      include MultiTargetHelper
      command_name 'msg'
      aliases 'dm', 'text'
      category :communication
      help_text 'Send a direct message to someone, regardless of location'
      usage 'msg <name> <message>'
      examples 'msg Alice Hey, where are you?', 'dm Bob Meeting at 5', 'text Charlie On my way!'

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]
        return error_result("Who do you want to message?") if blank?(text)

        # Parse: "msg Alice,Bob Hello!" or "msg Alice,Bob" (set target only)
        # First word is comma-separated target names, rest is message
        target_str, message = parse_target_and_message(text)
        return error_result("Who do you want to message?") if blank?(target_str)

        target_names = parse_target_names(target_str)
        return error_result("Who do you want to message?") if target_names.empty?

        result = find_targets_by_names(target_names) { |name| find_character_globally(name) }
        targets = result[:targets]
        not_found = result[:not_found]

        return no_targets_error(not_found) if targets.empty?

        # Persist MSG mode state
        found_names = targets.map(&:full_name).join(', ')
        character_instance.update(
          messaging_mode: 'msg',
          last_channel_name: 'msg',
          msg_target_character_ids: Sequel.pg_array(targets.map(&:id)),
          msg_target_names: target_str
        )
        ChannelHistoryService.push(character_instance)

        # If no message, just set mode (target only)
        if blank?(message)
          return success_result(
            "MSG mode set. Now messaging: #{found_names}",
            type: :status,
            data: { action: 'msg_mode_set', target_names: found_names }
          )
        end

        # Send to each target via DirectMessageService
        broadcast_id = SecureRandom.uuid
        results = []
        targets.each do |target|
          result = DirectMessageService.send_message(character_instance, target, message, broadcast_id: broadcast_id)
          results << { target: target, result: result }
        end

        # Show phone use in modern era (if visible) - once for all targets
        show_phone_use_if_applicable(targets.first) if targets.any?

        # Update DM target tracking
        targets.each { |t| update_dm_targets(t.id) }

        # Build combined response
        success_count = results.count { |r| r[:result][:success] }
        if success_count > 0
          # Store undo context - collect DM IDs and recipient instance IDs for deletion
          dm_ids = results.select { |r| r[:result][:success] }.map { |r| r[:result][:data]&.dig(:message_id) }.compact
          recipient_ids = targets.map { |t| t.primary_instance&.id }.compact
          store_undo_context('left', broadcast_id: broadcast_id, dm_ids: dm_ids, recipient_instance_ids: recipient_ids)
          first_success = results.find { |r| r[:result][:success] }
          response_msg = first_success[:result][:message]
          if targets.length > 1
            other_names = targets.reject { |t| t == first_success[:target] }.map(&:full_name)
            response_msg += "\n(Also sent to: #{other_names.join(', ')})" if other_names.any?
          end
          if not_found.any?
            response_msg += "\n(Could not find: #{not_found.join(', ')})"
          end

          # Return structured result
          dm_data = first_success[:result][:data] || {}
          dm_data[:action] = 'dm_sent'
          dm_data[:content] = response_msg
          success_result(
            response_msg,
            type: :message,
            data: dm_data
          )
        else
          error_result(results.first[:result][:error] || "Failed to send message.")
        end
      end

      private

      # Show "eyes flick to phone" in modern era if visible phone use
      def show_phone_use_if_applicable(target)
        return unless EraService.visible_phone_use?

        phone_message = "#{character.full_name}'s eyes flick to their phone."
        online_room_characters(exclude: [character_instance]).each do |observer|
          send_to_character(observer, phone_message)
        end
      end

      # Update DM target list for status bar (keep last 10)
      def update_dm_targets(target_id)
        current = character_instance.last_dm_target_ids || []
        new_list = ([target_id] + current).uniq.first(10)
        character_instance.update(last_dm_target_ids: Sequel.pg_array(new_list))
      rescue StandardError => e
        warn "[Msg] Error updating DM targets: #{e.message}"
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Communication::Msg)
