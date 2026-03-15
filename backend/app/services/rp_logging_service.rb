# frozen_string_literal: true

# RpLoggingService - Central service for logging all IC content
#
# Handles per-character logging, private mode awareness, and deduplication.
# All IC output should flow through this service to ensure proper logging.
#
# Timeline-Aware Logging:
# When characters are in past timelines (snapshots/historical), logs use
# timeline-relative timestamps. Each action is timestamped 1 minute after
# the previous one, starting from the snapshot's capture time or timeline start.
# This ensures logs appear in the correct chronological position when viewed.
#
# Usage:
#   RpLoggingService.log_to_room(room_id, content, sender:, type:, html:)
#   RpLoggingService.log_to_character(character_instance, content, sender:, type:, html:)
#   RpLoggingService.log_movement(character_instance, from_room:, to_room:, ...)
#   RpLoggingService.on_login(character_instance)
#   RpLoggingService.on_logout(character_instance)
#   RpLoggingService.logs_for_event(event, character:) - Get logs for an event
#
module RpLoggingService
  extend StringHelper
  # How much time to advance for each log entry in a timeline (60 seconds)
  TIMELINE_LOG_INCREMENT = 60

  class << self
    # Log content to all characters in a room
    # Creates one RpLog entry per witness
    #
    # @param room_id [Integer] The room where the action occurred
    # @param content [String] Plain text content
    # @param sender [CharacterInstance, nil] The character who performed the action
    # @param type [String, Symbol] Log type (say, emote, whisper, etc.)
    # @param html [String, nil] HTML formatted content (optional)
    # @param exclude [Array<Integer>] Character instance IDs to exclude from logging
    # @param scene_id [Integer, nil] Associated scene/event ID
    # @param event_id [Integer, nil] Associated event ID (auto-detected from sender if nil)
    def log_to_room(room_id, content, sender:, type:, html: nil, exclude: [], scene_id: nil, event_id: nil)
      return if blank?(content)
      return unless room_id

      room = Room[room_id]
      return unless room

      # Scope witnesses the same way room broadcasts are scoped (reality/event/flashback aware).
      witnesses = witness_list_for_room(
        room: room,
        sender: sender,
        event_id: event_id,
        exclude: exclude
      )

      # Determine if any participant is in private mode
      is_private = any_private_mode?(sender, witnesses)

      # Auto-detect event_id from sender if not provided
      effective_event_id = event_id || sender&.in_event_id

      witnesses.each do |witness|
        create_log_entry(
          character_instance: witness,
          room_id: room_id,
          sender: sender,
          content: content,
          html_content: html,
          log_type: type.to_s,
          is_private: is_private,
          scene_id: scene_id,
          event_id: effective_event_id,
          camera: spotlight_active?(witness, room)
        )
      end
    end

    # Log content to a specific character only
    #
    # @param character_instance [CharacterInstance] The recipient
    # @param content [String] Plain text content
    # @param sender [CharacterInstance, nil] The sender
    # @param type [String, Symbol] Log type
    # @param html [String, nil] HTML formatted content
    # @param scene_id [Integer, nil] Associated scene/event ID
    # @param event_id [Integer, nil] Associated event ID (auto-detected from sender if nil)
    def log_to_character(character_instance, content, sender:, type:, html: nil, scene_id: nil, event_id: nil)
      return if blank?(content)
      return unless character_instance

      is_private = character_instance.private_mode? || sender&.private_mode?
      room = character_instance.current_room

      # Auto-detect event_id from sender or recipient if not provided
      effective_event_id = event_id || sender&.in_event_id || character_instance.in_event_id

      create_log_entry(
        character_instance: character_instance,
        room_id: character_instance.current_room_id,
        sender: sender,
        content: content,
        html_content: html,
        log_type: type.to_s,
        is_private: is_private,
        scene_id: scene_id,
        event_id: effective_event_id,
        camera: spotlight_active?(character_instance, room)
      )
    end

    # Log movement between rooms
    #
    # @param character_instance [CharacterInstance] Moving character
    # @param from_room [Room, nil] Origin room
    # @param to_room [Room, nil] Destination room
    # @param departure_message [String, nil] Message shown to origin room
    # @param arrival_message [String, nil] Message shown to destination room
    def log_movement(character_instance, from_room:, to_room:, departure_message: nil, arrival_message: nil)
      # Log departure to witnesses in origin room
      if from_room && departure_message
        witnesses = witness_list_for_room(
          room: from_room,
          sender: character_instance,
          exclude: [character_instance.id]
        )

        witnesses.each do |witness|
          create_log_entry(
            character_instance: witness,
            room_id: from_room.id,
            sender: character_instance,
            content: departure_message,
            log_type: 'departure',
            is_private: witness.private_mode? || character_instance.private_mode?
          )
        end
      end

      # Log arrival to witnesses in destination room
      if to_room && arrival_message
        witnesses = witness_list_for_room(
          room: to_room,
          sender: character_instance,
          exclude: [character_instance.id]
        )

        witnesses.each do |witness|
          create_log_entry(
            character_instance: witness,
            room_id: to_room.id,
            sender: character_instance,
            content: arrival_message,
            log_type: 'arrival',
            is_private: witness.private_mode? || character_instance.private_mode?
          )
        end
      end

      # Create movement breakpoint for the moving character
      LogBreakpoint.record_move(character_instance, to_room) if to_room

      # Track movement for world memory sessions
      WorldMemoryService.handle_character_movement(
        character_instance: character_instance,
        from_room: from_room,
        to_room: to_room
      )
    end

    # Log room description when character looks or enters
    #
    # @param character_instance [CharacterInstance] The viewer
    # @param room [Room] The room being described
    # @param content [String] Room description text
    # @param html [String, nil] HTML formatted description
    def log_room_description(character_instance, room, content, html: nil)
      return unless character_instance && room

      create_log_entry(
        character_instance: character_instance,
        room_id: room.id,
        sender: nil, # Room descriptions have no sender
        content: content,
        html_content: html,
        log_type: 'room_desc',
        is_private: character_instance.private_mode?
      )
    end

    # Handle login: create wake breakpoint and fetch backfill
    #
    # @param character_instance [CharacterInstance] The character logging in
    # @return [Array<Hash>] Formatted log entries for backfill
    def on_login(character_instance)
      return [] unless character_instance

      # Create wake breakpoint
      LogBreakpoint.record_login(character_instance)

      # Fetch backfill logs
      backfill_for(character_instance)
    end

    # Handle logout: create sleep breakpoint and update timestamp
    #
    # @param character_instance [CharacterInstance] The character logging out
    def on_logout(character_instance)
      return unless character_instance

      # Update last_logout_at
      character_instance.update(last_logout_at: Time.now)

      # Create sleep breakpoint
      LogBreakpoint.record_logout(character_instance)
    end

    # Get recent logs for backfill on login
    # Uses logged_at for sorting to preserve timeline-aware order
    #
    # @param character_instance [CharacterInstance]
    # @param limit [Integer] Number of entries (default 50)
    # @return [Array<Hash>] Formatted log entries
    def backfill_for(character_instance, limit: 50)
      return [] unless character_instance

      logs = RpLog.where(character_instance_id: character_instance.id)
                  .order(Sequel.desc(:logged_at))
                  .limit(limit)
                  .all
                  .reverse # Chronological order

      # Filter private logs if user hasn't enabled the toggle
      unless character_instance.show_private_logs?
        logs = logs.reject { |log| log.is_private }
      end

      # Fetch room characters for personalization context
      room_characters = CharacterInstance.where(
        current_room_id: character_instance.current_room_id,
        online: true
      ).eager(:character).all

      logs.map { |log| log.to_api_hash(character_instance, room_characters: room_characters) }
    end

    # Get paginated log history with breakpoint navigation
    # Uses logged_at for sorting to preserve timeline-aware order
    #
    # @param character_instance [CharacterInstance]
    # @param before_breakpoint_id [Integer, nil] For pagination
    # @param limit [Integer] Entries per page
    # @param include_private [Boolean] Whether to include private mode logs
    # @return [Hash] { logs: [...], breakpoints: [...], has_more: bool }
    def log_history(character_instance, before_breakpoint_id: nil, limit: 100, include_private: false)
      return { logs: [], breakpoints: [], has_more: false } unless character_instance

      # Get breakpoints for section navigation
      breakpoints_query = LogBreakpoint.where(character_instance_id: character_instance.id)
                                        .order(Sequel.desc(:happened_at))
                                        .limit(20)

      if before_breakpoint_id
        ref_breakpoint = LogBreakpoint[before_breakpoint_id]
        if ref_breakpoint
          breakpoints_query = breakpoints_query.where { happened_at < ref_breakpoint.happened_at }
        end
      end

      breakpoints = breakpoints_query.all

      # Get logs within the timeframe - use logged_at for timeline-aware sorting
      logs_query = RpLog.where(character_instance_id: character_instance.id)
                        .order(Sequel.desc(:logged_at))
                        .limit(limit + 1) # Fetch one extra to check has_more

      unless include_private
        logs_query = logs_query.where(is_private: false)
      end

      if before_breakpoint_id && breakpoints.any?
        logs_query = logs_query.where { logged_at < breakpoints.first.happened_at }
      end

      logs = logs_query.all
      has_more = logs.length > limit
      logs = logs.first(limit)

      {
        logs: logs.map { |log| log.to_api_hash(character_instance) },
        breakpoints: breakpoints.map(&:to_api_hash),
        has_more: has_more
      }
    end

    # Get logs for a specific event
    # Respects logs_visible_to privacy setting
    # Uses logged_at for sorting to preserve timeline-aware order
    #
    # @param event [Event] The event
    # @param character [Character, nil] The viewing character (for privacy check)
    # @param limit [Integer] Maximum logs to return
    # @return [Array<Hash>] Formatted log entries
    def logs_for_event(event, character: nil, limit: 500)
      return [] unless event

      # Check if character can view the logs
      unless event.can_view_logs?(character)
        return []
      end

      # Get unique logs for the event (deduplicated by content + timestamp)
      logs = RpLog.where(event_id: event.id)
                  .order(:logged_at)
                  .limit(limit)
                  .all

      # Deduplicate logs (same content within short time window)
      seen = {}
      logs.select do |log|
        ts = log.display_timestamp
        key = "#{log.text}_#{ts.to_i / 60}" # 1 minute window
        if seen[key]
          false
        else
          seen[key] = true
          true
        end
      end.map { |log| log.to_api_hash(nil) }
    end

    private

    # Create a single log entry with deduplication
    def create_log_entry(character_instance:, room_id:, sender:, content:, log_type:,
                         html_content: nil, is_private: false, scene_id: nil, event_id: nil, camera: false)
      return unless character_instance && content

      # Strip display-only tags (e.g., <strong> for name bolding) from logged content
      content = strip_display_tags(content)
      html_content = strip_display_tags(html_content) if html_content

      # Check for duplicates in dedup window
      return if RpLog.duplicate?(
        character_instance.id,
        content,
        log_type: log_type,
        sender_character_id: sender&.character_id,
        room_id: room_id,
        event_id: event_id
      )

      # Calculate timeline-aware timestamp
      timeline = character_instance.timeline
      timeline_id = nil
      logged_at = Time.now

      if timeline && timeline.past_timeline?
        timeline_id = timeline.id
        logged_at = next_timeline_log_time(timeline)
      end

      RpLog.create(
        character_instance_id: character_instance.id,
        room_id: room_id,
        sender_character_id: sender&.character_id,
        content: content,
        html_content: html_content,
        log_type: log_type,
        is_private: is_private,
        scene_id: scene_id,
        event_id: event_id,
        camera: camera,
        emit_mode: log_type == 'emote',
        timeline_id: timeline_id,
        logged_at: logged_at
      )
    rescue Sequel::Error => e
      warn "[RpLoggingService] Failed to create log entry: #{e.message}"
      nil
    end

    # Strip display-only markup that shouldn't be persisted in logs:
    # - <strong> tags (name emphasis for viewer's own name)
    # - <sup class="emote-tag"> elements (Subtle, Privately, Private to X, Attempt tags)
    def strip_display_tags(text)
      return text unless text.is_a?(String)

      result = text.gsub(%r{</?strong>}, '')
      result = result.gsub(%r{\s*<sup class="emote-tag">.*?</sup>}i, '')
      result
    end

    # Check if any participant is in private mode
    def any_private_mode?(sender, witnesses)
      return true if sender&.private_mode?

      witnesses.any? { |w| w.private_mode? }
    end

    # Check if spotlight/camera is active for character
    def spotlight_active?(character_instance, room)
      return false unless character_instance

      # Check if character has event camera flag or is in active event
      (character_instance.respond_to?(:event_camera?) && character_instance.event_camera?) ||
        (character_instance.respond_to?(:in_event?) && character_instance.in_event?)
    end

    # Build a witness list for room logging using the same visibility rules as room broadcast.
    #
    # When a sender is present, scope to what the sender can actually see in that room.
    # When sender is nil, fall back to online room occupants with optional event filtering.
    def witness_list_for_room(room:, sender:, event_id: nil, exclude: [])
      dataset = if sender
        room.characters_here(sender.reality_id, viewer: sender)
      else
        query = room.characters_here
        query = query.where(in_event_id: event_id) if event_id
        query = query.where(flashback_instanced: false)
        query
      end

      dataset = dataset.exclude(id: exclude) if exclude && exclude.any?
      dataset.eager(:character).all
    end

    # ========================================
    # Timeline Log Time Tracking
    # ========================================

    # Get the next log timestamp for a timeline and advance the tracker
    # Returns: Time object representing when this log "happened" in the timeline
    #
    # @param timeline [Timeline] The past timeline
    # @return [Time] The timestamp for this log entry
    def next_timeline_log_time(timeline)
      key = timeline_log_time_key(timeline.id)

      REDIS_POOL.with do |redis|
        # Get or set the current log time for this timeline
        current_time_str = redis.get(key)

        if current_time_str
          # Advance by 1 minute from the last log
          current_time = Time.parse(current_time_str)
          next_time = current_time + TIMELINE_LOG_INCREMENT
        else
          # First log in this timeline - use the timeline's start time
          next_time = timeline_start_time(timeline)
        end

        # Store the updated time (expires after 24 hours of inactivity)
        redis.setex(key, 86_400, next_time.iso8601)

        next_time
      end
    rescue StandardError => e
      warn "[RpLoggingService] Redis error for timeline log time: #{e.message}"
      # Fall back to a reasonable time based on the timeline
      timeline_start_time(timeline)
    end

    # Get the starting timestamp for a timeline
    #
    # @param timeline [Timeline] The timeline
    # @return [Time] The starting time for logs in this timeline
    def timeline_start_time(timeline)
      if timeline.snapshot? && timeline.snapshot
        # For snapshot timelines, use when the snapshot was taken
        timeline.snapshot.snapshot_taken_at
      elsif timeline.historical? && timeline.year
        # For historical timelines, use a time in that year
        # Default to January 1st of that year at noon
        Time.new(timeline.year, 1, 1, 12, 0, 0)
      else
        # Fallback: use the timeline's creation time
        timeline.created_at || Time.now
      end
    end

    # Redis key for tracking timeline log times
    #
    # @param timeline_id [Integer]
    # @return [String]
    def timeline_log_time_key(timeline_id)
      "timeline_log_time:#{timeline_id}"
    end

    # Reset the log time tracker for a timeline
    # Call this when a timeline is reset or restarted
    #
    # @param timeline_id [Integer]
    def reset_timeline_log_time(timeline_id)
      REDIS_POOL.with do |redis|
        redis.del(timeline_log_time_key(timeline_id))
      end
    rescue StandardError => e
      warn "[RpLoggingService] Failed to reset timeline log time: #{e.message}"
    end
  end
end
