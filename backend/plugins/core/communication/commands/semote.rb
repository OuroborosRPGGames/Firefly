# frozen_string_literal: true

require_relative '../../../../app/helpers/message_persistence_helper'
require_relative '../../../../app/helpers/emote_approach_helper'
require_relative '../concerns/emote_broadcast_concern'
require_relative '../concerns/offline_mention_concern'

module Commands
  module Communication
    class SEmote < Commands::Base::Command
      include MessagePersistenceHelper
      include EmoteApproachHelper
      include EmoteBroadcastConcern
      include OfflineMentionConcern

      command_name 'semote'
      aliases 'smartemote', 'sem'
      category :roleplaying
      help_text 'Perform an action with automatic game command extraction'
      usage 'semote <action>'
      examples 'semote stands up and walks to the door', 'semote sits on the couch', 'sem draws his sword'

      requires_can_communicate_ic

      def can_execute?
        !!(super && location)
      end

      protected

      def perform_command(parsed_input)
        error = check_not_gagged("express yourself")
        return error if error

        emote_text = extract_emote_text(parsed_input)
        error = require_input(emote_text, "What did you want to emote?")
        return error if error

        error = validate_message_content(emote_text, message_type: 'emote',
                                         duplicate_error: "You recently performed a similar action.")
        return error if error

        rate_check = EmoteRateLimitService.check(character_instance, location)
        unless rate_check[:allowed]
          return error_result(rate_check[:message])
        end

        adverb, clean_text = extract_adverb(emote_text)
        processed_message = process_standard_emote(clean_text, adverb)
        processed_message = process_punctuation(processed_message)

        message_record = persist_room_message(processed_message, message_type: 'emote')
        return error_result("You can't seem to perform that action right now.") unless message_record

        broadcast_emote(processed_message)

        if EmoteRateLimitService.rate_limiting_active?(location, character_instance.reality_id)
          EmoteRateLimitService.record_emote(character_instance.id)
        end

        character_instance.update(last_channel_name: 'room')
        spawn_llm_processing(emote_text) unless character_instance.in_combat?

        # Use styled self_message for the HTTP response (avoids duplication with WebSocket)
        styled_content = @self_message || processed_message
        message_result(
          'semote',
          character.full_name,
          styled_content,
          message_id: message_record&.id,
          message_created_at: message_record&.created_at
        )
      end

      private

      def process_standard_emote(text, adverb = nil)
        text = resolve_mentions_and_approach(text) if text.include?('@')
        build_emote_message(character.full_name, text, adverb)
      end

      def broadcast_emote(message)
        is_spotlighted = character_instance.spotlighted?
        room_characters = online_room_characters.eager(:character).all

        @self_message = format_self_message(message, is_spotlighted, room_characters)
        broadcast_personalized_emote(message, is_spotlighted, room_characters)
        notify_offline_mentions(message)
        character_instance.decrement_spotlight! if is_spotlighted
      end

      def broadcast_personalized_emote(base_message, is_spotlighted, room_characters)
        NameLearningService.process_emote(character, base_message, room_characters)

        room_characters.each do |viewer_instance|
          next if viewer_instance.id == character_instance.id

          personalized_message = EmoteFormatterService.format_for_viewer(
            base_message, character, viewer_instance, room_characters
          )
          personalized_message = apply_wrapper_styling(personalized_message, is_spotlighted)

          send_to_character(viewer_instance, personalized_message)
        end
      end

      # Spawn a background thread to handle LLM action extraction
      # This allows the emote to broadcast immediately while processing continues async
      def spawn_llm_processing(emote_text)
        # Capture context needed for the background thread
        ci_id = character_instance.id

        Thread.new do
          process_llm_actions(ci_id, emote_text)
        rescue StandardError => e
          warn "[Semote] Background LLM processing error: #{e.message}"
        end
      end

      # Process LLM action extraction and execution
      # Called in background thread
      def process_llm_actions(character_instance_id, emote_text)
        # Re-fetch character instance in this thread (Sequel connections are thread-local)
        ci = CharacterInstance[character_instance_id]
        return unless ci

        # Skip if character is now in combat (may have changed since thread spawned)
        return if ci.in_combat?

        # Interpret the emote to extract actions
        result = SemoteInterpreterService.interpret(emote_text, ci)
        return unless result[:success] && result[:actions]&.any?

        # Get the semote log that was created during interpretation
        semote_log = SemoteLog.where(character_instance_id: ci.id)
                              .order(Sequel.desc(:created_at))
                              .first

        # Execute the extracted actions
        SemoteExecutorService.execute_actions_sequentially(
          character_instance: ci,
          actions: result[:actions],
          emote_text: emote_text,
          semote_log: semote_log
        )
      rescue StandardError => e
        warn "[Semote] LLM action processing failed: #{e.message}"
      end
    end
  end
end

# Auto-register the command when the file is loaded
Commands::Base::Registry.register(Commands::Communication::SEmote)
