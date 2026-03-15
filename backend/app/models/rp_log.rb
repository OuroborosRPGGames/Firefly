# frozen_string_literal: true

require 'digest'

# RpLog stores per-character roleplay logs
#
# Each observer gets their own log entry for what they witnessed.
# Supports private mode flagging, HTML content, and log type categorization.
#
# Timeline-Aware Logging:
# The `logged_at` timestamp represents when the action "happened" in the narrative.
# For present-day RP, this matches `created_at`. For past timeline RP (snapshots/historical),
# this is the timeline-relative timestamp so logs appear in correct chronological order.
#
class RpLog < Sequel::Model
  plugin :timestamps

  many_to_one :character_instance
  many_to_one :room
  many_to_one :sender_character, class: :Character, key: :sender_character_id
  many_to_one :timeline

  # Log types for categorization
  LOG_TYPES = %w[
    say emote whisper movement room_desc combat system
    arrival departure think attempt private_message
  ].freeze

  # Deduplication window in seconds
  DEDUP_WINDOW = 120

  # Alias for backward compatibility (old code uses 'text', database column is 'content')
  def text
    content
  end

  def text=(value)
    self.content = value
  end

  # Get all RP logs visible to a character instance
  # Uses logged_at for sorting to ensure timeline logs appear in correct order
  def self.visible_to(character_instance, limit = 100)
    return where(false) unless character_instance

    where(character_instance_id: character_instance.id)
      .order(Sequel.desc(:logged_at))
      .limit(limit)
  end

  # Get visible logs with privacy filtering
  # @param character_instance [CharacterInstance]
  # @param include_private [Boolean] whether to include private mode logs
  # @param limit [Integer]
  def self.visible_with_privacy(character_instance, include_private: false, limit: 100)
    return where(false) unless character_instance

    query = where(character_instance_id: character_instance.id)
    query = query.where(is_private: false) unless include_private
    query.order(Sequel.desc(:logged_at)).limit(limit)
  end

  # Get recent history for a character instance when they log in
  def self.recent_for_character(character_instance, limit = 100)
    return [] unless character_instance

    visible_to(character_instance, limit).reverse
  end

  # Get logs since a character's last logout
  # Uses logged_at for filtering since that's the "narrative" time
  # @param character_instance [CharacterInstance]
  # @param limit [Integer]
  def self.since_logout(character_instance, limit: 50)
    return [] unless character_instance

    last_logout = character_instance.last_logout_at

    if last_logout
      where(character_instance_id: character_instance.id)
        .where { logged_at > last_logout }
        .order(:logged_at)
        .limit(limit)
        .all
    else
      recent_for_character(character_instance, limit)
    end
  end

  # Get logs for a specific session (between breakpoints)
  # @param character_instance [CharacterInstance]
  # @param start_breakpoint [LogBreakpoint]
  # @param end_breakpoint [LogBreakpoint, nil]
  def self.for_session(character_instance, start_breakpoint:, end_breakpoint: nil)
    query = where(character_instance_id: character_instance.id)
            .where { logged_at >= start_breakpoint.happened_at }

    if end_breakpoint
      query = query.where { logged_at < end_breakpoint.happened_at }
    end

    query.order(:logged_at)
  end

  # Create a log entry for an emote/roleplay action
  # Creates one entry per character who witnesses the action
  # @deprecated Use RpLoggingService.log_to_room instead
  def self.log_action(character_instance, text, options = {})
    room_id = character_instance.current_room_id
    sender_id = options[:sender_character_id] || character_instance.character_id

    witnesses = CharacterInstance.where(current_room_id: room_id)
                                 .where(online: true)

    witnesses.each do |witness|
      create(
        character_instance_id: witness.id,
        text: text,
        room_id: room_id,
        sender_character_id: sender_id,
        emit_mode: options[:emit_mode] || false,
        scene_id: options[:scene_id],
        log_type: options[:log_type] || 'emote',
        is_private: options[:is_private] || false,
        html_content: options[:html_content]
      )
    end
  end

  # Check for duplicate content within dedup window
  # @param character_instance_id [Integer]
  # @param content [String]
  # @param log_type [String, nil]
  # @param sender_character_id [Integer, nil]
  # @param room_id [Integer, nil]
  # @param event_id [Integer, nil]
  # @return [Boolean]
  def self.duplicate?(character_instance_id, content, log_type: nil, sender_character_id: nil, room_id: nil, event_id: nil)
    cutoff = Time.now - GameConfig::Logging::DEDUP_WINDOW_SECONDS

    # Backward-compatible fallback: callers that provide no context get legacy
    # content-based dedup semantics.
    if log_type.nil? && sender_character_id.nil? && room_id.nil? && event_id.nil?
      return where(character_instance_id: character_instance_id)
             .where(content: content)
             .where { created_at > cutoff }
             .any?
    end

    hash = content_hash_for(
      content,
      character_instance_id,
      log_type: log_type,
      sender_character_id: sender_character_id,
      room_id: room_id,
      event_id: event_id
    )
    where(character_instance_id: character_instance_id)
      .where(content_hash: hash)
      .where { created_at > cutoff }
      .any?
  end

  # Generate content hash for deduplication
  # @param content [String]
  # @param character_instance_id [Integer]
  # @param log_type [String, nil]
  # @param sender_character_id [Integer, nil]
  # @param room_id [Integer, nil]
  # @param event_id [Integer, nil]
  # @return [String]
  def self.content_hash_for(content, character_instance_id, log_type: nil, sender_character_id: nil, room_id: nil, event_id: nil)
    key = [
      character_instance_id,
      log_type || '',
      sender_character_id || '',
      room_id || '',
      event_id || '',
      content
    ].join(':')
    Digest::SHA256.hexdigest(key)[0..63]
  end

  # Format the log entry for display
  def formatted_for(viewer_instance)
    display_text = text.dup

    if sender_character && viewer_instance
      original_name = sender_character.full_name
      display_name = sender_character.display_name_for(viewer_instance)
      display_text.gsub!(original_name, display_name) if original_name != display_name
    end

    {
      id: id,
      text: display_text,
      timestamp: display_timestamp,
      emit_mode: emit_mode,
      sender_name: sender_character&.display_name_for(viewer_instance)
    }
  end

  # Format for API response with optional per-viewer personalization
  # @param viewer_instance [CharacterInstance, nil]
  # @param room_characters [Array<CharacterInstance>, nil] Characters for name substitution context
  # @return [Hash]
  def to_api_hash(viewer_instance = nil, room_characters: nil)
    display_content = text
    display_html = html_content

    if viewer_instance
      if text
        display_content = MessagePersonalizationService.personalize(
          message: text,
          viewer: viewer_instance,
          room_characters: room_characters
        )
      end
      if html_content
        display_html = MessagePersonalizationService.personalize(
          message: html_content,
          viewer: viewer_instance,
          room_characters: room_characters
        )
      end
    end

    {
      id: id,
      content: display_content,
      html_content: display_html,
      log_type: log_type || 'emote',
      is_private: is_private || false,
      camera: camera || false,
      sender_name: viewer_instance ? sender_character&.display_name_for(viewer_instance, room_characters: room_characters) : sender_character&.full_name,
      room_name: room&.name,
      timestamp: display_timestamp&.iso8601,
      scene_id: scene_id,
      timeline_id: timeline_id,
      in_past_timeline: !timeline_id.nil?
    }
  end

  # Get the timestamp to display for this log entry
  # Uses logged_at (narrative time) when available, falls back to created_at
  # @return [Time, nil]
  def display_timestamp
    logged_at || created_at
  end

  # Check if this log entry is from a past timeline
  # @return [Boolean]
  def in_past_timeline?
    !timeline_id.nil?
  end

  # Validation
  def validate
    super
    errors.add(:content, 'cannot be empty') if StringHelper.blank?(content)
    errors.add(:character_instance_id, 'is required') unless character_instance_id
  end

  # Set content hash before create for deduplication
  def before_create
    super
    if content && character_instance_id
      self.content_hash ||= self.class.content_hash_for(
        content,
        character_instance_id,
        log_type: log_type,
        sender_character_id: sender_character_id,
        room_id: room_id,
        event_id: event_id
      )
    end
  end

  # Invalidate character story cache when new log is created
  def after_create
    super
    if character_instance&.character_id
      ChapterService.invalidate_cache(character_instance.character_id)
    end
  rescue StandardError => e
    warn "[RpLog] Cache invalidation failed: #{e.message}"
  end
end
