# frozen_string_literal: true

# WorldMemorySession tracks active RP sessions for eventual memory creation.
# Sessions accumulate IC messages and track participating characters/rooms.
class WorldMemorySession < Sequel::Model
  include StatusEnum

  plugin :validation_helpers
  plugin :timestamps

  many_to_one :room
  many_to_one :event
  many_to_one :parent_session, class: :WorldMemorySession, key: :parent_session_id
  one_to_many :child_sessions, class: :WorldMemorySession, key: :parent_session_id
  one_to_many :session_characters, class: :WorldMemorySessionCharacter, key: :session_id
  one_to_many :session_rooms, class: :WorldMemorySessionRoom, key: :session_id

  status_enum :status, %w[active finalizing finalized abandoned]
  MIN_MESSAGES_FOR_MEMORY = 5
  INACTIVITY_TIMEOUT_HOURS = 2

  def validate
    super
    validates_presence [:room_id, :started_at, :last_activity_at]
    validate_status_enum
  end

  def stale?
    return false unless active?

    hours_since_activity >= INACTIVITY_TIMEOUT_HOURS
  end

  def hours_since_activity
    (Time.now - last_activity_at) / 3600.0
  end

  def sufficient_for_memory?
    message_count >= MIN_MESSAGES_FOR_MEMORY
  end

  # ========================================
  # Character Tracking
  # ========================================

  # Count of currently active characters in session
  def active_character_count
    session_characters_dataset.where(is_active: true).count
  end

  # IDs of currently active characters
  def active_character_ids
    session_characters_dataset.where(is_active: true).select_map(:character_id)
  end

  # Add a character to this session
  # @param character [Character]
  def add_character!(character)
    existing = session_characters_dataset.where(character_id: character.id).first
    if existing
      existing.update(is_active: true, left_at: nil) unless existing.is_active
      existing
    else
      WorldMemorySessionCharacter.create(
        session_id: id,
        character_id: character.id,
        joined_at: Time.now,
        is_active: true
      )
    end
  end

  # Remove a character from this session (mark inactive)
  # @param character [Character]
  def remove_character!(character)
    sc = session_characters_dataset.where(character_id: character.id).first
    sc&.update(is_active: false, left_at: Time.now)
  end

  # Increment message count for a character
  # @param character [Character]
  def increment_character_messages!(character)
    sc = session_characters_dataset.where(character_id: character.id).first
    sc&.update(message_count: (sc.message_count || 0) + 1)
  end

  # ========================================
  # Room Tracking
  # ========================================

  # Add a room to this session's tracked rooms
  # @param room [Room]
  def add_room!(room)
    existing = session_rooms_dataset.where(room_id: room.id).first
    if existing
      existing.update(last_seen_at: Time.now)
      existing
    else
      WorldMemorySessionRoom.create(
        session_id: id,
        room_id: room.id,
        first_seen_at: Time.now,
        last_seen_at: Time.now
      )
    end
  end

  # Update activity timestamp for a room
  # @param room [Room]
  def update_room_activity!(room)
    sr = session_rooms_dataset.where(room_id: room.id).first
    sr&.update(message_count: (sr.message_count || 0) + 1, last_seen_at: Time.now)
  end

  # ========================================
  # Log Buffer Management
  # ========================================

  # Append content to the log buffer
  # @param content [String] The message content
  # @param sender_name [String] Display name of sender
  # @param type [Symbol] Message type
  # @param timestamp [Time]
  def append_log!(content, sender_name:, type:, timestamp: Time.now)
    return if has_private_content  # Skip if already marked private

    formatted = "[#{timestamp.strftime('%H:%M')}] #{sender_name} (#{type}): #{content}\n"
    new_buffer = (log_buffer || '') + formatted
    update(
      log_buffer: new_buffer,
      message_count: (message_count || 0) + 1,
      last_activity_at: Time.now
    )
  end

  # Mark this session as containing private content
  def mark_private!
    update(has_private_content: true, log_buffer: '[PRIVATE CONTENT EXCLUDED]')
  end

  # Update publicity level (track most restrictive)
  # @param level [String]
  def update_publicity!(level)
    merged = WorldMemory.more_restrictive_publicity(publicity_level, level)
    update(publicity_level: merged) if merged != publicity_level
  end

  # ========================================
  # Session Lifecycle
  # ========================================

  # Mark session as finalizing
  def finalize!
    update(status: 'finalizing', ended_at: Time.now)
  end

  # Mark session as finalized (memory created)
  def mark_finalized!
    update(status: 'finalized')
  end

  # Abandon session (no memory created)
  def abandon!
    update(status: 'abandoned', ended_at: Time.now)
  end

  # ========================================
  # Class Methods
  # ========================================

  class << self
    # Find active session for a room
    # @param room_id [Integer]
    # @return [WorldMemorySession, nil]
    def active_for_room(room_id)
      where(room_id: room_id, status: 'active').first
    end

    # Find active session for a room scoped to an event context.
    # Event-scoped RP should not be merged with non-event room traffic.
    # @param room_id [Integer]
    # @param event_id [Integer, nil]
    # @return [WorldMemorySession, nil]
    def active_for_room_context(room_id, event_id)
      where(room_id: room_id, status: 'active', event_id: event_id).first
    end

    # Get all stale sessions (inactive for 2+ hours)
    def stale_sessions
      cutoff = Time.now - (INACTIVITY_TIMEOUT_HOURS * 3600)
      where(status: 'active').where { last_activity_at < cutoff }
    end

    # Get sessions pending finalization
    def pending_finalization
      where(status: 'finalizing')
    end
  end
end
