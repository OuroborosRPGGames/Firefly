# frozen_string_literal: true

require_relative '../../../../app/helpers/message_persistence_helper'

module Commands
  module Social
    class Private < Commands::Base::Command
      include MessagePersistenceHelper
      include MessageFormattingHelper

      command_name 'private'
      aliases 'priv'
      category :social
      help_text 'Toggle private mode or perform a private emote visible only to you and your target'
      usage 'private, private <target> <emote>, private to <target> <emote>'
      examples 'private', 'private Bob winks knowingly', 'private to Alice makes a subtle gesture'

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]

        # No args: toggle private mode
        return toggle_private_mode if blank?(text)

        # Has args: perform private emote
        perform_private_emote(text, parsed_input)
      end

      private

      def toggle_private_mode
        character_instance.toggle_private_mode!

        if character_instance.private_mode?
          broadcast_to_room("#{character.full_name} enters private mode.")
          success_result(
            "You are now in private mode. Adult content is now visible when viewing others who are also in private mode.",
            type: :status,
            data: { private_mode: true }
          )
        else
          broadcast_to_room("#{character.full_name} leaves private mode.")
          success_result(
            "You have left private mode. Adult content is now hidden.",
            type: :status,
            data: { private_mode: false }
          )
        end
      end

      def perform_private_emote(text, parsed_input)
        # Use normalizer for "emote to target" reverse pattern (e.g., "private winks to Bob")
        normalized = parsed_input[:normalized]
        if normalized[:target] && normalized[:message] && text =~ /\bto\b/i && !text.match?(/^to\s+/i)
          text = "#{normalized[:target]} #{normalized[:message]}"
        else
          # Strip optional "to " prefix (existing behavior)
          text = text.sub(/^to\s+/i, '') if text.match?(/^to\s+/i)
        end

        # Use multi-word target matching (e.g., "short lady nudges" matches "short lady")
        target_instance, target_name, emote_text = find_target_and_message(text, exclude_self: false)

        return error_result("Who do you want to do something privately with?") if blank?(target_name)
        return error_result("What do you want to do privately?") if blank?(emote_text)

        # Check if targeting self
        if target_instance&.id == character_instance.id
          return error_result("You can't do something privately with yourself.")
        end

        return error_result("You don't see anyone by that name here.") unless target_instance

        # Validate for spam and abuse
        error = validate_message_content(emote_text, message_type: 'private_emote',
                                         duplicate_error: "You recently performed a similar private action.")
        return error if error

        # Resolve @mentions to character full names (skip DB query if no @ in text)
        if emote_text.include?('@')
          room_chars = CharacterInstance
                         .where(current_room_id: location.id, online: true)
                         .eager(:character).all
          emote_text = EmoteFormatterService.resolve_at_mentions(emote_text, character_instance, room_chars)
        end

        # Build base emote with full names (for persistence and personalization)
        base_emote = build_base_emote(emote_text, target_instance)

        # Participants for name lookup
        participants = [character_instance, target_instance]

        # Create personalized versions using EmoteFormatterService
        sender_message = format_private_for_sender(base_emote, target_instance, participants, target_name)
        target_message = format_private_for_target(base_emote, target_instance, participants)

        # Send ONLY to target via WebSocket (sender gets message via HTTP response)
        send_to_character(target_instance, target_message)

        # Log to RP logs for both sender and target
        log_roleplay(base_emote, type: :private_emote, target: target_instance)

        # Persist with private_emote type (not broadcast to room)
        message_record = persist_targeted_message(
          base_emote,
          target_instance,
          message_type: 'private_emote'
        )

        message_result(
          'private_emote',
          character.full_name,
          sender_message,
          target: target_instance.character.full_name,
          message_id: message_record&.id,
          message_created_at: message_record&.created_at,
          formatted_message: sender_message,
          skip_room_sync: true
        )
      end

      # Build base emote with real names for persistence.
      # Replaces "you" with target's full name so personalization works correctly.
      def build_base_emote(emote_text, target_instance)
        sanitized = emote_text.to_s
        # Replace "you" with target's full name in the emote text
        base = sanitized.gsub(/\byou\b/i, target_instance.character.full_name)
        # Prepend sender's name and add punctuation
        process_punctuation("#{character.full_name} #{base}")
      end

      # Format for sender: personalized names + private tag
      # @param matched_name [String] The name text the sender actually typed to target them
      def format_private_for_sender(base_emote, target_instance, participants, matched_name = nil)
        formatted = EmoteFormatterService.format_for_viewer(
          base_emote, character, character_instance, participants
        )
        # Use the matched name for the tag (what the sender typed), falling back to forename
        tag_name = matched_name || target_instance.character.forename
        "#{formatted} <sup class=\"emote-tag\">(Private to #{tag_name})</sup>"
      end

      # Format for target: personalized names + tag
      # Name display (bolded forename vs "you") is handled by user's perspective setting
      def format_private_for_target(base_emote, target_instance, participants)
        formatted = EmoteFormatterService.format_for_viewer(
          base_emote, character, target_instance, participants
        )
        "#{formatted} <sup class=\"emote-tag\">(Privately)</sup>"
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Social::Private)
