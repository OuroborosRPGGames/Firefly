# frozen_string_literal: true

# NpcAnimationQueue - Queue for tracking NPC animation responses
#
# This model tracks NPC responses for rate limiting and history.
# Responses are processed immediately via async jobs - no artificial delays.
# The LLM API latency provides natural timing for responses.
#
# Trigger types:
#   - high_turn: High animation level NPC responding to any IC content
#   - medium_mention: Medium level NPC responding to being mentioned
#   - medium_rng: Medium level NPC responding based on RNG + relevance
#   - low_mention: Low level NPC responding to direct mention
#
# Status flow: pending -> processing -> complete/failed
# Note: 'pending' state is typically brief as async processing starts immediately
#
class NpcAnimationQueue < Sequel::Model
  include StatusEnum

  plugin :validation_helpers
  plugin :timestamps, update_on_create: true

  many_to_one :character_instance
  many_to_one :room

  # Valid trigger types
  TRIGGER_TYPES = %w[high_turn medium_mention medium_rng low_mention].freeze

  # Valid statuses
  status_enum :status, %w[pending processing complete failed]

  def validate
    super
    validates_presence %i[character_instance_id room_id trigger_type status]
    validates_includes TRIGGER_TYPES, :trigger_type
    validate_status_enum
  end

  def before_create
    super
    self.scheduled_at ||= Time.now
    self.priority ||= GameConfig::QueueManagement::DEFAULT_PRIORITY
  end

  # Mark as processing
  # @return [Boolean] false if record was already deleted
  def start_processing!
    # Atomic claim: only one worker can move pending -> processing.
    updated = this.where(status: 'pending').update(status: 'processing')
    return false unless updated == 1

    refresh
    true
  rescue Sequel::NoExistingObject
    # Record was deleted between reading and updating (e.g., during test cleanup)
    false
  rescue StandardError => e
    warn "[NpcAnimationQueue] Failed to start processing for ##{id}: #{e.message}"
    false
  end

  # Mark as complete with response
  # @return [Boolean] false if record was already deleted
  def complete!(response_text)
    update(
      status: 'complete',
      processed_at: Time.now,
      llm_response: response_text
    )
    true
  rescue Sequel::NoExistingObject
    # Record was deleted between reading and updating (e.g., during test cleanup)
    false
  end

  # Mark as failed with error
  # @return [Boolean] false if record was already deleted
  def fail!(error_message)
    update(
      status: 'failed',
      processed_at: Time.now,
      error_message: error_message
    )
    true
  rescue Sequel::NoExistingObject
    # Record was deleted between reading and updating (e.g., during test cleanup)
    false
  end

  # ============================================
  # Queue Management
  # ============================================

  # Get next items ready to process
  # @param limit [Integer] max items to return
  # @return [Array<NpcAnimationQueue>]
  def self.pending_ready(limit: GameConfig::QueueManagement::NPC_QUEUE_BATCH_SIZE)
    where(status: 'pending')
      .where { scheduled_at <= Time.now }
      .order(:priority, :scheduled_at)
      .limit(limit)
      .all
  end

  # Count pending items for a room (for rate limiting)
  # @param room_id [Integer]
  # @return [Integer]
  def self.pending_count_for_room(room_id)
    where(room_id: room_id, status: 'pending').count
  end

  # Count completed items in rate window for a room (for rate limiting)
  # @param room_id [Integer]
  # @return [Integer]
  def self.recent_complete_count_for_room(room_id)
    rate_window = GameConfig::QueueManagement::RATE_WINDOW_SECONDS
    where(room_id: room_id, status: 'complete')
      .where { processed_at > Time.now - rate_window }
      .count
  end

  # Clean up old completed/failed entries
  # @param older_than [Integer] seconds
  def self.cleanup_old_entries(older_than: GameConfig::QueueManagement::NPC_CLEANUP_SECONDS)
    where(status: %w[complete failed])
      .where { processed_at < Time.now - older_than }
      .delete
  end

  # Cancel pending entries for a character instance (e.g., when they leave room)
  # @param character_instance_id [Integer]
  def self.cancel_for_instance(character_instance_id)
    where(character_instance_id: character_instance_id, status: 'pending')
      .update(status: 'failed', error_message: 'Cancelled - character left room')
  end

  # ============================================
  # Factory Methods
  # ============================================

  # Queue a new response for tracking
  # Note: Responses are processed immediately via async jobs.
  # The delay_seconds parameter exists for fallback scheduler compatibility
  # but defaults to 0 since async processing starts immediately.
  # @param npc_instance [CharacterInstance]
  # @param trigger_type [String]
  # @param content [String] trigger content
  # @param source_id [Integer] character_instance_id that triggered
  # @param delay_seconds [Integer] delay (0 = immediate, default)
  # @param priority [Integer] lower = higher priority
  # @return [NpcAnimationQueue]
  def self.queue_response(npc_instance:, trigger_type:, content:, source_id: nil, delay_seconds: 0, priority: 5)
    create(
      character_instance_id: npc_instance.id,
      room_id: npc_instance.current_room_id,
      trigger_type: trigger_type,
      trigger_content: content,
      trigger_source_id: source_id,
      status: 'pending',
      scheduled_at: Time.now + delay_seconds,
      priority: priority
    )
  end
end
