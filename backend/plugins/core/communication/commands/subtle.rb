# frozen_string_literal: true

require_relative '../../../../app/helpers/message_persistence_helper'
require_relative '../concerns/offline_mention_concern'

module Commands
  module Communication
    class Subtle < Commands::Base::Command
      include MessagePersistenceHelper
      include OfflineMentionConcern

      command_name 'subtle'
      category :roleplaying
      help_text 'Perform a subtle action visible only to those nearby'
      usage 'subtle <action>'
      examples 'subtle slides a note across the table', 'subtle winks conspiratorially'

      requires_can_communicate_ic

      def can_execute?
        !!(super && location)
      end

      protected

      def perform_command(parsed_input)
        error = check_not_gagged("express yourself")
        return error if error

        emote_text = extract_emote_text(parsed_input)
        error = require_input(emote_text, "What did you want to do subtly?")
        return error if error

        error = validate_message_content(emote_text, message_type: 'subtle',
                                         duplicate_error: "You recently performed a similar action.")
        return error if error

        if emote_text.include?('@')
          room_chars = CharacterInstance
                         .where(current_room_id: location.id, online: true)
                         .eager(:character).all
          emote_text = EmoteFormatterService.resolve_at_mentions(emote_text, character_instance, room_chars)
        end

        processed_message = "#{character.full_name} #{emote_text}"
        processed_message = process_punctuation(processed_message)

        message_record = persist_room_message(processed_message, message_type: 'subtle')
        return error_result("You can't seem to perform that action right now.") unless message_record

        broadcast_subtle_emote(processed_message)

        # Track channel usage for status bar
        character_instance.update(last_channel_name: 'room')

        # Use styled self_message for HTTP response (avoids duplication with WebSocket)
        styled_content = @self_message || processed_message
        message_result(
          'subtle',
          character.full_name,
          styled_content,
          subtle: true,
          message_id: message_record&.id,
          message_created_at: message_record&.created_at,
          skip_room_sync: true
        )
      end

      private

      def broadcast_subtle_emote(message)
        current_place = character_instance.current_place

        # Get all online characters in room
        room_characters = online_room_characters.eager(:character, :current_place).all

        # Determine who can see the full message (nearby characters only)
        full_recipients, _obscured_recipients = partition_recipients(room_characters, current_place)

        # Log for nearby witnesses only (not room-wide)
        log_roleplay(message, type: :subtle, recipients: full_recipients + [character_instance])

        subtle_tag = ' <sup class="emote-tag">(Subtle)</sup>'

        # Send full message to nearby characters
        full_recipients.each do |viewer_instance|
          next if viewer_instance.id == character_instance.id

          personalized = EmoteFormatterService.format_for_viewer(
            message,
            character,
            viewer_instance,
            room_characters
          )
          send_to_character(viewer_instance, "<span class=\"subtle-emote\">#{personalized}#{subtle_tag}</span>")
        end

        # Distant characters see nothing (removed obscured message)

        # Self message is delivered via message_result (HTTP response), not WebSocket
        self_formatted = EmoteFormatterService.format_for_viewer(
          message,
          character,
          character_instance,
          room_characters
        )
        @self_message = "<span class=\"subtle-emote\">#{self_formatted}#{subtle_tag}</span>"
      end

      # Partition room characters into those who see full message vs obscured
      #
      # Rules:
      # - At a place: characters at same place see full, others see obscured
      # - Not at a place: other ungrouped characters see full, those at places see obscured
      #
      # @return [Array<Array>] [full_recipients, obscured_recipients]
      def partition_recipients(room_characters, current_place)
        full_recipients = []
        obscured_recipients = []

        room_characters.each do |viewer|
          next if viewer.id == character_instance.id

          if current_place
            # Actor is at a place: same place sees full, others see obscured
            if viewer.current_place_id == current_place.id
              full_recipients << viewer
            else
              obscured_recipients << viewer
            end
          else
            # Actor is not at a place: other ungrouped characters see full
            if viewer.current_place_id.nil?
              full_recipients << viewer
            else
              obscured_recipients << viewer
            end
          end
        end

        [full_recipients, obscured_recipients]
      end

      def build_obscured_message(current_place)
        if current_place
          "[Someone at #{current_place.name} does something quietly.]"
        else
          "[Someone nearby does something quietly.]"
        end
      end
    end
  end
end

# Auto-register the command when the file is loaded
Commands::Base::Registry.register(Commands::Communication::Subtle)
