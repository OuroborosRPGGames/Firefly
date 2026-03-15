# frozen_string_literal: true

require_relative '../../../../app/helpers/message_persistence_helper'
require_relative '../../../../app/helpers/emote_approach_helper'
require_relative '../concerns/emote_broadcast_concern'
require_relative '../concerns/offline_mention_concern'

module Commands
  module Communication
    class Emote < Commands::Base::Command
      include MessagePersistenceHelper
      include EmoteApproachHelper
      include EmoteBroadcastConcern
      include OfflineMentionConcern

      command_name 'emote'
      aliases 'pose', ':', 'emit'
      category :roleplaying
      help_text 'Perform an action or express emotion'
      usage 'emote <action>, pose <action>, or :<action>'
      examples 'emote waves hello', ':smiles warmly', 'pose stretches'

      requires_can_communicate_ic

      def can_execute?
        !!(super && location)
      end

      protected

      def perform_command(parsed_input)
        error = check_not_gagged("express yourself")
        return error if error

        emote_text = extract_emote_text(parsed_input)
        emote_text = sanitize_user_html(emote_text) if emote_text
        error = require_input(emote_text, "What did you want to emote?")
        return error if error

        error = validate_message_content(emote_text, message_type: 'emote',
                                         duplicate_error: "You recently performed a similar action.")
        return error if error

        rate_check = EmoteRateLimitService.check(character_instance, location)
        unless rate_check[:allowed]
          return error_result(rate_check[:message])
        end

        emit_mode = parsed_input[:command_word] == 'emit'
        adverb, clean_text = extract_adverb(emote_text)

        if emit_mode && can_emit?
          processed_message = clean_text
        else
          processed_message = process_standard_emote(clean_text, adverb)
        end

        # Capital-letter emote without self-reference: require name inclusion or lowercase
        if processed_message == :no_self_reference
          return error_result(
            "Emotes starting with a capital letter should include your name (#{character.forename}). " \
            "Use lowercase to auto-prepend your name, e.g.: emote waves hello",
            restore_input: emote_text
          )
        end

        processed_message = process_punctuation(processed_message)

        message_record = persist_room_message(processed_message, message_type: 'emote')
        return error_result("You can't seem to perform that action right now.") unless message_record

        broadcast_id = SecureRandom.uuid
        broadcast_emote(processed_message, emit_mode, broadcast_id: broadcast_id)
        store_undo_context('right', broadcast_id: broadcast_id, message_id: message_record.id, room_id: location.id)

        if EmoteRateLimitService.rate_limiting_active?(location, character_instance.reality_id)
          EmoteRateLimitService.record_emote(character_instance.id)
        end

        character_instance.update(last_channel_name: 'room')

        # Use styled self_message for the HTTP response (avoids duplication with WebSocket)
        styled_content = @self_message || processed_message
        message_result(
          'emote',
          character.full_name,
          styled_content,
          emit_mode: emit_mode,
          message_id: message_record&.id,
          message_created_at: message_record&.created_at,
          skip_room_sync: true
        )
      end
      
      private
      
      def can_emit?
        return false unless character.respond_to?(:staff_level)

        staff_level = character.staff_level
        return false if blank?(staff_level)
        %w[admin staff gm].include?(staff_level.to_s.downcase)
      end
      
      def process_standard_emote(text, adverb = nil)
        # Resolve @mentions and silently approach first target
        text = resolve_mentions_and_approach(text) if text.include?('@')

        # Capital-letter emotes must include a self-reference; lowercase auto-prepends name
        if text.match?(/\A[A-Z]/)
          if mentions_self?(text)
            present?(adverb) ? "#{adverb.capitalize}, #{text}" : text
          else
            return :no_self_reference
          end
        else
          build_emote_message(character.full_name, text, adverb)
        end
      end
      
      def broadcast_emote(message, emit_mode = false, broadcast_id: nil)
        is_spotlighted = character_instance.spotlighted?

        # All online room characters for name lookup and delivery
        all_room_chars = CharacterInstance
                          .where(current_room_id: location.id, online: true)
                          .eager(:character)
                          .all

        @self_message = format_self_message(message, is_spotlighted, all_room_chars, emit_mode: emit_mode)

        broadcast_personalized_emote(message, emit_mode, is_spotlighted, all_room_chars, broadcast_id: broadcast_id)

        # Log IC activity (NPC animation + all IC side effects)
        # Exclude sender since broadcast_personalized_emote already logged them via RpLoggingService
        log_roleplay(message, type: :emote, exclude: [character_instance.id])

        notify_offline_mentions(message)
        character_instance.decrement_spotlight! if is_spotlighted
      end

      def broadcast_personalized_emote(base_message, emit_mode, is_spotlighted, all_room_chars, broadcast_id: nil)
        NameLearningService.process_emote(character, base_message, all_room_chars)

        # Log base (unpersonalized) message to RP for all witnesses
        # Uses RpLoggingService directly to avoid re-triggering NPC/AutoGM side effects
        RpLoggingService.log_to_room(
          location.id, base_message,
          sender: character_instance, type: 'emote'
        )

        broadcast_opts = {}
        broadcast_opts[:broadcast_id] = broadcast_id if broadcast_id

        # Pre-compute notification body (same for all viewers; title is per-viewer)
        notif_portrait = emit_mode ? nil : character.profile_pic_url
        notif_body     = emit_mode ? nil : base_message.gsub(/<[^>]+>/, ' ').gsub(/\s+/, ' ').strip.slice(0, 100)

        all_room_chars.each do |viewer_instance|
          next if viewer_instance.id == character_instance.id

          personalized_message = EmoteFormatterService.format_for_viewer(
            base_message, character, viewer_instance, all_room_chars
          )
          personalized_message = apply_wrapper_styling(personalized_message, is_spotlighted, emit_mode: emit_mode)

          send_opts = broadcast_opts.dup
          if notif_body && !notif_body.empty?
            sender_name = character.display_name_for(viewer_instance)
            send_opts[:notification] = { title: sender_name, body: notif_body, icon: notif_portrait, setting: 'notify_emote' }
          end

          send_to_character(viewer_instance, personalized_message, **send_opts)
        end
      end
      
    end
  end
end

# Auto-register the command when the file is loaded
Commands::Base::Registry.register(Commands::Communication::Emote)
