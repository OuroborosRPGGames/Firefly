# frozen_string_literal: true

# IcActivityService - Central hub for IC (in-character) activity side effects
#
# Consolidates all side effects that should fire when IC content is produced:
# RP logging, NPC animation, pet animation, world memory, Auto-GM, emote turns,
# flashback time, and email notifications.
#
# Each side effect is wrapped in safe_call so a failure in one does not block others.
#
# Usage:
#   IcActivityService.record(room_id:, content:, sender:, type:, ...)      # room-wide IC activity
#   IcActivityService.record_targeted(sender:, target:, content:, type:)  # two-party IC activity
#   IcActivityService.record_for(recipients:, content:, sender:, type:)   # specific witnesses
#
module IcActivityService
  class << self
    # Record room-wide IC activity and trigger all side effects.
    #
    # @param room_id [Integer] The room where the activity occurred
    # @param content [String] Plain text content
    # @param sender [CharacterInstance, nil] The character who performed the action
    # @param type [Symbol, String] IC type (say, emote, whisper, etc.)
    # @param exclude [Array<Integer>] Character instance IDs to exclude
    # @param scene_id [Integer, nil] Associated scene ID
    # @param html [String, nil] HTML formatted content
    # @param event_id [Integer, nil] Associated event ID
    def record(room_id:, content:, sender:, type:, exclude: [], scene_id: nil, html: nil, event_id: nil)
      return if StringHelper.blank?(content)
      return unless room_id

      # 1. RP Logging -- most important, fires first
      RpLoggingService.log_to_room(
        room_id, content,
        sender: sender, type: type.to_s,
        html: html, exclude: exclude,
        scene_id: scene_id, event_id: event_id
      )

      # All remaining side effects are best-effort and need a sender
      return unless sender

      safe_call('NpcAnimation') do
        NpcAnimationService.process_room_broadcast(
          room_id: room_id, content: content,
          sender_instance: sender, type: type.to_sym
        )
      end

      safe_call('PetAnimation') do
        PetAnimationService.process_room_broadcast(
          room_id: room_id, content: content,
          sender_instance: sender, type: type.to_sym
        )
      end

      safe_call('WorldMemory') do
        WorldMemoryService.track_ic_message(
          room_id: room_id, content: content,
          sender: sender, type: type.to_sym,
          is_private: sender.respond_to?(:private_mode?) && sender.private_mode?
        )
      end

      safe_call('AutoGm') do
        AutoGm::AutoGmSessionService.notify_player_action(
          room_id: room_id, content: content,
          sender_instance: sender, type: type.to_sym
        )
      end

      safe_call('EmoteTurn') do
        EmoteTurnService.record_emote(room_id, sender.id)
        EmoteTurnService.broadcast_turn(room_id)
      end

      safe_call('FlashbackTime') do
        FlashbackTimeService.touch_room_activity(room_id, exclude: exclude)
      end

      safe_call('EmailNotifier') do
        EmailSceneNotifier.notify_if_needed(room_id, content, sender)
      end
    end

    # Record a two-party IC interaction (e.g., whisper, say_to).
    # Logs for both the sender and the target.
    #
    # @param sender [CharacterInstance] The sender
    # @param target [CharacterInstance] The target
    # @param content [String] Plain text content
    # @param type [Symbol, String] IC type
    # @param scene_id [Integer, nil] Associated scene ID
    # @param html [String, nil] HTML formatted content
    def record_targeted(sender:, target:, content:, type:, scene_id: nil, html: nil)
      return if StringHelper.blank?(content)

      RpLoggingService.log_to_character(
        sender, content,
        sender: sender, type: type.to_s,
        html: html, scene_id: scene_id
      )
      RpLoggingService.log_to_character(
        target, content,
        sender: sender, type: type.to_s,
        html: html, scene_id: scene_id
      )
    end

    # Record IC activity for a specific set of witnesses.
    #
    # @param recipients [Array<CharacterInstance>, CharacterInstance] The recipients
    # @param content [String] Plain text content
    # @param sender [CharacterInstance, nil] The sender
    # @param type [Symbol, String] IC type
    # @param scene_id [Integer, nil] Associated scene ID
    # @param html [String, nil] HTML formatted content
    def record_for(recipients:, content:, sender:, type:, scene_id: nil, html: nil)
      return if StringHelper.blank?(content)

      Array(recipients).each do |recipient|
        RpLoggingService.log_to_character(
          recipient, content,
          sender: sender, type: type.to_s,
          html: html, scene_id: scene_id
        )
      end
    end

    private

    # Execute a block, catching and logging any errors so that one failure
    # does not prevent subsequent side effects from firing.
    #
    # @param service_name [String] Label for the warning message
    def safe_call(service_name)
      yield
    rescue StandardError => e
      warn "[IcActivityService] #{service_name} failed: #{e.message}"
    end
  end
end
