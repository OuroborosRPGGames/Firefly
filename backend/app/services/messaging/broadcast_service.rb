# frozen_string_literal: true

require_relative '../../helpers/string_helper'

# BroadcastService - Handles real-time message distribution to clients
#
# Uses Redis pub/sub for WebSocket broadcasting to connected clients.
# WebSocket connections (via WebsocketHandler) subscribe to channels and
# receive messages published here in real-time.
#
# Usage:
#   BroadcastService.to_room(room_id, message, exclude: [character_instance_id])
#   BroadcastService.to_character(character_instance, message)
#   BroadcastService.to_zone(zone_id, message)
#   BroadcastService.to_all(message)
#
# Channel names:
#   - room:#{room_id}           - Room-specific broadcasts
#   - character:#{instance_id}  - Character-specific messages
#   - zone:#{zone_id}           - Zone-wide announcements
#   - global                    - Server-wide broadcasts
#   - staff_vision              - Staff vision channel
#
module BroadcastService
  extend StringHelper

  class << self
    # Broadcast a message to all characters in a room
    #
    # @param room_id [Integer] The room to broadcast to
    # @param message [String, Hash] The message content
    # @param exclude [Array<Integer>] Character instance IDs to exclude
    # @param type [Symbol] Message type (:say, :emote, :system, etc.)
    def to_room(room_id, message, exclude: [], type: :message, skip_broadcast: false, **metadata)
      return if room_id.nil?

      log_broadcast(:room, room_id, message, exclude: exclude, type: type, **metadata)

      # Buffer for agents - they receive ALL broadcasts, not just IC types
      buffer_for_agents(room_id, message, type: type, exclude: exclude, **metadata)

      # Build visibility context from sender (for filtering in different realities/timelines)
      sender_context = metadata[:sender_instance] ?
        VisibilityContext.from_character_instance(metadata[:sender_instance]).to_h : nil

      # Build the broadcast payload
      payload = {
        type: type,
        message: message,
        timestamp: Time.now.iso8601,
        visibility_context: sender_context,
        exclude: exclude.empty? ? nil : exclude,
        sender_portrait_url: metadata[:sender_instance]&.character&.profile_pic_url,
        **metadata.except(:sender_instance, :sender_portrait_url)
      }

      unless skip_broadcast
        # Store for polling fallback (reliable delivery on reconnect)
        # Uses visibility filtering to only queue for eligible recipients
        # Returns enriched payload with id/sequence_number for tracking
        enriched = store_for_polling_fallback(room_id, payload, exclude: exclude, sender_instance: metadata[:sender_instance])

        # Broadcast via Redis pub/sub (instant WebSocket delivery)
        # WebSocket handler will filter based on visibility_context
        # Use enriched payload so clients can ack and track sequence numbers
        broadcast_via_anycable("room:#{room_id}", enriched || payload)
      end
    end

    # Send a message directly to a specific character instance
    #
    # @param character_instance [CharacterInstance] The recipient
    # @param message [String, Hash] The message content
    # @param type [Symbol] Message type
    # @param sender_instance [CharacterInstance, nil] The sender for logging
    def to_character(character_instance, message, type: :message, sender_instance: nil, **metadata)
      return if character_instance.nil?

      instance_id = character_instance.respond_to?(:id) ? character_instance.id : character_instance
      log_broadcast(:character, instance_id, message, type: type)

      # Auto-queue TTS for accessibility mode users
      if character_instance.respond_to?(:id)
        queue_tts_for_accessibility(
          character_instance,
          message,
          type: type,
          speaker: sender_instance
        )
      end

      # Build payload
      payload = {
        type: type,
        message: message,
        timestamp: Time.now.iso8601
      }
      payload[:broadcast_id] = metadata[:broadcast_id] if metadata[:broadcast_id]
      payload[:data] = metadata[:data] if metadata[:data]
      payload[:target_panel] = metadata[:target_panel] if metadata[:target_panel]
      payload[:dice_duration_ms] = metadata[:dice_duration_ms] if metadata[:dice_duration_ms]&.to_i&.positive?
      payload[:sender_portrait_url] = metadata[:sender_portrait_url] if metadata[:sender_portrait_url]
      payload[:sender_display_name] = metadata[:sender_display_name] if metadata[:sender_display_name]

      # Include notification hint for client — explicit from caller, or auto-built for DM/OOC types
      notif = metadata[:notification] || auto_notification(type, message, metadata)
      payload[:notification] = notif if notif

      # Store for polling fallback and get enriched payload with id/sequence_number
      enriched = store_for_character_fallback(instance_id, payload)

      # Broadcast enriched version so client can track sequence numbers
      broadcast_via_anycable("character:#{instance_id}", enriched || payload)
    end

    # Send a message directly to a character, optionally skipping TTS
    # Used for atmospheric emits and other non-IC content that shouldn't be logged
    #
    # @param character_instance [CharacterInstance] The recipient
    # @param message [String, Hash] The message content
    # @param type [Symbol] Message type
    # @param skip_tts [Boolean] Skip TTS queuing (default: false)
    def to_character_raw(character_instance, message, type: :message, skip_tts: false)
      return if character_instance.nil?

      instance_id = character_instance.respond_to?(:id) ? character_instance.id : character_instance
      log_broadcast(:character, instance_id, message, type: type)

      # TTS queuing - only if not skipped
      if !skip_tts && character_instance.respond_to?(:id)
        queue_tts_for_accessibility(
          character_instance,
          message,
          type: type,
          speaker: nil
        )
      end

      # Build payload
      payload = {
        type: type,
        message: message,
        timestamp: Time.now.iso8601
      }

      # Store for polling fallback and get enriched payload with id/sequence_number
      enriched = store_for_character_fallback(instance_id, payload)

      # Broadcast enriched version so client can track sequence numbers
      broadcast_via_anycable("character:#{instance_id}", enriched || payload)
    end

    # Broadcast to all characters in a zone
    #
    # @param zone_id [Integer] The zone to broadcast to
    # @param message [String, Hash] The message content
    # @param type [Symbol] Message type
    # @param sender_instance [CharacterInstance, nil] The sender for visibility filtering
    def to_zone(zone_id, message, type: :announcement, sender_instance: nil)
      return if zone_id.nil?

      log_broadcast(:zone, zone_id, message, type: type)

      # Build visibility context from sender
      sender_context = sender_instance ?
        VisibilityContext.from_character_instance(sender_instance).to_h : nil

      # Build payload
      payload = {
        type: type,
        message: message,
        timestamp: Time.now.iso8601,
        visibility_context: sender_context
      }

      # Store for polling fallback (reliable delivery on reconnect)
      enriched = store_for_zone_fallback(zone_id, payload, sender_instance: sender_instance)

      # Broadcast via Redis pub/sub to zone channel
      broadcast_via_anycable("zone:#{zone_id}", enriched || payload)
    end

    # Alias for backward compatibility
    alias_method :to_area, :to_zone

    # Broadcast to all connected characters (server-wide)
    #
    # @param message [String, Hash] The message content
    # @param type [Symbol] Message type
    # @param sender_instance [CharacterInstance, nil] The sender for visibility filtering
    def to_all(message, type: :global, sender_instance: nil)
      log_broadcast(:global, nil, message, type: type)

      # Build visibility context from sender
      sender_context = sender_instance ?
        VisibilityContext.from_character_instance(sender_instance).to_h : nil

      # Build payload
      payload = {
        type: type,
        message: message,
        timestamp: Time.now.iso8601,
        visibility_context: sender_context
      }

      # Store for polling fallback (reliable delivery on reconnect)
      enriched = store_for_global_fallback(payload, sender_instance: sender_instance)

      # Broadcast via Redis pub/sub to global channel
      broadcast_via_anycable('global', enriched || payload)
    end

    # Broadcast to all characters observing a specific character
    #
    # @param observed_character [CharacterInstance] The character being observed
    # @param message [String, Hash] The message content
    # @param type [Symbol] Message type
    def to_observers(observed_character, message, type: :observe)
      return if observed_character.nil?

      # Find all online characters observing this one
      observers = observed_character.current_observers.all

      observers.each do |observer|
        to_character(observer, message, type: type)
      end

      log_broadcast(:observers, observed_character.id, message, type: type, count: observers.length)
    end

    # Check if real-time broadcasting is enabled (Redis pub/sub available)
    #
    # @return [Boolean]
    def enabled?
      !!(defined?(REDIS_POOL) && REDIS_POOL)
    end

    # ========================================
    # Staff Vision Broadcasting
    # ========================================

    # Broadcast a message to all staff with vision enabled
    # Staff vision allows staff characters to see RP in all rooms except private mode rooms
    #
    # @param room [Room] The room where the message originated
    # @param message [String, Hash] The message content
    # @param type [Symbol] Message type
    def to_staff_vision(room, message, type: :staff_vision)
      return if room.nil?
      return if room.excludes_staff_vision?

      # Find online staff characters with vision enabled who are NOT in this room
      staff_instances = find_staff_vision_recipients(room)

      staff_instances.each do |ci|
        staff_message = build_staff_vision_message(room, message, type)
        to_character(ci, staff_message, type: :staff_vision)
      end

      log_broadcast(:staff_vision, room.id, message, type: type, recipients: staff_instances.length)
    end

    # Broadcast to room AND to staff vision simultaneously
    # This is the primary method to use for room broadcasts that staff should see
    #
    # @param room_id [Integer] The room to broadcast to
    # @param message [String, Hash] The message content
    # @param exclude [Array<Integer>] Character instance IDs to exclude
    # @param type [Symbol] Message type
    def to_room_with_staff_vision(room_id, message, exclude: [], type: :message)
      # First, do the normal room broadcast
      to_room(room_id, message, exclude: exclude, type: type)

      # Then broadcast to staff vision
      room = Room[room_id]
      to_staff_vision(room, message, type: type) if room
    end

    private

    # ========================================
    # Redis Pub/Sub Broadcasting
    # ========================================

    # Broadcast message via Redis pub/sub
    # WebSocket connections subscribe to these channels for real-time updates
    #
    # @param channel [String] The channel name (e.g., "room:123", "character:456")
    # @param payload [Hash] The message payload
    def broadcast_via_anycable(channel, payload)
      return unless enabled?

      REDIS_POOL.with do |redis|
        redis.publish(channel, payload.to_json)
      end
    rescue StandardError => e
      warn "[BroadcastService] Redis publish failed for #{channel}: #{e.message}"
    end

    # ========================================
    # Polling Fallback Storage
    # ========================================

    # Store message for room-based polling fallback
    def store_for_polling_fallback(room_id, payload, exclude: [], sender_instance: nil)
      eligible = VisibilityFilterService.eligible_recipients_in_room(
        room_id, sender_instance, exclude: exclude
      )
      store_fallback_message(payload.merge(room_id: room_id), eligible.map(&:id), scope: 'Polling', return_storable: true)
    end

    # Store message for character-specific polling fallback
    # @return [Hash, nil] The enriched payload with id/sequence_number, or nil on failure
    def store_for_character_fallback(instance_id, payload)
      store_fallback_message(
        payload.merge(character_instance_id: instance_id),
        [instance_id],
        scope: 'Character',
        return_storable: true
      )
    end

    # Store message for zone-wide polling fallback
    def store_for_zone_fallback(zone_id, payload, sender_instance: nil)
      recipient_ids = VisibilityFilterService.eligible_recipients_in_zone(zone_id, sender_instance)
      store_fallback_message(payload.merge(zone_id: zone_id), recipient_ids, scope: 'Zone', return_storable: true)
    end

    # Store message for global (server-wide) polling fallback
    def store_for_global_fallback(payload, sender_instance: nil)
      recipient_ids = VisibilityFilterService.eligible_recipients_global(sender_instance)
      store_fallback_message(payload.merge(global: true), recipient_ids, scope: 'Global', return_storable: true)
    end

    # Shared fallback storage: stores message in Redis and queues for recipients
    #
    # @param payload [Hash] The message payload with scope metadata merged in
    # @param recipient_ids [Array<Integer>] Character instance IDs to queue for
    # @param scope [String] Label for error logging
    # @param return_storable [Boolean] If true, returns the enriched payload
    # @return [Hash, nil] Enriched payload if return_storable, otherwise nil
    def store_fallback_message(payload, recipient_ids, scope: 'Fallback', return_storable: false)
      return unless enabled?
      return if recipient_ids.empty?

      REDIS_POOL.with do |redis|
        sequence_number = redis.incr('global_msg_sequence')
        message_id = SecureRandom.uuid

        storable = payload.merge(id: message_id, sequence_number: sequence_number)
        redis.setex("msg_data:#{message_id}", 3600, storable.to_json)

        recipient_ids.each do |rid|
          redis.sadd("msg_pending:#{rid}", message_id)
          redis.expire("msg_pending:#{rid}", 3600)
        end

        return_storable ? storable : nil
      end
    rescue StandardError => e
      warn "[BroadcastService] #{scope} fallback storage failed: #{e.message}"
      nil
    end

    # Buffer broadcasts for agents in the room
    # Agents receive ALL broadcasts, not filtered by IC type
    #
    # @param room_id [Integer] The room ID
    # @param message [String, Hash] The message content
    # @param type [Symbol] Message type
    # @param exclude [Array<Integer>] Character instance IDs to exclude
    def buffer_for_agents(room_id, message, type:, exclude: [], **metadata)
      return unless defined?(REDIS_POOL) && REDIS_POOL

      content = extract_content(message)
      return if blank?(content)

      # Find all agents in this room (eager load to avoid N+1)
      # Use qualified column reference to avoid Sequel association filtering
      agents_in_room = CharacterInstance
        .where(Sequel[:character_instances][:current_room_id] => room_id, online: true)
        .exclude(Sequel[:character_instances][:id] => exclude)
        .eager(character: :user)
        .all
        .select { |ci| ci.character&.user&.agent? }

      return if agents_in_room.empty?

      broadcast_data = {
        type: type.to_s,
        content: content,
        timestamp: Time.now.iso8601,
        room_id: room_id,
        metadata: metadata.except(:sender_instance).transform_keys(&:to_s)
      }.to_json

      REDIS_POOL.with do |redis|
        redis.pipelined do |pipeline|
          agents_in_room.each do |agent_instance|
            key = "agent_broadcasts:#{agent_instance.id}"
            pipeline.rpush(key, broadcast_data)
            pipeline.ltrim(key, -100, -1) # Keep last 100 broadcasts
            pipeline.expire(key, 3600) # Expire after 1 hour
          end
        end
      end
    rescue StandardError => e
      warn "[BroadcastService] Agent buffer error: #{e.message}"
    end

    # Extract plain text content from a message
    #
    # @param message [String, Hash] The message
    # @return [String, nil]
    def extract_content(message)
      case message
      when Hash
        message[:content] || message[:message] || message[:text] || message.to_s
      when String
        message
      else
        message.to_s
      end
    end

    # Extract HTML content from a message if present
    #
    # @param message [String, Hash] The message
    # @return [String, nil]
    def extract_html(message)
      return nil unless message.is_a?(Hash)

      message[:html] || message[:html_content] || message[:formatted]
    end

    # Find all staff character instances eligible for staff vision
    # Must be: online, staff_vision_enabled, staff character, user has can_see_all_rp permission
    #
    # @param exclude_room [Room, nil] Room to exclude recipients from (they're already in the room)
    # @return [Array<CharacterInstance>]
    def find_staff_vision_recipients(exclude_room = nil)
      # Query for online character instances with staff vision enabled
      # Eager load character -> user to prevent N+1 queries when checking permissions
      query = CharacterInstance
        .where(online: true, staff_vision_enabled: true)
        .eager(character: :user)

      # Exclude characters already in the room (they receive normal broadcast)
      query = query.exclude(Sequel[:character_instances][:current_room_id] => exclude_room.id) if exclude_room

      # Get all matching instances
      instances = query.all

      # Filter to only staff characters whose users have the required permission
      # All associations are pre-loaded so this is efficient in-memory filtering
      instances.select do |ci|
        ci.character&.staff_character? &&
          ci.character&.can_see_all_rp?
      end
    end

    # Build the staff vision message with room context
    #
    # @param room [Room] The source room
    # @param message [String, Hash] The original message
    # @param type [Symbol] The message type
    # @return [Hash]
    def build_staff_vision_message(room, message, type)
      {
        room_id: room.id,
        room_name: room.name,
        room_path: room.respond_to?(:full_path) ? room.full_path : room.name,
        message: message,
        original_type: type,
        staff_vision: true,
        timestamp: Time.now.iso8601
      }
    end

    # Log broadcast for debugging/testing
    # This provides visibility into what would be broadcast
    def log_broadcast(target_type, target_id, message, **options)
      return unless ENV['LOG_BROADCASTS'] == 'true' || ENV['RACK_ENV'] == 'development'

      formatted_message = case message
                          when Hash
                            message[:message] || message[:content] || message.to_s
                          else
                            message.to_s
                          end.to_s

      if ENV['LOG_BROADCASTS']
        target_desc = target_id ? "#{target_type}:#{target_id}" : target_type.to_s
        warn "[BroadcastService] #{target_desc} (#{options[:type]}): #{formatted_message[0, 100]}"
      end
    end

    # ========================================
    # TTS Accessibility Auto-Queue
    # ========================================

    # Queue TTS content for accessibility mode users
    # Only queues when accessibility mode is enabled and TTS is on
    #
    # @param character_instance [CharacterInstance] The recipient
    # @param message [String, Hash] The message content
    # @param type [Symbol] Message type
    # @param speaker [CharacterInstance, nil] Speaking character for speech
    def queue_tts_for_accessibility(character_instance, message, type:, speaker: nil)
      return unless TtsQueueService.should_queue_for?(character_instance)
      return unless tts_content_type?(type)

      content = extract_content(message)
      return if blank?(content)

      tts_type = map_to_tts_type(type)

      if tts_type == :speech && speaker
        TtsQueueService.queue_for(character_instance, content, type: :speech, speaker: speaker)
      else
        TtsQueueService.queue_for(character_instance, content, type: tts_type)
      end
    rescue StandardError => e
      warn "[BroadcastService] TTS queue error: #{e.message}"
    end

    # Check if this message type should be queued for TTS
    #
    # @param type [Symbol] The message type
    # @return [Boolean]
    def tts_content_type?(type)
      TTS_CONTENT_TYPES.include?(type.to_sym)
    end

    # Message types that should be queued for TTS
    TTS_CONTENT_TYPES = %i[
      say say_to emote whisper system room combat action
      departure arrival think attempt private_message
      message broadcast narrator
    ].freeze

    # Message types that get automatic notification payloads built at the to_character level.
    # RP emote types are handled by callers (emote.rb, broadcast_to_room) since type is stripped
    # before per-viewer sends to avoid duplicate RP logging.
    NOTIFY_MESSAGE_AUTO_TYPES = %i[dm ooc msg].freeze

    # Build notification for DM/OOC types using metadata already present on the payload
    def auto_notification(type, message, metadata)
      return nil unless NOTIFY_MESSAGE_AUTO_TYPES.include?(type.to_sym)

      body = strip_for_notification(extract_content(message))
      return nil if body.nil? || body.empty?

      {
        title: metadata[:sender_display_name] || 'New Message',
        body: body,
        icon: metadata[:sender_portrait_url],
        setting: 'notify_message'
      }
    end

    def strip_for_notification(text)
      return nil if text.nil? || text.empty?
      text.gsub(/<[^>]+>/, ' ').gsub(/\s+/, ' ').strip.slice(0, 100)
    end

    # Map broadcast message type to TTS content type
    #
    # @param type [Symbol] The broadcast message type
    # @return [Symbol] The TTS content type
    def map_to_tts_type(type)
      case type.to_sym
      when :say, :say_to, :whisper, :private_message
        :speech
      when :emote, :action, :think, :attempt
        :action
      when :room, :room_desc, :departure, :arrival
        :room
      when :combat
        :combat
      when :system, :broadcast, :message
        :system
      else
        :narrator
      end
    end
  end
end
