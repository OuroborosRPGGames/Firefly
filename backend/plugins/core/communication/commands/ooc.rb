# frozen_string_literal: true

require_relative '../concerns/multi_target_helper'

module Commands
  module Communication
    class Ooc < Commands::Base::Command
      include MultiTargetHelper
      command_name 'ooc'
      aliases 'oocp', 'oocmsg'
      category :communication
      help_text 'Send a private OOC message to one or more players'
      usage 'ooc <name(s)> <message>'
      examples(
        'ooc Alice Hello there!',
        'ooc Alice,Bob,Charlie Hey everyone!',
        'ooc Bob How are you doing?'
      )

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]&.strip

        # Show recent OOC contacts if no arguments
        if blank?(text)
          return show_ooc_contacts
        end

        # Parse recipients and optional message
        # "ooc Alice,Bob" → set target only
        # "ooc Alice,Bob Hello!" → set target + send
        match = text.match(/^(\S+)(?:\s+(.+))?$/m)
        unless match
          return error_result("Usage: ooc <name(s)> [message]\n\nExamples:\n  ooc Alice Hello!\n  ooc Alice,Bob Hey everyone!\n  ooc Alice,Bob  (sets OOC mode)")
        end

        recipient_str = match[1]
        message = match[2]&.strip

        recipient_names = parse_target_names(recipient_str)
        return error_result("Who do you want to message?") if recipient_names.empty?

        result = find_targets_by_names(recipient_names) do |name|
          char = find_character_by_name_globally(name)
          char&.user
        end
        recipient_users = result[:targets]
        not_found = result[:not_found]

        return no_targets_error(not_found) if recipient_users.empty?

        # Persist OOC mode state
        found_names = recipient_users.map { |u| display_name_for_user(u) }.join(', ')
        character_instance.update(
          messaging_mode: 'ooc',
          last_channel_name: 'ooc',
          current_ooc_target_ids: Sequel.pg_array(recipient_users.map(&:id)),
          ooc_target_names: recipient_str
        )
        ChannelHistoryService.push(character_instance)

        # If no message, just set mode (target only)
        if blank?(message)
          return success_result(
            "OOC mode set. Now messaging: #{found_names}",
            type: :status,
            data: { action: 'ooc_mode_set', target_names: found_names }
          )
        end

        # Send via OocMessageService
        broadcast_id = SecureRandom.uuid
        result = OocMessageService.send_message(character_instance, recipient_users, message, broadcast_id: broadcast_id)

        if result[:success]
          # Store undo context for deletion
          recipient_ids = recipient_users.map { |u| find_online_instance_id(u) }.compact
          store_undo_context('left', broadcast_id: broadcast_id, ooc_recipient_instance_ids: recipient_ids)
          # Build response message
          response_msg = result[:message]
          if not_found.any?
            response_msg += "\n(Could not find: #{not_found.join(', ')})"
          end

          success_result(
            response_msg,
            type: :message,
            data: {
              action: 'ooc_message_sent',
              recipient_user_ids: result[:data][:recipient_user_ids],
              recipient_names: result[:data][:recipient_names],
              sent_count: result[:data][:sent_count]
            }
          )
        else
          error_result(result[:error] || result[:message] || "Failed to send OOC message.")
        end
      end

      private

      # Show recent OOC contacts for quick messaging
      def show_ooc_contacts
        contacts = OocMessage.recent_contacts_for(current_user, limit: 10)

        if contacts.empty?
          return error_result(
            "No recent OOC contacts.\n\n" \
            "Usage: ooc <name(s)> <message>\n" \
            "  ooc Alice Hello!\n" \
            "  ooc Alice,Bob Hey everyone!"
          )
        end

        # Build contact list
        lines = ["Recent OOC contacts:"]
        contacts.each_with_index do |user, idx|
          char_name = display_name_for_user(user)
          lines << "  #{idx + 1}. #{char_name}"
        end
        lines << ""
        lines << "Usage: ooc <name> <message>"

        success_result(lines.join("\n"), type: :message)
      end

      # Get display name for a user
      def display_name_for_user(user)
        char = Character.where(user_id: user.id).exclude(is_npc: true).first
        char&.full_name || user.username || "User##{user.id}"
      end

      def find_online_instance_id(user)
        char = Character.where(user_id: user.id).exclude(is_npc: true).first
        return nil unless char

        ci = CharacterInstance.where(character_id: char.id, online: true).first
        ci&.id
      end

      def current_user
        character.user
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Communication::Ooc)
