# frozen_string_literal: true

require_relative '../../../../app/helpers/message_persistence_helper'
require_relative '../../../../app/helpers/communication_permission_helper'

module Commands
  module Communication
    class Whisper < Commands::Base::Command
      include MessagePersistenceHelper
      include MessageFormattingHelper
      include CommunicationPermissionHelper

      command_name 'whisper'
      aliases 'whi', 'wh'
      category :roleplaying
      help_text 'Whisper privately to someone in the room'
      usage 'whisper <target> <message>'
      examples 'whisper John Hello there!', 'whi Bob quietly How are you?'

      requires_can_communicate_ic

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]

        # No argument - show quickmenu of people in room
        if blank?(text)
          return show_whisper_menu
        end

        # Use normalizer for flexible patterns ("whisper to bob hello", "whisper hello to bob")
        normalized = parsed_input[:normalized]
        if normalized[:target] && normalized[:message]
          target_name = normalized[:target]
          message = normalized[:message]
        else
          target_name, message = parse_target_and_message(text)
        end

        error = require_input(target_name, "Who did you want to whisper to?")
        return error if error
        error = require_input(message, "What did you want to whisper?")
        return error if error

        # Find target character with disambiguation
        # Note: do not exclude self here; we handle self-target explicitly below.
        candidates = find_characters_in_room(location&.id)
        result = resolve_character_with_menu(target_name, candidates, { action: 'whisper', message: message })

        # If disambiguation needed, return the quickmenu
        if result[:disambiguation]
          return disambiguation_result(result[:result], "Who do you want to whisper to?")
        end

        # If error (no match found)
        return error_result(result[:error] || "You don't see anyone by that name here.") if result[:error]

        target_instance = result[:match]

        # Prevent self-whisper
        error = prevent_self_target(target_instance, "whisper to")
        return error if error

        # Check IC messaging permission
        error = check_ic_permission(target_instance)
        return error if error

        # Validate for spam and abuse (uses consolidated helper)
        error = validate_message_content(message, message_type: 'whisper',
                                         duplicate_error: "You recently whispered something similar.")
        return error if error

        # Extract adverb if present
        adverb, clean_message = extract_adverb(message)

        # Format the whisper message
        formatted_message = format_whisper_message(
          target_instance.character.full_name,
          clean_message,
          adverb
        )

        # Persist message (uses MessagePersistenceHelper)
        message_record = persist_targeted_message(formatted_message, target_instance, message_type: 'whisper')
        return error_result("You can't seem to whisper right now.") unless message_record

        # Broadcast to appropriate recipients
        broadcast_id = SecureRandom.uuid
        broadcast_whisper(formatted_message, target_instance, adverb, broadcast_id: broadcast_id)

        # Store undo context in Redis (60-second TTL)
        store_undo_context('right', broadcast_id: broadcast_id, message_id: message_record.id, room_id: location.id)

        # Log roleplay
        log_roleplay(formatted_message, type: :whisper, target: target_instance)

        # Track channel usage for status bar
        character_instance.update(last_channel_name: 'whisper')

        # Self-view uses preferred name (nickname/forename)
        self_name = character.display_name_for(character_instance)
        # Target uses forename - sender targeted them by name
        target_display = target_instance.character.forename
        self_formatted = format_narrative_message(
          character_name: self_name,
          text: process_punctuation(clean_message.strip),
          verb: 'whispers',
          target_name: target_display,
          adverb: adverb,
          adverb_before_verb: true,
          speech_color: character.speech_color
        )

        message_result(
          'whisper',
          character.full_name,
          clean_message,
          target: target_instance.character.full_name,
          message_id: message_record&.id,
          message_created_at: message_record&.created_at,
          formatted_message: self_formatted
        )
      end

      private

      def show_whisper_menu
        # Get other characters in the room (uses CharacterLookupHelper)
        others = find_others_in_room(location&.id, exclude_id: character_instance.id)

        if others.empty?
          return error_result("There's no one here to whisper to.")
        end

        options = others.each_with_index.map do |ci, idx|
          char = ci.character
          desc = char.short_desc || ''
          desc = desc[0..30] + '...' if desc.length > 33
          {
            key: (idx + 1).to_s,
            label: char.full_name,
            description: desc
          }
        end

        options << { key: 'q', label: 'Cancel', description: 'Nevermind' }

        char_data = others.map { |ci| { id: ci.id, name: ci.character.forename } }

        create_quickmenu(
          character_instance,
          "Who do you want to whisper to?",
          options,
          context: {
            command: 'whisper',
            stage: 'select_target',
            characters: char_data
          }
        )
      end

      # Note: parse_whisper_input removed - use parse_target_and_message from base command

      def format_whisper_message(target_name, message, adverb = nil)
        # Uses shared helper for narrative formatting
        # whisper places adverb before verb: "quietly whispers" not "whispers quietly"
        format_narrative_message(
          character_name: character.full_name,
          text: process_punctuation(message.strip),
          verb: 'whispers',
          target_name: target_name,
          adverb: adverb,
          adverb_before_verb: true,
          speech_color: character.speech_color
        )
      end

      # comma_punctuate is now inherited from MessageFormattingHelper

      def broadcast_whisper(full_message, target_instance, adverb = nil, broadcast_id: nil)
        target_name = target_instance.character.full_name

        # Send full message to target (personalized)
        personalized_message = substitute_names_for_viewer(full_message, target_instance)
        send_to_character(target_instance, personalized_message, broadcast_id: broadcast_id)

        # Send obscured message to others in room (excluding sender and target)
        obscured_message = format_obscured_message(
          character_name: character.full_name,
          verb: 'whispers',
          target_name: target_name,
          adverb: adverb
        )

        # Uses consolidated helper for observer broadcast
        broadcast_to_observers_personalized(obscured_message,
                                            exclude_instances: [character_instance, target_instance],
                                            broadcast_id: broadcast_id)

        # Trigger NPC animation (NPCs notice the whisper but content is obscured)
        if location && defined?(NpcAnimationService)
          NpcAnimationService.process_room_broadcast(
            room_id: location.id,
            content: obscured_message,
            sender_instance: character_instance,
            type: :whisper
          )
        end
      end

      # Note: substitute_names_for_viewer is now inherited from Base::Command
      # Note: has_recent_duplicate?, persist_targeted_message come from MessagePersistenceHelper
      # Note: check_ic_permission inherited from CommunicationPermissionHelper
    end
  end
end

Commands::Base::Registry.register(Commands::Communication::Whisper)
